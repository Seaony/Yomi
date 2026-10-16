import CoreFoundation
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
    case invalidRegion(String)
    case desktopSessionChanged
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text("未找到 Kimi Code API Key", "Kimi Code API key was not found")
        case .missingWebToken:
            AppLocalization.text("未找到 Kimi 网页会话", "Kimi web session was not found")
        case .expiredCodeCredential:
            AppLocalization.text(
                "Kimi Code 本机凭据已过期，请运行 kimi 重新登录，或在设置中添加 API Key",
                "Kimi Code local credential has expired. Run kimi to sign in again, or add an API key in Settings."
            )
        case .invalidAPIKey:
            AppLocalization.text("Kimi Code API Key 无效或已过期", "Kimi Code API key is invalid or expired")
        case .invalidWebToken:
            AppLocalization.text("Kimi 网页会话无效或已过期", "Kimi web session is invalid or expired")
        case .invalidEndpoint:
            AppLocalization.text("Kimi Code 接口必须是安全的 HTTPS 地址", "Kimi Code endpoint must be a secure HTTPS URL")
        case let .invalidRegion(region):
            AppLocalization.text("不支持 Kimi 区域：\(region)", "Unsupported Kimi region: \(region)")
        case .desktopSessionChanged:
            AppLocalization.text(
                "Kimi Desktop 会话已变化，请确认已登录目标账号后刷新 Yomi",
                "Kimi Desktop session changed. Confirm the intended account is signed in, then refresh Yomi."
            )
        case let .apiError(status):
            AppLocalization.text("Kimi 用量接口错误（HTTP \(status)）", "Kimi usage API error (HTTP \(status))")
        case .parseFailed:
            AppLocalization.text("无法解析 Kimi Code 用量", "Failed to parse Kimi Code usage")
        }
    }
}

