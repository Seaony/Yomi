import Foundation

nonisolated enum FutureAGIUsageError: LocalizedError, Equatable {
    case missingCredentials
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("Future AGI 需要同时填写 API Key 和 Secret Key（或设置 FI_API_KEY、FI_SECRET_KEY）", "Future AGI requires both an API key and a secret key (or FI_API_KEY and FI_SECRET_KEY).")
        case .authenticationExpired:
            AppLocalization.text("Future AGI 密钥无效或已过期", "The Future AGI keys are invalid or expired")
        case .permissionDenied:
            AppLocalization.text("Future AGI 密钥无权读取用量", "The Future AGI keys cannot read usage")
        case .rateLimited:
            AppLocalization.text("Future AGI 请求频率受限", "Future AGI rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("Future AGI 服务暂时不可用（HTTP \(status)）", "Future AGI is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Future AGI 请求失败（HTTP \(status)）", "Future AGI request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("Future AGI 返回了无法识别的用量概览", "Future AGI returned an unrecognized usage overview")
        }
    }
}

nonisolated enum FutureAGIUsageFetcher {
    static let overviewURL = URL(string: "https://api.futureagi.com/usage/v2/usage-overview/")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        secretKey configuredSecretKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["FI_API_KEY"]),
              let secretKey = cleaned(configuredSecretKey) ?? cleaned(environment["FI_SECRET_KEY"]) else {
            throw FutureAGIUsageError.missingCredentials
        }
        var request = URLRequest(url: overviewURL)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FutureAGIUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 401: throw FutureAGIUsageError.authenticationExpired
        case 403: throw FutureAGIUsageError.permissionDenied
        case 429: throw FutureAGIUsageError.rateLimited
        case 500...: throw FutureAGIUsageError.providerUnavailable(http.statusCode)
        default: throw FutureAGIUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? Bool == true,
              let result = root["result"] as? [String: Any],
              let dimensions = result["dimensions"] as? [Any],
              (1...16).contains(dimensions.count),
              let start = date(result["billing_period_start"]),
              let end = date(result["billing_period_end"]), end > start else {
            throw FutureAGIUsageError.parseFailure
        }
        var windows: [String: UsageWindow] = [:]
        var details: [UsageDetail] = []
        var keys = Set<String>()
        for raw in dimensions {
            guard let meter = raw as? [String: Any],
                  let key = meter["key"] as? String, keys.insert(key).inserted,
                  let name = label(meter["display_name"]), let unit = label(meter["display_unit"]) else {
                throw FutureAGIUsageError.parseFailure
            }
            let used = try amount(meter["current_usage"])
            let allowance = try amount(meter["free_allowance"])
            if allowance > 0 {
                windows[key] = UsageWindow(
                    id: "futureagi-\(key)",
                    label: key == "ai_credits" ? "AI credits" : key == "gateway_requests" ? "Gateway requests" : name,
                    usedFraction: min(1, used / allowance),
                    resetsAt: end,
                    detail: "\(number(used)) / \(number(allowance)) \(unit)"
                )
            }
            details.append(UsageDetail(id: "futureagi-\(key)", label: name, value: "\(number(used)) / \(number(allowance)) \(unit)"))
        }
        let cost = try amount(result["total_estimated_cost"])
        details.append(UsageDetail(
            id: "futureagi-estimated-cost",
            label: AppLocalization.text("本期预估费用", "Estimated usage cost"),
            value: cost.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        ))
        return ProviderUsage(
            id: ProviderID(rawValue: "futureagi"),
            state: .ready,
            windows: [windows["ai_credits"], windows["gateway_requests"]].compactMap { $0 },
            plan: label(result["plan_display_name"]),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func amount(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991 else { throw FutureAGIUsageError.parseFailure }
        return number.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String,
              text.range(of: #"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?$"#, options: .regularExpression) != nil
        else { return nil }
        if text.count == 10 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: text)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // 接口给的名称直接显示在界面上，只接受短的单行文字。
    private static func label(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 80,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return text
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
