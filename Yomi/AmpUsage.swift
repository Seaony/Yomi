import Foundation
import SweetCookieKit

enum AmpUsageError: LocalizedError, Equatable {
    case cliUnavailable
    case cliFailed(String)
    case cliTimedOut
    case notLoggedIn
    case missingAPIToken
    case invalidAPIToken
    case missingSession
    case sessionExpired
    case requestFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            AppLocalization.text("未找到 Amp 命令行工具", "Amp command line tool was not found")
        case let .cliFailed(message):
            AppLocalization.text("Amp 命令执行失败：\(message)", "Amp command failed: \(message)")
        case .cliTimedOut:
            AppLocalization.text("Amp 用量命令超时", "Amp usage command timed out")
        case .notLoggedIn:
            AppLocalization.text("尚未登录 Amp", "Not signed in to Amp")
        case .missingAPIToken:
            AppLocalization.text("未配置 Amp 访问令牌", "Amp access token is not configured")
        case .invalidAPIToken:
            AppLocalization.text("Amp 访问令牌无效或已过期", "Amp access token is invalid or expired")
        case .missingSession:
            AppLocalization.text("未找到 Amp 浏览器会话", "Amp browser session was not found")
        case .sessionExpired:
            AppLocalization.text("Amp 会话已过期，请重新登录", "Amp session has expired. Sign in again.")
        case let .requestFailed(message):
            AppLocalization.text("Amp 用量请求失败：\(message)", "Amp usage request failed: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Amp 用量：\(message)", "Failed to parse Amp usage: \(message)")
        }
    }
}

