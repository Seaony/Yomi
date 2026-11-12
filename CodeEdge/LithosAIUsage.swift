import Foundation

nonisolated enum LithosAIUsageError: LocalizedError, Equatable {
    case missingCookies
    case sessionExpired
    case permissionDenied
    case rateLimited
    case unavailable
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            AppLocalization.text(
                "请在 LithosAI 浏览器会话中粘贴同一次登录的 __Host-console_session 和 __Host-console_csrf Cookie；推理 API Key 无法读取账单",
                "Paste __Host-console_session and __Host-console_csrf cookies from the same LithosAI login under Browser session. Inference API keys cannot read billing."
            )
        case .sessionExpired:
            AppLocalization.text("LithosAI 会话已过期，请更新 Cookie", "The LithosAI session expired. Update the cookies.")
        case .permissionDenied:
            AppLocalization.text("LithosAI 控制台拒绝访问", "LithosAI console access was denied.")
        case .rateLimited:
            AppLocalization.text("LithosAI 控制台请求过于频繁", "LithosAI console requests are rate limited.")
        case .unavailable:
            AppLocalization.text("LithosAI 控制台暂时不可用", "LithosAI console is unavailable.")
        case let .apiError(status):
            AppLocalization.text("LithosAI 接口返回 HTTP \(status)", "LithosAI API returned HTTP \(status).")
        case .invalidResponse:
            AppLocalization.text("LithosAI 返回的数据无效", "The LithosAI response is invalid.")
        }
    }
}

nonisolated enum LithosAIUsageFetcher {
    private static let baseURL = URL(string: "https://console.lithosai.cloud")!
    private static let sessionCookieName = "__Host-console_session"
    private static let csrfCookieName = "__Host-console_csrf"
    private static let safeIntegerLimit = 9_007_199_254_740_991.0

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .cookie || source == .automatic,
              let cookies = cookieValues(credential),
              let csrf = cookies[csrfCookieName],
              let sessionCookie = cookies[sessionCookieName] else {
            throw LithosAIUsageError.missingCookies
        }
        let cookieHeader = "\(sessionCookieName)=\(sessionCookie); \(csrfCookieName)=\(csrf)"
        let me = try await get(
            path: "/api/me", cookieHeader: cookieHeader, csrf: csrf, session: session
        )
        guard let user = me["user"] as? [String: Any],
              let organization = me["activeOrganization"] as? [String: Any],
              let organizationID = text(organization["id"]),
              organizationID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw LithosAIUsageError.invalidResponse
        }
        let billing = try await get(
            path: "/api/billing", cookieHeader: cookieHeader, csrf: csrf,
            organizationID: organizationID, session: session
        )
        let balance = try amount(billing["balanceNanos"]) / 1_000_000_000
        guard let hasCard = boolean(billing["hasCard"]), let onHold = boolean(billing["onHold"]) else {
            throw LithosAIUsageError.invalidResponse
        }
        var details = [
            UsageDetail(id: "balance", label: AppLocalization.text("余额", "Balance"), value: money(balance)),
            UsageDetail(
                id: "payment-card", label: AppLocalization.text("支付卡", "Payment card"),
                value: hasCard ? AppLocalization.text("已添加", "Added") : AppLocalization.text("未添加", "Not added")
            ),
            UsageDetail(
                id: "account-status", label: AppLocalization.text("账号状态", "Account status"),
                value: onHold ? AppLocalization.text("已暂停", "On hold") : AppLocalization.text("正常", "Active")
            ),
        ]
        if let email = text(user["email"]) {
            details.append(UsageDetail(id: "email", label: AppLocalization.text("邮箱", "Email"), value: email))
        }
        if let name = text(organization["name"]) {
            details.append(UsageDetail(id: "organization", label: AppLocalization.text("组织", "Organization"), value: name))
        }
        do {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let end = formatter.string(from: now)
            let start = String(end.prefix(7)) + "-01"
            let spend = try await get(
                path: "/api/billing/spend?start=\(start)&end=\(end)", cookieHeader: cookieHeader,
                csrf: csrf, organizationID: organizationID, session: session
            )
            guard spend["start"] as? String == start, spend["end"] as? String == end,
                  let days = spend["days"] as? [[String: Any]] else {
                throw LithosAIUsageError.invalidResponse
            }
            var today = 0.0
            var month = 0.0
            for row in days {
                guard let day = row["day"] as? String,
                      day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      day >= start, day <= end else { throw LithosAIUsageError.invalidResponse }
                let nanos = try amount(row["nanos"])
                guard nanos >= 0 else { throw LithosAIUsageError.invalidResponse }
                month += nanos
                if day == end { today += nanos }
            }
            guard month <= safeIntegerLimit else { throw LithosAIUsageError.invalidResponse }
            details.append(UsageDetail(
                id: "today-spend", label: AppLocalization.text("今日（UTC）", "Today (UTC)"),
                value: money(today / 1_000_000_000)
            ))
            details.append(UsageDetail(
                id: "month-spend", label: AppLocalization.text("本月（UTC）", "This month (UTC)"),
                value: money(month / 1_000_000_000)
            ))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if error as? LithosAIUsageError == .sessionExpired { throw error }
            details.append(UsageDetail(
                id: "spend", label: AppLocalization.text("花费", "Spend"),
                value: AppLocalization.text("暂不可用", "Unavailable")
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "lithosai"), state: .ready, windows: [],
            balance: money(balance),
            providerCost: ProviderCostSummary(
                used: balance, limit: 0, currencyCode: "USD",
                period: AppLocalization.text("预付余额", "Prepaid credits"), balance: balance
            ),
            details: details, updatedAt: now
        )
    }

    private static func get(
        path: String,
        cookieHeader: String,
        csrf: String,
        organizationID: String? = nil,
        session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "X-Console-Csrf")
        if let organizationID { request.setValue(organizationID, forHTTPHeaderField: "X-Organization-Id") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == baseURL.host else {
            throw LithosAIUsageError.invalidResponse
        }
        switch http.statusCode {
        case 200: break
        case 401: throw LithosAIUsageError.sessionExpired
        case 403: throw LithosAIUsageError.permissionDenied
        case 429: throw LithosAIUsageError.rateLimited
        case 500...599: throw LithosAIUsageError.unavailable
        default: throw LithosAIUsageError.apiError(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LithosAIUsageError.invalidResponse
        }
        return root
    }

    private static func cookieValues(_ raw: String) -> [String: String]? {
        var header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !header.contains("\n"), !header.contains("\r") else { return nil }
        var values: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == sessionCookieName || name == csrfCookieName else { continue }
            guard !value.isEmpty, values[name] == nil else { return nil }
            values[name] = value
        }
        return values.count == 2 ? values : nil
    }

    private static func amount(_ raw: Any?) throws -> Double {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) <= safeIntegerLimit,
              number.doubleValue.rounded() == number.doubleValue else {
            throw LithosAIUsageError.invalidResponse
        }
        return number.doubleValue
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func money(_ amount: Double) -> String {
        if amount > 0, amount < 0.01 { return AppLocalization.text("少于 $0.01", "Less than $0.01") }
        return amount < 0 ? String(format: "-$%.2f", -amount) : String(format: "$%.2f", amount)
    }
}