nonisolated enum KimiUsageRegion: String, Sendable {
    case china
    case international

    var domain: String { self == .china ? "kimi.com" : "kimi.ai" }
    var apiBaseURL: URL { URL(string: "https://api.\(domain)")! }
    var webBaseURL: URL { URL(string: "https://www.\(domain)")! }
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
                return Int64(exactly: value).map(String.init) ?? String(value)
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
        let usage: Detail?
        let usages: CodeUsagePools?
        let limits: [RateLimit]?
        let user: User?
        let version: String?
        private let versionIsMalformed: Bool

        private enum CodingKeys: String, CodingKey { case usage, usages, limits, user, version }

        struct User: Codable, Sendable, Equatable {
            let membership: Membership?
        }

        struct Membership: Codable, Sendable, Equatable {
            let level: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = try container.decodeIfPresent(Detail.self, forKey: .usage)
            usages = try container.decodeIfPresent(CodeUsagePools.self, forKey: .usages)
            limits = try container.decodeIfPresent([RateLimit].self, forKey: .limits)
            user = try? container.decode(User.self, forKey: .user)
            version = try? container.decode(String.self, forKey: .version)
            versionIsMalformed = container.contains(.version)
                && (try? container.decodeNil(forKey: .version)) != true && version == nil
        }

        var planName: String? {
            guard let level = KimiUsageFetcher.cleaned(user?.membership?.level),
                  level != "LEVEL_UNSPECIFIED" else { return nil }
            guard !versionIsMalformed, version == nil || version == "GOODS_VERSION_V1" else { return level }
            switch level {
            case "LEVEL_FREE": return "Adagio"
            case "LEVEL_TRIAL": return "Andante"
            case "LEVEL_BASIC": return "Moderato"
            case "LEVEL_INTERMEDIATE": return "Allegretto"
            case "LEVEL_ADVANCED": return "Allegro"
            default: return level
            }
        }
    }

    struct CodeUsagePools: Codable, Sendable, Equatable {
        let session: RatioPool?
        let weekly: RatioPool?
        let monthly: RatioPool?

        private enum CodingKeys: String, CodingKey {
            case session = "limit_5h"
            case weekly = "limit_7d"
            case monthly = "limit_month_total"
        }
    }

    struct RatioPool: Codable, Sendable, Equatable {
        let usedRatio: Double?
        let resetTime: String?

        private enum CodingKeys: String, CodingKey {
            case usedRatio = "used_ratio"
            case resetTime = "reset_time"
        }
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

    private struct MembershipResponse: Decodable {
        let subscription: Subscription?

        struct Subscription: Decodable {
            let active: Bool?
            let status: String?
            let goods: Goods?
        }

        struct Goods: Decodable {
            let title: String?
        }

        var planName: String? {
            guard subscription?.active == true,
                  subscription?.status == "SUBSCRIPTION_STATUS_ACTIVE" else { return nil }
            return KimiUsageFetcher.cleaned(subscription?.goods?.title)
        }
    }

    private struct WebCredential: Sendable {
        let token: String
        var isDesktop = false
    }

    struct Snapshot: Sendable, Equatable {
        let weekly: Detail?
        let rateLimit: Detail?
        let rateLimitWindow: Window?
        let subscription: SubscriptionResponse?
        var codeUsagePools: CodeUsagePools? = nil
        var planName: String? = nil
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

    private static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        region configuredRegion: String? = nil,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        guard let region = KimiUsageRegion(rawValue: cleaned(configuredRegion) ?? "china") else {
            throw KimiUsageError.invalidRegion(configuredRegion ?? "")
        }
        let configured = cleaned(rawCredential)
        let webToken = resolvedWebToken(
            configured: configured, source: source, region: region, environment: environment, now: now
        )
        let apiKey = resolvedAPIKey(configured: configured, source: source, environment: environment)

        switch source {
        case .token:
            guard let apiKey else { throw KimiUsageError.missingAPIKey }
            return try await fetchCode(
                apiKey: apiKey,
                identityHeaders: [:],
                webToken: webToken,
                region: region,
                session: session,
                now: now,
                environment: environment
            )
        case .cookie:
            guard let webToken else { throw KimiUsageError.missingWebToken }
            return try await fetchWeb(credential: webToken, region: region, session: session, now: now)
        case .account:
            let credential = try localCodeCredential(region: region, environment: environment, now: now)
            return try await fetchCode(
                apiKey: credential,
                identityHeaders: codeIdentityHeaders(environment: environment),
                webToken: webToken,
                region: region,
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
                        region: region,
                        session: session,
                        now: now,
                        environment: environment
                    )
                } catch let error as KimiUsageError where shouldFallback(error) {
                    if let webToken {
                        return try await fetchWeb(credential: webToken, region: region, session: session, now: now)
                    }
                }
            }
            if let localToken = try? localCodeCredential(region: region, environment: environment, now: now) {
                do {
                    return try await fetchCode(
                        apiKey: localToken,
                        identityHeaders: codeIdentityHeaders(environment: environment),
                        webToken: webToken,
                        region: region,
                        session: session,
                        now: now,
                        environment: environment
                    )
                } catch let error as KimiUsageError where shouldFallback(error) {
                    if let webToken {
                        return try await fetchWeb(credential: webToken, region: region, session: session, now: now)
                    }
                }
            }
            guard let webToken else { throw UsageCollectionError.missingCredential }
            return try await fetchWeb(credential: webToken, region: region, session: session, now: now)
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
            subscription: nil,
            codeUsagePools: response.usages,
            planName: response.planName
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
        if let weekly = resolvedWindow(
            pool: snapshot.codeUsagePools?.weekly,
            detail: snapshot.weekly,
            id: "kimi-weekly",
            label: "7-day usage",
            countMinutes: 7 * 24 * 60,
            poolMinutes: 7 * 24 * 60
        ) {
            windows.append(weekly)
        }
        if let rate = resolvedWindow(
            pool: snapshot.codeUsagePools?.session,
            detail: snapshot.rateLimit,
            id: "kimi-session",
            label: rateLabel(minutes: snapshot.rateLimitWindow?.minutes ?? 5 * 60),
            countMinutes: snapshot.rateLimitWindow.map(\.minutes) ?? 5 * 60,
            poolMinutes: 5 * 60
        ) {
            windows.append(rate)
        }

        if let monthly = ratioWindow(
            pool: snapshot.codeUsagePools?.monthly, id: "kimi-monthly", label: "Total usage"
        ) {
            additional.append(monthly)
        } else if let balance = snapshot.subscription?.subscriptionBalance,
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
            let reliableWeekly = snapshot.codeUsagePools?.weekly?.usedRatio.map { $0.isFinite && $0 >= 0 } == true
                || snapshot.weekly.flatMap(usageCounts)?.isReliable == true
            if !reliableWeekly || !isEquivalent(candidate, weekly: windows.first(where: { $0.id == "kimi-weekly" })) {
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
            additionalWindows: additional, plan: snapshot.planName, updatedAt: now, message: nil
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
        region: KimiUsageRegion = .china,
        environment: [String: String],
        now: Date
    ) throws -> String {
        guard region == .china,
              cleaned(environment["KIMI_CODE_BASE_URL"]) == nil,
              cleaned(environment["KIMI_CODE_OAUTH_HOST"]) == nil,
              cleaned(environment["KIMI_OAUTH_HOST"]) == nil else { throw KimiUsageError.expiredCodeCredential }
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
        webToken: WebCredential?,
        region: KimiUsageRegion,
        session: URLSession,
        now: Date,
        environment: [String: String]
    ) async throws -> ProviderUsage {
        let baseURL = try codeBaseURL(region: region, environment: environment)
        var request = URLRequest(url: try codeUsageEndpoint(baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in identityHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let data = try await responseData(request, session: session, web: false)
        var snapshot = try parseCode(data)
        if let webToken {
            let membership = try await fetchMembership(
                credential: webToken, region: region, includePlan: snapshot.planName == nil, session: session
            )
            snapshot = Snapshot(
                weekly: snapshot.weekly, rateLimit: snapshot.rateLimit, rateLimitWindow: snapshot.rateLimitWindow,
                subscription: membership.stats, codeUsagePools: snapshot.codeUsagePools,
                planName: snapshot.planName ?? membership.plan
            )
        }
        return providerUsage(snapshot: snapshot, now: now)
    }

    private static func fetchWeb(
        credential: WebCredential,
        region: KimiUsageRegion,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var request = webRequest(
            url: region.webBaseURL.appendingPathComponent("apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"),
            token: credential.token
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        let data = try await responseData(request, session: session, web: true, credential: credential, region: region)
        var snapshot = try parseWeb(data)
        let membership = try await fetchMembership(credential: credential, region: region, session: session)
        snapshot = Snapshot(
            weekly: snapshot.weekly, rateLimit: snapshot.rateLimit, rateLimitWindow: snapshot.rateLimitWindow,
            subscription: membership.stats, planName: membership.plan
        )
        return providerUsage(snapshot: snapshot, now: now)
    }

    private static func fetchMembership(
        credential: WebCredential,
        region: KimiUsageRegion,
        includePlan: Bool = true,
        session: URLSession
    ) async throws -> (stats: SubscriptionResponse?, plan: String?) {
        let deadline = Date().addingTimeInterval(2)
        var stats: SubscriptionResponse?
        var plan: String?
        for method in ["GetSubscriptionStats", "GetSubscription"] {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, method != "GetSubscription" || includePlan else { break }
            var request = webRequest(
                url: region.webBaseURL.appendingPathComponent("apiv2/kimi.gateway.membership.v2.MembershipService/\(method)"),
                token: credential.token
            )
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = remaining
            do {
                let data = try await responseData(
                    request, session: session, web: true, credential: credential, region: region
                )
                if method == "GetSubscriptionStats" {
                    stats = try JSONDecoder().decode(SubscriptionResponse.self, from: data)
                } else {
                    plan = try JSONDecoder().decode(MembershipResponse.self, from: data).planName
                }
            } catch KimiUsageError.desktopSessionChanged {
                return (stats, plan)
            } catch {
                try Task.checkCancellation()
            }
        }
        return (stats, plan)
    }

    private static func responseData(
        _ request: URLRequest,
        session: URLSession,
        web: Bool,
        credential: WebCredential? = nil,
        region: KimiUsageRegion = .china
    ) async throws -> Data {
        try Task.checkCancellation()
        if let credential, credential.isDesktop {
            guard region == .china, request.url?.scheme == "https", request.url?.host == "www.kimi.com",
                  request.url?.port == nil || request.url?.port == 443,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.token)",
                  request.value(forHTTPHeaderField: "Cookie") == "kimi-auth=\(credential.token)",
                  desktopCurrentAuthToken() == credential.token else { throw KimiUsageError.desktopSessionChanged }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KimiUsageError.parseFailed }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw web ? KimiUsageError.invalidWebToken : KimiUsageError.invalidAPIKey
            }
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
        let origin = "https://\(url.host!)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("\(origin)/code/console", forHTTPHeaderField: "Referer")
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

    private static func resolvedWebToken(
        configured: String?,
        source: ProviderSource,
        region: KimiUsageRegion,
        environment: [String: String],
        now: Date
    ) -> WebCredential? {
        if let token = webToken(from: configured) { return WebCredential(token: token) }
        if source == .cookie, configured != nil { return nil }
        if let token = webToken(from: environment["KIMI_MANUAL_COOKIE"]) { return WebCredential(token: token) }
        if let token = webToken(from: environment["KIMI_AUTH_TOKEN"] ?? environment["kimi_auth_token"]) {
            return WebCredential(token: token)
        }
        if region == .china {
            if let token = desktopCurrentAuthToken(now: now) { return WebCredential(token: token, isDesktop: true) }
        } else if let token = desktopAuthToken(region: region) {
            return WebCredential(token: token)
        }
        return browserAuthToken(region: region).map { WebCredential(token: $0) }
    }

    private static func browserAuthToken(region: KimiUsageRegion) -> String? {
        let query = BrowserCookieQuery(domains: ["www.\(region.domain)", region.domain], domainMatch: .exact)
        let client = BrowserCookieClient()
        for browser in Browser.defaultImportOrder {
            guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: client) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if let token = cookies.first(where: { $0.name == "kimi-auth" })?.value,
                   !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return token }
            }
        }
        return nil
    }

    private static func desktopAuthToken(
        region: KimiUsageRegion,
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
          AND host_key IN ('www.\(region.domain)', '.www.\(region.domain)', '.\(region.domain)', '\(region.domain)')
        ORDER BY last_access_utc DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        guard let token = cleaned(String(cString: raw)) else { return nil }
        if let expiry = jwtClaims(token)?["exp"] as? Double, expiry <= Date().timeIntervalSince1970 { return nil }
        return token
    }

    private static func desktopCurrentAuthToken(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> String? {
        guard !Task.isCancelled else { return nil }
        let directory = home.resolvingSymlinksInPath()
            .appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        let key = Data("_https://www.kimi.com\0".utf8) + Data([1]) + Data("access_token".utf8)
        guard let value = ChromiumLocalStorageReader.readCurrentValue(forRawKey: key, in: directory),
              !Task.isCancelled, value.first == 1, value.count <= 16_385,
              let token = String(data: value.dropFirst(), encoding: .ascii), !token.isEmpty,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              let header = jwtObject(parts[0]), let algorithm = header["alg"] as? String,
              !algorithm.isEmpty, algorithm.lowercased() != "none",
              let claims = jwtObject(parts[1]), claims["typ"] as? String == "access",
              let expiry = numericDate(claims["exp"]), expiry > now.timeIntervalSince1970 else { return nil }
        let audiences = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains("kimi.com") else { return nil }
        if let notBefore = claims["nbf"] {
            guard let start = numericDate(notBefore), start <= now.timeIntervalSince1970 else { return nil }
        }
        return token
    }

    private static func numericDate(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let date = number.doubleValue
        return date.isFinite ? date : nil
    }

    private static func codeBaseURL(region: KimiUsageRegion, environment: [String: String]) throws -> URL {
        guard let raw = cleaned(environment["KIMI_CODE_BASE_URL"]) else { return region.apiBaseURL }
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
        guard let object = jwtClaims(jwt) else { return nil }
        return SessionInfo(
            deviceID: object["device_id"] as? String,
            sessionID: object["ssid"] as? String,
            trafficID: object["sub"] as? String
        )
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return jwtObject(parts[1])
    }

    private static func jwtObject(_ component: Substring) -> [String: Any]? {
        var payload = String(component).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func usageCounts(_ detail: Detail) -> (used: Int, limit: Int, isReliable: Bool)? {
        guard let limit = Int(detail.limit), limit > 0 else { return nil }
        if let used = detail.used.flatMap(Int.init), used >= 0 { return (used, limit, true) }
        if let remaining = detail.remaining.flatMap(Int.init), (0...limit).contains(remaining) {
            return (limit - remaining, limit, true)
        }
        return (0, limit, false)
    }

    private static func ratioWindow(pool: RatioPool?, id: String, label: String) -> UsageWindow? {
        guard let ratio = pool?.usedRatio, ratio.isFinite, ratio >= 0 else { return nil }
        return UsageWindow(id: id, label: label, usedFraction: clamped(ratio), resetsAt: date(pool?.resetTime))
    }

    private static func resolvedWindow(
        pool: RatioPool?,
        detail: Detail?,
        id: String,
        label: String,
        countMinutes: Int?,
        poolMinutes: Int
    ) -> UsageWindow? {
        let counts = detail.flatMap(usageCounts)
        let ratio = ratioWindow(
            pool: pool, id: id, label: id == "kimi-session" ? rateLabel(minutes: poolMinutes) : label
        )
        let preferCounts: Bool
        if let ratio, countMinutes == poolMinutes, let counts, counts.isReliable,
           clamped(Double(counts.used) / Double(counts.limit)) > ratio.usedFraction,
           let countReset = date(detail?.resetTime), let ratioReset = ratio.resetsAt {
            preferCounts = abs(countReset.timeIntervalSince(ratioReset)) <= 2
        } else {
            preferCounts = false
        }
        if let ratio, !preferCounts { return ratio }
        guard let detail, let counts else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedFraction: clamped(Double(counts.used) / Double(counts.limit)),
            resetsAt: date(detail.resetTime),
            detail: "\(counts.used)/\(counts.limit) requests"
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
        case .missingWebToken, .invalidWebToken, .invalidEndpoint, .invalidRegion, .desktopSessionChanged: false
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
