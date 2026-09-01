import Foundation
import SQLite3
import SweetCookieKit

enum KimiUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case missingWebToken
    case expiredCodeCredential
    case invalidAPIKey
    case invalidWebToken
    case invalidEndpoint
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text("未找到 Kimi Code API Key", "Kimi Code API key was not found")
        case .missingWebToken:
            AppLocalization.text("未找到 Kimi 网页会话", "Kimi web session was not found")
        case .expiredCodeCredential:
            AppLocalization.text("Kimi Code 本机凭据已过期，请重新登录", "Kimi Code local credential has expired. Sign in again.")
        case .invalidAPIKey:
            AppLocalization.text("Kimi Code API Key 无效或已过期", "Kimi Code API key is invalid or expired")
        case .invalidWebToken:
            AppLocalization.text("Kimi 网页会话无效或已过期", "Kimi web session is invalid or expired")
        case .invalidEndpoint:
            AppLocalization.text("Kimi Code 接口必须是安全的 HTTPS 地址", "Kimi Code endpoint must be a secure HTTPS URL")
        case let .apiError(status):
            AppLocalization.text("Kimi 用量接口错误（HTTP \(status)）", "Kimi usage API error (HTTP \(status))")
        case .parseFailed:
            AppLocalization.text("无法解析 Kimi Code 用量", "Failed to parse Kimi Code usage")
        }
    }
}

