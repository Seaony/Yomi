import Foundation
import CoreFoundation

nonisolated enum ClaudePlatformUsageError: LocalizedError, Equatable {
    case missingCookie
    case sessionExpired
    case noAPIOrganization
    case billingDenied
    case rateLimited
    case unavailable
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text("请粘贴 platform.claude.com 中包含 sessionKey 的 Cookie 请求头", "Paste a platform.claude.com Cookie header containing sessionKey.")
        case .sessionExpired:
            AppLocalization.text("Claude Console 会话已过期，请重新登录并更新 Cookie", "The Claude Console session expired. Sign in again and update the cookie.")
        case .noAPIOrganization:
            AppLocalization.text("未找到 Claude Console API 组织，请检查账号或 Organization ID", "No Claude Console API organization was found. Check the account or Organization ID.")
        case .billingDenied:
            AppLocalization.text("Claude Console 拒绝访问账单，请向组织所有者申请账单权限", "Claude Console billing access was denied. Ask the organization owner for billing access.")
        case .rateLimited:
            AppLocalization.text("Claude Console 请求过于频繁，请稍后再试", "Claude Console requests are rate limited. Try again later.")
        case .unavailable:
            AppLocalization.text("Claude Console 暂时不可用", "Claude Console is temporarily unavailable.")
        case let .requestFailed(status):
            AppLocalization.text("Claude Console 请求失败（HTTP \(status)）", "Claude Console request failed (HTTP \(status)).")
        case .invalidResponse:
            AppLocalization.text("无法解析 Claude Console 账单数据", "Could not parse Claude Console billing data.")
        }
    }
}

