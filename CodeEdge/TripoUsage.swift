import Foundation

nonisolated enum TripoUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case requestRejected
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Tripo API Key，请在设置中填写或设置 TRIPO_API_KEY", "Missing Tripo API key. Add one in Settings or set TRIPO_API_KEY")
        case .authenticationExpired:
            AppLocalization.text("Tripo API Key 无效，请在设置中检查", "Check your Tripo API key in Settings.")
        case .permissionDenied:
            AppLocalization.text("Tripo API Key 没有读取余额的权限，请在设置中检查", "The Tripo API key cannot read the balance. Check it in Settings.")
        case .rateLimited:
            AppLocalization.text("Tripo 请求频率受限，请稍后再试", "Tripo is rate limiting requests. Try again later.")
        case let .providerUnavailable(status):
            AppLocalization.text("Tripo 服务暂时不可用（HTTP \(status)）", "Tripo is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Tripo 请求失败（HTTP \(status)）", "Tripo request failed (HTTP \(status))")
        case .requestRejected:
            AppLocalization.text("Tripo 请求失败，请稍后刷新", "Tripo request failed. Try refreshing later.")
        case .parseFailure:
            AppLocalization.text("Tripo 返回了无法识别的内容", "Tripo returned an unrecognized response")
        }
    }
}

nonisolated enum TripoUsageFetcher {
    static let balanceURL = URL(string: "https://openapi.tripo3d.ai/v3/account/balance")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["TRIPO_API_KEY"]) else {
            throw TripoUsageError.missingCredentials
        }
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TripoUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 401: throw TripoUsageError.authenticationExpired
        case 403: throw TripoUsageError.permissionDenied
        case 429: throw TripoUsageError.rateLimited
        case 500...: throw TripoUsageError.providerUnavailable(http.statusCode)
        default: throw TripoUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"])
        else { throw TripoUsageError.parseFailure }
        guard code == 0 else { throw TripoUsageError.requestRejected }
        guard let body = root["data"] as? [String: Any],
              let balance = credits(body["balance"]),
              let frozen = credits(body["frozen"])
        else { throw TripoUsageError.parseFailure }

        // balance 已经是可用积分，frozen 是进行中任务预留的部分，不再相减；也不折算成金额。
        let balanceText = format(balance)
        return ProviderUsage(
            id: ProviderID(rawValue: "tripo"),
            state: .ready,
            windows: [],
            balance: AppLocalization.text("\(balanceText) Credits", "\(balanceText) credits"),
            details: [
                UsageDetail(id: "tripo-balance", label: AppLocalization.text("可用 Credits", "Balance"), value: balanceText),
                UsageDetail(id: "tripo-reserved", label: AppLocalization.text("冻结 Credits", "Reserved"), value: format(frozen)),
            ],
            updatedAt: now,
            message: nil
        )
    }

    // JSON 里的布尔值也会被当成数字，这里只接受真正的整数。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), let int = Int(exactly: double) else { return nil }
        return int
    }

    // 只接受非负的有限数字，缺失、字符串、布尔值都当作异常，不显示成 0。
    private static func credits(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let amount = number.doubleValue
        return amount.isFinite && amount >= 0 ? amount : nil
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
