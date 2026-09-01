import Foundation
import SweetCookieKit

nonisolated enum LongCatUsageError: LocalizedError, Equatable {
    case missingCookies
    case invalidSession
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            AppLocalization.text(
                "缺少 LongCat 会话 Cookie，请先登录 longcat.chat 或粘贴 Cookie 标头",
                "LongCat session cookies are missing. Sign in at longcat.chat, or paste a Cookie header."
            )
        case .invalidSession:
            AppLocalization.text(
                "LongCat 会话无效或已过期，请重新登录 longcat.chat",
                "LongCat session is invalid or expired. Please sign in again at longcat.chat."
            )
        case let .invalidRequest(message):
            AppLocalization.text("LongCat 请求无效：\(message)", "Invalid LongCat request: \(message)")
        case let .networkError(message):
            AppLocalization.text("LongCat 网络错误：\(message)", "LongCat network error: \(message)")
        case let .apiError(message):
            AppLocalization.text("LongCat 接口错误：\(message)", "LongCat API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 LongCat 用量：\(message)", "Failed to parse LongCat usage data: \(message)")
        }
    }
}

nonisolated struct LongCatUsageSnapshot: Sendable, Equatable {
    var totalQuota: Double?
    var usedQuota: Double?
    var remainingQuota: Double?
    var fuelPackTotal: Double?
    var fuelPackRemaining: Double?
    var nearestFuelExpiry: Date?
    var accountName: String?
    var updatedAt: Date

    init(
        totalQuota: Double? = nil,
        usedQuota: Double? = nil,
        remainingQuota: Double? = nil,
        fuelPackTotal: Double? = nil,
        fuelPackRemaining: Double? = nil,
        nearestFuelExpiry: Date? = nil,
        accountName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.totalQuota = totalQuota
        self.usedQuota = usedQuota
        self.remainingQuota = remainingQuota
        self.fuelPackTotal = fuelPackTotal
        self.fuelPackRemaining = fuelPackRemaining
        self.nearestFuelExpiry = nearestFuelExpiry
        self.accountName = accountName
        self.updatedAt = updatedAt
    }

    func toProviderUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let totalQuota, totalQuota > 0 {
            let used = resolvedUsed(total: totalQuota)
            windows.append(UsageWindow(
                id: "longcat-quota",
                label: "Quota",
                usedFraction: min(1, used / totalQuota),
                resetsAt: nil,
                detail: "\(Int(used))/\(Int(totalQuota))"
            ))
        }
        if let fuelPackTotal, fuelPackTotal > 0 {
            let remaining = fuelPackRemaining ?? fuelPackTotal
            let used = max(0, fuelPackTotal - remaining)
            windows.append(UsageWindow(
                id: "longcat-fuel-pack",
                label: "Fuel Pack",
                usedFraction: min(1, used / fuelPackTotal),
                resetsAt: nearestFuelExpiry,
                detail: "Fuel pack: \(Int(remaining))/\(Int(fuelPackTotal))"
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "longcat"),
            state: .ready,
            windows: windows,
            details: [],
            updatedAt: updatedAt,
            message: nil
        )
    }

    private func resolvedUsed(total: Double) -> Double {
        if let usedQuota { return max(0, usedQuota) }
        if let remainingQuota { return max(0, total - remainingQuota) }
        return 0
    }
}

nonisolated enum LongCatCookieHeader {
    private static let patterns = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    static func override(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: raw)
            else { continue }
            let value = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return raw.contains("=") ? raw : nil
    }

    static func environmentOverride(_ environment: [String: String]) -> String? {
        for key in ["LONGCAT_MANUAL_COOKIE", "longcat_manual_cookie"] {
            guard var value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if value.count >= 2,
               value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            if let value = override(from: value) { return value }
        }
        return nil
    }

    static func header(from cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"
        let matches = cookies.filter { cookie in
            guard cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
            guard !cookie.isSecure || isHTTPS else { return false }
            guard domain(cookie.domain, matches: host) else { return false }
            return path(cookie.path, matches: requestPath)
        }.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.domain < rhs.domain
        }
        guard !matches.isEmpty else { return nil }
        return matches.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalized = cookieDomain.lowercased()
        if normalized.hasPrefix(".") {
            let base = String(normalized.dropFirst())
            return host == base || host.hasSuffix(".\(base)")
        }
        return host == normalized
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        guard requestPath.hasPrefix(normalized) else { return false }
        if requestPath.count == normalized.count || normalized.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: normalized.count)
        return requestPath[boundary] == "/"
    }
}

