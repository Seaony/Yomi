import Foundation

nonisolated enum Sub2APIUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case missingBaseURL
    case invalidBaseURL
    case unauthorized
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case networkFailure(String)
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text(
                "缺少 sub2api API Key，请添加分组 API Key 或设置 SUB2API_API_KEY",
                "Missing sub2api API key. Add a group API key or set SUB2API_API_KEY."
            )
        case .missingBaseURL:
            AppLocalization.text(
                "缺少 sub2api Base URL，请在设置中添加或设置 SUB2API_BASE_URL",
                "Missing sub2api base URL. Add one in Settings or set SUB2API_BASE_URL."
            )
        case .invalidBaseURL:
            AppLocalization.text(
                "sub2api Base URL 必须使用 HTTPS；本地开发仅允许回环地址 HTTP，且不能包含凭据、查询或片段",
                "sub2api base URL must use HTTPS, or loopback HTTP for local development, without embedded credentials, a query, or a fragment."
            )
        case .unauthorized:
            AppLocalization.text(
                "sub2api 拒绝了 API Key，请确认 Key 有效且已分配到分组",
                "sub2api rejected the API key. Check that the key is active and assigned to a group."
            )
        case .rateLimited:
            AppLocalization.text("sub2api 请求频率受限", "sub2api rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text(
                "sub2api 暂时不可用（HTTP \(status)）",
                "sub2api is unavailable (HTTP \(status))"
            )
        case let .apiFailure(status):
            AppLocalization.text(
                "sub2api 请求失败（HTTP \(status)）",
                "sub2api request failed (HTTP \(status))"
            )
        case let .networkFailure(message):
            AppLocalization.text("sub2api 网络错误：\(message)", "sub2api network error: \(message)")
        case let .parseFailure(message):
            AppLocalization.text("无法解析 sub2api 用量：\(message)", "Could not parse sub2api usage: \(message)")
        }
    }
}

nonisolated struct Sub2APIQuota: Sendable, Equatable {
    let limit: Double
    let used: Double
    let remaining: Double
    let unit: String?
}

nonisolated struct Sub2APISubscription: Sendable, Equatable {
    let dailyUsage: Double
    let weeklyUsage: Double
    let monthlyUsage: Double
    let dailyLimit: Double?
    let weeklyLimit: Double?
    let monthlyLimit: Double?
    let expiresAt: Date?
}

nonisolated struct Sub2APIRateLimit: Sendable, Equatable {
    let window: String
    let limit: Double
    let used: Double
    let remaining: Double
    let resetsAt: Date?
}

nonisolated struct Sub2APIUsageTotals: Sendable, Equatable {
    let requests: Int64
    let tokens: Int64
    let cost: Double
}

