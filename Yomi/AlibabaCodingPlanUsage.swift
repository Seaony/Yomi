import Foundation
import SweetCookieKit

enum AlibabaCodingPlanFetcher {
    enum Region: String {
        case international = "intl"
        case chinaMainland = "cn"

        var gateway: String {
            self == .international
                ? "https://modelstudio.console.alibabacloud.com"
                : "https://bailian.console.aliyun.com"
        }

        var rpcGateway: String {
            self == .international
                ? "https://bailian-singapore-cs.alibabacloud.com"
                : "https://bailian-cs.console.aliyun.com"
        }

        var dashboard: URL {
            URL(string: self == .international
                ? "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan"
                : "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }

        var referer: URL {
            URL(string: self == .international
                ? "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan"
                : "https://bailian.console.aliyun.com/cn-beijing/?tab=model")!
        }

        var currentRegionID: String { self == .international ? "ap-southeast-1" : "cn-beijing" }
        var commodityCode: String { self == .international ? "sfm_codingplan_public_intl" : "sfm_codingplan_public_cn" }
        var consoleDomain: String {
            self == .international ? "modelstudio.console.alibabacloud.com" : "bailian.console.aliyun.com"
        }
        var consoleSite: String { self == .international ? "MODELSTUDIO_ALIBABACLOUD" : "BAILIAN_ALIYUN" }
        var rpcAction: String { self == .international ? "IntlBroadScopeAspnGateway" : "BroadScopeAspnGateway" }
    }

    private static let quotaAction = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"
    private static let cookieDomains = [
        "bailian-singapore-cs.alibabacloud.com", "bailian-cs.console.aliyun.com",
        "bailian-beijing-cs.aliyuncs.com", "modelstudio.console.alibabacloud.com",
        "bailian.console.aliyun.com", "free.aliyun.com", "account.aliyun.com",
        "signin.aliyun.com", "passport.alibabacloud.com", "console.alibabacloud.com",
        "console.aliyun.com", "alibabacloud.com", "aliyun.com",
    ]

    static func fetch(
        credential: String,
        region rawRegion: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let region = Region(rawValue: rawRegion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            ?? .international
        let cleaned = clean(credential)
        if cleaned.contains("=") {
            return try await fetchCookie(cookie: cleaned, region: region, session: session, now: now)
        }
        if !cleaned.isEmpty {
            return try await fetchAPI(key: cleaned, region: region, session: session, now: now)
        }
        if let cookie = automaticCookie() {
            return try await fetchCookie(cookie: cookie, region: region, session: session, now: now)
        }
        throw UsageCollectionError.missingCredential
    }

    static func fetchAPI(
        key: String,
        region: Region,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        do {
            return try await fetchAPIOnce(key: key, region: region, session: session, now: now)
        } catch {
            guard region == .international else { throw error }
            return try await fetchAPIOnce(key: key, region: .chinaMainland, session: session, now: now)
        }
    }

    static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = expand(object) as? [String: Any]
        else { throw UsageCollectionError.unreadableResponse }
        if let status = findInt(keys: ["statusCode", "status_code", "code"], in: root),
           status != 0, status != 200 { throw UsageCollectionError.requestFailed(status) }

        let instances = findArray(keys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: root)?
            .compactMap { $0 as? [String: Any] } ?? []
        let selected = activeInstance(instances, now: now)
        let selectedIsProven = selected.map { activeScore($0, now: now) > 0 } ?? false
        let quota: [String: Any]?
        if instances.count > 1, selectedIsProven {
            quota = selected.flatMap(findQuota)
        } else {
            quota = selected.flatMap(findQuota) ?? findQuota(root)
        }
        let plan = selected.flatMap(planName) ?? planName(root)
        guard let quota else {
            guard selectedIsProven, let plan else { throw UsageCollectionError.unreadableResponse }
            return ProviderUsage(
                id: ProviderID(rawValue: "alibaba"), state: .ready, windows: [],
                balance: nil, plan: normalizedPlan(plan), updatedAt: now, message: nil
            )
        }

        var windows: [UsageWindow] = []
        appendWindow(
            to: &windows, id: "alibaba-5h", label: "5-hour",
            used: int(quota, ["per5HourUsedQuota", "perFiveHourUsedQuota"]),
            total: int(quota, ["per5HourTotalQuota", "perFiveHourTotalQuota"]),
            reset: date(quota, ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"]),
            now: now, normalizeFiveHourReset: true
        )
        appendWindow(
            to: &windows, id: "alibaba-weekly", label: "Weekly",
            used: int(quota, ["perWeekUsedQuota"]), total: int(quota, ["perWeekTotalQuota"]),
            reset: date(quota, ["perWeekQuotaNextRefreshTime"]), now: now
        )
        appendWindow(
            to: &windows, id: "alibaba-monthly", label: "Monthly",
            used: int(quota, ["perBillMonthUsedQuota", "perMonthUsedQuota"]),
            total: int(quota, ["perBillMonthTotalQuota", "perMonthTotalQuota"]),
            reset: date(quota, ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"]),
            now: now
        )
        guard !windows.isEmpty || (selectedIsProven && plan != nil) else {
            throw UsageCollectionError.unreadableResponse
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "alibaba"), state: .ready, windows: windows,
            balance: nil, plan: plan.map(normalizedPlan), updatedAt: now, message: nil
        )
    }

    static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func fetchAPIOnce(
        key: String, region: Region, session: URLSession, now: Date
    ) async throws -> ProviderUsage {
        var components = URLComponents(string: region.gateway)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: quotaAction),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: region.currentRegionID),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "queryCodingPlanInstanceInfoRequest": ["commodityCode": region.commodityCode],
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(key, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gateway, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboard.absoluteString, forHTTPHeaderField: "Referer")
        return try await execute(request, session: session, now: now)
    }

