import CoreFoundation
import Foundation

nonisolated enum TavilyUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unsupportedSource
    case unauthorized
    case permissionDenied
    case rateLimited
    case serviceUnavailable(Int)
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Tavily API Key，请在设置中填写或设置 TAVILY_API_KEY", "Missing Tavily API key. Enter it in Settings or set TAVILY_API_KEY.")
        case .unsupportedSource:
            AppLocalization.text("Tavily 仅支持 API Key", "Tavily only supports an API key.")
        case .unauthorized:
            AppLocalization.text("Tavily API Key 无效或已过期", "The Tavily API key is invalid or expired.")
        case .permissionDenied:
            AppLocalization.text("Tavily API Key 没有读取用量的权限", "The Tavily API key does not have permission to read usage.")
        case .rateLimited:
            AppLocalization.text("Tavily 用量请求太频繁，每 10 分钟最多请求 10 次", "Tavily usage requests are rate limited to 10 requests per 10 minutes.")
        case let .serviceUnavailable(status):
            AppLocalization.text("Tavily 服务暂时不可用（HTTP \(status)）", "Tavily service is temporarily unavailable (HTTP \(status)).")
        case let .apiError(status):
            AppLocalization.text("Tavily 请求失败（HTTP \(status)）", "Tavily request failed (HTTP \(status)).")
        case .parseFailed:
            AppLocalization.text("无法识别 Tavily 返回的积分用量", "The Tavily credit usage response could not be read.")
        }
    }
}

nonisolated enum TavilyUsageFetcher {
    static let usageURL = URL(string: "https://api.tavily.com/usage")!

    static func fetch(
        source: ProviderSource,
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .token else { throw TavilyUsageError.unsupportedSource }
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["TAVILY_API_KEY"]) else {
            throw TavilyUsageError.missingCredentials
        }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TavilyUsageError.parseFailed }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw TavilyUsageError.unauthorized
        case 403: throw TavilyUsageError.permissionDenied
        case 429: throw TavilyUsageError.rateLimited
        case 500...: throw TavilyUsageError.serviceUnavailable(http.statusCode)
        default: throw TavilyUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let key = root["key"] as? [String: Any] else {
            throw TavilyUsageError.parseFailed
        }
        let planUsed = try count(account["plan_usage"])
        let planLimit = try count(account["plan_limit"])
        let keyUsed = try count(key["usage"])
        let keyLimit: Double? = key["limit"] is NSNull ? nil : try count(key["limit"])
        let plan: String
        if let raw = account["current_plan"] {
            guard let name = raw as? String, name.utf16.count <= 120, let name = cleaned(name) else {
                throw TavilyUsageError.parseFailed
            }
            plan = name
        } else {
            plan = AppLocalization.text("API Key", "API key")
        }
        var windows: [UsageWindow] = []
        if planLimit > 0 {
            windows.append(UsageWindow(
                id: "tavily-plan",
                label: AppLocalization.text("套餐积分", "Plan credits"),
                usedFraction: min(1, planUsed / planLimit),
                resetsAt: nil,
                detail: "\(credits(planUsed)) / \(credits(planLimit))"
            ))
        }
        if let keyLimit, keyLimit > 0 {
            windows.append(UsageWindow(
                id: "tavily-key",
                label: AppLocalization.text("API Key", "API key"),
                usedFraction: min(1, keyUsed / keyLimit),
                resetsAt: nil,
                detail: "\(credits(keyUsed)) / \(credits(keyLimit))"
            ))
        }
        var details = creditDetails(
            id: "plan",
            title: AppLocalization.text("账号套餐", "Account plan"),
            used: planUsed,
            limit: planLimit
        ) + creditDetails(
            id: "key",
            title: AppLocalization.text("API Key", "API key"),
            used: keyUsed,
            limit: keyLimit
        )
        if account["paygo_usage"] != nil || account["paygo_limit"] != nil {
            details += try creditDetails(
                id: "paygo",
                title: AppLocalization.text("按量付费", "Pay as you go"),
                used: count(account["paygo_usage"]),
                limit: count(account["paygo_limit"])
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "tavily"),
            state: .ready,
            windows: windows,
            plan: plan,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func count(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw TavilyUsageError.parseFailed
        }
        let count = number.doubleValue
        guard count.isFinite, count >= 0, count <= 9_007_199_254_740_991, count.rounded(.towardZero) == count else {
            throw TavilyUsageError.parseFailed
        }
        return count
    }

    private static func creditDetails(id: String, title: String, used: Double, limit: Double?) -> [UsageDetail] {
        var details = [
            UsageDetail(id: "tavily-\(id)-used", label: "\(title) · \(AppLocalization.text("已用", "Used"))", value: credits(used)),
            UsageDetail(
                id: "tavily-\(id)-limit",
                label: "\(title) · \(AppLocalization.text("上限", "Limit"))",
                value: limit.map(credits) ?? AppLocalization.text("不限量", "Unlimited")
            ),
        ]
        if let limit {
            details.append(UsageDetail(
                id: "tavily-\(id)-remaining",
                label: "\(title) · \(AppLocalization.text("剩余", "Remaining"))",
                value: credits(max(0, limit - used))
            ))
        }
        return details
    }

    private static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLocalization.currentLanguage.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return AppLocalization.text("\(number) 积分", "\(number) credits")
    }

    private static func cleaned(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