nonisolated struct Sub2APIUsageSnapshot: Sendable, Equatable {
    let mode: String?
    let status: String?
    let planName: String?
    let remaining: Double?
    let balance: Double?
    let unit: String
    let quota: Sub2APIQuota?
    let subscription: Sub2APISubscription?
    let rateLimits: [Sub2APIRateLimit]
    let todayUsage: Sub2APIUsageTotals?
    let totalUsage: Sub2APIUsageTotals?
    let expiresAt: Date?
    let updatedAt: Date

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let subscription {
            if let window = Self.subscriptionWindow(
                id: "sub2api-daily",
                label: AppLocalization.text("每日配额", "Daily quota", language: language),
                used: subscription.dailyUsage,
                limit: subscription.dailyLimit
            ) {
                windows.append(window)
            }
            if let window = Self.subscriptionWindow(
                id: "sub2api-weekly",
                label: AppLocalization.text("每周配额", "Weekly quota", language: language),
                used: subscription.weeklyUsage,
                limit: subscription.weeklyLimit
            ) {
                windows.append(window)
            }
            if let window = Self.subscriptionWindow(
                id: "sub2api-monthly",
                label: AppLocalization.text("每月配额", "Monthly quota", language: language),
                used: subscription.monthlyUsage,
                limit: subscription.monthlyLimit
            ) {
                windows.append(window)
            }
        } else if let quota, quota.limit > 0 {
            windows.append(UsageWindow(
                id: "sub2api-quota",
                label: AppLocalization.text("配额", "Quota", language: language),
                usedFraction: Self.usedFraction(used: quota.used, limit: quota.limit),
                resetsAt: nil,
                detail: Self.amount(used: quota.used, limit: quota.limit, unit: quota.unit ?? unit)
            ))
        }

        let additionalWindows = rateLimits.map { rate in
            UsageWindow(
                id: rate.window,
                label: Self.rateLimitLabel(rate.window, language: language),
                usedFraction: Self.usedFraction(used: rate.used, limit: rate.limit),
                resetsAt: rate.resetsAt,
                detail: Self.amount(used: rate.used, limit: rate.limit, unit: "USD")
            )
        }

        var details: [UsageDetail] = []
        if let balance {
            details.append(UsageDetail(
                id: "sub2api-balance",
                label: AppLocalization.text("余额", "Balance", language: language),
                value: Self.money(balance, unit: unit)
            ))
        }
        Self.appendUsageDetails(
            &details,
            totals: todayUsage,
            id: "today",
            title: AppLocalization.text("今日", "Today", language: language),
            language: language
        )
        Self.appendUsageDetails(
            &details,
            totals: totalUsage,
            id: "all-time",
            title: AppLocalization.text("全部", "All time", language: language),
            language: language
        )
        return ProviderUsage(
            id: ProviderID(rawValue: "sub2api"),
            state: .ready,
            windows: windows,
            additionalWindows: additionalWindows,
            balance: balance.map { Self.money($0, unit: unit) },
            plan: planName,
            today: todayUsage.map { DailyTokenUsage(tokens: $0.tokens, valueUSD: $0.cost) },
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func subscriptionWindow(
        id: String,
        label: String,
        used: Double,
        limit: Double?
    ) -> UsageWindow? {
        guard let limit, limit > 0 else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedFraction: usedFraction(used: used, limit: limit),
            resetsAt: nil,
            detail: amount(used: used, limit: limit, unit: "USD")
        )
    }

    private static func appendUsageDetails(
        _ details: inout [UsageDetail],
        totals: Sub2APIUsageTotals?,
        id: String,
        title: String,
        language: AppLanguage
    ) {
        guard let totals else { return }
        details.append(UsageDetail(
            id: "sub2api-\(id)-requests",
            label: "\(title) \(AppLocalization.text("请求", "requests", language: language))",
            value: Self.integer(totals.requests)
        ))
        details.append(UsageDetail(
            id: "sub2api-\(id)-tokens",
            label: "\(title) tokens",
            value: "\(Self.integer(totals.tokens)) · \(Self.money(totals.cost, unit: "USD"))"
        ))
    }

    private static func rateLimitLabel(_ raw: String, language: AppLanguage) -> String {
        switch raw.lowercased() {
        case "5h": AppLocalization.text("5 小时限额", "5 hour limit", language: language)
        case "1d": AppLocalization.text("每日限额", "Daily limit", language: language)
        case "7d": AppLocalization.text("7 天限额", "7 day limit", language: language)
        default: AppLocalization.text("\(raw) 限额", "\(raw) limit", language: language)
        }
    }

    private static func usedFraction(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 1 }
        return min(1, max(0, used / limit))
    }

    private static func amount(used: Double, limit: Double, unit: String) -> String {
        "\(money(used, unit: unit)) / \(money(limit, unit: unit))"
    }

    private static func money(_ value: Double, unit: String) -> String {
        if unit.uppercased() == "USD" {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return "$\(formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))"
        }
        return "\(String(format: "%.2f", value)) \(unit)"
    }

    private static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

