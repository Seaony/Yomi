import Foundation

nonisolated enum SiliconFlowUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidOrigin
    case authenticationExpired
    case balanceQueryRefused
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 SiliconFlow API Key，请在设置中填写或设置 SILICONFLOW_API_KEY", "Missing SiliconFlow API key. Add one in Settings or set SILICONFLOW_API_KEY")
        case .invalidOrigin:
            AppLocalization.text(
                "SiliconFlow API 地址只能是 https://api.siliconflow.cn 或 https://api.siliconflow.com",
                "SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com."
            )
        case .authenticationExpired:
            AppLocalization.text("SiliconFlow API Key 无效，请在设置中检查", "Check your SiliconFlow API key in Settings.")
        case .balanceQueryRefused:
            AppLocalization.text(
                "SiliconFlow 拒绝了余额查询，请在 SiliconFlow 控制台查看余额",
                "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console."
            )
        case .rateLimited:
            AppLocalization.text("SiliconFlow 请求频率受限，请稍后再试", "SiliconFlow is rate limiting requests. Try again later.")
        case let .providerUnavailable(status):
            AppLocalization.text("SiliconFlow 服务暂时不可用（HTTP \(status)）", "SiliconFlow is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("SiliconFlow 请求失败（HTTP \(status)）", "SiliconFlow request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("SiliconFlow 返回了无法识别的内容", "SiliconFlow returned an unrecognized response")
        }
    }
}

nonisolated enum SiliconFlowUsageFetcher {
    static let apiKeyEnvironmentKey = "SILICONFLOW_API_KEY"
    static let baseURLEnvironmentKey = "SILICONFLOW_BASE_URL"
    static let chinaOrigin = URL(string: "https://api.siliconflow.cn")!
    static let internationalOrigin = URL(string: "https://api.siliconflow.com")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        origin configuredOrigin: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment[apiKeyEnvironmentKey]) else {
            throw SiliconFlowUsageError.missingCredentials
        }
        // 地址不合法时直接报错，不把 Key 发到其他主机。
        guard let origin = resolvedOrigin(configured: configuredOrigin, environment: environment) else {
            throw SiliconFlowUsageError.invalidOrigin
        }
        var request = URLRequest(url: origin.appendingPathComponent("v1/user/info"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SiliconFlowUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 410: throw SiliconFlowUsageError.balanceQueryRefused
        case 401, 403: throw SiliconFlowUsageError.authenticationExpired
        case 429: throw SiliconFlowUsageError.rateLimited
        case 500...: throw SiliconFlowUsageError.providerUnavailable(http.statusCode)
        default: throw SiliconFlowUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, currency: origin == chinaOrigin ? "CNY" : "USD", now: now)
    }

    // 设置里的地址优先，其次是环境变量，都没有时默认中国区。
    static func resolvedOrigin(configured: String?, environment: [String: String]) -> URL? {
        guard let raw = cleaned(configured) ?? cleaned(environment[baseURLEnvironmentKey]) else {
            return chinaOrigin
        }
        return normalizedOrigin(raw)
    }

    // 只认两个官方地址，允许末尾带 /v1；端口、路径、查询参数和账号信息一律拒绝。
    static func normalizedOrigin(_ raw: String) -> URL? {
        let value = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "v1" else { return nil }
        switch host {
        case "api.siliconflow.cn": return chinaOrigin
        case "api.siliconflow.com": return internationalOrigin
        default: return nil
        }
    }

    static func parse(_ data: Data, currency: String, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"])
        else { throw SiliconFlowUsageError.parseFailure }
        if code == 20092 { throw SiliconFlowUsageError.balanceQueryRefused }
        if code == 30014 { throw SiliconFlowUsageError.authenticationExpired }
        guard code == 20000,
              root["status"] as? Bool == true,
              let body = root["data"] as? [String: Any],
              let total = money(body["totalBalance"])
        else { throw SiliconFlowUsageError.parseFailure }

        let totalText = format(total, currency: currency)
        var details = [
            UsageDetail(id: "siliconflow-balance", label: AppLocalization.text("余额", "Balance"), value: totalText),
        ]
        if let raw = present(body["chargeBalance"]) {
            guard let charged = money(raw) else { throw SiliconFlowUsageError.parseFailure }
            details.append(UsageDetail(
                id: "siliconflow-purchased",
                label: AppLocalization.text("充值余额", "Purchased"),
                value: format(charged, currency: currency)
            ))
        }
        if let raw = present(body["balance"]) {
            guard let bonus = money(raw) else { throw SiliconFlowUsageError.parseFailure }
            details.append(UsageDetail(
                id: "siliconflow-bonus",
                label: AppLocalization.text("赠送余额", "Bonus"),
                value: format(bonus, currency: currency)
            ))
        }
        // 账号状态不是 normal 时才显示，比如欠费。
        if let raw = present(body["status"]) {
            guard let status = raw as? String,
                  status.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil
            else { throw SiliconFlowUsageError.parseFailure }
            if status != "normal" {
                details.append(UsageDetail(
                    id: "siliconflow-status",
                    label: AppLocalization.text("账号状态", "Status"),
                    value: status
                ))
            }
        }
        // 接口没有额度上限，只显示余额，负数表示欠费，保留原值。
        return ProviderUsage(
            id: ProviderID(rawValue: "siliconflow"),
            state: .ready,
            windows: [],
            balance: totalText,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func present(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    // JSON 里的布尔值也会被当成数字，这里只接受真正的整数。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), let int = Int(exactly: double) else { return nil }
        return int
    }

    // 金额可能是数字，也可能是 "88.88" 这样的字符串；科学计数法等其他写法视为异常。
    private static func money(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard let text = value as? String,
              text.range(of: #"^-?(?:\d+|\d+\.\d+)$"#, options: .regularExpression) != nil,
              let amount = Double(text), amount.isFinite
        else { return nil }
        return amount
    }

    private static func format(_ value: Double, currency: String) -> String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
