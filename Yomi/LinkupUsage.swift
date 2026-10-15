import Foundation

nonisolated enum LinkupUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case networkFailure(String)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Linkup API Key，请在设置中填写或设置 LINKUP_API_KEY", "Missing Linkup API key. Add one in Settings or set LINKUP_API_KEY")
        case .authenticationExpired:
            AppLocalization.text("Linkup API Key 无效或已过期", "The Linkup API key is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("Linkup API Key 无权读取余额", "The Linkup API key cannot read the credit balance")
        case .rateLimited:
            AppLocalization.text("Linkup 请求频率受限", "Linkup rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("Linkup 服务暂时不可用（HTTP \(status)）", "Linkup is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Linkup 接口请求失败（HTTP \(status)）", "Linkup API request failed (HTTP \(status))")
        case let .networkFailure(message):
            AppLocalization.text("Linkup 网络错误：\(message)", "Linkup network error: \(message)")
        case .parseFailure:
            AppLocalization.text("Linkup 未返回有效的余额", "Linkup returned an unrecognized credit balance")
        }
    }
}

nonisolated enum LinkupUsageFetcher {
    static let balanceURL = URL(string: "https://api.linkup.so/v1/credits/balance")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["LINKUP_API_KEY"]) else {
            throw LinkupUsageError.missingCredentials
        }
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LinkupUsageError.networkFailure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LinkupUsageError.networkFailure(AppLocalization.text("无效的响应", "Invalid response"))
        }
        switch http.statusCode {
        case 200: break
        case 401: throw LinkupUsageError.authenticationExpired
        case 403: throw LinkupUsageError.permissionDenied
        case 429: throw LinkupUsageError.rateLimited
        case 500...599: throw LinkupUsageError.providerUnavailable(http.statusCode)
        default: throw LinkupUsageError.apiFailure(http.statusCode)
        }
        let balance = try parseBalance(data)
        let formatted = balance.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return ProviderUsage(
            id: ProviderID(rawValue: "linkup"),
            state: .ready,
            windows: [],
            balance: formatted,
            details: [UsageDetail(
                id: "linkup-credit-balance",
                label: AppLocalization.text("信用余额", "Credit balance"),
                value: formatted
            )],
            updatedAt: now
        )
    }

    static func parseBalance(_ data: Data) throws -> Double {
        guard let value = try? JSONDecoder().decode(BalanceResponse.self, from: data).balance,
              value.isFinite else {
            throw LinkupUsageError.parseFailure
        }
        return value
    }

    private struct BalanceResponse: Decodable {
        let balance: Double
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
