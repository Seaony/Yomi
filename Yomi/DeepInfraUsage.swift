import Foundation

nonisolated struct DeepInfraChecklistResponse: Decodable, Sendable {
    let stripeBalance: Double
    let recent: Double
    let limit: Double?
    let suspended: Bool
    let suspendReason: String?

    private enum CodingKeys: String, CodingKey {
        case stripeBalance = "stripe_balance"
        case recent
        case limit
        case suspended
        case suspendReason = "suspend_reason"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stripeBalance = try values.decode(Double.self, forKey: .stripeBalance)
        recent = try values.decode(Double.self, forKey: .recent)
        limit = try values.decodeIfPresent(Double.self, forKey: .limit)
        suspended = try values.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
        suspendReason = try values.decodeIfPresent(String.self, forKey: .suspendReason)
    }
}

nonisolated struct DeepInfraUsageResponse: Decodable, Sendable {
    let months: [Month]

    struct Month: Decodable, Sendable {
        let period: String
        let totalCostCents: Double

        private enum CodingKeys: String, CodingKey {
            case period
            case totalCostCents = "total_cost"
        }
    }
}

nonisolated struct DeepInfraUsageSnapshot: Sendable, Equatable {
    let availableBalanceUSD: Double
    let amountOwedUSD: Double
    let currentMonthCostUSD: Double
    let recentCostUSD: Double
    let spendingLimitUSD: Double?
    let suspended: Bool
    let suspendReason: String?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let balanceText = amountOwedUSD > 0
            ? "\(Self.usd(amountOwedUSD)) owed"
            : "\(Self.usd(availableBalanceUSD)) available"
        let providerCost = spendingLimitUSD.flatMap { limit in
            limit > 0 ? ProviderCostSummary(
                used: recentCostUSD,
                limit: limit,
                currencyCode: "USD",
                period: "Billing cycle",
                balance: availableBalanceUSD
            ) : nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "deepinfra"),
            state: .ready,
            windows: [],
            balance: balanceText,
            plan: nil,
            providerCost: providerCost,
            details: [
                UsageDetail(id: "deepinfra-balance", label: "Balance", value: balanceText),
                UsageDetail(
                    id: "deepinfra-month-spend",
                    label: "This month spend",
                    value: Self.usd(currentMonthCostUSD)
                ),
            ],
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

nonisolated enum DeepInfraUsageError: LocalizedError, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 DeepInfra API Key", "Missing DeepInfra API key")
        case let .networkError(message):
            AppLocalization.text("DeepInfra 网络错误：\(message)", "DeepInfra network error: \(message)")
        case let .apiError(message):
            AppLocalization.text("DeepInfra 接口错误：\(message)", "DeepInfra API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 DeepInfra 数据：\(message)", "Failed to parse DeepInfra response: \(message)")
        }
    }
}

nonisolated enum DeepInfraUsageFetcher {
    static let checklistURL = URL(string: "https://api.deepinfra.com/payment/checklist?compute_owed=true")!
    static let usageURL = URL(string: "https://api.deepinfra.com/payment/usage?from=current")!

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["DEEPINFRA_API_KEY"], environment["DEEPINFRA_TOKEN"]] {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if value.count >= 2,
               value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(apiKey rawAPIKey: String?, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: rawAPIKey) else {
            throw DeepInfraUsageError.missingCredentials
        }
        do {
            let checklistData = try await response(url: checklistURL, apiKey: apiKey, session: session)
            let usageData = try await response(url: usageURL, apiKey: apiKey, session: session)
            return try parse(checklistData: checklistData, usageData: usageData, now: now).toProviderUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeepInfraUsageError {
            throw error
        } catch {
            throw DeepInfraUsageError.networkError(error.localizedDescription)
        }
    }

    private static func response(url: URL, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepInfraUsageError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200: return data
        case 401: throw DeepInfraUsageError.apiError("API key rejected (HTTP 401).")
        case 403: throw DeepInfraUsageError.apiError("API key cannot access billing data (HTTP 403).")
        default: throw DeepInfraUsageError.apiError("HTTP \(http.statusCode)")
        }
    }

    static func parse(
        checklistData: Data,
        usageData: Data,
        now: Date = Date()
    ) throws -> DeepInfraUsageSnapshot {
        do {
            let decoder = JSONDecoder()
            let checklist = try decoder.decode(DeepInfraChecklistResponse.self, from: checklistData)
            let usage = try decoder.decode(DeepInfraUsageResponse.self, from: usageData)
            let recent = max(0, checklist.recent)
            let currentMonth = usage.months.last.map { max(0, $0.totalCostCents / 100) } ?? recent
            let netBalance = checklist.stripeBalance + recent
            return DeepInfraUsageSnapshot(
                availableBalanceUSD: max(0, -netBalance),
                amountOwedUSD: max(0, netBalance),
                currentMonthCostUSD: currentMonth,
                recentCostUSD: recent,
                spendingLimitUSD: checklist.limit.flatMap { $0 > 0 ? $0 : nil },
                suspended: checklist.suspended,
                suspendReason: checklist.suspendReason,
                updatedAt: now
            )
        } catch {
            throw DeepInfraUsageError.parseFailed(error.localizedDescription)
        }
    }
}