nonisolated enum AmpUsageFetcher {
    struct WorkspaceBalance: Sendable, Equatable {
        let name: String
        let remaining: Double
    }

    struct Subscription: Sendable, Equatable {
        let plan: String
        let otherUsedFraction: Double
        let orbUsedFraction: Double
        let resetsAt: Date
        let resetDescription: String
    }

    struct Snapshot: Sendable, Equatable {
        let freeQuota: Double?
        let freeUsed: Double?
        let hourlyReplenishment: Double?
        let windowHours: Double?
        let freeResetDescription: String?
        let individualCredits: Double?
        let workspaceBalances: [WorkspaceBalance]
        let accountEmail: String?
        let accountOrganization: String?
        let subscription: Subscription?
    }

    private struct FreeUsage {
        let quota: Double
        let used: Double
        let hourlyReplenishment: Double
        let windowHours: Double?
        let resetDescription: String?
    }

    private struct UsageAPIResponse: Decodable {
        let ok: Bool
        let result: Result?
        let error: APIError?

        struct Result: Decodable { let displayText: String }
        struct APIError: Decodable {
            let code: String?
            let message: String?
        }
    }

    static let usageURL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
    static let settingsURL = URL(string: "https://ampcode.com/settings")!
    private static let browserOrder: [Browser] = Browser.defaultImportOrder

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        switch source {
        case .account:
            return providerUsage(try await fetchCLI(environment: environment, now: now), now: now)
        case .token:
            guard let token = resolvedAPIToken(configured: rawCredential, environment: environment) else {
                throw AmpUsageError.missingAPIToken
            }
            return providerUsage(try await fetchAPI(token: token, session: session, now: now), now: now)
        case .cookie:
            guard let cookie = sessionCookieHeader(rawCredential) ?? automaticCookie() else {
                throw AmpUsageError.missingSession
            }
            return providerUsage(try await fetchWeb(cookie: cookie, session: session), now: now)
        case .automatic:
            if executable(environment: environment) != nil {
                do {
                    return providerUsage(try await fetchCLI(environment: environment, now: now), now: now)
                } catch {
                    if isCancellation(error) { throw error }
                }
            }
            if let token = resolvedAPIToken(configured: rawCredential, environment: environment) {
                do {
                    return providerUsage(try await fetchAPI(token: token, session: session, now: now), now: now)
                } catch {
                    if isCancellation(error) { throw error }
                }
            }
            guard let cookie = sessionCookieHeader(rawCredential) ?? automaticCookie() else {
                throw AmpUsageError.missingSession
            }
            return providerUsage(try await fetchWeb(cookie: cookie, session: session), now: now)
        case .command, .endpoint:
            throw UsageCollectionError.missingCredential
        }
    }

    static func parseDisplayText(_ displayText: String, now: Date = Date()) throws -> Snapshot {
        let text = stripANSICodes(displayText).replacingOccurrences(of: "**", with: "")
        let identity = captures(
            #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#,
            in: text
        )
        if identity == nil, looksSignedOut(text) { throw AmpUsageError.notLoggedIn }

        let amount = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        let legacyFreePattern = #"(?im)^\s*Amp Free:\s*\$?"# + amount
            + #"\s*/\s*\$?"# + amount
            + #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amount + #"\s*/\s*hour\))?"#
        let dailyFreePattern = #"(?im)^\s*Amp Free:\s*"# + amount
            + #"\s*%\s+remaining(?:\s+today)?(?:\s*(\(resets\s+daily\)))?"#
        let creditsPattern = #"(?im)^\s*Individual credits:\s*\$?"# + amount + #"\s+remaining"#
        let workspacePattern = #"(?im)^\s*Workspace\s+(.+?):\s*\$?"# + amount + #"\s+remaining"#
        let subscriptionSuffix = #"\s*"# + amount
            + #"\s*%\s+other\s+usage\s+and\s+"# + amount
            + #"\s*%\s+orb\s+usage\s+remaining\s*-\s*resets\s+upon\s+renewal\s+in\s+"#
            + #"([0-9][0-9,]*)\s+(days?|months?)(?:\s+-\s+https?://\S+)?\s*$"#
        let subscriptionPatterns = [
            #"(?im)^\s*Subscription\s+(.+?):"# + subscriptionSuffix,
            #"(?im)^\s*Amp\s+(.+?)\s+Subscription:"# + subscriptionSuffix,
        ]

        let legacyFree: FreeUsage? = {
            guard let fields = captures(legacyFreePattern, in: text),
                  let remaining = number(fields[0]), let quota = number(fields[1]) else { return nil }
            let hourly = number(fields[2]) ?? 0
            return FreeUsage(
                quota: quota,
                used: max(0, quota - remaining),
                hourlyReplenishment: hourly,
                windowHours: hourly > 0 ? max(1, (quota / hourly).rounded()) : nil,
                resetDescription: nil
            )
        }()
        let dailyFree: FreeUsage? = {
            guard let fields = captures(dailyFreePattern, in: text), let remaining = number(fields[0]) else {
                return nil
            }
            let clampedRemaining = min(100, max(0, remaining))
            return FreeUsage(
                quota: 100,
                used: 100 - clampedRemaining,
                hourlyReplenishment: 0,
                windowHours: 24,
                resetDescription: nonEmpty(fields[1]).map { _ in "resets daily" }
            )
        }()
        let free = legacyFree ?? dailyFree
        let individualCredits = captures(creditsPattern, in: text)?.first.flatMap(number)
        let workspaces = allCaptures(workspacePattern, in: text).compactMap { fields -> WorkspaceBalance? in
            guard fields.count == 2, let name = nonEmpty(fields[0]), let remaining = number(fields[1]) else {
                return nil
            }
            return WorkspaceBalance(name: name, remaining: remaining)
        }
        let subscription: Subscription? = {
            guard let fields = subscriptionPatterns.lazy.compactMap({ captures($0, in: text) }).first,
                  fields.count == 5,
                  let plan = nonEmpty(fields[0]),
                  let otherRemaining = number(fields[1]),
                  let orbRemaining = number(fields[2]),
                  let renewalValue = Int(fields[3].replacingOccurrences(of: ",", with: "")),
                  let resetsAt = subscriptionResetDate(value: renewalValue, unit: fields[4], now: now)
            else { return nil }
            let singular = fields[4].lowercased().hasPrefix("month") ? "month" : "day"
            return Subscription(
                plan: plan,
                otherUsedFraction: (100 - min(100, max(0, otherRemaining))) / 100,
                orbUsedFraction: (100 - min(100, max(0, orbRemaining))) / 100,
                resetsAt: resetsAt,
                resetDescription: "renews in \(renewalValue) \(singular)\(renewalValue == 1 ? "" : "s")"
            )
        }()

        guard free != nil || subscription != nil || individualCredits != nil || !workspaces.isEmpty else {
            throw AmpUsageError.parseFailed("Missing Amp usage data")
        }
        return Snapshot(
            freeQuota: free?.quota,
            freeUsed: free?.used,
            hourlyReplenishment: free?.hourlyReplenishment,
            windowHours: free?.windowHours,
            freeResetDescription: free?.resetDescription,
            individualCredits: individualCredits,
            workspaceBalances: workspaces,
            accountEmail: nonEmpty(identity?[0]),
            accountOrganization: nonEmpty(identity?[1]),
            subscription: subscription
        )
    }

    static func parseLegacyHTML(_ html: String) throws -> Snapshot {
        guard let free = parseFreeTierUsage(html) else {
            if looksSignedOut(html) { throw AmpUsageError.notLoggedIn }
            throw AmpUsageError.parseFailed("Missing Amp Free usage data")
        }
        return Snapshot(
            freeQuota: free.quota,
            freeUsed: free.used,
            hourlyReplenishment: free.hourlyReplenishment,
            windowHours: free.windowHours,
            freeResetDescription: nil,
            individualCredits: nil,
            workspaceBalances: [],
            accountEmail: nil,
            accountOrganization: nil,
            subscription: nil
        )
    }

    static func parseAPIResponse(_ data: Data, now: Date = Date()) throws -> Snapshot {
        let response: UsageAPIResponse
        do {
            response = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        } catch {
            throw AmpUsageError.parseFailed("Invalid Amp usage API response")
        }
        guard response.ok else {
            if response.error?.code == "auth-required" { throw AmpUsageError.invalidAPIToken }
            throw AmpUsageError.requestFailed(response.error?.message ?? "Amp usage API returned an error")
        }
        guard let text = response.result?.displayText, !text.isEmpty else {
            throw AmpUsageError.parseFailed("Missing Amp usage display text")
        }
        return try parseDisplayText(text, now: now)
    }

    static func providerUsage(_ snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        var primary: [UsageWindow] = []
        var additional: [UsageWindow] = []
        if let subscription = snapshot.subscription {
            primary = [
                UsageWindow(
                    id: "amp-other",
                    label: "Other usage",
                    usedFraction: subscription.otherUsedFraction,
                    resetsAt: subscription.resetsAt,
                    detail: nil
                ),
                UsageWindow(
                    id: "amp-orb",
                    label: "Orb usage",
                    usedFraction: subscription.orbUsedFraction,
                    resetsAt: subscription.resetsAt,
                    detail: nil
                ),
            ]
        }
        if let freeWindow = freeWindow(snapshot, now: now) {
            if snapshot.subscription == nil { primary = [freeWindow] }
            else { additional = [freeWindow] }
        }
        var details: [UsageDetail] = []
        if let credits = snapshot.individualCredits {
            details.append(UsageDetail(
                id: "amp-individual-credits",
                label: "Individual credits",
                value: usd(credits)
            ))
        }
        details.append(contentsOf: snapshot.workspaceBalances.enumerated().map { index, workspace in
            UsageDetail(
                id: "amp-workspace-\(index)",
                label: snapshot.workspaceBalances.count == 1
                    ? "Workspace credits"
                    : "Workspace credits \(index + 1)",
                value: usd(workspace.remaining)
            )
        })
        return ProviderUsage(
            id: ProviderID(rawValue: "amp"),
            state: .ready,
            windows: primary,
            additionalWindows: additional,
            plan: snapshot.subscription?.plan,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    static func makeAPIRequest(token: String) throws -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": "userDisplayBalanceInfo",
            "params": [:],
        ])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func makeWebRequest(cookie: String) -> URLRequest {
        var request = URLRequest(url: settingsURL)
        request.timeoutInterval = 18
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://ampcode.com", forHTTPHeaderField: "Origin")
        request.setValue(settingsURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    static func sessionCookieHeader(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)Cookie:\s*([^\r\n]+)"#,
        ]
        for pattern in patterns {
            if let captured = captures(pattern, in: value)?.first {
                value = captured
                break
            }
        }
        let sessions = value.split(separator: ";").compactMap { rawPair -> String? in
            let pair = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == "session" else { return nil }
            let cookieValue = pair[pair.index(after: separator)...]
            return cookieValue.isEmpty ? nil : "session=\(cookieValue)"
        }
        return sessions.isEmpty ? nil : sessions.joined(separator: "; ")
    }

    static func shouldAttachCookie(to url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https" else { return false }
        return isAmpHost(url)
    }

    static func isLoginRedirect(_ url: URL?) -> Bool {
        guard isAmpHost(url), let url else { return false }
        if url.host?.lowercased() == "auth.ampcode.com" { return true }
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        if parts.contains("login") || parts.contains("signin") || parts.contains("sign-in") { return true }
        guard parts.contains("auth") else { return false }
        let query = url.query?.lowercased() ?? ""
        return query.contains("returnto=") || query.contains("redirect=") || query.contains("redirectto=")
    }

    static func executable(environment: [String: String]) -> URL? {
        if let override = cleaned(environment["AMP_CLI_PATH"]) {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let home = cleaned(environment["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin", "\(home)/.amp/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("amp")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static func fetchCLI(environment: [String: String], now: Date) async throws -> Snapshot {
        guard let executable = executable(environment: environment) else { throw AmpUsageError.cliUnavailable }
        return try parseDisplayText(
            try await runCLI(executable: executable, environment: environment),
            now: now
        )
    }

    private static func runCLI(executable: URL, environment: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = ["usage"]
                var commandEnvironment = environment
                commandEnvironment["NO_COLOR"] = "1"
                process.environment = commandEnvironment
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: AmpUsageError.cliTimedOut)
                    return
                }
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: AmpUsageError.cliFailed(
                        text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: AmpUsageError.parseFailed("The Amp CLI returned no usage data"))
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func fetchAPI(token: String, session: URLSession, now: Date) async throws -> Snapshot {
        let (data, response) = try await session.data(
            for: makeAPIRequest(token: token),
            delegate: APIRedirectDelegate()
        )
        guard let http = response as? HTTPURLResponse else {
            throw AmpUsageError.parseFailed("Invalid Amp usage API response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AmpUsageError.invalidAPIToken }
        guard http.statusCode == 200 else { throw AmpUsageError.requestFailed("HTTP \(http.statusCode)") }
        return try parseAPIResponse(data, now: now)
    }

    private static func fetchWeb(cookie: String, session: URLSession) async throws -> Snapshot {
        let redirectDelegate = WebRedirectDelegate(cookie: cookie)
        let (data, response) = try await session.data(
            for: makeWebRequest(cookie: cookie),
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw AmpUsageError.parseFailed("Invalid Amp settings response")
        }
        if http.statusCode == 401 || http.statusCode == 403
            || redirectDelegate.detectedLoginRedirect || isLoginRedirect(http.url) {
            throw AmpUsageError.sessionExpired
        }
        guard http.statusCode == 200 else { throw AmpUsageError.requestFailed("HTTP \(http.statusCode)") }
        return try parseLegacyHTML(String(data: data, encoding: .utf8) ?? "")
    }

    private final class APIRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private final class WebRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let cookie: String
        private(set) var detectedLoginRedirect = false

        init(cookie: String) {
            self.cookie = cookie
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if AmpUsageFetcher.isLoginRedirect(request.url) {
                detectedLoginRedirect = true
                completionHandler(nil)
                return
            }
            var redirected = request
            if AmpUsageFetcher.shouldAttachCookie(to: request.url) {
                redirected.setValue(cookie, forHTTPHeaderField: "Cookie")
            } else {
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            redirected.setValue(response.url?.absoluteString, forHTTPHeaderField: "Referer")
            completionHandler(redirected)
        }
    }

    private static func freeWindow(_ snapshot: Snapshot, now: Date) -> UsageWindow? {
        guard let quota = snapshot.freeQuota, let used = snapshot.freeUsed else { return nil }
        let fraction = quota > 0 ? min(1, max(0, used / quota)) : 0
        let reset: Date? = {
            if snapshot.freeResetDescription == "resets daily" { return nextDailyReset(after: now) }
            guard quota > 0, let hourly = snapshot.hourlyReplenishment, hourly > 0 else { return nil }
            return now.addingTimeInterval(max(0, used / hourly) * 3600)
        }()
        return UsageWindow(
            id: "amp-free",
            label: "Amp Free",
            usedFraction: fraction,
            resetsAt: reset,
            detail: nil
        )
    }

    private static func parseFreeTierUsage(_ html: String) -> FreeUsage? {
        for token in ["freeTierUsage", "getFreeTierUsage"] {
            guard let object = extractObject(named: token, in: html),
                  let quota = keyedNumber("quota", in: object),
                  let used = keyedNumber("used", in: object),
                  let hourly = keyedNumber("hourlyReplenishment", in: object) else { continue }
            return FreeUsage(
                quota: quota,
                used: used,
                hourlyReplenishment: hourly,
                windowHours: keyedNumber("windowHours", in: object),
                resetDescription: nil
            )
        }
        return nil
    }

    private static func extractObject(named token: String, in text: String) -> String? {
        guard let tokenRange = text.range(of: token),
              let start = text[tokenRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func keyedNumber(_ key: String, in text: String) -> Double? {
        captures("\\b\(NSRegularExpression.escapedPattern(for: key))\\b\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)", in: text)?
            .first.flatMap(number)
    }

    private static func subscriptionResetDate(value: Int, unit: String, now: Date) -> Date? {
        if unit.lowercased().hasPrefix("month") {
            return Calendar(identifier: .gregorian).date(byAdding: .month, value: value, to: now)
        }
        return now.addingTimeInterval(TimeInterval(value) * 24 * 60 * 60)
    }

    private static func nextDailyReset(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "America/New_York") else { return nil }
        calendar.timeZone = timeZone
        return calendar.nextDate(after: date, matching: DateComponents(hour: 20), matchingPolicy: .nextTime)
    }

    private static func automaticCookie() -> String? {
        let query = BrowserCookieQuery(domains: ["ampcode.com", "www.ampcode.com"])
        let client = BrowserCookieClient()
        for browser in browserOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if let session = cookies.first(where: { $0.name == "session" }), !session.value.isEmpty {
                    return "session=\(session.value)"
                }
            }
        }
        return nil
    }

    static func resolvedAPIToken(configured: String, environment: [String: String]) -> String? {
        if let token = cleanToken(environment["AMP_API_KEY"]) { return token }
        guard sessionCookieHeader(configured) == nil else { return nil }
        return cleanToken(configured)
    }

    private static func isAmpHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "ampcode.com" || host == "www.ampcode.com" || host.hasSuffix(".ampcode.com")
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func stripANSICodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func cleaned(_ raw: String?) -> String? { nonEmpty(raw) }

    private static func cleanToken(_ raw: String?) -> String? {
        guard let value = cleaned(raw) else { return nil }
        return cleaned(unquoted(value))
    }

    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2,
              (raw.hasPrefix("\"") && raw.hasSuffix("\"") || raw.hasPrefix("'") && raw.hasSuffix("'"))
        else { return raw }
        return String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sign in") || lower.contains("log in") || lower.contains("login")
    }

    private static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }
}
