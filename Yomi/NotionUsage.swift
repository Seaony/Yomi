import Foundation
import SweetCookieKit

nonisolated enum NotionUsageError: LocalizedError, Equatable, Sendable {
    case noSessionCookie
    case cookieImportDeferred
    case invalidCredentials
    case noWorkspace
    case allowanceNotApplicable(workspace: String?)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            return AppLocalization.text(
                "未找到 Notion Cookie。请先在浏览器中登录 notion.com。",
                "No Notion cookies found. Please log in to notion.com in your browser."
            )
        case .cookieImportDeferred:
            return AppLocalization.text(
                "只能在手动刷新时读取 Notion Cookie。请手动刷新一次以导入 Cookie。",
                "Notion cookies can only be read during a manual refresh. Refresh once to import them."
            )
        case .invalidCredentials:
            return AppLocalization.text(
                "Notion 会话 Cookie 无效或已过期。",
                "Notion session cookie is invalid or expired."
            )
        case .noWorkspace:
            return AppLocalization.text(
                "此账号没有可用的 Notion 工作区。",
                "No Notion workspace found for this account."
            )
        case let .allowanceNotApplicable(workspace):
            if let workspace {
                return AppLocalization.text(
                    "Notion AI 不会追踪“\(workspace)”的用量额度。额度仅适用于 Business 和 Enterprise 工作区。",
                    "Notion AI usage allowance is not tracked for \"\(workspace)\". Allowances apply to Business and Enterprise workspaces."
                )
            }
            return AppLocalization.text(
                "Notion AI 不会追踪此工作区的用量额度。额度仅适用于 Business 和 Enterprise 工作区。",
                "Notion AI usage allowance is not tracked for this workspace. Allowances apply to Business and Enterprise workspaces."
            )
        case let .apiError(message):
            return AppLocalization.text("Notion 接口错误：\(message)", "Notion API error: \(message)")
        case let .parseFailed(message):
            return AppLocalization.text("无法解析 Notion 用量：\(message)", "Could not parse Notion usage: \(message)")
        }
    }
}

nonisolated struct NotionWorkspace: Sendable, Equatable {
    let id: String
    let name: String?
    let planType: String?
    let subscriptionTier: String?

    var mayHaveAllowance: Bool {
        switch subscriptionTier?.lowercased() {
        case "business", "enterprise": true
        default: false
        }
    }

    var displayTier: String? {
        guard let raw = subscriptionTier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

nonisolated struct NotionAccount: Sendable, Equatable {
    let userID: String?
    let email: String?
    let name: String?
    let workspaces: [NotionWorkspace]

    func resolveWorkspace(preferredID: String? = nil) -> NotionWorkspace? {
        if let preferredID = Self.normalizeSpaceID(preferredID),
           let match = workspaces.first(where: { Self.normalizeSpaceID($0.id) == preferredID }) {
            return match
        }
        return workspaces.first(where: \.mayHaveAllowance) ?? workspaces.first
    }

    static func normalizeSpaceID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let compact = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32, compact.allSatisfy(\.isHexDigit) else { return trimmed.lowercased() }
        let characters = Array(compact)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(characters[$0]) }
            .joined(separator: "-")
    }
}

nonisolated struct NotionRollingWindow: Decodable, Sendable, Equatable {
    let creditType: String?
    let scope: String?
    let window: String?
    let used: Double?
    let limit: Double?
}

nonisolated struct NotionBillingPeriodWindow: Decodable, Sendable, Equatable {
    let creditType: String?
    let scope: String?
    let cadence: String?
    let used: Double?
    let limit: Double?
    let periodEndMs: Double?
}

nonisolated struct NotionCreditRateLimitStatus: Decodable, Sendable, Equatable {
    let status: String?
    let window: NotionRollingWindow?
    let resetsInSeconds: Double?
    let billingPeriodWindow: NotionBillingPeriodWindow?
    let enforcement: String?

    var isNotApplicable: Bool {
        status?.lowercased() == "not_applicable"
    }
}

