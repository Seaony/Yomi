import Foundation

nonisolated enum FalUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationRejected
    case permissionDenied
    case rateLimited
    case providerUnavailable
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 fal API Key，请在设置中添加或设置 FAL_KEY", "Missing fal API key. Add one in Settings or set FAL_KEY.")
        case .authenticationRejected:
            AppLocalization.text("fal API Key 已失效，请更新密钥", "The fal API key was rejected. Update the key.")
        case .permissionDenied:
            AppLocalization.text(
                "fal API Key 需要 billing:usage:read 权限（BILLING、READONLY 或 FULL 预设）",
                "The fal API key needs billing:usage:read permission (BILLING, READONLY, or FULL preset)."
            )
        case .rateLimited:
            AppLocalization.text("fal 请求频率受限", "fal rate limit reached")
        case .providerUnavailable:
            AppLocalization.text("fal 服务或信用余额暂时不可用，请稍后刷新", "fal service or credit balance is temporarily unavailable. Refresh again later.")
        case let .requestFailed(status):
            AppLocalization.text("fal 账单请求失败（HTTP \(status)）", "fal billing request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("fal 返回了无法识别的信用余额", "fal returned an unrecognized credit balance")
        }
    }
}

nonisolated enum FalUsageFetcher {
    static let billingURL = URL(string: "https://api.fal.ai/v1/account/billing?expand=credits")!

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment["FAL_KEY"]] {
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
            throw FalUsageError.missingCredentials
        }
        var request = URLRequest(url: billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FalUsageError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw FalUsageError.authenticationRejected
        case 403: throw FalUsageError.permissionDenied
        case 429: throw FalUsageError.rateLimited
        case 500...599: throw FalUsageError.providerUnavailable
        default: throw FalUsageError.requestFailed(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FalUsageError.invalidResponse
        }
        guard let credits = root["credits"] as? [String: Any] else {
            throw FalUsageError.providerUnavailable
        }
        let balance: Double?
        if let raw = credits["current_balance"] as? String,
           raw.range(of: #"^\s*-?\d+(?:\.\d+)?\s*$"#, options: .regularExpression) != nil {
            balance = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let raw = credits["current_balance"] as? NSNumber,
                  CFGetTypeID(raw) != CFBooleanGetTypeID() {
            balance = raw.doubleValue
        } else {
            balance = nil
        }
        guard let balance, balance.isFinite else { throw FalUsageError.invalidResponse }
        let currency: String
        if let raw = credits["currency"] as? String,
           raw.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil {
            currency = raw
        } else {
            currency = "USD"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = AppLocalization.currentLanguage.locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let balanceText = formatter.string(from: NSNumber(value: balance)) ?? "\(currency) \(String(format: "%.2f", balance))"
        var details = [UsageDetail(
            id: "fal-credit-balance",
            label: AppLocalization.text("信用余额", "Credit balance"),
            value: balanceText
        )]
        if let username = root["username"] as? String,
           !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append(UsageDetail(
                id: "fal-account",
                label: AppLocalization.text("账号", "Account"),
                value: username.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "fal"),
            state: .ready,
            windows: [],
            balance: balanceText,
            details: details,
            updatedAt: now,
            message: nil
        )
    }
}
