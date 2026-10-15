import Foundation

nonisolated enum MuseAIUsageError: LocalizedError {
    case missingCookie
    case loginRequired
    case actionNotFound

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text("缺少 muse.ai Cookie 标头", "Missing muse.ai cookie header")
        case .loginRequired:
            AppLocalization.text("muse.ai 会话已过期，请重新登录", "The muse.ai session expired. Sign in again.")
        case .actionNotFound:
            AppLocalization.text(
                "未找到 muse.ai 订阅接口，请刷新后重试",
                "Could not find the muse.ai subscription action. Refresh to retry."
            )
        }
    }
}

nonisolated enum MuseAIUsageFetcher {
    private struct Subscription: Decodable {
        struct Usage: Decodable {
            let percentUsed: Double
            let resetsAt: Double?
        }
        struct Tier: Decodable { let name: String? }
        struct Agreement: Decodable { let currentPeriodEndTime: Double? }
        let usage: Usage
        let tier: Tier?
        let agreement: Agreement?
        let usageRowLabel: String?
        let usageRowValueLabel: String?
        let topupBalance: Double?
        let topupTotal: Double?
        let topupRowLabel: String?
        let topupRowValueLabel: String?
    }

    private struct FlightRow: Decodable {
        let success: Bool?
        let subscription: Subscription?
    }

    private static let origin = "https://muse.ai"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        cookieHeader: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let cookie = normalizedCookie(cookieHeader) else { throw MuseAIUsageError.missingCookie }
        let requestSession = URLSession(
            configuration: session.configuration,
            delegate: MuseAIRedirectGuard(),
            delegateQueue: nil
        )
        defer { requestSession.finishTasksAndInvalidate() }
        let actionID = try await discoverAction(cookie: cookie, session: requestSession)
        let (body, response) = try await request(
            path: "/", cookie: cookie, actionID: actionID, session: requestSession
        )
        if signedOut(response) { throw MuseAIUsageError.loginRequired }
        if response.statusCode == 404, body.localizedCaseInsensitiveContains("server action not found") {
            throw MuseAIUsageError.actionNotFound
        }
        guard response.statusCode == 200 else { throw UsageCollectionError.requestFailed(response.statusCode) }
        return try parse(body, now: now)
    }

    static func parse(_ body: String, now: Date = Date()) throws -> ProviderUsage {
        var subscription: Subscription?
        for line in body.components(separatedBy: .newlines) {
            guard let json = capture(#"^[0-9a-f]+:(\{.*\})\s*$"#, in: line),
                  let row = try? JSONDecoder().decode(FlightRow.self, from: Data(json.utf8)),
                  row.success == true
            else { continue }
            subscription = row.subscription
        }
        guard let subscription, subscription.usage.percentUsed.isFinite else {
            throw UsageCollectionError.unreadableResponse
        }
        var additionalWindows: [UsageWindow] = []
        if let balance = subscription.topupBalance, let total = subscription.topupTotal,
           balance.isFinite, total.isFinite, total > 0 {
            let value = tokensLeft(subscription.topupRowValueLabel) ?? subscription.topupRowValueLabel
                ?? AppLocalization.text(
                    "剩余 \(String(format: "$%.2f", balance / 1_000_000))",
                    "\(String(format: "$%.2f", balance / 1_000_000)) left"
                )
            additionalWindows.append(UsageWindow(
                id: "museai-topup",
                label: subscription.topupRowLabel ?? AppLocalization.text("额外 Token", "Additional tokens"),
                usedFraction: min(1, max(0, (total - balance) / total)),
                resetsAt: nil,
                detail: value
            ))
        }
        var details: [UsageDetail] = []
        if let renewal = date(subscription.agreement?.currentPeriodEndTime) {
            details.append(UsageDetail(
                id: "museai-renewal",
                label: AppLocalization.text("订阅续费时间", "Subscription renewal"),
                value: renewal.formatted(date: .abbreviated, time: .shortened)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "museai"),
            state: .ready,
            windows: [UsageWindow(
                id: "museai-weekly",
                label: AppLocalization.text("每周", "Weekly"),
                usedFraction: min(1, max(0, subscription.usage.percentUsed / 100)),
                resetsAt: date(subscription.usage.resetsAt),
                detail: tokensLeft(subscription.usageRowValueLabel)
            )],
            additionalWindows: additionalWindows,
            plan: subscription.tier?.name ?? subscription.usageRowLabel,
            details: details,
            updatedAt: now
        )
    }

    private static func discoverAction(cookie: String, session: URLSession) async throws -> String {
        let (page, response) = try await request(path: "/", cookie: cookie, session: session)
        if signedOut(response) { throw MuseAIUsageError.loginRequired }
        guard response.statusCode == 200 else { throw UsageCollectionError.requestFailed(response.statusCode) }
        let paths = Array(chunkPaths(page).prefix(96))
        var text = ""
        for start in stride(from: 0, to: paths.count, by: 8) {
            let batch = Array(paths[start..<min(start + 8, paths.count)])
            text += "\n" + (try await fetchChunks(batch, session: session)).joined(separator: "\n")
            guard text.utf8.count <= 8 * 1024 * 1024 else { throw MuseAIUsageError.actionNotFound }
            guard let module = capture(#"\.A\((\d+)\)\.then\(\(\{[^}]*Settings"#, in: text),
                  let loader = capture(
                    "[,\\{\\[]\(module),\\w+=>\\{\\w+\\.v\\(\\w+=>Promise\\.all\\(\\[([^\\]]*)",
                    in: text
                  )
            else { continue }
            let settingsPaths = Array(chunkPaths(loader).prefix(32))
            for offset in stride(from: 0, to: settingsPaths.count, by: 8) {
                let settingsBatch = Array(settingsPaths[offset..<min(offset + 8, settingsPaths.count)])
                for chunk in try await fetchChunks(settingsBatch, session: session) {
                    if let id = capture(#""([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction""#, in: chunk) {
                        return id
                    }
                }
            }
            break
        }
        throw MuseAIUsageError.actionNotFound
    }

    private static func fetchChunks(_ paths: [String], session: URLSession) async throws -> [String] {
        let chunks = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for path in paths {
                group.addTask {
                    guard let (body, response) = try? await request(path: path, session: session),
                          response.statusCode == 200
                    else { return "" }
                    return body
                }
            }
            var bodies: [String] = []
            for await body in group { bodies.append(body) }
            return bodies
        }
        try Task.checkCancellation()
        return chunks
    }

    private static func request(
        path: String,
        cookie: String? = nil,
        actionID: String? = nil,
        session: URLSession
    ) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: origin + path)!)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(path == "/" ? "text/html" : "*/*", forHTTPHeaderField: "Accept")
        if let actionID {
            request.httpMethod = "POST"
            request.httpBody = Data(#"[{"includeAgreement":true}]"#.utf8)
            request.setValue("text/x-component", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(actionID, forHTTPHeaderField: "Next-Action")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let body = String(data: data, encoding: .utf8) else {
            throw UsageCollectionError.unreadableResponse
        }
        return (body, http)
    }

    private static func signedOut(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
            || (response.value(forHTTPHeaderField: "Location") ?? "").hasPrefix("https://auth.muse.ai/")
    }

    private static func chunkPaths(_ body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"static/chunks/[\w~.-]+\.js"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let range = Range(match.range, in: body) else { return nil }
            let path = "/_next/" + body[range]
            return seen.insert(path).inserted ? path : nil
        }
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil,
              value.split(separator: ";").allSatisfy({ $0.contains("=") })
        else { return nil }
        return value
    }

    private static func tokensLeft(_ label: String?) -> String? {
        label.flatMap { capture(#"\(([^()]+ tokens left)\)"#, in: $0) }
    }

    private static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

private nonisolated final class MuseAIRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
