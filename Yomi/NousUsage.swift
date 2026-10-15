import Foundation

nonisolated enum NousUsageError: LocalizedError {
    case missingCredentials
    case invalidAuthFile
    case expiredToken
    case unauthorized
    case apiError(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未找到 Nous Portal 登录，请运行 hermes 登录或设置 NOUS_PORTAL_ACCESS_TOKEN",
                "Nous Portal login was not found. Run hermes to sign in or set NOUS_PORTAL_ACCESS_TOKEN"
            )
        case .invalidAuthFile:
            AppLocalization.text(
                "Hermes 认证文件没有 Nous Portal 访问令牌，请运行 hermes auth add nous 登录",
                "The Hermes auth file has no Nous Portal access token. Run hermes auth add nous to sign in"
            )
        case .expiredToken, .unauthorized:
            AppLocalization.text(
                "Nous Portal 访问令牌已过期，请运行 hermes 更新登录或提供新的访问令牌",
                "The Nous Portal access token has expired. Run hermes to renew the login or provide a fresh access token"
            )
        case let .apiError(status):
            AppLocalization.text("Nous Portal 请求失败（HTTP \(status)）", "Nous Portal request failed (HTTP \(status))")
        case let .invalidResponse(field):
            AppLocalization.text("Nous Portal 返回字段无效：\(field)", "Invalid Nous Portal response field: \(field)")
        }
    }
}

