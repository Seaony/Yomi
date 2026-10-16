import Foundation
import SweetCookieKit

nonisolated enum HelmcodeUsageError: LocalizedError {
    case missingCookies
    case cookieImportDeferred
    case invalidCookie
    case invalidSession
    case apiError(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            AppLocalization.text(
                "未找到 Helmcode 会话，请先登录 cloud.helmcode.com 或 cloud.nan.builders，或粘贴 Cookie 标头",
                "No Helmcode session found. Sign in to cloud.helmcode.com or cloud.nan.builders, or paste a Cookie header."
            )
        case .cookieImportDeferred:
            AppLocalization.text("请手动刷新一次以读取 Helmcode Cookie", "Refresh manually to import Helmcode cookies.")
        case .invalidCookie:
            AppLocalization.text("请粘贴 Cookie 标头，不支持 cURL 命令", "Paste a Cookie header. cURL captures are not supported.")
        case .invalidSession:
            AppLocalization.text("Helmcode 会话已过期，请重新登录", "The Helmcode session expired. Sign in again.")
        case let .apiError(status):
            AppLocalization.text("Helmcode 请求失败（HTTP \(status)）", "Helmcode request failed (HTTP \(status))")
        case let .invalidResponse(field):
            AppLocalization.text("Helmcode 额度字段无效：\(field)", "Invalid Helmcode quota field: \(field)")
        }
    }
}

