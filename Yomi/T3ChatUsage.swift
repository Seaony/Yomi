import Foundation
import SweetCookieKit

enum T3ChatUsageError: LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case vercelChallenge
    case requestFailed(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "未找到 T3 Chat 浏览器会话，请先登录 t3.chat",
                "No T3 Chat browser session was found. Sign in to t3.chat first."
            )
        case .sessionExpired:
            AppLocalization.text(
                "T3 Chat 会话无效或已过期",
                "The T3 Chat session is invalid or expired."
            )
        case .vercelChallenge:
            AppLocalization.text(
                "T3 Chat 返回了 Vercel 安全验证，请粘贴完整的浏览器 cURL 请求",
                "T3 Chat returned a Vercel security challenge. Paste the full browser cURL request."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "T3 Chat 用量请求失败（HTTP \(status)）",
                "T3 Chat usage request failed (HTTP \(status))"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 T3 Chat 用量：\(message)",
                "Could not parse T3 Chat usage: \(message)"
            )
        }
    }
}

nonisolated enum T3ChatUsageFetcher {
    struct Subscription: Decodable, Sendable, Equatable {
        let productId: String?
        let productName: String?
        let status: String?
        let currentPeriodStart: TimeInterval?
        let currentPeriodEnd: TimeInterval?
        let canceledAt: TimeInterval?
        let trialEndsAt: TimeInterval?
    }

    struct CustomerData: Decodable, Sendable, Equatable {
        let subTier: String?
        let subscription: Subscription?
        let lifetimeBalance: Double?
        let usageBand: String?
        let billingNextResetAt: TimeInterval?
        let usageFourHourPercentage: Double?
        let usageMonthPercentage: Double?
        let usageFourHourNextResetAt: TimeInterval?
        let usagePeriodPercentage: Double?
        let usageWindowNextResetAt: TimeInterval?

        var planName: String? {
            let raw = subscription?.productName ?? subTier
            guard let raw = cleaned(raw) else { return nil }
            return raw.split(separator: "-").map { part in
                part.prefix(1).uppercased() + String(part.dropFirst())
            }.joined(separator: " ")
        }
    }

    struct Snapshot: Sendable, Equatable {
        let customerData: CustomerData
        let updatedAt: Date

        func toProviderUsage() -> ProviderUsage {
            let baseReset = T3ChatUsageFetcher.date(fromEpoch: customerData.usageFourHourNextResetAt)
                ?? T3ChatUsageFetcher.date(fromEpoch: customerData.usageWindowNextResetAt)
            let overageReset = T3ChatUsageFetcher.date(fromEpoch: customerData.subscription?.currentPeriodEnd)
            let baseLabel: String
            if let band = T3ChatUsageFetcher.cleaned(customerData.usageBand) {
                baseLabel = "Base - \(band)"
            } else {
                baseLabel = "Base"
            }
            return ProviderUsage(
                id: ProviderID(rawValue: "t3chat"),
                state: .ready,
                windows: [
                    UsageWindow(
                        id: "t3chat-base",
                        label: baseLabel,
                        usedFraction: T3ChatUsageFetcher.percent(customerData.usageFourHourPercentage) / 100,
                        resetsAt: baseReset,
                        detail: nil
                    ),
                    UsageWindow(
                        id: "t3chat-overage",
                        label: "Overage",
                        usedFraction: T3ChatUsageFetcher.percent(
                            customerData.usageMonthPercentage ?? customerData.usagePeriodPercentage
                        ) / 100,
                        resetsAt: overageReset,
                        detail: nil
                    ),
                ],
                balance: nil,
                plan: customerData.planName,
                updatedAt: updatedAt,
                message: nil
            )
        }
    }

    struct RequestContext: Sendable, Equatable {
        let cookieHeader: String
        let headers: [String: String]
    }

    private static let browserDomains = ["t3.chat", "www.t3.chat"]
    private static let endpoint = "https://t3.chat/api/trpc/getCustomerData"
    private static let input = #"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#
    private static let forwardedHeaders = [
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "cache-control": "Cache-Control",
        "pragma": "Pragma",
        "priority": "Priority",
        "referer": "Referer",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
        "trpc-accept": "trpc-accept",
        "user-agent": "User-Agent",
        "x-client-context": "x-client-context",
        "x-deployment-id": "X-Deployment-Id",
        "x-trpc-batch": "x-trpc-batch",
        "x-trpc-source": "x-trpc-source",
    ]

    static func fetch(
        cookieHeaderOverride: String?,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let context: RequestContext
        switch source {
        case .cookie:
            guard let override = requestContext(from: cookieHeaderOverride) else {
                throw T3ChatUsageError.missingSession
            }
            context = override
        case .automatic, .account:
            guard let cookie = automaticCookie() else { throw T3ChatUsageError.missingSession }
            context = RequestContext(cookieHeader: cookie, headers: [:])
        case .token, .command, .endpoint:
            throw UsageCollectionError.missingCredential
        }
        return try await fetchCustomerData(context: context, session: session, now: now).toProviderUsage()
    }

    static func fetchCustomerData(
        context: RequestContext,
        session: URLSession,
        now: Date = Date()
    ) async throws -> Snapshot {
        guard let cookie = normalizeCookie(context.cookieHeader) else {
            throw T3ChatUsageError.missingSession
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: input),
        ]
        guard let url = components?.url else {
            throw T3ChatUsageError.parseFailed("Invalid customer data URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/jsonl", forHTTPHeaderField: "trpc-accept")
        request.setValue("web-client", forHTTPHeaderField: "x-trpc-source")
        request.setValue("true", forHTTPHeaderField: "x-trpc-batch")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://t3.chat/settings/customization", forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("u=4", forHTTPHeaderField: "Priority")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("https://t3.chat", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3ChatUsageError.parseFailed("Response was not HTTP.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw T3ChatUsageError.sessionExpired
            }
            if http.statusCode == 429,
               http.value(forHTTPHeaderField: "x-vercel-mitigated") == "challenge" {
                throw T3ChatUsageError.vercelChallenge
            }
            throw T3ChatUsageError.requestFailed(http.statusCode)
        }
        return try parseJSONLines(data, now: now)
    }

    static func parseJSONLines(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw T3ChatUsageError.parseFailed("Response is not UTF-8.")
        }
        return try parseJSONLines(text, now: now)
    }

    static func parseJSONLines(_ text: String, now: Date = Date()) throws -> Snapshot {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let customerObject = findCustomerData(in: object)
            else { continue }
            do {
                let encoded = try JSONSerialization.data(withJSONObject: customerObject)
                let customerData = try JSONDecoder().decode(CustomerData.self, from: encoded)
                return Snapshot(customerData: customerData, updatedAt: now)
            } catch {
                throw T3ChatUsageError.parseFailed(error.localizedDescription)
            }
        }
        throw T3ChatUsageError.parseFailed("Missing customer data object.")
    }

    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = cleaned(raw) else { return nil }
        let fields = headerFields(from: raw)
        let capturedCookie = headerValue(named: "Cookie", in: fields)
        guard let cookie = normalizeCookie(capturedCookie ?? raw) else { return nil }
        var headers: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let name = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = forwardedHeaders[name.lowercased()], !value.isEmpty else { continue }
            headers[canonical] = value
        }
        return RequestContext(cookieHeader: cookie, headers: headers)
    }

    static func normalizeCookie(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        let fields = headerFields(from: value)
        if let captured = headerValue(named: "Cookie", in: fields) {
            value = captured
        } else if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        let pairs = value.split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { return nil }
            return pair
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    static func automaticCookie() -> String? {
        let query = BrowserCookieQuery(domains: browserDomains)
        let client = BrowserCookieClient()
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources where !source.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard !cookies.isEmpty else { continue }
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return nil
    }

    static func date(fromEpoch raw: TimeInterval?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    private static func percent(_ raw: Double?) -> Double {
        min(100, max(0, raw ?? 0))
    }

    private static func findCustomerData(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["usageFourHourPercentage"] != nil
                || dictionary["usageMonthPercentage"] != nil
                || dictionary["subscription"] != nil && dictionary["usageBand"] != nil {
                return dictionary
            }
            for value in dictionary.values {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        return nil
    }

    private static func headerFields(from raw: String) -> [String] {
        let pattern =
            #"(?s)(?:^|\s)(?:-H|--header)(?:\s+|=|(?=['"$]))"#
                + #"(?:\$'((?:\\.|[^'])*)'|'([^']*)'|"((?:\\.|[^"])*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.matches(in: raw, range: range).compactMap { match in
            if let value = capture(1, match: match, raw: raw) {
                return unescapeShell(value, ansi: true)
            }
            if let value = capture(2, match: match, raw: raw) { return value }
            if let value = capture(3, match: match, raw: raw) {
                return unescapeShell(value, ansi: false)
            }
            if let value = capture(4, match: match, raw: raw) {
                return unescapeShell(value, ansi: false)
            }
            return nil
        }
    }

    private static func headerValue(named name: String, in fields: [String]) -> String? {
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let fieldName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fieldName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func capture(_ index: Int, match: NSTextCheckingResult, raw: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: raw)
        else { return nil }
        return String(raw[range])
    }

    private static func unescapeShell(_ raw: String, ansi: Bool) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "\\" else {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let next = raw.index(after: index)
            guard next < raw.endIndex else { return output }
            switch raw[next] {
            case "n" where ansi: output.append("\n")
            case "r" where ansi: output.append("\r")
            case "t" where ansi: output.append("\t")
            case "\n": break
            default: output.append(raw[next])
            }
            index = raw.index(after: next)
        }
        return output
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