nonisolated enum NousUsageFetcher {
    private struct Credential {
        let token: String
        let portal: String?
        let expiresAt: Date?
    }

    static func fetch(
        accessToken: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let credential = try resolveCredential(accessToken: accessToken, environment: environment, now: now)
        let baseURL = portalURL(environment: environment, stored: credential.portal)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/account"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NousUsageError.apiError(0) }
        if http.statusCode == 401 { throw NousUsageError.unauthorized }
        guard http.statusCode == 200 else { throw NousUsageError.apiError(http.statusCode) }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NousUsageError.invalidResponse("JSON")
        }
        if let error = root["error"], !(error is NSNull), (error as? Bool) != false {
            throw NousUsageError.invalidResponse("error")
        }
        let subscription = try object(root["subscription"], field: "subscription")
        let access = try object(root["paid_service_access"], field: "paid_service_access")
        let user = try object(root["user"], field: "user")
        let organization = try object(root["organisation"], field: "organisation")
        let monthly = try number(subscription["monthly_credits"], field: "monthly_credits")
        if let monthly, monthly < 0 { throw NousUsageError.invalidResponse("monthly_credits") }
        let remaining = try number(subscription["credits_remaining"], field: "credits_remaining")
            ?? number(access["subscription_credits_remaining"], field: "subscription_credits_remaining")
        let rollover = try number(subscription["rollover_credits"], field: "rollover_credits")
        let purchased = try number(root["purchased_credits_remaining"], field: "purchased_credits_remaining")
            ?? number(access["purchased_credits_remaining"], field: "paid_service_access.purchased_credits_remaining")
        let total = try number(access["total_usable_credits"], field: "total_usable_credits")
        guard [monthly, remaining, rollover, purchased, total].contains(where: { $0 != nil }) else {
            throw NousUsageError.invalidResponse("credits")
        }
        var renewal: Date?
        if let raw = subscription["current_period_end"], !(raw is NSNull) {
            guard let value = raw as? String, let date = isoDate(value) else {
                throw NousUsageError.invalidResponse("current_period_end")
            }
            renewal = date
        }
        var windows: [UsageWindow] = []
        if let monthly, monthly > 0, let remaining {
            windows = [UsageWindow(
                id: "nous-monthly-credits",
                label: AppLocalization.text("每月额度", "Monthly credits"),
                usedFraction: max(0, monthly - max(0, remaining)) / monthly,
                resetsAt: renewal,
                detail: AppLocalization.text(
                    "剩余 \(usd(max(0, remaining))) / \(usd(monthly))",
                    "\(usd(max(0, remaining))) of \(usd(monthly)) left"
                )
            )]
        }
        var details: [UsageDetail] = []
        if let remaining {
            let grant = monthly.flatMap { $0 > 0 ? " / \(usd($0))" : nil } ?? ""
            details.append(UsageDetail(
                id: "nous-subscription-credits",
                label: AppLocalization.text("订阅剩余额度", "Subscription credits"),
                value: "\(usd(max(0, remaining)))\(grant)"
            ))
        } else if let monthly {
            details.append(UsageDetail(
                id: "nous-monthly-grant",
                label: AppLocalization.text("每月额度", "Monthly grant"),
                value: usd(monthly)
            ))
        }
        if let rollover, rollover > 0 {
            details.append(UsageDetail(
                id: "nous-rollover", label: AppLocalization.text("结转额度", "Rollover credits"), value: usd(rollover)
            ))
        }
        if let renewal {
            let formatter = DateFormatter()
            formatter.locale = AppLocalization.currentLanguage.locale
            formatter.dateStyle = .medium
            details.append(UsageDetail(
                id: "nous-renewal", label: AppLocalization.text("续订时间", "Renews"), value: formatter.string(from: renewal)
            ))
        }
        if let purchased {
            details.append(UsageDetail(
                id: "nous-top-up", label: AppLocalization.text("充值额度", "Top-up credits"), value: usd(purchased)
            ))
        }
        if let total {
            details.append(UsageDetail(
                id: "nous-total", label: AppLocalization.text("可用总额度", "Total usable"), value: usd(total)
            ))
        }
        if let email = cleaned(user["email"] as? String) {
            details.append(UsageDetail(id: "nous-account", label: AppLocalization.text("账号", "Account"), value: email))
        }
        if let name = cleaned(organization["name"] as? String) {
            details.append(UsageDetail(id: "nous-organization", label: AppLocalization.text("组织", "Organization"), value: name))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "nous"),
            state: .ready,
            windows: windows,
            balance: (total ?? purchased).map(usd),
            plan: cleaned(subscription["plan"] as? String)
                ?? ((access["has_active_subscription"] as? Bool) == true ? AppLocalization.text("订阅", "Subscription") : nil),
            details: details,
            updatedAt: now
        )
    }

    private static func resolveCredential(
        accessToken: String?, environment: [String: String], now: Date
    ) throws -> Credential {
        if let token = cleaned(accessToken) ?? cleaned(environment["NOUS_PORTAL_ACCESS_TOKEN"]) {
            let expiry = jwtExpiry(token)
            if let expiry, expiry.timeIntervalSince(now) <= 60 { throw NousUsageError.expiredToken }
            return Credential(token: token, portal: nil, expiresAt: expiry)
        }
        let home = cleaned(environment["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let root = cleaned(environment["HERMES_HOME"]) ?? "\(home)/.hermes"
        let rootURL = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
        var sawFile = false
        var sawExpired = false
        for name in ["auth.json", "shared/nous_auth.json"] {
            let url = rootURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            sawFile = true
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credential = storedCredential(json)
            else { continue }
            if let expiry = credential.expiresAt, expiry.timeIntervalSince(now) <= 60 {
                sawExpired = true
                continue
            }
            return credential
        }
        if sawExpired { throw NousUsageError.expiredToken }
        throw sawFile ? NousUsageError.invalidAuthFile : NousUsageError.missingCredentials
    }

    private static func storedCredential(_ root: [String: Any]) -> Credential? {
        func read(_ state: [String: Any]) -> Credential? {
            guard let token = cleaned(state["access_token"] as? String) else { return nil }
            return Credential(
                token: token,
                portal: cleaned(state["portal_base_url"] as? String),
                expiresAt: (state["expires_at"] as? String).flatMap(isoDate) ?? jwtExpiry(token)
            )
        }
        if let providers = root["providers"] as? [String: Any],
           let nous = providers["nous"] as? [String: Any], let credential = read(nous) {
            return credential
        }
        if let pool = root["credential_pool"] as? [String: Any], let entries = pool["nous"] as? [[String: Any]] {
            let candidates = entries.compactMap { entry -> (Credential, Double, Double, Int)? in
                guard let credential = read(entry) else { return nil }
                return (
                    credential,
                    (entry["agent_key_expires_at"] as? String).flatMap(isoDate)?.timeIntervalSince1970 ?? 0,
                    credential.expiresAt?.timeIntervalSince1970 ?? 0,
                    entry["priority"] as? Int ?? 0
                )
            }
            if let selected = candidates.max(by: { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                if left.2 != right.2 { return left.2 < right.2 }
                return left.3 > right.3
            }) { return selected.0 }
        }
        return read(root)
    }

    private static func portalURL(environment: [String: String], stored: String?) -> URL {
        func origin(_ raw: String?) -> URL? {
            guard let raw = cleaned(raw),
                  let components = URLComponents(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                  components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil, components.path.isEmpty
            else { return nil }
            return components.url
        }
        for key in ["NOUS_PORTAL_BASE_URL", "HERMES_PORTAL_BASE_URL"] {
            if let url = origin(environment[key]) { return url }
        }
        if let url = origin(stored), let host = url.host?.lowercased(),
           host == "nousresearch.com" || host.hasSuffix(".nousresearch.com") { return url }
        return URL(string: "https://portal.nousresearch.com")!
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    private static func object(_ value: Any?, field: String) throws -> [String: Any] {
        guard let value, !(value is NSNull) else { return [:] }
        guard let object = value as? [String: Any] else { throw NousUsageError.invalidResponse(field) }
        return object
    }

    private static func number(_ value: Any?, field: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.doubleValue
        }
        if let raw = value as? String {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
               let number = Double(text), number.isFinite { return number }
        }
        throw NousUsageError.invalidResponse(field)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}