nonisolated struct NotionUsageSnapshot: Sendable, Equatable {
    let rateLimit: NotionCreditRateLimitStatus
    let workspace: NotionWorkspace?
    let account: NotionAccount?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let rolling = rateLimit.window,
           let fraction = Self.fraction(used: rolling.used, limit: rolling.limit) {
            windows.append(UsageWindow(
                id: "notion-rolling",
                label: AppLocalization.text("滚动", "Rolling"),
                usedFraction: fraction,
                resetsAt: Self.rollingReset(from: rateLimit.resetsInSeconds, now: updatedAt),
                detail: nil
            ))
        }
        if let billing = rateLimit.billingPeriodWindow,
           let fraction = Self.fraction(used: billing.used, limit: billing.limit) {
            windows.append(UsageWindow(
                id: "notion-monthly",
                label: AppLocalization.text("每月", "Monthly"),
                usedFraction: fraction,
                resetsAt: Self.date(fromMilliseconds: billing.periodEndMs),
                detail: nil
            ))
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "notion"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: workspace?.displayTier,
            providerCost: nil,
            details: [],
            updatedAt: updatedAt,
            message: nil
        )
    }

    static func fraction(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, used / limit)
    }

    static func rollingMinutes(fromWindowToken raw: String?) -> Int? {
        guard let minutes = minutes(fromWindowToken: raw), minutes != 30 * 24 * 60 else { return nil }
        return minutes
    }

    static func minutes(fromWindowToken raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty,
              let unit = raw.last,
              let value = Int(raw.dropLast()), value > 0 else { return nil }
        switch unit {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 24 * 60
        case "w": return value * 7 * 24 * 60
        default: return nil
        }
    }

    static func rollingReset(from seconds: Double?, now: Date) -> Date? {
        guard let seconds, seconds >= 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    static func date(fromMilliseconds raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw / 1_000)
    }
}

nonisolated enum NotionUsageParser {
    static func parseRateLimitStatus(_ data: Data) throws -> NotionCreditRateLimitStatus {
        let status: NotionCreditRateLimitStatus
        do {
            status = try JSONDecoder().decode(NotionCreditRateLimitStatus.self, from: data)
        } catch {
            throw NotionUsageError.parseFailed(error.localizedDescription)
        }
        guard status.isNotApplicable || status.window != nil || status.billingPeriodWindow != nil else {
            throw NotionUsageError.parseFailed("getCreditRateLimitStatus returned no usage windows.")
        }
        return status
    }

    static func parseSpaces(_ data: Data) throws -> NotionAccount {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionUsageError.parseFailed("getSpaces response is not a JSON object.")
        }
        guard let userID = resolveUserID(in: root), let container = root[userID] as? [String: Any] else {
            throw NotionUsageError.parseFailed("getSpaces response did not identify a single user.")
        }

        var email: String?
        var name: String?
        if let users = container["notion_user"] as? [String: Any] {
            let record = users[userID].flatMap(unwrapRecord) ?? users.values.compactMap(unwrapRecord).first
            email = record?["email"] as? String
            name = record?["name"] as? String
        }

        var workspaces: [NotionWorkspace] = []
        if let spaces = container["space"] as? [String: Any] {
            for key in spaces.keys.sorted() {
                guard let record = spaces[key].flatMap(unwrapRecord) else { continue }
                workspaces.append(NotionWorkspace(
                    id: (record["id"] as? String) ?? key,
                    name: record["name"] as? String,
                    planType: record["plan_type"] as? String,
                    subscriptionTier: record["subscription_tier"] as? String
                ))
            }
        }
        return NotionAccount(userID: userID, email: email, name: name, workspaces: workspaces)
    }

    private static func resolveUserID(in root: [String: Any]) -> String? {
        let identified = root.keys.filter { key in
            guard let container = root[key] as? [String: Any],
                  let users = container["notion_user"] as? [String: Any],
                  let record = users[key].flatMap(unwrapRecord) else { return false }
            return record["id"] as? String == key
        }
        if identified.count == 1 { return identified.first }
        if identified.isEmpty, root.count == 1 { return root.keys.first }
        return nil
    }

    private static func unwrapRecord(_ raw: Any) -> [String: Any]? {
        guard let outer = raw as? [String: Any] else { return nil }
        guard let value = outer["value"] as? [String: Any] else { return outer }
        return value["value"] as? [String: Any] ?? value
    }
}

