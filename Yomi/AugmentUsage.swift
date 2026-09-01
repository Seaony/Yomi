import Foundation
import SweetCookieKit

enum AugmentUsageError: LocalizedError, Equatable {
    case cliUnavailable
    case cliNotAuthenticated
    case cliOutputMissing
    case cliTimedOut
    case missingSession
    case sessionExpired
    case requestFailed(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            AppLocalization.text("未找到 Auggie 命令行工具", "Auggie command line tool was not found")
        case .cliNotAuthenticated:
            AppLocalization.text("Auggie 尚未登录", "Auggie is not authenticated")
        case .cliOutputMissing:
            AppLocalization.text("Auggie 未返回账号用量", "Auggie returned no account usage")
        case .cliTimedOut:
            AppLocalization.text("Auggie 用量命令超时", "Auggie usage command timed out")
        case .missingSession:
            AppLocalization.text("未找到 Augment 浏览器会话", "Augment browser session was not found")
        case .sessionExpired:
            AppLocalization.text("Augment 会话已过期，请重新登录", "Augment session has expired. Sign in again.")
        case let .requestFailed(status):
            AppLocalization.text("Augment 用量请求失败（HTTP \(status)）", "Augment usage request failed (HTTP \(status))")
        case .parseFailed:
            AppLocalization.text("无法解析 Augment 用量", "Failed to parse Augment usage")
        }
    }
}