nonisolated enum ClaudePlatformUsageFetcher {
    private struct Grant {
        let id: Int
        let label: String
        let program: String?
        let purchased: Bool
        let remaining: Double
        let granted: Double
        let expiresAt: Date?
    }

    static func fetch(
        credential: String,
        source: ProviderSource,
        organizationID: String = "",
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .cookie || source == .automatic,
              let cookie = cookieHeader(credential) else { throw ClaudePlatformUsageError.missingCookie }
        let organizationsData = try await get(path: "/api/organizations", cookie: cookie, session: session)
        guard let organizations = try? JSONSerialization.jsonObject(with: organizationsData) as? [[String: Any]] else {
            throw ClaudePlatformUsageError.invalidResponse
        }
        let requested = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [(id: String, name: String?)] = []
        for organization in organizations where (organization["capabilities"] as? [String])?.contains("api") == true {
            guard let id = text(organization["uuid"]),
                  id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
                throw ClaudePlatformUsageError.invalidResponse
            }
            if requested.isEmpty || id == requested { candidates.append((id, text(organization["name"]))) }
        }
        guard !candidates.isEmpty else { throw ClaudePlatformUsageError.noAPIOrganization }
        for candidate in candidates {
            let data: Data
            do {
                data = try await get(
                    path: "/api/organizations/\(candidate.id)/prepaid/credits", cookie: cookie,
                    billing: true, session: session
                )
            } catch ClaudePlatformUsageError.billingDenied {
                continue
            }
            var usage = try parseCredits(data, now: now)
            if let name = candidate.name {
                usage.details.append(UsageDetail(id: "organization", label: AppLocalization.text("组织", "Organization"), value: name))
            }
            do {
                let spendData = try await get(
                    path: "/api/organizations/\(candidate.id)/current_spend", cookie: cookie,
                    billing: true, session: session
                )
                let spend = try object(JSONSerialization.jsonObject(with: spendData))
                let amount = try minorUnits(spend["amount"])
                guard amount >= 0 else { throw ClaudePlatformUsageError.invalidResponse }
                let credits = try object(JSONSerialization.jsonObject(with: data))
                let scale = try currencyScale(credits)
                usage.details.append(UsageDetail(
                    id: "month-spend", label: AppLocalization.text("本月（UTC）", "This month (UTC)"),
                    value: money(amount / scale, currency: usage.providerCost!.currencyCode)
                ))
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                usage.details.append(UsageDetail(
                    id: "spend", label: AppLocalization.text("花费", "Spend"),
                    value: AppLocalization.text("暂不可用", "Unavailable")
                ))
            }
            return usage
        }
        throw ClaudePlatformUsageError.billingDenied
    }

    static func parseCredits(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudePlatformUsageError.invalidResponse
        }
        let currency = text(root["currency"]) ?? "USD"
        guard currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
            throw ClaudePlatformUsageError.invalidResponse
        }
        let scale = try currencyScale(root)
        let balance = try minorUnits(root["amount"]) / scale
        var grants: [Grant] = []
        for (field, purchased) in [("promo_tranches", false), ("tranches", true)] {
            guard let raw = root[field], !(raw is NSNull) else { continue }
            guard let list = raw as? [[String: Any]] else { throw ClaudePlatformUsageError.invalidResponse }
            for tranche in list {
                let granted = try minorUnits(tranche["granted_amount_minor_units"]) / scale
                let remaining = try minorUnits(tranche["remaining_amount_minor_units"]) / scale
                let expiresAt = date(text(tranche["expires_at"]))
                guard granted > 0, expiresAt.map({ $0 > now }) ?? true else { continue }
                grants.append(Grant(
                    id: grants.count,
                    label: text(tranche["name"]) ?? (purchased
                        ? AppLocalization.text("购买额度", "Purchased credit")
                        : AppLocalization.text("API 额度", "API credit")),
                    program: text(tranche["program_id"]), purchased: purchased,
                    remaining: max(0, remaining), granted: granted, expiresAt: expiresAt
                ))
            }
        }
        grants.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let subscription = grants.first { $0.program == "subscription_api_credit" && $0.remaining > 0 }
        let purchased = grants.first { $0.purchased && $0.remaining > 0 } ?? grants.first { $0.purchased }
        let windows = [subscription, purchased].compactMap { grant -> UsageWindow? in
            guard let grant else { return nil }
            return UsageWindow(
                id: grant.purchased ? "claudeplatform-purchased" : "claudeplatform-api-credit",
                label: grant.purchased ? AppLocalization.text("购买额度", "Purchased credit") : AppLocalization.text("API 额度", "API credit"),
                usedFraction: min(1, max(0, (grant.granted - grant.remaining) / grant.granted)),
                resetsAt: nil,
                detail: grantDescription(grant, currency: currency, now: now)
            )
        }
        let details = grants.filter { $0.id != subscription?.id && $0.id != purchased?.id }.map { grant in
            UsageDetail(id: "credit-grant-\(grant.id)", label: grant.label, value: grantDescription(grant, currency: currency, now: now))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "claudeplatform"), state: .ready, windows: windows,
            balance: money(balance, currency: currency),
            providerCost: ProviderCostSummary(
                used: balance, limit: 0, currencyCode: currency,
                period: AppLocalization.text("预付余额", "Prepaid credits"), balance: balance
            ),
            details: details, updatedAt: now
        )
    }

    private static func get(path: String, cookie: String, billing: Bool = false, session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://platform.claude.com\(path)")!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudePlatformUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401: throw ClaudePlatformUsageError.sessionExpired
        case 403: throw billing ? ClaudePlatformUsageError.billingDenied : ClaudePlatformUsageError.sessionExpired
        case 429: throw ClaudePlatformUsageError.rateLimited
        case 500...599: throw ClaudePlatformUsageError.unavailable
        default: throw ClaudePlatformUsageError.requestFailed(http.statusCode)
        }
    }

    private static func cookieHeader(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.contains("\r"), !value.contains("\n"), value.split(separator: ";").contains(where: {
            let pair = $0.trimmingCharacters(in: .whitespaces)
            return pair.hasPrefix("sessionKey=") && !pair.dropFirst(11).isEmpty
        }) else { return nil }
        return value
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw ClaudePlatformUsageError.invalidResponse }
        return result
    }

    private static func minorUnits(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ClaudePlatformUsageError.invalidResponse
        }
        let amount = number.doubleValue
        guard amount.isFinite, abs(amount) <= 9_007_199_254_740_991, amount.rounded() == amount else {
            throw ClaudePlatformUsageError.invalidResponse
        }
        return amount
    }

    private static func currencyScale(_ root: [String: Any]) throws -> Double {
        guard let rawBalance = root["balance"], !(rawBalance is NSNull) else { return 100 }
        let balance = try object(rawBalance)
        let credits = try object(balance["credits"] is NSNull ? [:] : balance["credits"] ?? [:])
        guard let rawExponent = credits["exponent"], !(rawExponent is NSNull) else { return 100 }
        let exponent = try minorUnits(rawExponent)
        guard (0...4).contains(exponent) else { throw ClaudePlatformUsageError.invalidResponse }
        return pow(10, exponent)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func money(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = AppLocalization.currentLanguage.locale
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }

    private static func grantDescription(_ grant: Grant, currency: String, now: Date) -> String {
        let left = money(grant.remaining, currency: currency)
        let total = money(grant.granted, currency: currency)
        let amounts = AppLocalization.text("剩余 \(left) / \(total)", "\(left) of \(total) left")
        guard let expiresAt = grant.expiresAt else { return amounts }
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.currentLanguage.locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sameYear = calendar.component(.year, from: now) == calendar.component(.year, from: expiresAt)
        formatter.dateFormat = AppLocalization.text(sameYear ? "M月d日" : "yyyy年M月d日", sameYear ? "MMM d" : "MMM d, yyyy")
        let expiry = formatter.string(from: expiresAt)
        return amounts + AppLocalization.text(" · \(expiry)到期（UTC）", " · Expires \(expiry) (UTC)")
    }
}
