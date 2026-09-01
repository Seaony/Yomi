import Foundation

nonisolated enum MoonshotUsageRegion: String, CaseIterable, Sendable {
    case international
    case china

    private static let balancePath = "v1/users/me/balance"

    var balanceURL: URL {
        let host = switch self {
        case .international: "https://api.moonshot.ai"
        case .china: "https://api.moonshot.cn"
        }
        return URL(string: host)!.appendingPathComponent(Self.balancePath)
    }
}

nonisolated enum MoonshotUsageError: LocalizedError, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 Moonshot Open Platform API Key",
                "Missing Moonshot Open Platform API key"
            )
        case let .networkError(message):
            AppLocalization.text(
                "Moonshot 网络错误：\(message)",
                "Moonshot network error: \(message)"
            )
        case let .apiError(message):
            AppLocalization.text(
                "Moonshot API 错误：\(message)",
                "Moonshot API error: \(message)"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Moonshot 返回的数据：\(message)",
                "Failed to parse Moonshot response: \(message)"
            )
        }
    }
}

nonisolated enum MoonshotUsageFetcher {
    struct Summary: Sendable, Equatable {
        let availableBalance: Double
        let voucherBalance: Double
        let cashBalance: Double
        let updatedAt: Date
    }

    private struct BalanceResponse: Decodable {
        let code: Int
        let data: BalanceData
        let scode: String
        let status: Bool
    }

    private struct BalanceData: Decodable {
        let availableBalance: Double
        let voucherBalance: Double
        let cashBalance: Double

        private enum CodingKeys: String, CodingKey {
            case availableBalance = "available_balance"
            case voucherBalance = "voucher_balance"
            case cashBalance = "cash_balance"
        }
    }

    static let apiKeyEnvironmentKeys = ["MOONSHOT_API_KEY", "MOONSHOT_KEY"]
    static let regionEnvironmentKey = "MOONSHOT_REGION"
    private static let timeout: TimeInterval = 15

    static func fetch(
        apiKey configuredAPIKey: String?,
        region configuredRegion: String?,
        apiKeyRegion configuredAPIKeyRegion: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let region = resolvedRegion(configured: configuredRegion, environment: environment)
        guard let apiKey = resolvedAPIKey(
            configured: configuredAPIKey,
            configuredRegion: configuredAPIKeyRegion,
            selectedRegion: region,
            environment: environment
        ) else {
            throw MoonshotUsageError.missingCredentials
        }

        var request = URLRequest(url: balanceURL(region: region))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw MoonshotUsageError.networkError("Invalid response")
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw MoonshotUsageError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            throw MoonshotUsageError.apiError("HTTP \(http.statusCode)")
        }

        return providerUsage(summary: try parseSummary(data, now: now))
    }

    static func resolvedRegion(
        configured: String?,
        environment: [String: String]
    ) -> MoonshotUsageRegion {
        let raw = cleaned(configured) ?? cleanedEnvironmentValue(environment[regionEnvironmentKey])
        guard let raw else { return .international }
        return MoonshotUsageRegion(rawValue: raw.lowercased()) ?? .international
    }

    static func resolvedAPIKey(
        configured: String?,
        configuredRegion: String?,
        selectedRegion: MoonshotUsageRegion,
        environment: [String: String]
    ) -> String? {
        if let configured = cleaned(configured) {
            let boundRegion = cleaned(configuredRegion)
                .flatMap { MoonshotUsageRegion(rawValue: $0.lowercased()) }
                ?? selectedRegion
            if boundRegion == selectedRegion {
                return configured
            }
        }

        let environmentRegion = resolvedRegion(configured: nil, environment: environment)
        guard environmentRegion == selectedRegion else { return nil }
        for key in apiKeyEnvironmentKeys {
            if let value = cleanedEnvironmentValue(environment[key]) {
                return value
            }
        }
        return nil
    }

    static func storedAPIKeyRegion(_ value: String?, hasLegacyStoredKey: Bool) -> String? {
        if let value = cleaned(value) { return value }
        return hasLegacyStoredKey ? MoonshotUsageRegion.china.rawValue : nil
    }

    static func balanceURL(region: MoonshotUsageRegion) -> URL {
        region.balanceURL
    }

    static func parseSummary(_ data: Data, now: Date = Date()) throws -> Summary {
        let response: BalanceResponse
        do {
            response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw MoonshotUsageError.parseFailed(error.localizedDescription)
        }

        guard response.code == 0, response.status else {
            throw MoonshotUsageError.apiError("code \(response.code), scode \(response.scode)")
        }

        return Summary(
            availableBalance: response.data.availableBalance,
            voucherBalance: response.data.voucherBalance,
            cashBalance: response.data.cashBalance,
            updatedAt: now
        )
    }

    static func providerUsage(summary: Summary) -> ProviderUsage {
        let balance = currency(summary.availableBalance)
        let detail: String
        if summary.cashBalance < 0 {
            detail = "\(balance) · \(currency(abs(summary.cashBalance))) in deficit"
        } else {
            detail = balance
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "moonshot"),
            state: .ready,
            windows: [],
            balance: balance,
            plan: nil,
            details: [UsageDetail(id: "moonshot-balance", label: "Balance", value: detail)],
            updatedAt: summary.updatedAt,
            message: nil
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func cleanedEnvironmentValue(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        return cleaned(value)
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}
