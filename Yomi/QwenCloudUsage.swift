import CoreFoundation
import Foundation
import SweetCookieKit

enum QwenCloudUsageError: LocalizedError, Equatable {
    case loginRequired
    case invalidCredentials
    case apiError(String)
    case networkError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            AppLocalization.text(
                "Qwen Cloud 需要重新登录，请在浏览器登录后重试",
                "Qwen Cloud login required. Sign in in your browser and try again."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "Qwen Cloud 已拒绝当前会话，请重新导入或粘贴 Cookie",
                "Qwen Cloud rejected the stored session. Re-import or re-paste the Cookie header."
            )
        case let .apiError(message):
            AppLocalization.text("Qwen Cloud 用量接口错误：\(message)", "Qwen Cloud usage API error: \(message)")
        case let .networkError(message):
            AppLocalization.text("Qwen Cloud 网络错误：\(message)", "Qwen Cloud network error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Qwen Cloud 用量：\(message)", "Failed to parse Qwen Cloud usage: \(message)")
        }
    }
}

nonisolated enum QwenCloudUsageFetcher {
    struct CookieHeaders: Sendable {
        let api: String
        let dashboard: String
    }

    static let gatewayBaseURLString = "https://home.qwencloud.com"
    static let dataGatewayBaseURLString = "https://cs-data.qwencloud.com"
    static let productCode = "sfm_tokenplansolo_public_intl"
    static let consoleProduct = "sfm_bailian"
    static let consoleAction = "IntlBroadScopeAspnGateway"
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let quotaConfigAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
    static let region = "ap-southeast-1"
    static let language = "en-US"

    private static let cookieDomains = [
        "qwencloud.com",
        "home.qwencloud.com",
        "account.qwencloud.com",
        "signin.qwencloud.com",
        "www.qwencloud.com",
        "alibabacloud.com",
        "account.alibabacloud.com",
        "aliyun.com",
        "console.aliyun.com",
    ]
    private static let authTicketCookies: Set<String> = [
        "login_aliyunid_ticket",
        "login_qwencloud_ticket",
        "qwen_sso_ticket",
    ]

    static func fetch(
        credential rawCredential: String,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        let headers: CookieHeaders
        if let manual = normalizedCookie(rawCredential) {
            headers = CookieHeaders(api: manual, dashboard: manual)
        } else if let supplied = normalizedCookie(environment["QWEN_CLOUD_COOKIE"]) {
            headers = CookieHeaders(api: supplied, dashboard: supplied)
        } else if let imported = automaticCookieHeaders(environment: environment) {
            headers = imported
        } else {
            throw UsageCollectionError.missingCredential
        }

        let secToken = try await resolveSECToken(
            cookieHeader: headers.dashboard,
            apiURL: resolveAPIURL(api: usageAPI, environment: environment),
            dashboardURL: dashboardURL(environment: environment),
            apiCookieHeader: headers.api,
            session: session
        )
        let usageData = try await request(
            api: usageAPI,
            parameters: [:],
            secToken: secToken,
            headers: headers,
            session: session,
            environment: environment
        )
        let subscriptionData = try? await request(
            api: subscriptionAPI,
            parameters: ["commodityCode": productCode],
            secToken: secToken,
            headers: headers,
            session: session,
            environment: environment
        )
        let quotaConfigData = try? await request(
            api: quotaConfigAPI,
            parameters: [:],
            secToken: secToken,
            headers: headers,
            session: session,
            environment: environment
        )
        return try parse(
            usageData: usageData,
            subscriptionData: subscriptionData,
            quotaConfigData: quotaConfigData,
            now: now
        )
    }

    static func parse(
        usageData: Data,
        subscriptionData: Data? = nil,
        quotaConfigData: Data? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        if let current = try parseCurrent(
            usageData: usageData,
            subscriptionData: subscriptionData,
            quotaConfigData: quotaConfigData,
            now: now
        ) {
            return current
        }
        return try parseLegacy(data: usageData, now: now)
    }

    static func dashboardURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = hostOverride(environment: environment) ?? gatewayBaseURLString
        return URL(string: trimmedBase(base) + "/billing/subscription/token-plan-individual")!
    }

    static func defaultQuotaURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        defaultAPIURL(api: usageAPI, environment: environment)
    }

    static func resolveAPIURL(
        api: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        quotaURLOverride(environment: environment) ?? defaultAPIURL(api: api, environment: environment)
    }

    static func hostOverride(environment: [String: String]) -> String? {
        guard let raw = cleaned(environment["QWEN_CLOUD_HOST"]) else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return trimmedBase(url.absoluteString)
    }

    static func quotaURLOverride(environment: [String: String]) -> URL? {
        guard let raw = cleaned(environment["QWEN_CLOUD_QUOTA_URL"]) else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard let cleaned = cleaned(raw) else { return nil }
        let pairs = cleaned.split(separator: ";").compactMap { component -> String? in
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return "\(name)=\(value)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    static func automaticCookieHeaders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CookieHeaders? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        for browser in [Browser.chrome, Browser.brave] {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard isAuthenticatedSession(cookies) else { continue }
                guard let api = cookieHeader(cookies, targetURL: resolveAPIURL(api: usageAPI, environment: environment)),
                      let dashboard = cookieHeader(cookies, targetURL: dashboardURL(environment: environment))
                else { continue }
                return CookieHeaders(api: api, dashboard: dashboard)
            }
        }
        return nil
    }

    static func isAuthenticatedSession(_ cookies: [HTTPCookie]) -> Bool {
        !Set(cookies.map(\.name)).isDisjoint(with: authTicketCookies)
    }

    static func cookieHeader(_ cookies: [HTTPCookie], targetURL: URL, now: Date = Date()) -> String? {
        var selected: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard !cookie.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cookie.expiresDate.map({ $0 >= now }) ?? true,
                  cookieMatches(cookie, targetURL: targetURL) else { continue }
            if let existing = selected[cookie.name] {
                let lhs = (cookie.path.count, normalizedDomain(cookie).count, cookie.expiresDate ?? .distantPast)
                let rhs = (existing.path.count, normalizedDomain(existing).count, existing.expiresDate ?? .distantPast)
                if lhs >= rhs { selected[cookie.name] = cookie }
            } else {
                selected[cookie.name] = cookie
            }
        }
        guard !selected.isEmpty else { return nil }
        return selected.keys.sorted().compactMap { name in
            selected[name].map { "\($0.name)=\($0.value)" }
        }.joined(separator: "; ")
    }

    static func extractSECToken(from html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: html,
                      range: NSRange(html.startIndex..<html.endIndex, in: html)
                  ), let range = Range(match.range(at: 1), in: html) else { continue }
            let value = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    private static func defaultAPIURL(api: String, environment: [String: String]) -> URL {
        let base = hostOverride(environment: environment) ?? dataGatewayBaseURLString
        var components = URLComponents(string: trimmedBase(base) + "/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: consoleAction),
            URLQueryItem(name: "product", value: consoleProduct),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return components.url!
    }

    private static func request(
        api: String,
        parameters: [String: String],
        secToken: String,
        headers: CookieHeaders,
        session: URLSession,
        environment: [String: String]
    ) async throws -> Data {
        let url = resolveAPIURL(api: api, environment: environment)
        let dashboard = dashboardURL(environment: environment)
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": dashboard.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": dashboard.host ?? "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": language,
        ]
        if let anonymous = cookieValue("cna", in: headers.api) {
            cornerstone["X-Anonymous-Id"] = anonymous
        }
        var dataParameters = parameters as [String: Any]
        dataParameters["cornerstoneParam"] = cornerstone
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": dataParameters]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw QwenCloudUsageError.parseFailed("Could not encode request parameters")
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "product", value: consoleProduct),
            URLQueryItem(name: "action", value: consoleAction),
            URLQueryItem(name: "sec_token", value: secToken),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "params", value: paramsJSON),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(headers.api, forHTTPHeaderField: "Cookie")
        request.setValue(hostOverride(environment: environment) ?? gatewayBaseURLString, forHTTPHeaderField: "Origin")
        request.setValue(dashboard.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = cookieValue("login_aliyunid_csrf", in: headers.api)
            ?? cookieValue("csrf", in: headers.api) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await routedData(
                request: request,
                session: session,
                apiURL: url,
                dashboardURL: dashboard,
                headers: headers
            )
        } catch {
            throw QwenCloudUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QwenCloudUsageError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw QwenCloudUsageError.invalidCredentials
        default:
            throw QwenCloudUsageError.apiError("HTTP \(http.statusCode)")
        }
    }

    private static func resolveSECToken(
        cookieHeader: String,
        apiURL: URL,
        dashboardURL: URL,
        apiCookieHeader: String,
        session: URLSession
    ) async throws -> String {
        let headers = CookieHeaders(api: apiCookieHeader, dashboard: cookieHeader)
        var dashboardFailure: Error?
        do {
            var request = URLRequest(url: dashboardURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            let (data, response) = try await routedData(
                request: request,
                session: session,
                apiURL: apiURL,
                dashboardURL: dashboardURL,
                headers: headers
            )
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (500...599).contains(http.statusCode) { throw URLError(.badServerResponse) }
            if http.statusCode == 200, let html = String(data: data, encoding: .utf8),
               !looksLikeLoginPage(html), let token = extractSECToken(from: html) {
                return token
            }
        } catch {
            dashboardFailure = error
        }

        if let token = cookieValue("sec_token", in: cookieHeader) { return token }

        do {
            var components = URLComponents()
            components.scheme = dashboardURL.scheme ?? "https"
            components.host = dashboardURL.host
            components.port = dashboardURL.port
            components.path = "/tool/user/info.json"
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            let (data, response) = try await routedData(
                request: request,
                session: session,
                apiURL: apiURL,
                dashboardURL: dashboardURL,
                headers: headers
            )
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let raw = try? JSONSerialization.jsonObject(with: data),
               let token = findFirstString(keys: ["secToken", "sec_token", "csrfToken", "token"], in: expand(raw)) {
                return token
            }
        } catch {
            if dashboardFailure == nil { dashboardFailure = error }
        }
        if let dashboardFailure { throw QwenCloudUsageError.networkError(dashboardFailure.localizedDescription) }
        throw QwenCloudUsageError.loginRequired
    }

    private static func routedData(
        request: URLRequest,
        session: URLSession,
        apiURL: URL,
        dashboardURL: URL,
        headers: CookieHeaders
    ) async throws -> (Data, URLResponse) {
        let delegate = RedirectDelegate(
            apiURL: apiURL,
            dashboardURL: dashboardURL,
            apiCookieHeader: headers.api,
            dashboardCookieHeader: headers.dashboard
        )
        return try await session.data(for: request, delegate: delegate)
    }

    private static func parseCurrent(
        usageData: Data,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        now: Date
    ) throws -> ProviderUsage? {
        guard let raw = try? JSONSerialization.jsonObject(with: usageData) else { return nil }
        let expanded = expand(raw)
        guard let usage = findDictionary(
            containing: ["per5HourPercentage", "per1WeekPercentage"],
            in: expanded
        ) else { return nil }
        let fiveHour = ratio(usage["per5HourPercentage"])
        let weekly = ratio(usage["per1WeekPercentage"])
        guard fiveHour != nil || weekly != nil else { return nil }

        let planCode = subscriptionData.flatMap { data -> String? in
            guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return findFirstString(
                keys: ["specCode", "spec_code", "planName", "plan_name"],
                in: expand(raw)
            )?.lowercased()
        }
        let totals = quotaConfigData.flatMap { data -> (fiveHour: Double?, weekly: Double?)? in
            guard let planCode, let raw = try? JSONSerialization.jsonObject(with: data),
                  let value = findFirstValue(keys: [planCode], in: expand(raw)),
                  let quota = value as? [String: Any] else { return nil }
            let five = number(quota["five_hour"] ?? quota["fiveHour"])
            let week = number(quota["weekly"])
            return five != nil || week != nil ? (five, week) : nil
        }
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(UsageWindow(
                id: "qwencloud-5h",
                label: "5-hour",
                usedFraction: fiveHour,
                resetsAt: date(usage["per5HourResetTime"]),
                detail: quotaDetail(fraction: fiveHour, total: totals?.fiveHour)
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "qwencloud-weekly",
                label: "Weekly",
                usedFraction: weekly,
                resetsAt: date(usage["per1WeekResetTime"]),
                detail: quotaDetail(fraction: weekly, total: totals?.weekly)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "qwencloud"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: planCode.map(displayPlan),
            updatedAt: now,
            message: nil
        )
    }

    private static func parseLegacy(data: Data, now: Date) throws -> ProviderUsage {
        guard !data.isEmpty else { throw QwenCloudUsageError.parseFailed("Empty response body") }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            if let text = String(data: data, encoding: .utf8)?.lowercased(),
               text.contains("<html"), text.contains("login") || text.contains("sign in") {
                throw QwenCloudUsageError.loginRequired
            }
            throw QwenCloudUsageError.parseFailed("Invalid JSON response")
        }
        let expanded = expand(raw)
        guard let root = expanded as? [String: Any] else {
            throw QwenCloudUsageError.parseFailed("Unexpected payload")
        }
        try throwIfError(root)
        let quotaKeys = usedKeys + totalKeys + remainingKeys
        let summary = findDictionary(containing: quotaKeys, in: root)
            ?? findDictionary(containing: countKeys, in: root)
            ?? root
        let total = firstNumber(keys: totalKeys, in: summary)
        let remaining = firstNumber(keys: remainingKeys, in: summary)
        let used = firstNumber(keys: usedKeys, in: summary)
            ?? total.flatMap { total in remaining.map { max(0, total - $0) } }
        let count = firstNumber(keys: countKeys, in: summary)
        let plan = findFirstString(keys: planKeys, in: summary)
            ?? ((count ?? 0) > 0 || total != nil ? "TOKEN PLAN" : nil)
        guard plan != nil || total != nil || used != nil || remaining != nil || count != nil else {
            throw QwenCloudUsageError.parseFailed("Missing token plan data")
        }
        var windows: [UsageWindow] = []
        if let total, total > 0, let used = used ?? remaining.map({ total - $0 }) {
            let normalized = max(0, min(used, total))
            windows.append(UsageWindow(
                id: "qwencloud-credits",
                label: "5-hour",
                usedFraction: normalized / total,
                resetsAt: findDate(keys: resetKeys, in: summary) ?? findDate(keys: resetKeys, in: root),
                detail: "\(format(normalized)) / \(format(total)) credits used"
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "qwencloud"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: plan,
            updatedAt: now,
            message: nil
        )
    }

    private static let planKeys = [
        "planName", "plan_name", "packageName", "package_name", "commodityName",
        "commodity_name", "specType", "SpecType", "instanceName", "instance_name",
        "displayName", "display_name", "ProductName", "productName", "name", "title",
        "planType", "plan_type",
    ]
    private static let usedKeys = [
        "usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits",
        "usage", "used", "usedAmount", "consumeAmount", "usedValue", "UsedValue",
        "consumedValue", "ConsumedValue",
    ]
    private static let totalKeys = [
        "totalQuota", "total_quota", "totalCredits", "totalCredit", "quota", "creditLimit",
        "creditsTotal", "monthlyTotalQuota", "amount", "totalValue", "TotalValue",
        "cycleTotalValue", "CycleTotalValue",
    ]
    private static let remainingKeys = [
        "remainingQuota", "remainQuota", "remainingCredits", "remainingCredit", "availableCredits",
        "balance", "remaining", "availableAmount", "remainAmount", "totalSurplusValue",
        "TotalSurplusValue", "surplusValue", "SurplusValue", "cycleSurplusValue", "CycleSurplusValue",
    ]
    private static let countKeys = ["totalCount", "TotalCount", "subscriptionTotalNumber", "SubscriptionTotalNumber"]
    private static let resetKeys = [
        "nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd", "billCycleEndTime",
        "expireTime", "expirationTime", "endTime", "validEndTime", "instanceEndTime", "EndTime",
        "cycleEndTime", "CycleEndTime", "nearestExpireDate", "NearestExpireDate",
    ]

    private static func throwIfError(_ root: [String: Any]) throws {
        let successResponse = bool(root["successResponse"])
        let code = findFirstString(keys: ["errorCode", "code", "status", "statusCode"], in: root)
        let message = findFirstString(keys: ["errorMsg", "message", "msg", "statusMessage"], in: root)
        if successResponse == false || findBoolValues(keys: ["Success", "success"], in: root).contains(false) {
            let combined = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
            if combined.contains("login") || combined.contains("needlogin") || combined.contains("tokenerror") {
                throw QwenCloudUsageError.loginRequired
            }
            if combined.contains("forbidden") || combined.contains("unauthorized")
                || combined.contains("notauthorised") || combined.contains("notauthorized") {
                throw QwenCloudUsageError.invalidCredentials
            }
            throw QwenCloudUsageError.apiError(message ?? code ?? "request was not successful")
        }
        if let status = findFirstInt(keys: ["statusCode", "status_code", "code"], in: root),
           status != 0, status != 200 {
            if status == 401 || status == 403 { throw QwenCloudUsageError.invalidCredentials }
            throw QwenCloudUsageError.apiError(message ?? "status code \(status)")
        }
        let combined = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
        if combined.contains("needlogin") || combined.contains("login") || combined.contains("tokenerror") {
            throw QwenCloudUsageError.loginRequired
        }
        if combined.contains("forbidden") || combined.contains("unauthorized")
            || combined.contains("notauthorised") || combined.contains("notauthorized") {
            throw QwenCloudUsageError.invalidCredentials
        }
    }

    private static func expand(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
               let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                return expand(decoded)
            }
            return value
        }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(expand) }
        if let array = value as? [Any] { return array.map(expand) }
        return value
    }

    private static func findDictionary(containing keys: [String], in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if keys.contains(where: { dictionary[$0] != nil }) { return dictionary }
            for child in dictionary.values {
                if let found = findDictionary(containing: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findDictionary(containing: keys, in: child) { return found }
            }
        }
        return nil
    }

    private static func findFirstValue(keys: [String], in value: Any) -> Any? {
        let lowered = Set(keys.map { $0.lowercased() })
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary where lowered.contains(key.lowercased()) { return child }
            for child in dictionary.values {
                if let found = findFirstValue(keys: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findFirstValue(keys: keys, in: child) { return found }
            }
        }
        return nil
    }

    private static func findFirstString(keys: [String], in value: Any) -> String? {
        for key in keys {
            if let value = findConverted(key: key, in: value, transform: string) { return value }
        }
        return nil
    }

    private static func findFirstInt(keys: [String], in value: Any) -> Int? {
        for key in keys {
            if let value = findConverted(key: key, in: value, transform: integer) { return value }
        }
        return nil
    }

    private static func findConverted<T>(
        key: String,
        in value: Any,
        transform: (Any?) -> T?
    ) -> T? {
        if let dictionary = value as? [String: Any] {
            for (candidate, child) in dictionary where candidate.caseInsensitiveCompare(key) == .orderedSame {
                if let converted = transform(child) { return converted }
            }
            for child in dictionary.values {
                if let found = findConverted(key: key, in: child, transform: transform) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findConverted(key: key, in: child, transform: transform) { return found }
            }
        }
        return nil
    }

    private static func findBoolValues(keys: [String], in value: Any) -> [Bool] {
        if let dictionary = value as? [String: Any] {
            return keys.compactMap { bool(dictionary[$0]) }
                + dictionary.values.flatMap { findBoolValues(keys: keys, in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { findBoolValues(keys: keys, in: $0) } }
        return []
    }

    private static func firstNumber(keys: [String], in dictionary: [String: Any]) -> Double? {
        keys.lazy.compactMap { number(dictionary[$0]) }.first
    }

    private static func findDate(keys: [String], in value: Any) -> Date? {
        for key in keys {
            if let found = findConverted(key: key, in: value, transform: date) { return found }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isFinite ? $0 : nil }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value),
              number >= Double(Int.min),
              number <= Double(Int.max)
        else { return nil }
        return Int(number)
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return nil }
        switch string.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard let value = number(value), value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value), number > 0 {
            return Date(timeIntervalSince1970: number >= 1_000_000_000_000 ? number / 1000 : number)
        }
        guard let string = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func trimmedBase(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        for component in header.split(separator: ";") {
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let candidate = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.caseInsensitiveCompare(name) == .orderedSame, !value.isEmpty { return String(value) }
        }
        return nil
    }

    private static func normalizedDomain(_ cookie: HTTPCookie) -> String {
        cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func cookieMatches(_ cookie: HTTPCookie, targetURL: URL) -> Bool {
        guard let host = targetURL.host?.lowercased() else { return false }
        let domain = normalizedDomain(cookie)
        guard !domain.isEmpty, host == domain || host.hasSuffix(".\(domain)") else { return false }
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = targetURL.path.isEmpty ? "/" : targetURL.path
        if cookiePath == requestPath || cookiePath == "/" { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary == requestPath.endIndex || requestPath[boundary] == "/"
    }

    private static func looksLikeLoginPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return lowered.contains("passport.alibabacloud.com")
            || lowered.contains("signin.aliyun.com")
            || lowered.contains("account.alibabacloud.com/login")
            || lowered.contains("login.qwencloud.com")
            || lowered.contains("login") && lowered.contains("password") && lowered.contains("sign in")
    }

    private static func quotaDetail(fraction: Double, total: Double?) -> String? {
        guard let total, total > 0 else { return nil }
        return "\(format(total * fraction)) / \(format(total)) credits used"
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func displayPlan(_ plan: String) -> String {
        switch plan {
        case "lite": "Lite"
        case "standard": "Standard"
        case "pro": "Pro"
        case "max": "Max"
        default: plan
        }
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    private let apiURL: URL
    private let dashboardURL: URL
    private let apiCookieHeader: String
    private let dashboardCookieHeader: String

    init(apiURL: URL, dashboardURL: URL, apiCookieHeader: String, dashboardCookieHeader: String) {
        self.apiURL = apiURL
        self.dashboardURL = dashboardURL
        self.apiCookieHeader = apiCookieHeader
        self.dashboardCookieHeader = dashboardCookieHeader
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(routedRequest(
            task: task,
            response: response,
            request: request
        ))
    }

    private func routedRequest(
        task: URLSessionTask,
        response: HTTPURLResponse,
        request: URLRequest
    ) -> URLRequest? {
        guard Self.redirectStatuses.contains(response.statusCode),
              let original = task.originalRequest,
              let source = response.url ?? original.url,
              let target = request.url,
              source.scheme?.lowercased() == "https",
              target.scheme?.lowercased() == "https",
              source.user == nil, source.password == nil,
              target.user == nil, target.password == nil else { return nil }

        let crossOrigin = !Self.sameOrigin(source, target)
        if crossOrigin {
            let method = request.httpMethod?.uppercased() ?? "GET"
            guard (method == "GET" || method == "HEAD"), request.httpBody == nil,
                  request.httpBodyStream == nil else { return nil }
        }
        var routed = crossOrigin ? Self.sanitized(request) : request
        guard routed != nil else { return nil }
        if Self.sameOrigin(target, apiURL), target.path == apiURL.path,
           original.value(forHTTPHeaderField: "Accept")?.contains("text/html") != true {
            routed?.setValue(apiCookieHeader, forHTTPHeaderField: "Cookie")
        } else if Self.sameOrigin(target, dashboardURL) {
            routed?.setValue(dashboardCookieHeader, forHTTPHeaderField: "Cookie")
        } else {
            routed = Self.sanitized(routed!)
        }
        return routed
    }

    private static func sanitized(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url else { return nil }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD", request.httpBody == nil,
              request.httpBodyStream == nil else { return nil }
        var result = URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        result.httpMethod = method
        for header in ["Accept", "Accept-Language", "User-Agent"] {
            if let value = request.value(forHTTPHeaderField: header) {
                result.setValue(value, forHTTPHeaderField: header)
            }
        }
        return result
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && normalizedPort(lhs) == normalizedPort(rhs)
    }

    private static func normalizedPort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil
    }
}
