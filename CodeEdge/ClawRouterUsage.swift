import Foundation

nonisolated enum ClawRouterUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidEndpoint
    case unauthorized
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 ClawRouter API Key", "Missing ClawRouter API key")
        case .invalidEndpoint:
            AppLocalization.text("ClawRouter Base URL 必须是 HTTPS 或裸主机名", "ClawRouter Base URL must use HTTPS or a bare host")
        case .unauthorized:
            AppLocalization.text("ClawRouter 拒绝了 API Key", "ClawRouter rejected the API key")
        case .rateLimited:
            AppLocalization.text("ClawRouter 请求频率受限", "ClawRouter rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("ClawRouter 暂时不可用（HTTP \(status)）", "ClawRouter is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("ClawRouter 请求失败（HTTP \(status)）", "ClawRouter request failed (HTTP \(status))")
        case let .parseFailure(message):
            AppLocalization.text("无法解析 ClawRouter 用量：\(message)", "Failed to parse ClawRouter usage: \(message)")
        }
    }
}

nonisolated enum ClawRouterUsageFetcher {
    struct RoutedProvider: Sendable, Equatable {
        let name: String
        let requests: Int64
        let successes: Int64
        let errors: Int64
        let tokens: Int64
        let cost: Double
    }

    struct Snapshot: Sendable, Equatable {
        let budgetConfigured: Bool
        let budgetLedger: String
        let budgetLimit: Double?
        let budgetSpent: Double?
        let budgetRemaining: Double?
        let budgetResetsAt: Date?
        let requestCount: Int64
        let successCount: Int64
        let errorCount: Int64
        let inputTokens: Int64
        let outputTokens: Int64
        let totalTokens: Int64
        let actualCost: Double
        let providers: [RoutedProvider]
        let updatedAt: Date

        func toProviderUsage() -> ProviderUsage {
            var windows: [UsageWindow] = []
            var providerCost: ProviderCostSummary?
            if let spent = budgetSpent, let limit = budgetLimit {
                if limit > 0 {
                    windows.append(UsageWindow(
                        id: "clawrouter-monthly-budget",
                        label: AppLocalization.text("月度预算", "Monthly budget"),
                        usedFraction: max(0, min(spent / limit, 1)),
                        resetsAt: budgetResetsAt,
                        detail: String(format: "$%.6f / $%.2f", spent, limit)
                    ))
                }
                providerCost = ProviderCostSummary(
                    used: spent,
                    limit: limit,
                    currencyCode: "USD",
                    period: AppLocalization.text("本月", "This month"),
                    balance: budgetRemaining
                )
            } else if actualCost > 0 {
                providerCost = ProviderCostSummary(
                    used: actualCost,
                    limit: 0,
                    currencyCode: "USD",
                    period: AppLocalization.text("本月", "This month"),
                    balance: nil
                )
            }

            var details = [
                UsageDetail(
                    id: "clawrouter-requests",
                    label: AppLocalization.text("请求", "Requests"),
                    value: "\(requestCount) · \(successCount) succeeded · \(errorCount) failed"
                ),
                UsageDetail(
                    id: "clawrouter-tokens",
                    label: "Tokens",
                    value: "\(totalTokens) · \(inputTokens) input · \(outputTokens) output"
                ),
                UsageDetail(
                    id: "clawrouter-actual-cost",
                    label: AppLocalization.text("实际费用", "Actual cost"),
                    value: String(format: "$%.6f", actualCost)
                ),
            ]
            if let spent = budgetSpent, let limit = budgetLimit {
                var value = String(format: "$%.6f / $%.2f", spent, limit)
                if let budgetRemaining { value += String(format: " · $%.6f remaining", budgetRemaining) }
                details.append(UsageDetail(
                    id: "clawrouter-budget",
                    label: AppLocalization.text("月度预算", "Monthly budget"),
                    value: value
                ))
            }
            return ProviderUsage(
                id: ProviderID(rawValue: "clawrouter"),
                state: .ready,
                windows: windows,
                plan: nil,
                providerCost: providerCost,
                details: details,
                updatedAt: updatedAt,
                message: nil
            )
        }
    }

    static let defaultBaseURL = URL(string: "https://clawrouter.openclaw.ai")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        endpointOverride configuredEndpoint: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["CLAWROUTER_API_KEY"]) else {
            throw ClawRouterUsageError.missingCredentials
        }
        let endpoint = try usageURL(configured: configuredEndpoint, environment: environment)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClawRouterUsageError.parseFailure("invalid response") }
        switch http.statusCode {
        case 200..<300: return try parse(data, now: now).toProviderUsage()
        case 401, 403: throw ClawRouterUsageError.unauthorized
        case 429: throw ClawRouterUsageError.rateLimited
        case 500...: throw ClawRouterUsageError.providerUnavailable(http.statusCode)
        default: throw ClawRouterUsageError.apiFailure(http.statusCode)
        }
    }

    static func usageURL(configured: String?, environment: [String: String]) throws -> URL {
        let base: URL
        if let raw = cleaned(configured) ?? cleaned(environment["CLAWROUTER_BASE_URL"]) {
            var candidate = raw
            if !candidate.contains("://") { candidate = "https://\(candidate)" }
            guard var components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else { throw ClawRouterUsageError.invalidEndpoint }
            components.scheme = "https"
            guard let value = components.url else { throw ClawRouterUsageError.invalidEndpoint }
            base = value
        } else {
            base = defaultBaseURL
        }
        var value = base
        while value.path.count > 1, value.path.hasSuffix("/") { value.deleteLastPathComponent() }
        if value.lastPathComponent != "v1" { value.appendPathComponent("v1") }
        value.appendPathComponent("usage")
        return value
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let budget = root["budget"] as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let summary = usage["summary"] as? [String: Any],
              let providerValues = usage["providers"] as? [Any] else {
            throw ClawRouterUsageError.parseFailure("response shape is invalid")
        }
        guard let configured = budget["configured"] as? Bool,
              let ledger = budget["ledger"] as? String else {
            throw ClawRouterUsageError.parseFailure("budget is invalid")
        }
        let limit = try optionalMicros(budget["limitMicros"], field: "budget.limitMicros")
        let spent = try optionalMicros(budget["spentMicros"], field: "budget.spentMicros")
        let remaining = try optionalMicros(budget["remainingMicros"], field: "budget.remainingMicros")
        let requestCount = try integer(summary["requestCount"], field: "summary.requestCount")
        let successCount = try integer(summary["successCount"], field: "summary.successCount")
        let errorCount = try integer(summary["errorCount"], field: "summary.errorCount")
        let inputTokens = try integer(summary["inputTokens"], field: "summary.inputTokens")
        let outputTokens = try integer(summary["outputTokens"], field: "summary.outputTokens")
        let totalTokens = try integer(summary["totalTokens"], field: "summary.totalTokens")
        let actualCost = try micros(summary["actualCostMicros"], field: "summary.actualCostMicros")
        let providers = try providerValues.map { value -> RoutedProvider in
            guard let object = value as? [String: Any], let rawName = object["provider"] as? String else {
                throw ClawRouterUsageError.parseFailure("provider name must be a string")
            }
            return RoutedProvider(
                name: cleaned(rawName) ?? "Unknown",
                requests: try integer(object["requestCount"], field: "provider.requestCount"),
                successes: try integer(object["successCount"], field: "provider.successCount"),
                errors: try integer(object["errorCount"], field: "provider.errorCount"),
                tokens: try integer(object["totalTokens"], field: "provider.totalTokens"),
                cost: try micros(object["actualCostMicros"], field: "provider.actualCostMicros")
            )
        }.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Snapshot(
            budgetConfigured: configured,
            budgetLedger: ledger,
            budgetLimit: limit,
            budgetSpent: spent,
            budgetRemaining: remaining,
            budgetResetsAt: monthlyReset(budget["windowKey"]),
            requestCount: requestCount,
            successCount: successCount,
            errorCount: errorCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            actualCost: actualCost,
            providers: providers,
            updatedAt: now
        )
    }

    private static func integer(_ raw: Any?, field: String) throws -> Int64 {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int64.min),
              number.doubleValue <= Double(Int64.max) else {
            throw ClawRouterUsageError.parseFailure("\(field) must be an integer")
        }
        return number.int64Value
    }
    private static func micros(_ raw: Any?, field: String) throws -> Double {
        Double(try integer(raw, field: field)) / 1_000_000
    }
    private static func optionalMicros(_ raw: Any?, field: String) throws -> Double? {
        if raw == nil || raw is NSNull { return nil }
        return try micros(raw, field: field)
    }
    private static func monthlyReset(_ raw: Any?) -> Date? {
        guard let raw = raw as? String,
              let match = raw.range(of: #"\d{4}-\d{2}$"#, options: .regularExpression) else { return nil }
        let pieces = raw[match].split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 2 else { return nil }
        var year = pieces[0]
        var month = pieces[1] + 1
        if month == 13 { year += 1; month = 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: 1).date
    }
    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
