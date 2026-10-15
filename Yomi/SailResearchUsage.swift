import Foundation

nonisolated enum SailResearchUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case creditsExhausted
    case permissionDenied
    case rateLimited
    case unavailable
    case missingBillingAccount
    case networkError
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Sail Research API Key", "Missing Sail Research API key")
        case .unauthorized:
            AppLocalization.text("Sail Research API Key 无效或已过期", "The Sail Research API key is invalid or expired")
        case .creditsExhausted:
            AppLocalization.text("Sail Research 余额已用完，API Key 已停用", "Sail Research disabled this API key because credits are exhausted")
        case .permissionDenied:
            AppLocalization.text("Sail Research API Key 无权访问组织账单", "The Sail Research API key cannot access organization billing")
        case .rateLimited:
            AppLocalization.text("Sail Research 用量请求过于频繁", "Sail Research usage requests are rate limited")
        case .unavailable:
            AppLocalization.text("Sail Research 账单数据暂时不可用", "Sail Research billing data is temporarily unavailable")
        case .missingBillingAccount:
            AppLocalization.text("Sail Research 组织尚未开通账单账户", "The Sail Research organization has no billing account")
        case .networkError:
            AppLocalization.text("Sail Research 网络请求失败", "Sail Research network request failed")
        case let .apiError(status):
            AppLocalization.text("Sail Research 请求失败（HTTP \(status)）", "Sail Research request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("无法解析 Sail Research 账单数据", "Failed to parse Sail Research billing data")
        }
    }
}

nonisolated enum SailResearchUsageFetcher {
    static let endpoint = URL(string: "https://api.sailresearch.com/v2/usage/summary?range=30d")!
    static let environmentKeys = ["SAIL_API_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["SAIL_API_KEY"]] {
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configuredAPIKey, environment: environment) else {
            throw SailResearchUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SailResearchUsageError.networkError
        }
        guard let http = response as? HTTPURLResponse else { throw SailResearchUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw SailResearchUsageError.unauthorized
        case 402: throw SailResearchUsageError.creditsExhausted
        case 403: throw SailResearchUsageError.permissionDenied
        case 429: throw SailResearchUsageError.rateLimited
        case 500...599: throw SailResearchUsageError.unavailable
        default: throw SailResearchUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "usage.summary"
        else { throw SailResearchUsageError.invalidResponse }
        guard try boolean(root["available"]) else { throw SailResearchUsageError.unavailable }
        guard try boolean(root["has_metronome_customer"]) else {
            throw SailResearchUsageError.missingBillingAccount
        }
        let balanceUnavailable = try boolean(root["balance_unavailable"])
        let spend = try dollars(root["period_spend"])
        guard spend >= 0, let range = root["effective_range"] as? String else {
            throw SailResearchUsageError.invalidResponse
        }
        let spendLabel: String
        switch range {
        case "1h": spendLabel = AppLocalization.text("最近 1 小时消费", "Last hour spend")
        case "6h": spendLabel = AppLocalization.text("最近 6 小时消费", "Last 6 hours spend")
        case "24h": spendLabel = AppLocalization.text("最近 24 小时消费", "Last 24 hours spend")
        case "7d": spendLabel = AppLocalization.text("最近 7 天消费", "Last 7 days spend")
        case "30d": spendLabel = AppLocalization.text("最近 30 天消费", "Last 30 days spend")
        case "period": spendLabel = AppLocalization.text("账单周期消费", "Billing-period spend")
        default: throw SailResearchUsageError.invalidResponse
        }
        let balance = try balanceUnavailable ? nil : usd(dollars(root["balance"]))
        return ProviderUsage(
            id: ProviderID(rawValue: "sailresearch"),
            state: .ready,
            windows: [],
            balance: balance,
            details: [
                UsageDetail(
                    id: "sailresearch-balance",
                    label: AppLocalization.text("组织余额", "Organization credit balance"),
                    value: balance ?? AppLocalization.text("暂不可用", "Unavailable")
                ),
                UsageDetail(id: "sailresearch-spend", label: spendLabel, value: usd(spend)),
            ],
            updatedAt: now,
            message: nil
        )
    }

    private static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw SailResearchUsageError.invalidResponse
        }
        return number.boolValue
    }

    private static func dollars(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { throw SailResearchUsageError.invalidResponse }
        return number.doubleValue / 100
    }

    private static func usd(_ value: Double) -> String {
        String(format: value < 0 ? "-$%.2f" : "$%.2f", abs(value))
    }
}
