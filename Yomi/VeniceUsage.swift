import Foundation

nonisolated enum VeniceUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case invalidResponse
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Venice API Key", "Missing Venice API key")
        case .unauthorized:
            AppLocalization.text("Venice API Key 无效", "The Venice API key is invalid")
        case let .apiError(status):
            AppLocalization.text("Venice 接口请求失败（HTTP \(status)）", "Venice API request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("Venice 返回内容无效", "The Venice response is invalid")
        case let .invalidField(field):
            AppLocalization.text("Venice 字段无效：\(field)", "Invalid Venice field: \(field)")
        }
    }
}

nonisolated struct VeniceUsageSnapshot: Sendable, Equatable {
    let canConsume: Bool
    let consumptionCurrency: String?
    let diem: Double?
    let usd: Double?
    let diemEpochAllocation: Double?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let currency = consumptionCurrency?.uppercased()
        let fraction: Double
        let detail: String
        let balance: String?
        if !canConsume {
            fraction = 1
            detail = "Balance unavailable for API calls"
            balance = nil
        } else if currency == "USD", let usd, usd > 0 {
            fraction = 0
            detail = String(format: "$%.2f USD remaining", usd)
            balance = String(format: "$%.2f", usd)
        } else if currency != "USD", let diem, let allocation = diemEpochAllocation, allocation > 0 {
            fraction = min(1, max(0, (allocation - diem) / allocation))
            detail = String(format: "DIEM %.2f / %.2f epoch allocation", diem, allocation)
            balance = String(format: "DIEM %.2f", diem)
        } else if currency == "DIEM", let diem, diem > 0 {
            fraction = 0
            detail = String(format: "DIEM %.2f remaining", diem)
            balance = String(format: "DIEM %.2f", diem)
        } else if let diem, diem > 0 {
            fraction = 0
            detail = String(format: "DIEM %.2f remaining", diem)
            balance = String(format: "DIEM %.2f", diem)
        } else if let usd, usd > 0 {
            fraction = 0
            detail = String(format: "$%.2f USD remaining", usd)
            balance = String(format: "$%.2f", usd)
        } else {
            fraction = 1
            detail = "No Venice API balance available"
            balance = nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "venice"),
            state: .ready,
            windows: [UsageWindow(
                id: "venice-balance",
                label: "Balance",
                usedFraction: fraction,
                resetsAt: nil,
                detail: detail
            )],
            balance: balance,
            plan: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum VeniceUsageFetcher {
    static let endpoint = URL(string: "https://api.venice.ai/api/v1/billing/balance")!
    static let environmentKeys = ["VENICE_API_KEY", "VENICE_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured].compactMap({ $0 }) + environmentKeys.compactMap({ environment[$0] }) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw VeniceUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VeniceUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now).toProviderUsage()
        case 401, 403: throw VeniceUsageError.unauthorized
        default: throw VeniceUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> VeniceUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VeniceUsageError.invalidResponse
        }
        guard let canConsumeValue = root["canConsume"] as? NSNumber,
              CFGetTypeID(canConsumeValue) == CFBooleanGetTypeID() else {
            throw VeniceUsageError.invalidField("canConsume")
        }
        guard let balances = root["balances"] as? [String: Any] else {
            throw VeniceUsageError.invalidField("balances")
        }
        let currency: String?
        if root["consumptionCurrency"] == nil || root["consumptionCurrency"] is NSNull {
            currency = nil
        } else if let value = root["consumptionCurrency"] as? String {
            currency = value.isEmpty ? nil : value
        } else {
            throw VeniceUsageError.invalidField("consumptionCurrency")
        }
        return VeniceUsageSnapshot(
            canConsume: canConsumeValue.boolValue,
            consumptionCurrency: currency,
            diem: try optionalNumber(balances["diem"], field: "balances.diem"),
            usd: try optionalNumber(balances["usd"], field: "balances.usd"),
            diemEpochAllocation: try optionalNumber(root["diemEpochAllocation"], field: "diemEpochAllocation"),
            updatedAt: now
        )
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let number = Double(trimmed), number.isFinite else {
                throw VeniceUsageError.invalidField(field)
            }
            return number
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw VeniceUsageError.invalidField(field)
        }
        return number.doubleValue
    }
}
