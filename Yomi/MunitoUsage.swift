import Foundation

nonisolated enum MunitoUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Munito Admin API Key，请在设置中填写或设置 MUNITO_API_KEY", "Missing Munito admin API key. Add one in Settings or set MUNITO_API_KEY")
        case .authenticationExpired:
            AppLocalization.text("Munito API Key 无效或已过期", "The Munito API key is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("Munito 拒绝了这个密钥：Admin API 需要带“Read account data”权限的密钥", "Munito rejected the key: the Admin API needs a key with Read account data permission.")
        case .rateLimited:
            AppLocalization.text("Munito 请求频率受限", "Munito rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("Munito 服务暂时不可用（HTTP \(status)）", "Munito is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Munito 请求失败（HTTP \(status)）", "Munito request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("Munito 返回了无法识别的花费限额", "Munito returned an unrecognized spend limits response")
        }
    }
}

nonisolated enum MunitoUsageFetcher {
    private static let baseURL = URL(string: "https://api.munito.ai/admin/v1")!

    struct Period: Equatable {
        let spent: Double
        let limit: Double?
        let organizationLimit: Double?
        let accountLimit: Double?
        let stoppedUntil: String?
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey)
            ?? cleaned(environment["MUNITO_API_KEY"]) ?? cleaned(environment["MUNITO_ADMIN_KEY"]) else {
            throw MunitoUsageError.missingCredentials
        }
        let (limitsData, status) = try await get("limits", apiKey: apiKey, session: session)
        switch status {
        case 200: break
        case 401: throw MunitoUsageError.authenticationExpired
        case 403: throw MunitoUsageError.permissionDenied
        case 429: throw MunitoUsageError.rateLimited
        case 500...: throw MunitoUsageError.providerUnavailable(status)
        default: throw MunitoUsageError.apiFailure(status)
        }
        // 组织信息只是补充，读不到不影响花费和限额。
        let organization: [String: Any]? = if let (data, status) = try? await get("organization", apiKey: apiKey, session: session),
                                               status == 200 {
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            nil
        }
        return try parse(limitsData, organization: organization, now: now)
    }

    static func parse(_ data: Data, organization: [String: Any]? = nil, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPeriods = root["periods"] as? [Any] else { throw MunitoUsageError.parseFailure }
        var periods: [String: Period] = [:]
        for raw in rawPeriods {
            guard let entry = raw as? [String: Any] else { throw MunitoUsageError.parseFailure }
            guard let kind = text(entry["period"]), kind == "day" || kind == "month" else { continue }
            let stopped = text(entry["stopped_until"])
            if let stopped, stopped.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                options: .regularExpression
            ) == nil { throw MunitoUsageError.parseFailure }
            periods[kind] = Period(
                spent: try money(entry["spent_usd"]),
                limit: try optionalMoney(entry["limit_usd"]),
                organizationLimit: try optionalMoney(entry["organization_limit_usd"]),
                accountLimit: try optionalMoney(entry["account_limit_usd"]),
                stoppedUntil: stopped
            )
        }
        let day = periods["day"]
        let month = periods["month"]
        var details: [UsageDetail] = []
        func addRows(_ key: String, label: String, period: Period) {
            let spend = usd(period.spent)
            let value = if let limit = period.limit, limit > 0 { "\(spend) / \(usd(limit))" } else { spend }
            details.append(UsageDetail(id: "munito-\(key)", label: label, value: value))
            if let limit = period.organizationLimit, limit > 0, limit != period.limit {
                details.append(UsageDetail(
                    id: "munito-\(key)-organization", label: label + AppLocalization.text(" 组织限额", " organization limit"), value: usd(limit)
                ))
            }
            if let limit = period.accountLimit, limit > 0, limit != period.limit {
                details.append(UsageDetail(
                    id: "munito-\(key)-account", label: label + AppLocalization.text(" 账号限额", " account limit"), value: usd(limit)
                ))
            }
            if let stopped = period.stoppedUntil {
                details.append(UsageDetail(
                    id: "munito-\(key)-stopped", label: label + AppLocalization.text(" 停用至", " stopped until"), value: stopped
                ))
            }
        }
        if let day { addRows("day", label: AppLocalization.text("今天", "Today"), period: day) }
        if let month { addRows("month", label: AppLocalization.text("本月", "This month"), period: month) }
        if let tier = text(root["usage_tier"]) ?? text(organization?["usage_tier"]) {
            details.append(UsageDetail(id: "munito-tier", label: AppLocalization.text("用量等级", "Usage tier"), value: tier))
        }
        if let status = text(organization?["status"]) {
            details.append(UsageDetail(id: "munito-status", label: AppLocalization.text("组织状态", "Status"), value: status.prefix(1).uppercased() + status.dropFirst()))
        }
        if let region = text(organization?["data_region"]) {
            details.append(UsageDetail(id: "munito-region", label: AppLocalization.text("数据区域", "Data region"), value: region))
        }

        var windows: [UsageWindow] = []
        if let day, let limit = day.limit, limit > 0 {
            windows.append(UsageWindow(id: "munito-day", label: "Today", usedFraction: min(1, day.spent / limit), resetsAt: nil, detail: nil))
        }
        if let month, let limit = month.limit, limit > 0 {
            windows.append(UsageWindow(id: "munito-month", label: "This month", usedFraction: min(1, month.spent / limit), resetsAt: nil, detail: nil))
        }
        let costPeriod = month ?? day
        return ProviderUsage(
            id: ProviderID(rawValue: "munito"),
            state: .ready,
            windows: windows,
            plan: text(organization?["name"]),
            providerCost: costPeriod.map {
                ProviderCostSummary(
                    used: $0.spent, limit: $0.limit ?? 0, currencyCode: "USD",
                    period: month != nil ? AppLocalization.text("本月", "This month") : AppLocalization.text("今天", "Today"),
                    balance: nil
                )
            },
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func get(_ path: String, apiKey: String, session: URLSession) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MunitoUsageError.parseFailure }
        return (data, http.statusCode)
    }

    // 金额可能是数字或数字字符串，负数和其他格式都当作接口异常。
    private static func money(_ value: Any?) throws -> Double {
        let amount: Double? = if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            number.doubleValue
        } else if let text = value as? String,
                  text.range(of: #"^\s*-?\d+(?:\.\d+)?\s*$"#, options: .regularExpression) != nil {
            Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            nil
        }
        guard let amount, amount.isFinite, amount >= 0 else { throw MunitoUsageError.parseFailure }
        return amount
    }

    private static func optionalMoney(_ value: Any?) throws -> Double? {
        value == nil || value is NSNull ? nil : try money(value)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        text(value)
    }
}
