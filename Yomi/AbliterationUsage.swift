import Foundation

nonisolated enum AbliterationUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 abliteration.ai API Key，请在设置中填写或设置 ABLITERATION_API_KEY", "Missing abliteration.ai API key. Add one in Settings or set ABLITERATION_API_KEY")
        case .authenticationExpired:
            AppLocalization.text("abliteration.ai API Key 无效，请在设置中检查", "Check your abliteration.ai API key in Settings.")
        case .rateLimited:
            AppLocalization.text("abliteration.ai 请求频率受限，请稍后再试", "abliteration.ai is rate limiting requests. Try again later.")
        case let .providerUnavailable(status):
            AppLocalization.text("abliteration.ai 服务暂时不可用（HTTP \(status)）", "abliteration.ai is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("abliteration.ai 请求失败（HTTP \(status)）", "abliteration.ai request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("abliteration.ai 返回了无法识别的内容", "abliteration.ai returned an unrecognized response")
        }
    }
}

nonisolated enum AbliterationUsageFetcher {
    static let creditsURL = URL(string: "https://api.abliteration.ai/v1/credits")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["ABLITERATION_API_KEY"]) else {
            throw AbliterationUsageError.missingCredentials
        }
        var request = URLRequest(url: creditsURL)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AbliterationUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw AbliterationUsageError.authenticationExpired
        case 429: throw AbliterationUsageError.rateLimited
        case 500...: throw AbliterationUsageError.providerUnavailable(http.statusCode)
        default: throw AbliterationUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any],
              let total = money(body["total_credits"]),
              let used = money(body["total_usage"]) else {
            throw AbliterationUsageError.parseFailure
        }
        let windows = total > 0 ? [UsageWindow(
            id: "abliteration-credits",
            label: "Credits",
            usedFraction: min(1, used / total),
            resetsAt: nil,
            detail: "\(usd(used)) / \(usd(total))"
        )] : []
        return ProviderUsage(
            id: ProviderID(rawValue: "abliteration"),
            state: .ready,
            windows: windows,
            balance: usd(max(0, total - used)),
            details: [
                UsageDetail(id: "abliteration-balance", label: AppLocalization.text("余额", "Balance"), value: usd(max(0, total - used))),
                UsageDetail(id: "abliteration-used", label: AppLocalization.text("已用额度", "Credits used"), value: usd(used)),
                UsageDetail(id: "abliteration-total", label: AppLocalization.text("总额度", "Credits"), value: usd(total)),
            ],
            updatedAt: now,
            message: nil
        )
    }

    // JSON 里的布尔值也会被当成数字，这里只接受真正的数字。
    private static func money(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let amount = number.doubleValue
        return amount.isFinite && amount >= 0 ? amount : nil
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
