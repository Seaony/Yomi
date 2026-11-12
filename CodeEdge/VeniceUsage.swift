import Foundation

nonisolated enum VeniceUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case invalidResponse
    case invalidField(String)
    case missingSession
    case expiredSession
    case anonymousSession
    case missingQuota

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Venice API Key", "Missing Venice API key")
        case .unauthorized:
            AppLocalization.text("Venice API Key 无效", "The Venice API key is invalid")
        case let .apiError(status):
            AppLocalization.text("Venice 接口请求失败（HTTP \(status)）", "Venice API request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("Venice 返回内容无效", "The Venice response is invalid")
        case let .invalidField(field):
            AppLocalization.text("Venice 字段无效：\(field)", "Invalid Venice field: \(field)")
        case .missingSession:
            AppLocalization.text(
                "未找到 Venice 会话（__session、__session_<后缀> 或 __venice-auth.session-token），请保持已登录的 venice.ai 标签页打开后重试，或粘贴新的 Cookie",
                "No Venice session was found (__session, __session_<suffix>, or __venice-auth.session-token). Keep a signed-in venice.ai tab active and retry, or paste a fresh Cookie header."
            )
        case .expiredSession:
            AppLocalization.text(
                "Venice 会话无效或已过期，请保持已登录的 venice.ai 标签页打开后重试；Clerk 会话约 60 秒过期，手动模式需重新复制 Cookie",
                "The Venice session is invalid or expired. Keep a signed-in venice.ai tab active and retry; Clerk sessions last about 60 seconds. Manual mode needs a fresh Cookie header."
            )
        case .anonymousSession:
            AppLocalization.text("Venice 浏览器会话未登录，没有订阅积分", "The Venice browser session is anonymous and has no subscription credits.")
        case .missingQuota:
            AppLocalization.text("Venice 浏览器会话未返回订阅积分", "The Venice browser session did not include subscription credits.")
        }
    }
}