nonisolated enum LongCatUsageFetcher {
    struct ImportedSession: @unchecked Sendable {
        let cookies: [HTTPCookie]
        let sourceLabel: String
    }

    private enum Authentication: @unchecked Sendable {
        case header(String)
        case cookies([HTTPCookie])

        func header(for url: URL) -> String? {
            switch self {
            case let .header(value): value.isEmpty ? nil : value
            case let .cookies(cookies): LongCatCookieHeader.header(from: cookies, for: url)
            }
        }
    }

    static let userCurrentURL = URL(string: "https://longcat.chat/api/v1/user-current")!
    static let tokenPacksSummaryURL = URL(string: "https://longcat.chat/api/pay/quota/metering/token-packs/summary")!
    static let tokenUsageURL = URL(string: "https://longcat.chat/api/lc-platform/v1/tokenUsage")!
    static let pendingFuelURL = URL(string: "https://longcat.chat/api/lc-platform/v1/pending-fuel-packages")!
    private static let host = "https://longcat.chat"
    private static let cookieDomains = ["longcat.chat", "www.longcat.chat"]

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowBrowserImport: Bool,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if source == .cookie || source == .token {
            guard let cookie = LongCatCookieHeader.override(from: credential) else {
                throw LongCatUsageError.missingCookies
            }
            return try await fetchUsage(cookieHeader: cookie, session: session, now: now).toProviderUsage()
        }
        if let cookie = LongCatCookieHeader.environmentOverride(environment) {
            return try await fetchUsage(cookieHeader: cookie, session: session, now: now).toProviderUsage()
        }
        guard allowBrowserImport else { throw LongCatUsageError.missingCookies }
        return try await fetchImportedSessions(automaticSessions()) { imported in
            try await fetchUsage(cookies: imported.cookies, session: session, now: now)
        }.toProviderUsage()
    }

    static func fetchImportedSessions(
        _ sessions: [ImportedSession],
        fetch: (ImportedSession) async throws -> LongCatUsageSnapshot
    ) async throws -> LongCatUsageSnapshot {
        var lastCredentialError: LongCatUsageError = .missingCookies
        for session in sessions {
            do {
                return try await fetch(session)
            } catch let error as LongCatUsageError where error == .invalidSession || error == .missingCookies {
                lastCredentialError = error
            }
        }
        throw lastCredentialError
    }

    static func fetchUsage(
        cookieHeader: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> LongCatUsageSnapshot {
        try await fetchUsage(authentication: .header(cookieHeader), session: session, now: now)
    }

    static func fetchUsage(
        cookies: [HTTPCookie],
        session: URLSession,
        now: Date = Date()
    ) async throws -> LongCatUsageSnapshot {
        try await fetchUsage(authentication: .cookies(cookies), session: session, now: now)
    }

    private static func fetchUsage(
        authentication: Authentication,
        session: URLSession,
        now: Date
    ) async throws -> LongCatUsageSnapshot {
        let requestSession = guardedSession(copying: session)
        defer { requestSession.finishTasksAndInvalidate() }

        let accountPayload = try await requiredRequest(
            url: userCurrentURL,
            method: "GET",
            authentication: authentication,
            session: requestSession
        )
        guard let account = try unwrap(accountPayload) as? [String: Any] else {
            throw LongCatUsageError.parseFailed("user-current data was not an object")
        }

        var summary: [String: Any]?
        if let data = try? await requiredRequest(
            url: tokenPacksSummaryURL,
            method: "POST",
            authentication: authentication,
            session: requestSession
        ), let payload = try? unwrap(data), let object = payload as? [String: Any] {
            summary = object
        }

        var usage: [String: Any]?
        if activeTokenPackLot(from: summary) == nil {
            let data = try await requiredRequest(
                url: tokenUsageURL,
                method: "GET",
                authentication: authentication,
                session: requestSession
            )
            guard let object = try unwrap(data) as? [String: Any] else {
                throw LongCatUsageError.parseFailed("tokenUsage data was not an object")
            }
            let canonical = objectValue(object["usage"]) ?? object
            guard number(canonical["totalToken"]) != nil else {
                throw LongCatUsageError.parseFailed("tokenUsage data was missing totalToken")
            }
            usage = object
        }

        var fuel: [String: Any]?
        do {
            if let data = try await optionalRequest(
                url: pendingFuelURL,
                method: "GET",
                authentication: authentication,
                session: requestSession
            ), let payload = try? unwrap(data), let object = payload as? [String: Any] {
                fuel = object
            }
        } catch {}
        return buildSnapshot(
            account: account,
            tokenPackSummary: summary,
            tokenUsage: usage,
            pendingFuel: fuel,
            now: now
        )
    }

    static func buildSnapshot(
        account: [String: Any]?,
        tokenPackSummary: [String: Any]?,
        tokenUsage: [String: Any]?,
        pendingFuel: [String: Any]?,
        now: Date = Date()
    ) -> LongCatUsageSnapshot {
        var snapshot = LongCatUsageSnapshot(updatedAt: now)
        if let account {
            snapshot.accountName = string(account["name"]) ?? string(account["nickName"])
        }
        if let lot = activeTokenPackLot(from: tokenPackSummary), let total = number(lot["totalToken"]) {
            let used = number(lot["consumedToken"]) ?? 0
            snapshot.totalQuota = total
            snapshot.usedQuota = used
            snapshot.remainingQuota = total - used
        } else if let tokenUsage {
            let usage = objectValue(tokenUsage["usage"]) ?? tokenUsage
            snapshot.totalQuota = number(usage["totalToken"])
            snapshot.usedQuota = number(usage["usedToken"])
            snapshot.remainingQuota = number(usage["availableToken"])
        }
        if let pendingFuel { applyFuelPackages(pendingFuel, to: &snapshot) }
        return snapshot
    }

    private static func activeTokenPackLot(from summary: [String: Any]?) -> [String: Any]? {
        guard let lot = objectValue(summary?["currentLot"]),
              string(lot["status"])?.uppercased() == "ACTIVE",
              let total = number(lot["totalToken"]), total > 0
        else { return nil }
        return lot
    }

    private static func applyFuelPackages(_ object: [String: Any], to snapshot: inout LongCatUsageSnapshot) {
        let total = number(object["totalQuota"])
        let packages = array(object["list"])
        var remaining = 0.0
        var sawRemaining = false
        var nearestExpiry: Date?
        for package in packages {
            if let value = number(package["availableToken"]) {
                remaining += value
                sawRemaining = true
            }
            if let expiry = parseDate(package["expireTime"]), nearestExpiry == nil || expiry < nearestExpiry! {
                nearestExpiry = expiry
            }
        }
        if let total, total > 0 {
            snapshot.fuelPackTotal = total
            snapshot.fuelPackRemaining = sawRemaining ? remaining : total
        }
        snapshot.nearestFuelExpiry = nearestExpiry
    }

    private static func requiredRequest(
        url: URL,
        method: String,
        authentication: Authentication,
        session: URLSession
    ) async throws -> Data {
        guard let data = try await request(
            url: url, method: method, authentication: authentication, session: session, required: true
        ) else { throw LongCatUsageError.parseFailed("\(url.lastPathComponent) response was empty") }
        return data
    }

    private static func optionalRequest(
        url: URL,
        method: String,
        authentication: Authentication,
        session: URLSession
    ) async throws -> Data? {
        try await request(url: url, method: method, authentication: authentication, session: session, required: false)
    }

    private static func request(
        url: URL,
        method: String,
        authentication: Authentication,
        session: URLSession,
        required: Bool
    ) async throws -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "POST" {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let cookie = authentication.header(for: url) else { throw LongCatUsageError.missingCookies }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.setValue("\(host)/platform/usage", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LongCatUsageError.networkError(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw LongCatUsageError.networkError("Invalid response")
        }
        if http.statusCode == 200 { return data }
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode) {
            throw LongCatUsageError.invalidSession
        }
        if required { throw LongCatUsageError.apiError("HTTP \(http.statusCode) for \(url.path)") }
        return nil
    }

    private static func unwrap(_ data: Data) throws -> Any {
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw LongCatUsageError.parseFailed("response was not a JSON object") }
        guard let object = raw as? [String: Any] else {
            throw LongCatUsageError.parseFailed("response was not a JSON object")
        }
        if let code = integer(object["code"]), code != 0, code != 200 {
            let message = string(object["message"]) ?? string(object["msg"]) ?? "code \(code)"
            if code == 401 || code == 403 { throw LongCatUsageError.invalidSession }
            throw LongCatUsageError.apiError(message)
        }
        return object["data"] ?? object
    }

    private static func automaticSessions() -> [ImportedSession] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        let client = BrowserCookieClient()
        var sessions: [ImportedSession] = []
        for browser in [Browser.chrome, Browser.firefox] {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
            for group in groups.values.sorted(by: { mergedLabel($0) < mergedLabel($1) }) {
                let records = mergeRecords(group)
                let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                if !cookies.isEmpty {
                    sessions.append(ImportedSession(cookies: cookies, sourceLabel: mergedLabel(group)))
                }
            }
        }
        return sessions
    }

    private static func mergedLabel(_ sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        return base.hasSuffix(" (Network)") ? String(base.dropLast(" (Network)".count)) : base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sorted = sources.sorted { storePriority($0.store.kind) < storePriority($1.store.kind) }
        var merged: [String: BrowserCookieRecord] = [:]
        for source in sorted {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                guard let existing = merged[key] else {
                    merged[key] = record
                    continue
                }
                switch (existing.expires, record.expires) {
                case let (lhs?, rhs?) where rhs > lhs: merged[key] = record
                case (nil, .some): merged[key] = record
                default: break
                }
            }
        }
        return Array(merged.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func guardedSession(copying session: URLSession) -> URLSession {
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: LongCatRedirectGuard(), delegateQueue: nil)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as String: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value) ?? Double(value).map(Int.init)
        case let value as NSNumber: value.intValue
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func objectValue(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func array(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return []
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            if seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        }
        if let string = string(value) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: string)
        }
        return nil
    }
}

private final class LongCatRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectedURL = request.url,
              originalURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              redirectedURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              originalURL.scheme?.lowercased() == redirectedURL.scheme?.lowercased(),
              originalURL.host?.lowercased() == redirectedURL.host?.lowercased(),
              normalizedPort(originalURL) == normalizedPort(redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func normalizedPort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : nil
    }
}