nonisolated enum AugmentUsageFetcher {
    struct Credits: Decodable, Sendable, Equatable {
        let usageUnitsRemaining: Double?
        let usageUnitsConsumedThisBillingCycle: Double?
        let usageUnitsAvailable: Double?
        let usageBalanceStatus: String?
    }

    struct Subscription: Decodable, Sendable, Equatable {
        let planName: String?
        let billingPeriodEnd: String?
        let email: String?
        let organization: String?
    }

    struct Snapshot: Sendable, Equatable {
        let remaining: Double
        let used: Double
        let limit: Double
        let resetsAt: Date?
        let email: String?
        let organization: String?
        let plan: String?
    }

    private static let baseURL = URL(string: "https://app.augmentcode.com")!
    private static let sessionCookieNames: Set<String> = [
        "session", "_session", "web_rpc_proxy_session", "auth0", "auth0.is.authenticated",
        "a0.spajs.txs", "__Secure-next-auth.session-token", "next-auth.session-token",
        "__Secure-authjs.session-token", "__Host-authjs.csrf-token", "authjs.session-token",
    ]
    private static let browserOrder: [Browser] = [
        .safari, .chrome, .chromeBeta, .chromeCanary, .edge, .edgeBeta,
        .brave, .arc, .dia, .arcBeta, .firefox,
    ]

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        switch source {
        case .account:
            return providerUsage(try await fetchCLI(environment: environment), now: now)
        case .cookie:
            guard let cookie = normalizedCookie(rawCredential) ?? automaticCookie() else {
                throw AugmentUsageError.missingSession
            }
            return providerUsage(try await fetchWeb(cookie: cookie, session: session), now: now)
        case .automatic:
            if executable(environment: environment) != nil,
               let snapshot = try? await fetchCLI(environment: environment) {
                return providerUsage(snapshot, now: now)
            }
            guard let cookie = normalizedCookie(rawCredential) ?? automaticCookie() else {
                throw AugmentUsageError.missingSession
            }
            return providerUsage(try await fetchWeb(cookie: cookie, session: session), now: now)
        case .token, .command, .endpoint:
            throw UsageCollectionError.missingCredential
        }
    }

    static func parseCLI(_ output: String, timeZone: TimeZone = .current) throws -> Snapshot {
        if output.contains("Authentication failed") || output.contains("auggie login") {
            throw AugmentUsageError.cliNotAuthenticated
        }
        var remaining: Double?
        var used: Double?
        var total: Double?
        var monthlyMaximum: Double?
        var end: Date?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = captureNumber(#"([\d,]+)\s+credits\s*/\s*month"#, in: line) {
                monthlyMaximum = value
                total = total ?? value
            }
            if line.contains("credits remaining"),
               let value = captureNumber(#"([\d,]+)\s+credits\s+remaining"#, in: line) {
                remaining = value
            }
            if line.contains("remaining"), line.contains("credits used") {
                remaining = captureNumber(#"([\d,]+)\s+remaining"#, in: line) ?? remaining
                if let values = captures(#"([\d,]+)\s*/\s*([\d,]+)\s+credits used"#, in: line),
                   values.count == 2 {
                    used = number(values[0])
                    total = number(values[1])
                }
            }
            if let values = captures(#"ends\s+([\d/]+)"#, in: line), let value = values.first {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d/yyyy"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                end = formatter.date(from: value)
            }
        }
        guard let remaining, let total = total ?? monthlyMaximum else { throw AugmentUsageError.parseFailed }
        return Snapshot(
            remaining: remaining,
            used: used ?? max(0, total - remaining),
            limit: total,
            resetsAt: end,
            email: nil,
            organization: nil,
            plan: nil
        )
    }

    static func parseWeb(creditsData: Data, subscriptionData: Data?) throws -> Snapshot {
        let credits = try JSONDecoder().decode(Credits.self, from: creditsData)
        let subscription = subscriptionData.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        let limit: Double?
        if let available = credits.usageUnitsAvailable, available > 0 {
            limit = available
        } else if let remaining = credits.usageUnitsRemaining,
                  let consumed = credits.usageUnitsConsumedThisBillingCycle {
            limit = remaining + consumed
        } else {
            limit = nil
        }
        guard let limit, limit >= 0 else { throw AugmentUsageError.parseFailed }
        let remaining = max(0, credits.usageUnitsRemaining ?? max(0, limit - (credits.usageUnitsConsumedThisBillingCycle ?? 0)))
        let used = max(0, credits.usageUnitsConsumedThisBillingCycle ?? max(0, limit - remaining))
        return Snapshot(
            remaining: remaining,
            used: used,
            limit: limit,
            resetsAt: parseDate(subscription?.billingPeriodEnd),
            email: cleaned(subscription?.email),
            organization: cleaned(subscription?.organization),
            plan: cleaned(subscription?.planName)
        )
    }

    static func providerUsage(_ snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        let usedFraction = snapshot.limit > 0 ? min(1, max(0, snapshot.used / snapshot.limit)) : 1
        return ProviderUsage(
            id: ProviderID(rawValue: "augment"),
            state: .ready,
            windows: [UsageWindow(
                id: "augment-credits",
                label: "Credits",
                usedFraction: usedFraction,
                resetsAt: snapshot.resetsAt,
                detail: "\(compact(snapshot.used))/\(compact(snapshot.limit)) credits"
            )],
            balance: compact(snapshot.remaining) + " credits",
            plan: snapshot.plan,
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        let patterns = [#"(?i)-H\s*'Cookie:\s*([^']+)'"#, #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
                        #"(?i)Cookie:\s*([^\r\n]+)"#]
        for pattern in patterns {
            if let captured = captures(pattern, in: value)?.first { value = captured; break }
        }
        let pairs = value.split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { return nil }
            return pair
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    static func automaticCookie() -> String? {
        let query = BrowserCookieQuery(domains: ["augmentcode.com", "app.augmentcode.com"])
        let client = BrowserCookieClient()
        for browser in browserOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard cookies.contains(where: { sessionCookieNames.contains($0.name) }) else { continue }
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return nil
    }

    static func executable(environment: [String: String]) -> URL? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent("auggie")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static func fetchCLI(environment: [String: String]) async throws -> Snapshot {
        guard let executable = executable(environment: environment) else { throw AugmentUsageError.cliUnavailable }
        let output = try await runCLI(executable: executable, environment: environment)
        return try parseCLI(output)
    }

    private static func runCLI(executable: URL, environment: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["account", "status"]
                process.environment = environment
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: AugmentUsageError.cliTimedOut)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    continuation.resume(throwing: AugmentUsageError.cliOutputMissing)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func fetchWeb(cookie: String, session: URLSession) async throws -> Snapshot {
        let credits = try await request(path: "api/credits", cookie: cookie, required: true, session: session)
        let subscription = try? await request(path: "api/subscription", cookie: cookie, required: false, session: session)
        return try parseWeb(creditsData: credits, subscriptionData: subscription)
    }

    private static func request(
        path: String,
        cookie: String,
        required: Bool,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AugmentUsageError.parseFailed }
        if http.statusCode == 401 { throw AugmentUsageError.sessionExpired }
        if http.statusCode == 403, required { throw AugmentUsageError.requestFailed(403) }
        guard http.statusCode == 200 else { throw AugmentUsageError.requestFailed(http.statusCode) }
        return data
    }

    private static func captureNumber(_ pattern: String, in text: String) -> Double? {
        captures(pattern, in: text)?.first.flatMap(number)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func compact(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
