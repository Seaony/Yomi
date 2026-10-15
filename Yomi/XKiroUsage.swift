import CoreFoundation
import Foundation

nonisolated enum XKiroUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case permissionDenied
    case rateLimited(retryAfterSeconds: TimeInterval)
    case providerUnavailable(Int)
    case apiFailure(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 xKiro API Key，请添加或设置 XKIRO_API_KEY", "Missing xKiro API key. Add one or set XKIRO_API_KEY.")
        case .unauthorized:
            AppLocalization.text("xKiro API Key 无效或已过期", "The xKiro API key is invalid or expired.")
        case .permissionDenied:
            AppLocalization.text("xKiro 拒绝访问用量", "xKiro denied access to usage.")
        case .rateLimited:
            AppLocalization.text("xKiro 请求频率受限", "xKiro rate limit reached.")
        case let .providerUnavailable(status):
            AppLocalization.text("xKiro 暂时不可用（HTTP \(status)）", "xKiro is unavailable (HTTP \(status)).")
        case let .apiFailure(status):
            AppLocalization.text("xKiro 请求失败（HTTP \(status)）", "xKiro request failed (HTTP \(status)).")
        case .invalidResponse:
            AppLocalization.text("无法解析 xKiro 免费 Token 用量", "Could not parse xKiro free-token usage.")
        }
    }
}

nonisolated struct XKiroUsageSnapshot: Sendable, Equatable {
    let used: Int64?
    let limit: Int64?
    let remaining: Int64?
    let uncapped: Bool
    let accountEmail: String?
    let plan: String?
    let payAsYouGo: Bool
    let updatedAt: Date

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let used, let limit {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            windows.append(UsageWindow(
                id: "xkiro-daily-free-tokens",
                label: AppLocalization.text("每日免费 Token", "Daily free tokens", language: language),
                usedFraction: limit == 0 ? 1 : min(1, max(0, Double(used) / Double(limit))),
                resetsAt: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: updatedAt)),
                detail: "\(Self.count(used)) / \(Self.count(limit)) tokens"
            ))
        }
        var details: [UsageDetail] = []
        if let used {
            details.append(UsageDetail(
                id: "xkiro-used",
                label: AppLocalization.text("今日已用 Token", "Tokens used today", language: language),
                value: Self.count(used)
            ))
        }
        if let limit {
            details.append(UsageDetail(
                id: "xkiro-limit",
                label: AppLocalization.text("每日额度", "Daily allowance", language: language),
                value: Self.count(limit)
            ))
        } else if uncapped {
            details.append(UsageDetail(
                id: "xkiro-limit",
                label: AppLocalization.text("每日额度", "Daily allowance", language: language),
                value: AppLocalization.text("未报告上限", "No cap reported", language: language)
            ))
        }
        if let remaining {
            details.append(UsageDetail(
                id: "xkiro-remaining",
                label: AppLocalization.text("剩余 Token", "Tokens remaining", language: language),
                value: Self.count(remaining)
            ))
        }
        details.append(UsageDetail(
            id: "xkiro-reset",
            label: AppLocalization.text("每日重置", "Daily reset", language: language),
            value: "00:00 UTC"
        ))
        if let accountEmail {
            details.append(UsageDetail(
                id: "xkiro-account",
                label: AppLocalization.text("账号", "Account", language: language),
                value: accountEmail
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "xkiro"),
            state: .ready,
            windows: windows,
            plan: payAsYouGo ? AppLocalization.text("按量付费", "Pay as you go", language: language) : plan,
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func count(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

nonisolated enum XKiroUsageFetcher {
    static let endpoint = URL(string: "https://api.xkiro.com/v1/usage")!
    static let apiKeyEnvironmentKey = "XKIRO_API_KEY"

    static func fetch(
        apiKey: String?,
        source: ProviderSource,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .token,
              let token = cleaned(apiKey) ?? cleaned(environment[apiKeyEnvironmentKey]) else {
            throw XKiroUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XKiroUsageError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try parse(data, now: now).toProviderUsage()
        case 401:
            throw XKiroUsageError.unauthorized
        case 403:
            throw XKiroUsageError.permissionDenied
        case 429:
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            throw XKiroUsageError.rateLimited(retryAfterSeconds: delay.isFinite && delay >= 0 ? min(delay, 10) : 1)
        case let status where status >= 500:
            throw XKiroUsageError.providerUnavailable(http.statusCode)
        default:
            throw XKiroUsageError.apiFailure(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> XKiroUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "usage",
              let free = root["free_tokens"] as? [String: Any] else {
            throw XKiroUsageError.invalidResponse
        }
        let used = try counter(free["used_today"])
        let limit = try counter(free["limit_per_day"])
        let remaining = try counter(free["remaining"])
        let uncapped = free["limit_per_day"] is NSNull
        guard used != nil || limit != nil || remaining != nil || uncapped else {
            throw XKiroUsageError.invalidResponse
        }
        let user = root["user"] as? [String: Any]
        return XKiroUsageSnapshot(
            used: used,
            limit: limit,
            remaining: remaining,
            uncapped: uncapped,
            accountEmail: cleaned(user?["email"] as? String),
            plan: cleaned(root["plan"] as? String),
            payAsYouGo: root["plan"] is NSNull,
            updatedAt: now
        )
    }

    private static func counter(_ value: Any?) throws -> Int64? {
        if value == nil || value is NSNull { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw XKiroUsageError.invalidResponse }
        let count = number.doubleValue
        guard count.isFinite, count >= 0, count <= 9_007_199_254_740_991, count.rounded(.towardZero) == count else {
            throw XKiroUsageError.invalidResponse
        }
        return Int64(count)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
