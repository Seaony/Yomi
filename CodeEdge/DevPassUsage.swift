import Foundation

nonisolated enum DevPassUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case permissionDenied
    case rateLimited
    case unavailable
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 DevPass API Key", "Missing DevPass API key")
        case .unauthorized:
            AppLocalization.text("DevPass API Key 无效或已停用", "The DevPass API key is invalid or inactive")
        case .permissionDenied:
            AppLocalization.text("DevPass 需要常规 Gateway API Key", "DevPass requires a regular gateway API key")
        case .rateLimited:
            AppLocalization.text("DevPass 用量请求过于频繁", "DevPass usage requests are rate limited")
        case .unavailable:
            AppLocalization.text("DevPass 用量暂时不可用", "DevPass usage is temporarily unavailable")
        case let .apiError(status):
            AppLocalization.text("DevPass 请求失败（HTTP \(status)）", "DevPass request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("无法解析 DevPass 用量数据", "Failed to parse DevPass usage data")
        }
    }
}

nonisolated enum DevPassUsageFetcher {
    static let endpoint = URL(string: "https://api.llmgateway.io/v1/key")!
    static let environmentKeys = ["DEVPASS_API_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["DEVPASS_API_KEY"]] {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw DevPassUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DevPassUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw DevPassUsageError.unauthorized
        case 403: throw DevPassUsageError.permissionDenied
        case 429: throw DevPassUsageError.rateLimited
        case 500...599: throw DevPassUsageError.unavailable
        default: throw DevPassUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["data"] as? [String: Any],
              let plan = values["devPlan"] as? String,
              ["none", "lite", "pro", "max"].contains(plan)
        else {
            throw DevPassUsageError.invalidResponse
        }
        let keyUsed = try money(values["usage"])
        let keyLimit: Double?
        if values["limit"] is NSNull {
            keyLimit = nil
        } else {
            keyLimit = try money(values["limit"])
        }
        var details = [UsageDetail(
            id: "devpass-key-used",
            label: AppLocalization.text("Key 累计消费", "All-time key usage"),
            value: usd(keyUsed)
        )]
        if let keyLimit {
            details.append(UsageDetail(
                id: "devpass-key-limit",
                label: AppLocalization.text("Key 消费上限", "Key spending limit"),
                value: usd(keyLimit)
            ))
        }
        var windows: [UsageWindow] = []
        if plan != "none" {
            let used = try money(values["devPlanCreditsUsed"])
            let limit = try money(values["devPlanCreditsLimit"])
            let remaining = try money(values["devPlanCreditsRemaining"])
            let weeklyUsed = try money(values["devPlanPremiumCreditsUsed"])
            let weeklyLimit = try money(values["devPlanPremiumWeeklyLimit"])
            let resetsAt = try resetDate(values["devPlanPremiumWeekResetsAt"])
            if limit > 0 {
                windows.append(UsageWindow(
                    id: "devpass-cycle",
                    label: AppLocalization.text("套餐额度", "Plan credits"),
                    usedFraction: min(1, used / limit),
                    resetsAt: nil,
                    detail: "\(usd(used)) / \(usd(limit))"
                ))
            }
            if weeklyLimit > 0 {
                windows.append(UsageWindow(
                    id: "devpass-premium-weekly",
                    label: AppLocalization.text("Premium 周额度", "Premium weekly"),
                    usedFraction: min(1, weeklyUsed / weeklyLimit),
                    resetsAt: resetsAt,
                    detail: "\(usd(weeklyUsed)) / \(usd(weeklyLimit))"
                ))
            }
            details.insert(contentsOf: [
                UsageDetail(
                    id: "devpass-cycle-used",
                    label: AppLocalization.text("周期已用", "Cycle used"),
                    value: "\(usd(used)) / \(usd(limit))"
                ),
                UsageDetail(
                    id: "devpass-cycle-remaining",
                    label: AppLocalization.text("周期剩余", "Cycle remaining"),
                    value: usd(remaining)
                ),
                UsageDetail(
                    id: "devpass-weekly-used",
                    label: AppLocalization.text("Premium 周额度", "Premium weekly"),
                    value: "\(usd(weeklyUsed)) / \(usd(weeklyLimit))"
                ),
            ], at: 0)
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "devpass"),
            state: .ready,
            windows: windows,
            plan: plan == "none"
                ? AppLocalization.text("按量付费", "Pay as you go")
                : "DevPass \(plan.capitalized)",
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func money(_ value: Any?) throws -> Double {
        guard let value = value as? String,
              value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Double(value), amount.isFinite
        else {
            throw DevPassUsageError.invalidResponse
        }
        return amount
    }

    private static func resetDate(_ value: Any?) throws -> Date? {
        if value is NSNull { return nil }
        guard let value = value as? String,
              value.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                options: .regularExpression
              ) != nil
        else {
            throw DevPassUsageError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw DevPassUsageError.invalidResponse }
        return date
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}
