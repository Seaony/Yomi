import Foundation

nonisolated enum VercelUsageError: LocalizedError, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Vercel Gateway API Key", "Missing Vercel Gateway API key")
        case let .networkError(message):
            AppLocalization.text("Vercel Gateway 网络错误：\(message)", "Vercel Gateway network error: \(message)")
        case let .apiError(status):
            AppLocalization.text(
                "Vercel Gateway 请求失败（HTTP \(status)）",
                "Vercel Gateway request failed (HTTP \(status))"
            )
        case .invalidResponse:
            AppLocalization.text("Vercel Gateway 返回的余额数据无效", "Vercel Gateway returned an invalid credit balance")
        }
    }
}

nonisolated struct VercelUsageSnapshot: Sendable, Equatable {
    let availableBalanceUSD: Double
    let lifetimeSpendUSD: Double
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "vercel"),
            state: .ready,
            windows: [],
            balance: Self.usd(availableBalanceUSD),
            plan: nil,
            details: [
                UsageDetail(
                    id: "vercel-balance",
                    label: AppLocalization.text("可用余额", "Available balance"),
                    value: Self.usd(availableBalanceUSD)
                ),
                UsageDetail(
                    id: "vercel-lifetime-spend",
                    label: AppLocalization.text("累计消费", "Lifetime spend"),
                    value: Self.usd(lifetimeSpendUSD)
                ),
            ],
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func usd(_ value: Double) -> String {
        value < 0 ? String(format: "-$%.2f", -value) : String(format: "$%.2f", value)
    }
}

nonisolated enum VercelUsageFetcher {
    static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v1/credits")!
    static let environmentKeys = ["AI_GATEWAY_API_KEY"]

    private struct CreditResponse: Decodable {
        let balance: String
        let totalUsed: String

        private enum CodingKeys: String, CodingKey {
            case balance
            case totalUsed = "total_used"
        }
    }

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["AI_GATEWAY_API_KEY"]] {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
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
            throw VercelUsageError.missingCredentials
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
            throw VercelUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw VercelUsageError.invalidResponse }
        guard http.statusCode == 200 else { throw VercelUsageError.apiError(http.statusCode) }
        return try parse(data, now: now).toProviderUsage()
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> VercelUsageSnapshot {
        guard let response = try? JSONDecoder().decode(CreditResponse.self, from: data),
              let balance = money(response.balance),
              let spent = money(response.totalUsed), spent >= 0 else {
            throw VercelUsageError.invalidResponse
        }
        return VercelUsageSnapshot(availableBalanceUSD: balance, lifetimeSpendUSD: spent, updatedAt: now)
    }

    private static func money(_ value: String) -> Double? {
        guard value.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let amount = Double(value), amount.isFinite else { return nil }
        return amount
    }
}
