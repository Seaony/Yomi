import Foundation

nonisolated enum SofyaUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case permissionDenied
    case rateLimited
    case serviceUnavailable(Int)
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Sofya API Key，请填写或设置 SOFYA_API_KEY", "Missing Sofya API key. Enter one or set SOFYA_API_KEY.")
        case .unauthorized:
            AppLocalization.text("Sofya API Key 无效或已过期", "The Sofya API key is invalid or expired.")
        case .permissionDenied:
            AppLocalization.text("Sofya API Key 没有访问权限", "The Sofya API key does not have access.")
        case .rateLimited:
            AppLocalization.text("Sofya 请求过于频繁，请稍后重试", "Sofya rate limit exceeded. Try again later.")
        case let .serviceUnavailable(status):
            AppLocalization.text("Sofya 服务暂时不可用（HTTP \(status)）", "Sofya service is temporarily unavailable (HTTP \(status)).")
        case let .apiError(status):
            AppLocalization.text("Sofya 请求失败（HTTP \(status)）", "Sofya request failed (HTTP \(status)).")
        case .invalidResponse:
            AppLocalization.text("无法解析 Sofya 账户积分", "Could not parse Sofya account credits.")
        }
    }
}

nonisolated enum SofyaUsageFetcher {
    private struct Account: Decodable {
        let credits: Double?
        let planCredits: Double?
        let purchasedCredits: Double?
        let isFreeTier: Bool?
        let creditsResetAt: String?

        enum CodingKeys: String, CodingKey {
            case credits
            case planCredits = "plan_credits"
            case purchasedCredits = "purchased_credits"
            case isFreeTier = "is_free_tier"
            case creditsResetAt = "credits_reset_at"
        }
    }

    static let endpoint = URL(string: "https://sofya.co/v1/auth/me")!
    static let environmentKey = "SOFYA_API_KEY"

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configured) ?? cleaned(environment[environmentKey]) else {
            throw SofyaUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SofyaUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw SofyaUsageError.unauthorized
        case 403: throw SofyaUsageError.permissionDenied
        case 429: throw SofyaUsageError.rateLimited
        case 500...599: throw SofyaUsageError.serviceUnavailable(http.statusCode)
        default: throw SofyaUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let account = try? JSONDecoder().decode(Account.self, from: data) else {
            throw SofyaUsageError.invalidResponse
        }
        let balances = [account.credits, account.planCredits, account.purchasedCredits].compactMap { $0 }
        guard !balances.isEmpty, balances.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SofyaUsageError.invalidResponse
        }
        let reset: Date?
        if let raw = account.creditsResetAt {
            guard let date = resetDate(raw) else { throw SofyaUsageError.invalidResponse }
            reset = date
        } else {
            reset = nil
        }
        var details: [UsageDetail] = []
        if let credits = account.credits {
            details.append(UsageDetail(
                id: "sofya-available-credits",
                label: AppLocalization.text("可用积分", "Available credits"),
                value: formatCredits(credits)
            ))
        }
        if let credits = account.planCredits {
            details.append(UsageDetail(
                id: "sofya-plan-credits",
                label: AppLocalization.text("套餐积分", "Plan credits"),
                value: formatCredits(credits)
            ))
        }
        if let credits = account.purchasedCredits {
            details.append(UsageDetail(
                id: "sofya-purchased-credits",
                label: AppLocalization.text("购买积分", "Purchased credits"),
                value: formatCredits(credits)
            ))
        }
        if account.isFreeTier == true, let reset {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS 'UTC'"
            details.append(UsageDetail(
                id: "sofya-monthly-reset",
                label: AppLocalization.text("月重置时间", "Monthly reset"),
                value: formatter.string(from: reset).replacingOccurrences(of: ".000 UTC", with: " UTC")
            ))
        }
        let plan: String
        switch account.isFreeTier {
        case true: plan = AppLocalization.text("免费档", "Free tier")
        case false: plan = AppLocalization.text("按量付费", "Pay as you go")
        case nil: plan = "API"
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "sofya"),
            state: .ready,
            windows: [],
            balance: account.credits.map { AppLocalization.text("\(formatCredits($0)) 积分", "\(formatCredits($0)) credits") },
            plan: plan,
            details: details,
            updatedAt: now
        )
    }

    private static func formatCredits(_ credits: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: credits)) ?? String(credits)
    }

    private static func resetDate(_ raw: String) -> Date? {
        guard raw.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let components = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = DateComponents(year: components[0], month: components[1], day: components[2])
        guard let localDate = calendar.date(from: expected) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: localDate)
        guard actual.year == expected.year,
              actual.month == expected.month,
              actual.day == expected.day else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