nonisolated enum Sub2APIUsageFetcher {
    private struct Response: Decodable {
        let mode: String?
        let isValid: Bool?
        let status: String?
        let planName: String?
        let remaining: Double?
        let balance: Double?
        let unit: String?
        let quota: Quota?
        let subscription: Subscription?
        let rateLimits: [RateLimit]?
        let usage: Usage?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case mode, isValid, status, planName, remaining, balance, unit, quota, subscription, usage
            case rateLimits = "rate_limits"
            case expiresAt = "expires_at"
        }
    }

    private struct Quota: Decodable {
        let limit: Double?
        let used: Double?
        let remaining: Double?
        let unit: String?
    }

    private struct Subscription: Decodable {
        let dailyUsage: Double?
        let weeklyUsage: Double?
        let monthlyUsage: Double?
        let dailyLimit: Double?
        let weeklyLimit: Double?
        let monthlyLimit: Double?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case dailyUsage = "daily_usage_usd"
            case weeklyUsage = "weekly_usage_usd"
            case monthlyUsage = "monthly_usage_usd"
            case dailyLimit = "daily_limit_usd"
            case weeklyLimit = "weekly_limit_usd"
            case monthlyLimit = "monthly_limit_usd"
            case expiresAt = "expires_at"
        }
    }

    private struct RateLimit: Decodable {
        let window: String?
        let limit: Double?
        let used: Double?
        let remaining: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case window, limit, used, remaining
            case resetsAt = "reset_at"
        }
    }

    private struct Usage: Decodable {
        let today: Totals?
        let total: Totals?
    }

    private struct Totals: Decodable {
        let requests: Int64?
        let tokens: Int64?
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case requests
            case tokens = "total_tokens"
            case cost = "actual_cost"
        }
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        endpointOverride configuredBaseURL: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["SUB2API_API_KEY"]) else {
            throw Sub2APIUsageError.missingAPIKey
        }
        let baseURL = try resolvedBaseURL(configured: configuredBaseURL, environment: environment)
        let endpoint = try usageURL(baseURL: baseURL, timeZone: timeZone)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Sub2APIUsageError.networkFailure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Sub2APIUsageError.parseFailure("response was not HTTP")
        }
        switch http.statusCode {
        case 200..<300:
            return try parse(data, now: now).toProviderUsage()
        case 401, 403:
            throw Sub2APIUsageError.unauthorized
        case 429:
            throw Sub2APIUsageError.rateLimited
        case 500...:
            throw Sub2APIUsageError.providerUnavailable(http.statusCode)
        default:
            throw Sub2APIUsageError.apiFailure(http.statusCode)
        }
    }

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        cleaned(configured) ?? cleaned(environment["SUB2API_API_KEY"])
    }

    static func resolvedBaseURL(configured: String?, environment: [String: String]) throws -> URL {
        guard let raw = cleaned(configured) ?? cleaned(environment["SUB2API_BASE_URL"]) else {
            throw Sub2APIUsageError.missingBaseURL
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let rawHost = components.host?.lowercased(),
              case let host = normalizedHost(rawHost),
              !host.isEmpty,
              !host.contains("%"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              scheme == "https" || isLoopback(host),
              let url = components.url,
              let encodedHost = url.host(percentEncoded: true),
              !encodedHost.contains("%")
        else {
            throw Sub2APIUsageError.invalidBaseURL
        }
        return url
    }

    static func usageURL(baseURL: URL, timeZone: TimeZone = .current) throws -> URL {
        var raw = baseURL.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix("/v1"), !raw.hasSuffix("/v1/usage") { raw += "/v1" }
        if !raw.hasSuffix("/usage") { raw += "/usage" }
        guard var components = URLComponents(string: raw) else { throw Sub2APIUsageError.invalidBaseURL }
        components.queryItems = [
            URLQueryItem(name: "days", value: "30"),
            URLQueryItem(name: "timezone", value: timeZone.identifier),
        ]
        guard let url = components.url else { throw Sub2APIUsageError.invalidBaseURL }
        return url
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Sub2APIUsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Sub2APIUsageError.parseFailure(decodingMessage(error))
        }
        if response.isValid == false { throw Sub2APIUsageError.unauthorized }

        let quota: Sub2APIQuota? = try response.quota.map { value in
            guard let limit = value.limit else { throw Sub2APIUsageError.parseFailure("quota.limit is required") }
            guard let used = value.used else { throw Sub2APIUsageError.parseFailure("quota.used is required") }
            guard let remaining = value.remaining else {
                throw Sub2APIUsageError.parseFailure("quota.remaining is required")
            }
            return Sub2APIQuota(limit: limit, used: used, remaining: remaining, unit: value.unit)
        }

        let subscription: Sub2APISubscription? = try response.subscription.map { value in
            Sub2APISubscription(
                dailyUsage: value.dailyUsage ?? 0,
                weeklyUsage: value.weeklyUsage ?? 0,
                monthlyUsage: value.monthlyUsage ?? 0,
                dailyLimit: value.dailyLimit,
                weeklyLimit: value.weeklyLimit,
                monthlyLimit: value.monthlyLimit,
                expiresAt: try parseDate(value.expiresAt, field: "subscription.expires_at")
            )
        }

        let rateLimits = try (response.rateLimits ?? []).enumerated().map { index, value in
            guard let window = cleaned(value.window) else {
                throw Sub2APIUsageError.parseFailure("rate_limits[\(index)].window is required")
            }
            guard let limit = value.limit else {
                throw Sub2APIUsageError.parseFailure("rate_limits[\(index)].limit is required")
            }
            guard let used = value.used else {
                throw Sub2APIUsageError.parseFailure("rate_limits[\(index)].used is required")
            }
            guard let remaining = value.remaining else {
                throw Sub2APIUsageError.parseFailure("rate_limits[\(index)].remaining is required")
            }
            return Sub2APIRateLimit(
                window: window,
                limit: limit,
                used: used,
                remaining: remaining,
                resetsAt: try parseDate(value.resetsAt, field: "rate_limits[\(index)].reset_at")
            )
        }

        let unit = cleaned(response.unit) ?? quota.flatMap { cleaned($0.unit) } ?? "USD"
        return Sub2APIUsageSnapshot(
            mode: response.mode,
            status: response.status,
            planName: response.planName,
            remaining: response.remaining,
            balance: response.balance,
            unit: unit,
            quota: quota,
            subscription: subscription,
            rateLimits: rateLimits,
            todayUsage: totals(response.usage?.today),
            totalUsage: totals(response.usage?.total),
            expiresAt: try parseDate(response.expiresAt, field: "expires_at"),
            updatedAt: now
        )
    }

    private static func totals(_ value: Totals?) -> Sub2APIUsageTotals? {
        value.map { Sub2APIUsageTotals(requests: $0.requests ?? 0, tokens: $0.tokens ?? 0, cost: $0.cost ?? 0) }
    }

    private static func parseDate(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        guard let date = ordinary.date(from: raw) else {
            throw Sub2APIUsageError.parseFailure("\(field) is not a valid date")
        }
        return date
    }

    private static func decodingMessage(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "response was not valid JSON" }
        switch decoding {
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return field.isEmpty ? "response must be an object" : "\(field) has an invalid type"
        case let .keyNotFound(key, context):
            let prefix = context.codingPath.map(\.stringValue).joined(separator: ".")
            return (prefix.isEmpty ? key.stringValue : "\(prefix).\(key.stringValue)") + " is required"
        case .dataCorrupted:
            return "response was not valid JSON"
        @unknown default:
            return "response was not valid JSON"
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              octets.dropFirst().allSatisfy({ UInt8($0) != nil })
        else { return false }
        return first == 127
    }

    private static func normalizedHost(_ host: String) -> String {
        if host.hasPrefix("["), host.hasSuffix("]") {
            return String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