    private static func fetchCookie(
        cookie: String, region: Region, session: URLSession, now: Date
    ) async throws -> ProviderUsage {
        let secToken = try await resolveSECToken(cookie: cookie, region: region, session: session)
        var components = URLComponents(string: region.rpcGateway)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: region.rpcAction),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: quotaAction),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        let traceID = UUID().uuidString.lowercased()
        var cornerstone: [String: Any] = [
            "feTraceId": traceID, "feURL": region.dashboard.absoluteString,
            "protocol": "V2", "console": "ONE_CONSOLE", "productCode": "p_efm",
            "domain": region.consoleDomain, "consoleSite": region.consoleSite,
            "userNickName": "", "userPrincipalName": "", "xsp_lang": "en-US",
        ]
        if let anonymous = cookieValue("cna", cookie) { cornerstone["X-Anonymous-Id"] = anonymous }
        let params: [String: Any] = [
            "Api": quotaAction, "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": region.commodityCode, "onlyLatestOne": true,
                ],
                "cornerstoneParam": cornerstone,
            ],
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "params", value: String(decoding: paramsData, as: UTF8.self)),
            URLQueryItem(name: "region", value: region.currentRegionID),
            URLQueryItem(name: "sec_token", value: secToken),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let csrf = cookieValue("login_aliyunid_csrf", cookie) ?? cookieValue("csrf", cookie) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gateway, forHTTPHeaderField: "Origin")
        request.setValue(region.referer.absoluteString, forHTTPHeaderField: "Referer")
        return try await execute(request, session: session, now: now)
    }

    private static func execute(_ request: URLRequest, session: URLSession, now: Date) async throws -> ProviderUsage {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return try parse(data: data, now: now)
    }

    private static func resolveSECToken(cookie: String, region: Region, session: URLSession) async throws -> String {
        if let html = try? await textRequest(
            url: region.dashboard, cookie: cookie, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            session: session
        ), let token = secToken(in: html) { return token }
        let userInfo = URL(string: region.gateway)!.appending(path: "tool/user/info.json")
        if let text = try? await textRequest(
            url: userInfo, cookie: cookie, accept: "application/json, text/plain, */*", session: session
        ), let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let token = findString(keys: ["secToken", "sec_token"], in: expand(object)) { return token }
        if let token = cookieValue("sec_token", cookie) { return token }
        throw UsageCollectionError.missingCredential
    }

    private static func textRequest(
        url: URL, cookie: String, accept: String, session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { throw UsageCollectionError.unreadableResponse }
        return text
    }

    private static func automaticCookie() -> String? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        let browsers: [Browser] = [.chrome, .chromeBeta, .brave, .edge, .arc, .firefox, .safari]
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let names = Set(cookies.map(\.name))
                let authenticated = names.contains("login_aliyunid_ticket")
                    && (names.contains("login_aliyunid_pk") || names.contains("login_current_pk")
                        || names.contains("login_aliyunid"))
                guard authenticated else { continue }
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return nil
    }

    private static func appendWindow(
        to windows: inout [UsageWindow], id: String, label: String,
        used: Int?, total: Int?, reset: Date?, now: Date,
        normalizeFiveHourReset: Bool = false
    ) {
        guard let used, let total, total > 0 else { return }
        var normalizedReset = reset
        if normalizeFiveHourReset, let reset, reset.timeIntervalSince(now) < 60 {
            let shifted = reset.addingTimeInterval(5 * 60 * 60)
            normalizedReset = shifted.timeIntervalSince(now) >= 60 ? shifted : now.addingTimeInterval(5 * 60 * 60)
        }
        windows.append(UsageWindow(
            id: id, label: label,
            usedFraction: Double(max(0, min(used, total))) / Double(total),
            resetsAt: normalizedReset, detail: "\(used) / \(total) used"
        ))
    }

    private static func activeInstance(_ instances: [[String: Any]], now: Date) -> [String: Any]? {
        guard !instances.isEmpty else { return nil }
        let ranked = instances.map { ($0, activeScore($0, now: now)) }
        let best = ranked.max { $0.1 < $1.1 }
        return (best?.1 ?? 0) > 0 ? best?.0 : instances.first
    }

    private static func activeScore(_ value: [String: Any], now: Date) -> Int {
        if let status = string(value, ["status", "instanceStatus"])?.uppercased() {
            if ["VALID", "ACTIVE"].contains(status) { return 3 }
            if ["EXPIRED", "INVALID", "INACTIVE", "DISABLED", "TERMINATED", "STOPPED"].contains(status) { return -1 }
        }
        if let active = boolean(value, ["isActive", "active"]) { return active ? 3 : -1 }
        if let expiry = date(value, ["endTime", "periodEndTime", "expireTime", "expirationTime"]), expiry > now {
            return 1
        }
        return 0
    }

    private static func findQuota(_ value: [String: Any]) -> [String: Any]? {
        findDictionary(keys: ["codingPlanQuotaInfo", "coding_plan_quota_info"], in: value)
            ?? findDictionary(containing: [
                "per5HourUsedQuota", "per5HourTotalQuota", "perWeekUsedQuota",
                "perWeekTotalQuota", "perBillMonthUsedQuota", "perBillMonthTotalQuota",
            ], in: value)
    }

    private static func planName(_ value: [String: Any]) -> String? {
        if let instances = findArray(keys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: value) {
            for item in instances {
                if let item = item as? [String: Any],
                   let name = string(item, ["planName", "plan_name", "instanceName", "instance_name", "packageName", "package_name"]) {
                    return name
                }
            }
        }
        return findString(keys: ["planName", "plan_name", "packageName", "package_name"], in: value)
    }

    private static func normalizedPlan(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("lite") { return "Lite" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("starter") { return "Starter" }
        if lower.contains("enterprise") { return "Enterprise" }
        return raw
    }

    private static func expand(_ value: Any) -> Any {
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) { return expand(decoded) }
        if let dict = value as? [String: Any] {
            return dict.mapValues(expand)
        }
        if let array = value as? [Any] { return array.map(expand) }
        return value
    }

    private static func findDictionary(keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            for key in keys { if let found = dict[key] as? [String: Any] { return found } }
            for child in dict.values { if let found = findDictionary(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findDictionary(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findDictionary(containing keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for child in dict.values { if let found = findDictionary(containing: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findDictionary(containing: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findArray(keys: [String], in value: Any) -> [Any]? {
        if let dict = value as? [String: Any] {
            for key in keys { if let array = dict[key] as? [Any] { return array } }
            for child in dict.values { if let found = findArray(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findArray(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findString(keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys { if let string = parseString(dict[key]) { return string } }
            for child in dict.values { if let found = findString(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findString(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findInt(keys: [String], in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for key in keys { if let integer = parseInt(dict[key]) { return integer } }
            for child in dict.values { if let found = findInt(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findInt(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func int(_ dict: [String: Any], _ keys: [String]) -> Int? {
        keys.lazy.compactMap { parseInt(dict[$0]) }.first
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { parseString(dict[$0]) }.first
    }

    private static func boolean(_ dict: [String: Any], _ keys: [String]) -> Bool? {
        keys.lazy.compactMap { key in
            if let bool = dict[key] as? Bool { return bool }
            if let number = dict[key] as? NSNumber { return number.boolValue }
            guard let text = parseString(dict[key])?.lowercased() else { return nil }
            if ["true", "1", "yes", "active", "valid"].contains(text) { return true }
            if ["false", "0", "no", "inactive", "invalid", "expired"].contains(text) { return false }
            return nil
        }.first
    }

    private static func date(_ dict: [String: Any], _ keys: [String]) -> Date? {
        keys.lazy.compactMap { parseDate(dict[$0]) }.first
    }

    private static func parseInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = parseString(value) { return Int(text) }
        return nil
    }

    private static func parseString(_ value: Any?) -> String? {
        if let string = value as? String {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = parseString(value) else { return nil }
        if let raw = Double(text) { return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw) }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func secToken(in html: String) -> String? {
        let patterns = [
            #"SEC_TOKEN\s*:\s*\"([^\"]+)\""#, #"SEC_TOKEN\s*:\s*'([^']+)'"#,
            #"secToken\s*:\s*\"([^\"]+)\""#, #"sec_token\s*:\s*\"([^\"]+)\""#,
            #"sec_token\s*:\s*'([^']+)'"#, #"\"SEC_TOKEN\"\s*:\s*\"([^\"]+)\""#,
            #"\"sec_token\"\s*:\s*\"([^\"]+)\""#,
        ]
        return patterns.lazy.compactMap { capture($0, html) }.first
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func cookieValue(_ name: String, _ header: String) -> String? {
        for segment in header.split(separator: ";") {
            let pair = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            if pair[..<separator] == name {
                let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }
}