nonisolated enum HelmcodeUsageFetcher {
    private struct Tenant {
        let domain: String
        let name: String
        let cookieDomains: [String]
    }

    private static let tenants = [
        Tenant(domain: "helmcode.com", name: "Helmcode Cloud", cookieDomains: ["cloud-api.helmcode.com", "helmcode.com"]),
        Tenant(domain: "nan.builders", name: "NaN Builders", cookieDomains: ["nan.builders"]),
    ]

    static func fetch(
        credential: String,
        source: ProviderSource,
        tenant: String,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cachedTenant: String? = nil,
        cacheUpdate: @escaping @Sendable (String?, String?) async -> Void = { _, _ in },
        allowBrowserImport: Bool = false,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let requestSession = URLSession(configuration: configuration, delegate: HelmcodeRedirectGuard(), delegateQueue: nil)
        defer { requestSession.finishTasksAndInvalidate() }

        if source == .cookie {
            let selected = tenants[tenant == "nanBuilders" ? 1 : 0]
            return try await fetchUsage(
                cookie: normalizedCookie(credential), tenant: selected, session: requestSession, now: now
            )
        }
        guard source == .automatic else { throw HelmcodeUsageError.missingCookies }
        var rejected = false
        let cachedTenantIndex: Int? = switch cachedTenant {
        case "helmcode": 0
        case "nanBuilders": 1
        default: nil
        }
        if let index = cachedTenantIndex, let raw = cachedCookieHeader, let header = try? normalizedCookie(raw) {
            do {
                return try await fetchUsage(cookie: header, tenant: tenants[index], session: requestSession, now: now)
            } catch HelmcodeUsageError.invalidSession {
                rejected = true
                await cacheUpdate(nil, nil)
            }
        }
        guard allowBrowserImport else {
            throw rejected ? HelmcodeUsageError.invalidSession : HelmcodeUsageError.cookieImportDeferred
        }
        let client = BrowserCookieClient()
        for candidate in tenants {
            for domain in candidate.cookieDomains {
                let query = BrowserCookieQuery(domains: [domain, "www.\(domain)"], domainMatch: .exact)
                for browser in Browser.defaultImportOrder {
                    guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: client) else { continue }
                    for imported in sources where !imported.records.isEmpty {
                        let cookies = BrowserCookieClient.makeHTTPCookies(imported.records, origin: query.origin)
                        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                        guard !header.isEmpty else { continue }
                        do {
                            let usage = try await fetchUsage(cookie: header, tenant: candidate, session: requestSession, now: now)
                            await cacheUpdate(header, candidate.domain == "helmcode.com" ? "helmcode" : "nanBuilders")
                            return usage
                        } catch HelmcodeUsageError.invalidSession {
                            rejected = true
                        }
                    }
                }
            }
        }
        throw rejected ? HelmcodeUsageError.invalidSession : HelmcodeUsageError.missingCookies
    }

    private static func fetchUsage(
        cookie: String,
        tenant: Tenant,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let quota = try await request("/api/usage/quota", cookie: cookie, tenant: tenant, timeout: 8, session: session)
        let billing = try? await request("/api/billing", cookie: cookie, tenant: tenant, timeout: 2, session: session)
        let credits = tenant.domain == "helmcode.com"
            ? try? await request("/api/billing/credits", cookie: cookie, tenant: tenant, timeout: 2, session: session)
            : nil
        return try parse(quota: quota, billing: billing, credits: credits, tenantName: tenant.name, now: now)
    }

    static func parse(
        quota: Data,
        billing: Data? = nil,
        credits: Data? = nil,
        tenantName: String = "Helmcode Cloud",
        now: Date = Date()
    ) throws -> ProviderUsage {
        guard let root = object(quota), let periodStart = root["periodStart"] as? String,
              let models = root["models"] as? [Any] else {
            throw HelmcodeUsageError.invalidResponse("periodStart / models")
        }
        let subscription = billing.flatMap(object)?["subscription"] as? [String: Any]
        let premium = (subscription?["premium"] as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } ?? false
        let fallback = nextMonth(after: periodStart)
        var windows: [UsageWindow] = []
        for model in models {
            guard let row = model as? [String: Any], let name = row["model"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 120, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw HelmcodeUsageError.invalidResponse("model")
            }
            let cap = try integer(row["cap"], field: "cap")
            let used = try integer(row["tokensUsed"], field: "tokensUsed")
            let credit = try optionalInteger(row["creditTokens"], field: "creditTokens") ?? 0
            let hours = try optionalInteger(row["windowHours"], field: "windowHours")
            if let hours, !(1...8760).contains(hours) { throw HelmcodeUsageError.invalidResponse("windowHours") }
            guard cap > 0, hours == nil || premium else { continue }
            let reset = (row["periodEnd"] as? String).flatMap(date) ?? fallback
            let detail = "\(name) · \(format(used)) / \(format(cap)) tokens" + (hours.map {
                AppLocalization.text(" · \(format($0)) 小时窗口", " · \(format($0))-hour window")
            } ?? "") + (credit > 0
                ? AppLocalization.text(" · \(format(credit)) 由余额支付", " · \(format(credit)) credit-funded") : "")
            windows.append(UsageWindow(
                id: "helmcode-\(name)",
                label: name,
                usedFraction: used / cap,
                resetsAt: reset,
                detail: detail
            ))
        }
        windows.sort {
            $0.usedFraction == $1.usedFraction ? $0.label < $1.label : $0.usedFraction > $1.usedFraction
        }
        var cost: ProviderCostSummary?
        if let credits = credits.flatMap(object), let balance = try? integer(credits["balanceMicros"], field: "balanceMicros", allowsNegative: true) {
            let currency = credits["currency"] == nil || credits["currency"] is NSNull
                ? "EUR" : (credits["currency"] as? String)?.uppercased() ?? ""
            if currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil {
                let remaining = max(0, balance / 1_000_000)
                cost = ProviderCostSummary(
                    used: remaining,
                    limit: 0,
                    currencyCode: currency,
                    period: AppLocalization.text("预付余额", "Prepaid balance"),
                    balance: remaining
                )
            }
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "helmcode"),
            state: .ready,
            windows: Array(windows.prefix(1)),
            additionalWindows: Array(windows.dropFirst()),
            providerCost: cost,
            details: [UsageDetail(id: "tenant", label: AppLocalization.text("租户", "Tenant"), value: tenantName)],
            updatedAt: now,
            message: nil
        )
    }

    private static func request(
        _ path: String,
        cookie: String,
        tenant: Tenant,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cloud-api.\(tenant.domain)\(path)")!)
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://cloud.\(tenant.domain)", forHTTPHeaderField: "Origin")
        request.setValue("https://cloud.\(tenant.domain)/dashboard", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HelmcodeUsageError.invalidResponse("HTTP") }
        if (300..<400).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
            throw HelmcodeUsageError.invalidSession
        }
        guard (200..<300).contains(http.statusCode) else { throw HelmcodeUsageError.apiError(http.statusCode) }
        return data
    }

    private static func normalizedCookie(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HelmcodeUsageError.missingCookies }
        if value.lowercased().hasPrefix("curl ") { throw HelmcodeUsageError.invalidCookie }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.contains("="), value.rangeOfCharacter(from: .newlines) == nil else {
            throw HelmcodeUsageError.invalidCookie
        }
        return value
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func integer(_ value: Any?, field: String, allowsNegative: Bool = false) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw HelmcodeUsageError.invalidResponse(field)
        }
        let result = number.doubleValue
        guard result.isFinite, abs(result) <= 9_007_199_254_740_991,
              result.rounded(.towardZero) == result, allowsNegative || result >= 0 else {
            throw HelmcodeUsageError.invalidResponse(field)
        }
        return result
    }

    private static func optionalInteger(_ value: Any?, field: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        return try integer(value, field: field)
    }

    private static func nextMonth(after value: String) -> Date? {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}(?:T|$)", options: .regularExpression) != nil else { return nil }
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1] + 1, day: 1))
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private final class HelmcodeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