nonisolated enum KimiUsageFetcher {
    struct Detail: Codable, Sendable, Equatable {
        let limit: String
        let used: String?
        let remaining: String?
        let resetTime: String?

        private enum CodingKeys: String, CodingKey {
            case limit, used, remaining, resetTime, resetAt
            case resetTimeSnake = "reset_time"
            case resetAtSnake = "reset_at"
        }

        init(limit: String, used: String?, remaining: String?, resetTime: String?) {
            self.limit = limit
            self.used = used
            self.remaining = remaining
            self.resetTime = resetTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let limit = Self.string(in: container, key: .limit) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.limit,
                    DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing limit")
                )
            }
            self.limit = limit
            used = Self.string(in: container, key: .used)
            remaining = Self.string(in: container, key: .remaining)
            resetTime = Self.string(in: container, key: .resetTime)
                ?? Self.string(in: container, key: .resetAt)
                ?? Self.string(in: container, key: .resetTimeSnake)
                ?? Self.string(in: container, key: .resetAtSnake)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(used, forKey: .used)
            try container.encodeIfPresent(remaining, forKey: .remaining)
            try container.encodeIfPresent(resetTime, forKey: .resetTime)
        }

        private static func string(
            in container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> String? {
            if let value = try? container.decode(String.self, forKey: key) { return value }
            if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
            if let value = try? container.decode(Double.self, forKey: key) {
                return value.rounded(.towardZero) == value ? String(Int64(value)) : String(value)
            }
            return nil
        }
    }

    struct Window: Codable, Sendable, Equatable {
        let duration: Int
        let timeUnit: String

        var minutes: Int? {
            guard duration > 0 else { return nil }
            let multiplier: Int
            switch timeUnit {
            case "TIME_UNIT_MINUTE": multiplier = 1
            case "TIME_UNIT_HOUR": multiplier = 60
            case "TIME_UNIT_DAY": multiplier = 1_440
            default: return nil
            }
            let result = duration.multipliedReportingOverflow(by: multiplier)
            return result.overflow ? nil : result.partialValue
        }
    }

    struct RateLimit: Codable, Sendable, Equatable {
        let window: Window
        let detail: Detail
    }

    struct CodeResponse: Codable, Sendable, Equatable {
        let usage: Detail
        let limits: [RateLimit]?
    }

    struct WebUsage: Codable, Sendable, Equatable {
        let scope: String
        let detail: Detail
        let limits: [RateLimit]?
    }

    struct WebResponse: Codable, Sendable, Equatable {
        let usages: [WebUsage]
    }

    struct SubscriptionBalance: Codable, Sendable, Equatable {
        let feature: String?
        let type: String?
        let amountUsedRatio: Double?
        let kimiCodeUsedRatio: Double?
        let expireTime: String?
    }

    struct SubscriptionRateLimit: Codable, Sendable, Equatable {
        let ratio: Double?
        let enabled: Bool?
        let resetTime: String?
    }

    struct SubscriptionResponse: Codable, Sendable, Equatable {
        let subscriptionBalance: SubscriptionBalance?
        let ratelimitCode7d: SubscriptionRateLimit?
    }

    struct Snapshot: Sendable, Equatable {
        let weekly: Detail
        let rateLimit: Detail?
        let rateLimitWindow: Window?
        let subscription: SubscriptionResponse?
    }

    private struct CodeCredential: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
            refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""
            if let value = try? container.decode(Double.self, forKey: .expiresAt) {
                expiresAt = value
            } else if let value = try? container.decode(String.self, forKey: .expiresAt) {
                expiresAt = TimeInterval(value)
            } else {
                expiresAt = nil
            }
        }
    }

    private struct SessionInfo: Sendable {
        let deviceID: String?
        let sessionID: String?
        let trafficID: String?
    }

    static let defaultCodeBaseURL = URL(string: "https://api.kimi.com")!
    static let webUsageURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!
    static let subscriptionURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
    )!
    private static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        let configured = cleaned(rawCredential)
        let webToken = resolvedWebToken(configured: configured, environment: environment)
        let apiKey = resolvedAPIKey(configured: configured, source: source, environment: environment)

        switch source {
        case .token:
            guard let apiKey else { throw KimiUsageError.missingAPIKey }
            return try await fetchCode(
                apiKey: apiKey,
                identityHeaders: [:],
                webToken: webToken,
                session: session,
                now: now,
                environment: environment
            )
        case .cookie:
            guard let webToken else { throw KimiUsageError.missingWebToken }
            return try await fetchWeb(token: webToken, session: session, now: now)
        case .account:
            let credential = try localCodeCredential(environment: environment, now: now)
            return try await fetchCode(
                apiKey: credential,
                identityHeaders: codeIdentityHeaders(environment: environment),
                webToken: webToken,
                session: session,
                now: now,
                environment: environment
            )
        case .automatic:
            if let apiKey {
                do {
                    return try await fetchCode(
                        apiKey: apiKey,
                        identityHeaders: [:],
                        webToken: webToken,
                        session: session,
                        now: now,
                        environment: environment
                    )
                } catch let error as KimiUsageError where shouldFallback(error) {
                    if let webToken { return try await fetchWeb(token: webToken, session: session, now: now) }
                }
            }
            if let localToken = try? localCodeCredential(environment: environment, now: now) {
                do {
                    return try await fetchCode(
                        apiKey: localToken,
                        identityHeaders: codeIdentityHeaders(environment: environment),
                        webToken: webToken,
                        session: session,
                        now: now,
                        environment: environment
                    )
                } catch let error as KimiUsageError where shouldFallback(error) {
                    if let webToken { return try await fetchWeb(token: webToken, session: session, now: now) }
                }
            }
            guard let webToken else { throw UsageCollectionError.missingCredential }
            return try await fetchWeb(token: webToken, session: session, now: now)
        case .command, .endpoint:
            throw UsageCollectionError.missingCredential
        }
    }

    static func parseCode(_ data: Data) throws -> Snapshot {
        let response = try JSONDecoder().decode(CodeResponse.self, from: data)
        return Snapshot(
            weekly: response.usage,
            rateLimit: response.limits?.first?.detail,
            rateLimitWindow: response.limits?.first?.window,
            subscription: nil
        )
    }

    static func parseWeb(_ data: Data, subscriptionData: Data? = nil) throws -> Snapshot {
        let response = try JSONDecoder().decode(WebResponse.self, from: data)
        guard let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw KimiUsageError.parseFailed
        }
        let subscription = subscriptionData.flatMap { try? JSONDecoder().decode(SubscriptionResponse.self, from: $0) }
        return Snapshot(
            weekly: coding.detail,
            rateLimit: coding.limits?.first?.detail,
            rateLimitWindow: coding.limits?.first?.window,
            subscription: subscription
        )
    }

    static func providerUsage(snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        var additional: [UsageWindow] = []
        if let weekly = usageWindow(
            detail: snapshot.weekly,
            id: "kimi-weekly",
            label: "7-day usage",
            defaultMinutes: 7 * 24 * 60,
            now: now
        ) {
            windows.append(weekly)
        }
        if let detail = snapshot.rateLimit,
           let rate = usageWindow(
               detail: detail,
               id: "kimi-session",
               label: rateLabel(minutes: snapshot.rateLimitWindow?.minutes ?? 5 * 60),
               defaultMinutes: snapshot.rateLimitWindow?.minutes ?? 5 * 60,
               now: now
           ) {
            windows.append(rate)
        }

        if let balance = snapshot.subscription?.subscriptionBalance,
           balance.feature == nil || balance.feature == "FEATURE_OMNI",
           balance.type == nil || balance.type == "SUBSCRIPTION",
           let ratio = balance.amountUsedRatio, ratio.isFinite {
            additional.append(UsageWindow(
                id: "kimi-monthly",
                label: "Total usage",
                usedFraction: clamped(ratio),
                resetsAt: date(balance.expireTime),
                detail: nil
            ))
        }
        if let limit = snapshot.subscription?.ratelimitCode7d,
           limit.enabled != false,
           let ratio = limit.ratio, ratio.isFinite {
            let candidate = UsageWindow(
                id: "kimi-code-7d",
                label: "Code 7-day",
                usedFraction: clamped(ratio),
                resetsAt: date(limit.resetTime),
                detail: nil
            )
            if !isEquivalent(candidate, weekly: windows.first(where: { $0.id == "kimi-weekly" })) {
                additional.append(candidate)
            }
        }
        guard !windows.isEmpty || !additional.isEmpty else {
            return ProviderUsage(
                id: ProviderID(rawValue: "kimi"), state: .failed, windows: [],
                updatedAt: now, message: KimiUsageError.parseFailed.localizedDescription
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "kimi"), state: .ready, windows: windows,
            additionalWindows: additional, updatedAt: now, message: nil
        )
    }

    static func codeUsageEndpoint(baseURL: URL) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil else { throw KimiUsageError.invalidEndpoint }
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "coding/v1" || normalizedPath.hasSuffix("/coding/v1") {
            return baseURL.appendingPathComponent("usages")
        }
        if normalizedPath == "coding" || normalizedPath.hasSuffix("/coding") {
            return baseURL.appendingPathComponent("v1/usages")
        }
        return baseURL.appendingPathComponent("coding/v1/usages")
    }

    static func webToken(from raw: String?) -> String? {
        guard let raw = cleaned(raw) else { return nil }
        let patterns = [
            #"(?i)kimi-auth=([A-Za-z0-9._\-+=/]+)"#,
            #"(?i)kimi-auth:\s*([A-Za-z0-9._\-+=/]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            return String(raw[range])
        }
        if raw.hasPrefix("eyJ"), raw.split(separator: ".").count == 3 { return raw }
        return nil
    }

    static func localCodeCredential(
        environment: [String: String],
        now: Date
    ) throws -> String {
        guard environment["KIMI_CODE_BASE_URL"] == nil,
              environment["KIMI_CODE_OAUTH_HOST"] == nil,
              environment["KIMI_OAUTH_HOST"] == nil else { throw KimiUsageError.expiredCodeCredential }
        let home = cleaned(environment["KIMI_CODE_HOME"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
        let url = home.appendingPathComponent("credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: url),
              let credential = try? JSONDecoder().decode(CodeCredential.self, from: data),
              !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiresAt = credential.expiresAt, expiresAt.isFinite,
              expiresAt > now.addingTimeInterval(60).timeIntervalSince1970 else {
            throw KimiUsageError.expiredCodeCredential
        }
        return credential.accessToken
    }

    private static func fetchCode(
        apiKey: String,
        identityHeaders: [String: String],
        webToken: String?,
        session: URLSession,
        now: Date,
        environment: [String: String]
    ) async throws -> ProviderUsage {
        let baseURL = try codeBaseURL(environment: environment)
        var request = URLRequest(url: try codeUsageEndpoint(baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in identityHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let data = try await responseData(request, session: session, web: false)
        var snapshot = try parseCode(data)
        if let webToken, let subscription = try? await fetchSubscription(token: webToken, session: session) {
            snapshot = Snapshot(
                weekly: snapshot.weekly,
                rateLimit: snapshot.rateLimit,
                rateLimitWindow: snapshot.rateLimitWindow,
                subscription: subscription
            )
        }
        return providerUsage(snapshot: snapshot, now: now)
    }

    private static func fetchWeb(token: String, session: URLSession, now: Date) async throws -> ProviderUsage {
        var request = webRequest(url: webUsageURL, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        let data = try await responseData(request, session: session, web: true)
        let subscriptionData: Data? = try? await {
            var subscriptionRequest = webRequest(url: subscriptionURL, token: token)
            subscriptionRequest.httpBody = Data("{}".utf8)
            return try await responseData(subscriptionRequest, session: session, web: true)
        }()
        return providerUsage(snapshot: try parseWeb(data, subscriptionData: subscriptionData), now: now)
    }

    private static func fetchSubscription(token: String, session: URLSession) async throws -> SubscriptionResponse {
        var request = webRequest(url: subscriptionURL, token: token)
        request.httpBody = Data("{}".utf8)
        let data = try await responseData(request, session: session, web: true)
        return try JSONDecoder().decode(SubscriptionResponse.self, from: data)
    }

    private static func responseData(_ request: URLRequest, session: URLSession, web: Bool) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KimiUsageError.parseFailed }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw web ? KimiUsageError.invalidWebToken : KimiUsageError.invalidAPIKey }
            if web, http.statusCode == 403 { throw KimiUsageError.invalidWebToken }
            throw KimiUsageError.apiError(http.statusCode)
        }
        return data
    }

    private static func webRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        if let info = sessionInfo(token) {
            request.setValue(info.deviceID, forHTTPHeaderField: "x-msh-device-id")
            request.setValue(info.sessionID, forHTTPHeaderField: "x-msh-session-id")
            request.setValue(info.trafficID, forHTTPHeaderField: "x-traffic-id")
        }
        return request
    }

    private static func resolvedAPIKey(
        configured: String?,
        source: ProviderSource,
        environment: [String: String]
    ) -> String? {
        if let value = cleaned(environment["KIMI_CODE_API_KEY"]) { return value }
        guard source != .cookie, let configured, webToken(from: configured) == nil else { return nil }
        return configured
    }

    private static func resolvedWebToken(configured: String?, environment: [String: String]) -> String? {
        if let token = webToken(from: configured) { return token }
        if let token = webToken(from: environment["KIMI_MANUAL_COOKIE"]) { return token }
        if let token = webToken(from: environment["KIMI_AUTH_TOKEN"] ?? environment["kimi_auth_token"]) {
            return token
        }
        if let token = desktopAuthToken() { return token }
        return browserAuthToken()
    }

    private static func browserAuthToken() -> String? {
        let query = BrowserCookieQuery(domains: ["www.kimi.com", "kimi.com"])
        let client = BrowserCookieClient()
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if let token = cookies.first(where: { $0.name == "kimi-auth" })?.value,
                   !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return token }
            }
        }
        return nil
    }

    private static func desktopAuthToken(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let path = home.appendingPathComponent("Library/Application Support/kimi-desktop/Cookies").path
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        let sql = """
        SELECT value FROM cookies
        WHERE name = 'kimi-auth'
          AND host_key IN ('www.kimi.com', '.www.kimi.com', '.kimi.com', 'kimi.com')
        ORDER BY last_access_utc DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return cleaned(String(cString: raw))
    }

    private static func codeBaseURL(environment: [String: String]) throws -> URL {
        guard let raw = cleaned(environment["KIMI_CODE_BASE_URL"]) else { return defaultCodeBaseURL }
        guard let url = URL(string: raw) else { throw KimiUsageError.invalidEndpoint }
        _ = try codeUsageEndpoint(baseURL: url)
        return url
    }

    private static func codeIdentityHeaders(environment: [String: String]) -> [String: String] {
        let home = cleaned(environment["KIMI_CODE_HOME"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
        let deviceURL = home.appendingPathComponent("device_id")
        let deviceID = cleaned(try? String(contentsOf: deviceURL, encoding: .utf8)) ?? UUID().uuidString.lowercased()
        return [
            "User-Agent": "Yomi/1",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": "1",
            "X-Msh-Device-Name": ascii(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": "macOS",
            "X-Msh-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
            "X-Msh-Device-Id": deviceID,
        ]
    }

    private static func sessionInfo(_ jwt: String) -> SessionInfo? {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return SessionInfo(
            deviceID: object["device_id"] as? String,
            sessionID: object["ssid"] as? String,
            trafficID: object["sub"] as? String
        )
    }

    private static func usageWindow(
        detail: Detail,
        id: String,
        label: String,
        defaultMinutes: Int,
        now: Date
    ) -> UsageWindow? {
        guard let limit = Int(detail.limit), limit > 0 else { return nil }
        let used: Int
        if let value = detail.used.flatMap(Int.init), value >= 0 {
            used = value
        } else if let remaining = detail.remaining.flatMap(Int.init), (0...limit).contains(remaining) {
            used = limit - remaining
        } else {
            used = 0
        }
        return UsageWindow(
            id: id,
            label: label,
            usedFraction: clamped(Double(used) / Double(limit)),
            resetsAt: date(detail.resetTime),
            detail: "\(used)/\(limit) requests"
        )
    }

    private static func rateLabel(minutes: Int) -> String {
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour usage" }
        return "\(minutes)-minute usage"
    }

    private static func isEquivalent(_ candidate: UsageWindow, weekly: UsageWindow?) -> Bool {
        guard let weekly, abs(candidate.usedFraction - weekly.usedFraction) <= 0.01,
              let lhs = candidate.resetsAt, let rhs = weekly.resetsAt else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 5 * 60
    }

    private static func shouldFallback(_ error: KimiUsageError) -> Bool {
        switch error {
        case .missingAPIKey, .expiredCodeCredential, .invalidAPIKey, .apiError, .parseFailed: true
        case .missingWebToken, .invalidWebToken, .invalidEndpoint: false
        }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func ascii(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { (0x20...0x7E).contains($0.value) })
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