nonisolated enum NotionUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    struct RequestContext: Sendable, Equatable {
        let cookieHeader: String
        let headers: [String: String]

        init(cookieHeader: String, headers: [String: String] = [:]) {
            self.cookieHeader = NotionUsageFetcher.normalizeCookie(cookieHeader) ?? ""
            self.headers = headers
        }

        var isUsable: Bool { !cookieHeader.isEmpty }
    }

    struct ImportedSession: @unchecked Sendable {
        let cookies: [HTTPCookie]
        let sourceLabel: String

        var cookieHeader: String {
            cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        var tokenV2: String? {
            cookies.first(where: { $0.name == NotionUsageFetcher.sessionCookieName })?.value
        }
    }

    static let sessionCookieName = "token_v2"
    static let baseURL = URL(string: "https://app.notion.com")!
    static let getSpacesURL = URL(string: "https://app.notion.com/api/v3/getSpaces")!
    static let getCreditRateLimitStatusURL = URL(string: "https://app.notion.com/api/v3/getCreditRateLimitStatus")!
    private static let refererURL = URL(string: "https://app.notion.com/")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let forwardedManualHeaders = [
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "notion-audit-log-platform": "notion-audit-log-platform",
        "notion-client-version": "notion-client-version",
        "referer": "Referer",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
        "user-agent": "User-Agent",
        "x-notion-active-user-header": "x-notion-active-user-header",
    ]
    private static let cookieDomains = [
        "app.notion.com", "www.notion.com", "notion.com", "www.notion.so", "notion.so",
    ]
    private static let cookieHeaderPatterns = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
    ]
    private static let importCache = ImportSessionCache(ttl: 5)

    static func fetch(
        credential: String,
        source: ProviderSource,
        workspaceID: String?,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        allowBrowserImport: Bool,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if source == .cookie {
            guard let context = requestContext(from: credential) else { throw NotionUsageError.noSessionCookie }
            return try await fetchUsage(
                context: context,
                preferredSpaceID: workspaceID,
                timeout: 15,
                now: now,
                session: session
            ).toProviderUsage()
        }
        guard source == .automatic || source == .account else { throw UsageCollectionError.missingCredential }

        if let cached = requestContext(from: cachedCookieHeader) {
            do {
                return try await fetchUsage(
                    context: cached,
                    preferredSpaceID: workspaceID,
                    timeout: 15,
                    now: now,
                    session: session
                ).toProviderUsage()
            } catch NotionUsageError.invalidCredentials {
                await cacheUpdate(nil)
            }
        }

        guard allowBrowserImport else { throw NotionUsageError.cookieImportDeferred }
        let imported = try importSession()
        let snapshot = try await fetchUsage(
            context: RequestContext(cookieHeader: imported.cookieHeader),
            preferredSpaceID: workspaceID,
            timeout: 15,
            now: now,
            session: session
        )
        await cacheUpdate(imported.cookieHeader)
        return snapshot.toProviderUsage()
    }

    static func fetchUsage(
        cookieHeader: String,
        preferredSpaceID: String? = nil,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        session: URLSession
    ) async throws -> NotionUsageSnapshot {
        try await fetchUsage(
            context: RequestContext(cookieHeader: cookieHeader),
            preferredSpaceID: preferredSpaceID,
            timeout: timeout,
            now: now,
            session: session
        )
    }

    static func fetchUsage(
        context: RequestContext,
        preferredSpaceID: String?,
        timeout: TimeInterval,
        now: Date,
        session: URLSession
    ) async throws -> NotionUsageSnapshot {
        guard context.isUsable else { throw NotionUsageError.noSessionCookie }
        let account = try await fetchAccount(context: context, timeout: timeout, session: session)
        guard let workspace = account.resolveWorkspace(preferredID: preferredSpaceID) else {
            throw NotionUsageError.noWorkspace
        }
        let data = try await post(
            url: getCreditRateLimitStatusURL,
            endpoint: "getCreditRateLimitStatus",
            body: ["spaceId": workspace.id],
            context: context,
            timeout: timeout,
            session: session
        )
        let status = try NotionUsageParser.parseRateLimitStatus(data)
        guard !status.isNotApplicable else {
            throw NotionUsageError.allowanceNotApplicable(workspace: workspace.name)
        }
        return NotionUsageSnapshot(
            rateLimit: status,
            workspace: workspace,
            account: account,
            updatedAt: now
        )
    }

    static func fetchAccount(
        context: RequestContext,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> NotionAccount {
        let data = try await post(
            url: getSpacesURL,
            endpoint: "getSpaces",
            body: [:],
            context: context,
            timeout: timeout,
            session: session
        )
        return try NotionUsageParser.parseSpaces(data)
    }

    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = cleaned(raw) else { return nil }
        let fields = headerFields(from: raw)
        var headers: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let name = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = forwardedManualHeaders[name.lowercased()], !value.isEmpty else { continue }
            headers[canonical] = value
        }
        guard let normalized = normalizeCookie(headerValue(named: "Cookie", in: fields) ?? raw) else { return nil }
        let cookieHeader = cookiePairs(normalized).isEmpty
            ? "\(sessionCookieName)=\(normalized)"
            : normalized
        let context = RequestContext(cookieHeader: cookieHeader, headers: headers)
        return context.isUsable ? context : nil
    }

    static func normalizeCookie(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        for pattern in cookieHeaderPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: value) else { continue }
            let extracted = value[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty {
                value = String(extracted)
                break
            }
        }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func cookiePairs(_ raw: String) -> [(name: String, value: String)] {
        guard let normalized = normalizeCookie(raw) else { return [] }
        return normalized.split(separator: ";").compactMap { part in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (String(name), String(value))
        }
    }

    static func deduplicatedByName(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var best: [String: (rank: Int, cookie: HTTPCookie)] = [:]
        for cookie in cookies {
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let rank = cookieDomains.firstIndex(of: host.lowercased()) ?? cookieDomains.count
            if let existing = best[cookie.name], existing.rank <= rank { continue }
            best[cookie.name] = (rank, cookie)
        }
        return best.keys.sorted().compactMap { best[$0]?.cookie }
    }

    private static func post(
        url: URL,
        endpoint: String,
        body: [String: String],
        context: RequestContext,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        applyDefaultHeaders(to: &request)
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(context.cookieHeader, forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            throw NotionUsageError.apiError("Non-HTTP response from \(endpoint)")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw NotionUsageError.invalidCredentials }
            throw NotionUsageError.apiError("HTTP \(http.statusCode) from \(endpoint)")
        }
        return data
    }

    private static func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    }

    private static func importSession() throws -> ImportedSession {
        let now = Date()
        if let cached = importCache.load(now: now) { return cached }
        let query = BrowserCookieQuery(domains: cookieDomains)
        let client = BrowserCookieClient()
        guard let sources = try? client.records(matching: query, in: Browser.chrome) else {
            throw NotionUsageError.noSessionCookie
        }
        for source in sources where !source.records.isEmpty {
            let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
            let deduped = deduplicatedByName(cookies)
            guard deduped.contains(where: { $0.name == sessionCookieName }) else { continue }
            let imported = ImportedSession(cookies: deduped, sourceLabel: source.label)
            importCache.store(imported, now: now)
            return imported
        }
        throw NotionUsageError.noSessionCookie
    }

    private static func headerFields(from raw: String) -> [String] {
        let pattern =
            #"(?s)(?:^|\s)(?:-H|--header)(?:\s+|=|(?=['"$]))"#
                + #"(?:\$'((?:\\.|[^'])*)'|'([^']*)'|"((?:\\.|[^"])*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.matches(in: raw, range: range).compactMap { match in
            if let value = capture(1, match: match, raw: raw) { return unescapeShell(value, ansi: true) }
            if let value = capture(2, match: match, raw: raw) { return value }
            if let value = capture(3, match: match, raw: raw) { return unescapeShell(value, ansi: false) }
            if let value = capture(4, match: match, raw: raw) { return unescapeShell(value, ansi: false) }
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
        guard match.numberOfRanges > index, let range = Range(match.range(at: index), in: raw) else { return nil }
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

    private final class ImportSessionCache: @unchecked Sendable {
        private let ttl: TimeInterval
        private let lock = NSLock()
        private var entry: (session: ImportedSession, expiresAt: Date)?

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func load(now: Date) -> ImportedSession? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry, entry.expiresAt > now else {
                entry = nil
                return nil
            }
            return entry.session
        }

        func store(_ session: ImportedSession, now: Date) {
            lock.lock()
            entry = (session, now.addingTimeInterval(ttl))
            lock.unlock()
        }
    }
}
