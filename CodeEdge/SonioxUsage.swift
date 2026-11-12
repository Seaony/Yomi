import Foundation

nonisolated enum SonioxUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Soniox 组织 API Key，请在设置中填写或设置 SONIOX_ORG_API_KEY", "Missing Soniox organization API key. Add one in Settings or set SONIOX_ORG_API_KEY")
        case .authenticationExpired:
            AppLocalization.text("Soniox 拒绝了组织 API Key，请确认它没有被撤销", "Soniox rejected the organization API key. Check that it has not been revoked.")
        case .permissionDenied:
            AppLocalization.text("Soniox 需要带“余额与花费”和“用量与限额”权限的组织 API Key，不支持项目 API Key", "Soniox requires an organization API key with Balance and spend and Usage and limits access. Project API keys are not supported.")
        case .rateLimited:
            AppLocalization.text("Soniox 请求频率受限，请稍后刷新", "Soniox rate limit reached. Wait a moment, then refresh.")
        case let .providerUnavailable(status):
            AppLocalization.text("Soniox 服务暂时不可用（HTTP \(status)）", "Soniox is temporarily unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Soniox 账单请求失败（HTTP \(status)）", "Soniox billing request failed (HTTP \(status))")
        case let .invalidField(field):
            AppLocalization.text("Soniox 返回的账单数据无效：\(field)", "Soniox returned invalid billing data: \(field)")
        }
    }
}

nonisolated enum SonioxUsageFetcher {
    private static let baseURL = URL(string: "https://api.soniox.com/v1/organization")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["SONIOX_ORG_API_KEY"]) else {
            throw SonioxUsageError.missingCredentials
        }
        let balance = try await get("balance", apiKey: apiKey, session: session)
        let monthly = try await get("usage/monthly", apiKey: apiKey, session: session)
        return try parse(balance: balance, monthly: monthly, now: now)
    }

    static func parse(balance: Data, monthly: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let billing = try? JSONSerialization.jsonObject(with: balance) as? [String: Any] else {
            throw SonioxUsageError.invalidField("expected an object")
        }
        guard let usage = try? JSONSerialization.jsonObject(with: monthly) as? [String: Any] else {
            throw SonioxUsageError.invalidField("expected an object")
        }
        let available = try money(billing["available_balance_usd"], field: "available_balance_usd", signed: true)
        guard let invoiceBilling = billing["invoice_billing_enabled"] as? NSNumber,
              CFGetTypeID(invoiceBilling) == CFBooleanGetTypeID() else {
            throw SonioxUsageError.invalidField("invoice_billing_enabled")
        }
        let used = try money(usage["usage_usd"], field: "usage_usd")
        let budget = try money(usage["monthly_budget_usd"], field: "monthly_budget_usd")
        guard let month = usage["month"] as? String,
              month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
            throw SonioxUsageError.invalidField("month")
        }
        // 月预算在下个月 1 日（UTC）重置。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let resetsAt = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
            .flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }

        let isPrepaid = !invoiceBilling.boolValue
        let windows = budget > 0 ? [UsageWindow(
            id: "soniox-budget",
            label: "Monthly budget",
            usedFraction: min(1, used / budget),
            resetsAt: resetsAt,
            detail: "\(usd(used)) / \(usd(budget))"
        )] : []
        var details = [UsageDetail(
            id: "soniox-billing",
            label: AppLocalization.text("计费方式", "Billing"),
            value: isPrepaid ? AppLocalization.text("预付费", "Prepaid") : AppLocalization.text("发票结算", "Invoice billing")
        )]
        if budget == 0 {
            details.append(UsageDetail(id: "soniox-budget", label: AppLocalization.text("每月预算", "Monthly budget"), value: usd(0)))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "soniox"),
            state: .ready,
            windows: windows,
            balance: isPrepaid ? usd(available) : nil,
            providerCost: ProviderCostSummary(
                used: used, limit: budget, currencyCode: "USD", period: AppLocalization.text("本月", "This month"),
                balance: isPrepaid ? available : nil
            ),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func get(_ path: String, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SonioxUsageError.invalidField("response") }
        switch http.statusCode {
        case 200: return data
        case 401: throw SonioxUsageError.authenticationExpired
        case 403: throw SonioxUsageError.permissionDenied
        case 429: throw SonioxUsageError.rateLimited
        case 500...: throw SonioxUsageError.providerUnavailable(http.statusCode)
        default: throw SonioxUsageError.apiFailure(http.statusCode)
        }
    }

    // Soniox 的金额是十进制字符串。
    private static func money(_ value: Any?, field: String, signed: Bool = false) throws -> Double {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
              text.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let amount = Double(text), amount.isFinite, signed || amount >= 0 else {
            throw SonioxUsageError.invalidField(field)
        }
        return amount
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
