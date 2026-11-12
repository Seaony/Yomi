import Foundation

nonisolated enum AtlasCloudUsageError: LocalizedError, Equatable {
    case missingCredentials
    case networkError
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Atlas Cloud API Key", "Missing Atlas Cloud API key")
        case .networkError:
            AppLocalization.text("Atlas Cloud 网络请求失败", "Atlas Cloud network request failed")
        case let .apiError(status):
            AppLocalization.text(
                "Atlas Cloud 接口错误：HTTP \(status)",
                "Atlas Cloud API error: HTTP \(status)"
            )
        case .parseFailed:
            AppLocalization.text(
                "Atlas Cloud 返回了无法识别的账户美元余额",
                "Atlas Cloud returned an unrecognized USD account balance"
            )
        }
    }
}

nonisolated enum AtlasCloudUsageFetcher {
    private struct BalanceResponse: Decodable {
        struct Available: Decodable {
            let value: String
            let currency: String
        }

        let object: String
        let scope: String
        let available: Available
    }

    static let balanceURL = URL(string: "https://api.atlascloud.ai/public/v1/balance")!

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["ATLASCLOUD_API_KEY"]] {
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configuredAPIKey) else {
            throw AtlasCloudUsageError.missingCredentials
        }
        var request = URLRequest(url: balanceURL)
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
            throw AtlasCloudUsageError.networkError
        }
        guard let http = response as? HTTPURLResponse else {
            throw AtlasCloudUsageError.networkError
        }
        guard http.statusCode == 200 else {
            throw AtlasCloudUsageError.apiError(http.statusCode)
        }

        let balance = try parseBalance(data)
        let balanceText = String(format: balance < 0 ? "-$%.2f" : "$%.2f", abs(balance))
        return ProviderUsage(
            id: ProviderID(rawValue: "atlascloud"),
            state: .ready,
            windows: [],
            balance: balanceText,
            details: [
                UsageDetail(
                    id: "atlascloud-available-balance",
                    label: AppLocalization.text("可用余额", "Available balance"),
                    value: balanceText
                ),
            ],
            updatedAt: now,
            message: nil
        )
    }

    static func parseBalance(_ data: Data) throws -> Double {
        guard let response = try? JSONDecoder().decode(BalanceResponse.self, from: data),
              response.object == "balance",
              response.scope == "account",
              response.available.currency == "usd",
              response.available.value.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(response.available.value), value.isFinite
        else {
            throw AtlasCloudUsageError.parseFailed
        }
        return value
    }
}