nonisolated struct VeniceUsageSnapshot: Sendable, Equatable {
    let canConsume: Bool
    let consumptionCurrency: String?
    let diem: Double?
    let usd: Double?
    let diemEpochAllocation: Double?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let currency = consumptionCurrency?.uppercased()
        let fraction: Double
        let detail: String
        let balance: String?
        if !canConsume {
            fraction = 1
            detail = "Balance unavailable for API calls"
            balance = nil
        } else if currency == "USD", let usd, usd > 0 {
            fraction = 0
            detail = String(format: "$%.2f USD remaining", usd)
            balance = String(format: "$%.2f", usd)
        } else if currency != "USD", let diem, let allocation = diemEpochAllocation, allocation > 0 {
            fraction = min(1, max(0, (allocation - diem) / allocation))
            detail = String(format: "DIEM %.2f / %.2f epoch allocation", diem, allocation)
            balance = String(format: "DIEM %.2f", diem)
        } else if currency == "DIEM", let diem, diem > 0 {
            fraction = 0
            detail = String(format: "DIEM %.2f remaining", diem)
            balance = String(format: "DIEM %.2f", diem)
        } else if let diem, diem > 0 {
            fraction = 0
            detail = String(format: "DIEM %.2f remaining", diem)
            balance = String(format: "DIEM %.2f", diem)
        } else if let usd, usd > 0 {
            fraction = 0
            detail = String(format: "$%.2f USD remaining", usd)
            balance = String(format: "$%.2f", usd)
        } else {
            fraction = 1
            detail = "No Venice API balance available"
            balance = nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "venice"),
            state: .ready,
            windows: [UsageWindow(
                id: "venice-balance",
                label: "Balance",
                usedFraction: fraction,
                resetsAt: nil,
                detail: detail
            )],
            balance: balance,
            plan: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum VeniceUsageFetcher {
    static let endpoint = URL(string: "https://api.venice.ai/api/v1/billing/balance")!
    static let webEndpoint = URL(string: "https://outerface.venice.ai/api/user/session")!
    static let environmentKeys = ["VENICE_API_KEY", "VENICE_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured].compactMap({ $0 }) + environmentKeys.compactMap({ environment[$0] }) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw VeniceUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VeniceUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now).toProviderUsage()
        case 401, 403: throw VeniceUsageError.unauthorized
        default: throw VeniceUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> VeniceUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VeniceUsageError.invalidResponse
        }
        guard let canConsumeValue = root["canConsume"] as? NSNumber,
              CFGetTypeID(canConsumeValue) == CFBooleanGetTypeID() else {
            throw VeniceUsageError.invalidField("canConsume")
        }
        guard let balances = root["balances"] as? [String: Any] else {
            throw VeniceUsageError.invalidField("balances")
        }
        let currency: String?
        if root["consumptionCurrency"] == nil || root["consumptionCurrency"] is NSNull {
            currency = nil
        } else if let value = root["consumptionCurrency"] as? String {
            currency = value.isEmpty ? nil : value
        } else {
            throw VeniceUsageError.invalidField("consumptionCurrency")
        }
        return VeniceUsageSnapshot(
            canConsume: canConsumeValue.boolValue,
            consumptionCurrency: currency,
            diem: try optionalNumber(balances["diem"], field: "balances.diem"),
            usd: try optionalNumber(balances["usd"], field: "balances.usd"),
            diemEpochAllocation: try optionalNumber(root["diemEpochAllocation"], field: "diemEpochAllocation"),
            updatedAt: now
        )
    }

    static func fetchWeb(cookieHeader: String, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        try Task.checkCancellation()
        guard let header = sessionCookieHeader(cookieHeader),
              let separator = header.firstIndex(of: "=") else { throw VeniceUsageError.missingSession }
        let name = String(header[..<separator])
        let token = String(header[header.index(after: separator)...])
        var request = URLRequest(url: webEndpoint)
        request.httpShouldHandleCookies = false
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        if name == "__venice-auth.session-token" {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VeniceUsageError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw VeniceUsageError.expiredSession }
        guard (200..<300).contains(http.statusCode) else { throw VeniceUsageError.apiError(http.statusCode) }
        return try parseWeb(data, now: now)
    }

    static func sessionCookieHeader(_ raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("cookie:") { raw = String(raw.dropFirst(7)) }
        let legacyName = "__venice-auth.session-token"
        var legacy: String?
        var clerk: String?
        var chunks: [Int: String] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if name == legacyName {
                legacy = "\(name)=\(value)"
            } else if name.hasPrefix(legacyName + "."),
                      let index = Int(name.dropFirst(legacyName.count + 1)), index >= 0 {
                chunks[index] = value
            } else if name == "__session" || (name.hasPrefix("__session_") && name.count > 10) {
                if clerk == nil || name == "__session" { clerk = "\(name)=\(value)" }
            }
        }
        if let legacy { return legacy }
        if !chunks.isEmpty {
            let ordered = (0..<chunks.count).compactMap { chunks[$0] }
            if ordered.count == chunks.count { return "\(legacyName)=\(ordered.joined())" }
        }
        return clerk
    }

    static func parseWeb(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VeniceUsageError.invalidResponse
        }
        guard let token = root["token"] as? String else { throw VeniceUsageError.expiredSession }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw VeniceUsageError.invalidResponse }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
            throw VeniceUsageError.invalidResponse
        }
        guard let expiration = webNumber(claims["exp"]),
              (1_000_000_000...4_000_000_000).contains(expiration),
              Date(timeIntervalSince1970: expiration).timeIntervalSince(now) > -60 else {
            throw VeniceUsageError.expiredSession
        }
        let plan = (claims["userType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plan, ["anonymous", "anon", "guest", "unauthenticated", "logged_out"].contains(plan.lowercased()) {
            throw VeniceUsageError.anonymousSession
        }
        guard let usage = claims["bundledCreditsUsage"] as? [String: Any],
              let spent = webNumber(usage["usedThisCycle"]),
              let refill = webNumber(usage["monthlyRefillCredits"]), refill > 0 else {
            throw VeniceUsageError.missingQuota
        }
        var details: [UsageDetail] = []
        if let available = webNumber(usage["availableCredits"]) ?? webNumber(claims["bundledCredits"]) {
            details.append(UsageDetail(id: "venice-subscription-credits", label: AppLocalization.text("可用订阅积分", "Subscription credits available"), value: formatCredits(available)))
        }
        if let total = webNumber(claims["veniceCredits"]) {
            details.append(UsageDetail(id: "venice-total-credits", label: AppLocalization.text("可用总积分", "Total credits available"), value: formatCredits(total)))
        }
        details.append(UsageDetail(id: "venice-cycle-spending", label: AppLocalization.text("本周期已用", "Used this cycle"), value: formatCredits(spent)))
        details.append(UsageDetail(id: "venice-monthly-refill", label: AppLocalization.text("每月补充积分", "Monthly refill"), value: formatCredits(refill)))
        if let cap = webNumber(usage["tierCap"]) {
            details.append(UsageDetail(id: "venice-bank-cap", label: AppLocalization.text("积分累计上限", "Bank cap"), value: formatCredits(cap)))
        }
        if let milliseconds = webNumber(usage["nextRefillAt"]),
           (1_000_000_000...4_000_000_000).contains(milliseconds / 1_000) {
            let formatter = DateFormatter()
            formatter.locale = AppLocalization.currentLanguage.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            details.append(UsageDetail(id: "venice-next-refill", label: AppLocalization.text("下次补充", "Next refill"), value: formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "venice"), state: .ready, windows: [],
            plan: plan?.isEmpty == false ? plan : nil, details: details, updatedAt: now
        )
    }

    private static func webNumber(_ value: Any?) -> Double? {
        guard let number = try? optionalNumber(value, field: "credits"), number >= 0 else { return nil }
        return number
    }

    private static func formatCredits(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let number = Double(trimmed), number.isFinite else {
                throw VeniceUsageError.invalidField(field)
            }
            return number
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw VeniceUsageError.invalidField(field)
        }
        return number.doubleValue
    }
}
