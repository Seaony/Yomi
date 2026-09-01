import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum AlibabaTokenPlanFetcher {
    enum Region: String, CaseIterable {
        case international = "intl"
        case chinaMainland = "cn"
        case internationalPersonal = "intl-personal"
        case chinaMainlandPersonal = "cn-personal"

        var gateway: String {
            switch self {
            case .international, .internationalPersonal:
                "https://modelstudio.console.alibabacloud.com"
            case .chinaMainland, .chinaMainlandPersonal:
                "https://bailian.console.aliyun.com"
            }
        }

        var quotaGateway: String {
            switch self {
            case .international, .chinaMainland: gateway
            case .internationalPersonal: "https://bailian-singapore-cs.alibabacloud.com"
            case .chinaMainlandPersonal: "https://bailian-cs.console.aliyun.com"
            }
        }

        var dashboard: URL {
            switch self {
            case .international:
                URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan")!
            case .chinaMainland:
                URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
            case .internationalPersonal:
                URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan/personal")!
            case .chinaMainlandPersonal:
                URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!
            }
        }

        var currentRegionID: String {
            switch self {
            case .international, .internationalPersonal: "ap-southeast-1"
            case .chinaMainland, .chinaMainlandPersonal: "cn-beijing"
            }
        }

        var cliConsoleSite: String {
            switch self {
            case .international, .internationalPersonal: "international"
            case .chinaMainland, .chinaMainlandPersonal: "domestic"
            }
        }

        var productCode: String {
            switch self {
            case .international: "sfm_tokenplanteams_dp_intl"
            case .chinaMainland: "sfm_tokenplanteams_dp_cn"
            case .internationalPersonal: "sfm_tokenplansolo_public_intl"
            case .chinaMainlandPersonal: "sfm_tokenplansolo_public_cn"
            }
        }

        var isPersonal: Bool {
            self == .internationalPersonal || self == .chinaMainlandPersonal
        }

        var personalAction: String {
            switch self {
            case .international, .internationalPersonal: "IntlBroadScopeAspnGateway"
            case .chinaMainland, .chinaMainlandPersonal: "BroadScopeAspnGateway"
            }
        }

        var personalConsoleSite: String {
            switch self {
            case .international, .internationalPersonal: "MODELSTUDIO_ALBABACLOUD"
            case .chinaMainland, .chinaMainlandPersonal: "BAILIAN_ALIYUN"
            }
        }
    }

    struct CookieHeaders {
        let api: String
        let dashboard: String
    }

    private static let personalUsageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    private static let personalSubscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    private static let personalQuotaConfigAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"
    private static let cookieDomains = [
        "bailian-singapore-cs.alibabacloud.com", "bailian-cs.console.aliyun.com",
        "modelstudio.console.alibabacloud.com", "bailian.console.aliyun.com",
        "free.aliyun.com", "account.aliyun.com", "signin.aliyun.com",
        "passport.alibabacloud.com", "console.alibabacloud.com", "console.aliyun.com",
        "alibabacloud.com", "aliyun.com",
    ]

    static func fetch(
        credential: String,
        source: ProviderSource,
        region rawRegion: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let region = Region(rawValue: clean(rawRegion ?? "")) ?? .international
        if source == .command {
            return try await fetchCLI(region: region, now: now)
        }
        if source == .automatic, let usage = try? await fetchCLI(region: region, now: now) {
            return usage
        }

        let manual = clean(credential)
        let environmentCookie = clean(ProcessInfo.processInfo.environment["ALIBABA_TOKEN_PLAN_COOKIE"] ?? "")
        let headers: CookieHeaders?
        if !manual.isEmpty {
            headers = CookieHeaders(api: manual, dashboard: manual)
        } else if !environmentCookie.isEmpty {
            headers = CookieHeaders(api: environmentCookie, dashboard: environmentCookie)
        } else {
            headers = automaticCookieHeaders(region: region)
        }
        guard let headers else { throw UsageCollectionError.missingCredential }
        if region.isPersonal {
            return try await fetchPersonal(headers: headers, region: region, session: session, now: now)
        }
        return try await fetchTeam(headers: headers, region: region, session: session, now: now)
    }

    static func parseCLI(data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageCollectionError.unreadableResponse
        }
        let fiveHour = ratio(root["per5HourPercentage"])
        let weekly = ratio(root["per1WeekPercentage"])
        guard fiveHour != nil || weekly != nil else { throw UsageCollectionError.unreadableResponse }
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(UsageWindow(
                id: "alibaba-token-plan-5h", label: "5-hour", usedFraction: fiveHour,
                resetsAt: millisecondsDate(root["per5HourResetTime"]), detail: nil
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "alibaba-token-plan-weekly", label: "7-day", usedFraction: weekly,
                resetsAt: millisecondsDate(root["per1WeekResetTime"]), detail: nil
            ))
        }
        return usage(windows: windows, plan: "Token Plan", now: now)
    }

    static func parseTeam(data: Data, now: Date = Date()) throws -> ProviderUsage {
        let root = try rootObject(data)
        try throwIfError(root)
        let quotaKeys = usedKeys + totalKeys + remainingKeys
        let summary = findDictionary(containing: quotaKeys, in: root)
            ?? findDictionary(containing: countKeys, in: root)
            ?? root
        let total = double(summary, totalKeys)
        let remaining = double(summary, remainingKeys)
        let used = double(summary, usedKeys) ?? total.flatMap { value in
            remaining.map { max(0, value - $0) }
        }
        let count = double(summary, countKeys)
        let plan = string(summary, planKeys) ?? findString(keys: planKeys, in: root)
            ?? ((count ?? 0) > 0 || total != nil ? "Token Plan" : nil)
        guard plan != nil || total != nil || used != nil || remaining != nil || count != nil else {
            throw UsageCollectionError.unreadableResponse
        }

        var windows: [UsageWindow] = []
        if let total, total > 0, let used = used ?? remaining.map({ total - $0 }) {
            let normalized = max(0, min(used, total))
            windows.append(UsageWindow(
                id: "alibaba-token-plan-monthly", label: "Credits",
                usedFraction: normalized / total,
                resetsAt: date(summary, resetKeys) ?? findDate(keys: resetKeys, in: root),
                detail: "\(format(normalized)) / \(format(total)) credits used"
            ))
        }
        return usage(windows: windows, plan: plan, now: now)
    }

    static func parsePersonal(
        usageData: Data,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let root = try rootObject(usageData)
        try throwIfError(root)
        guard let frame = findDictionary(
            containing: ["per5HourPercentage", "per1WeekPercentage"], in: root
        ) else { throw UsageCollectionError.unreadableResponse }
        let fiveHour = ratio(frame["per5HourPercentage"])
        let weekly = ratio(frame["per1WeekPercentage"])
        guard fiveHour != nil || weekly != nil else { throw UsageCollectionError.unreadableResponse }

        let planCode = subscriptionData.flatMap { data -> String? in
            guard let root = try? rootObject(data) else { return nil }
            return findString(keys: ["specCode", "spec_code", "planName", "plan_name"], in: root)?.lowercased()
        }
        let totals = quotaConfigData.flatMap { data -> (Double?, Double?)? in
            guard let planCode, let root = try? rootObject(data),
                  let planValue = findValue(key: planCode, in: root),
                  let quota = planValue as? [String: Any]
            else { return nil }
            return (number(quota["five_hour"] ?? quota["fiveHour"]), number(quota["weekly"]))
        }
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(UsageWindow(
                id: "alibaba-token-plan-5h", label: "5-hour", usedFraction: fiveHour,
                resetsAt: parsedDate(frame["per5HourResetTime"]),
                detail: quotaDetail(fraction: fiveHour, total: totals?.0)
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "alibaba-token-plan-weekly", label: "7-day", usedFraction: weekly,
                resetsAt: parsedDate(frame["per1WeekResetTime"]),
                detail: quotaDetail(fraction: weekly, total: totals?.1)
            ))
        }
        return usage(windows: windows, plan: planCode.map(displayPlan) ?? "Personal", now: now)
    }

    static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func cliArguments(region: Region) -> [String] {
        [
            "usage", "token-plan", "--console-region", region.currentRegionID,
            "--console-site", region.cliConsoleSite, "--output", "json",
        ]
    }

    static func extractSECToken(_ html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"SEC_TOKEN['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)
                  ), let range = Range(match.range(at: 1), in: html)
            else { continue }
            let value = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    private static func fetchCLI(region: Region, now: Date) async throws -> ProviderUsage {
        try await Task.detached(priority: .utility) {
            let environment = ProcessInfo.processInfo.environment
            let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            guard let binary = path.split(separator: ":", omittingEmptySubsequences: false)
                .map({ $0.isEmpty ? "." : String($0) })
                .map({ URL(fileURLWithPath: $0).appending(path: "bl").path })
                .first(where: FileManager.default.isExecutableFile(atPath:))
            else { throw UsageCollectionError.missingCredential }

            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = cliArguments(region: region)
            let allowed = Set([
                "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            ])
            process.environment = environment.filter { allowed.contains($0.key) }
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            let outputTask = Task.detached {
                output.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errors.fileHandleForReading.readDataToEndOfFile()
            }
            let data = await outputTask.value
            let errorData = await errorTask.value
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? "bl"
                throw UsageCollectionError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return try parseCLI(data: data, now: now)
        }.value
    }

    private static func fetchTeam(
        headers: CookieHeaders, region: Region, session: URLSession, now: Date
    ) async throws -> ProviderUsage {
        let secToken = await resolveSECToken(headers: headers, region: region, session: session)
        var components = URLComponents(string: quotaBase(region: region))!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: "GetSubscriptionSummary"),
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "_tag", value: ""),
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: ["ProductCode": region.productCode])
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "action", value: "GetSubscriptionSummary"),
            URLQueryItem(name: "params", value: String(decoding: paramsData, as: UTF8.self)),
            URLQueryItem(name: "region", value: region.currentRegionID),
        ] + (secToken.map { [URLQueryItem(name: "sec_token", value: $0)] } ?? [])
        let data = try await post(
            url: components.url!, body: Data((body.percentEncodedQuery ?? "").utf8),
            cookie: headers.api, region: region, session: session
        )
        return try parseTeam(data: data, now: now)
    }

    private static func fetchPersonal(
        headers: CookieHeaders, region: Region, session: URLSession, now: Date
    ) async throws -> ProviderUsage {
        let secToken = await resolveSECToken(headers: headers, region: region, session: session)
        let subscription = try? await personalRequest(
            api: personalSubscriptionAPI, parameters: ["commodityCode": region.productCode],
            secToken: secToken, cookie: headers.api, region: region, session: session
        )
        let quota = try? await personalRequest(
            api: personalQuotaConfigAPI, parameters: [:], secToken: secToken,
            cookie: headers.api, region: region, session: session
        )
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            let data = try await personalRequest(
                api: personalUsageAPI, parameters: [:], secToken: secToken,
                cookie: headers.api, region: region, session: session
            )
            if let parsed = try? parsePersonal(
                usageData: data, subscriptionData: subscription,
                quotaConfigData: quota, now: now
            ) { return parsed }
        }
        throw UsageCollectionError.unreadableResponse
    }

    private static func personalRequest(
        api: String, parameters: [String: String], secToken: String?, cookie: String,
        region: Region, session: URLSession
    ) async throws -> Data {
        var components = URLComponents(string: quotaBase(region: region))!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: region.personalAction),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(), "feURL": region.dashboard.absoluteString,
            "protocol": "V2", "console": "ONE_CONSOLE", "productCode": "p_efm",
            "switchUserType": 3, "domain": region.dashboard.host ?? "",
            "consoleSite": region.personalConsoleSite, "userNickName": "",
            "userPrincipalName": "", "xsp_lang": "en-US",
        ]
        if let anonymous = cookieValue("cna", cookie) { cornerstone["X-Anonymous-Id"] = anonymous }
        var dataParameters = parameters as [String: Any]
        dataParameters["cornerstoneParam"] = cornerstone
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": dataParameters]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "action", value: region.personalAction),
            URLQueryItem(name: "region", value: region.currentRegionID),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "params", value: String(decoding: paramsData, as: UTF8.self)),
        ] + (secToken.map { [URLQueryItem(name: "sec_token", value: $0)] } ?? [])
        return try await post(
            url: components.url!, body: Data((body.percentEncodedQuery ?? "").utf8),
            cookie: cookie, region: region, session: session
        )
    }

    private static func post(
        url: URL, body: Data, cookie: String, region: Region, session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gateway, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboard.absoluteString, forHTTPHeaderField: "Referer")
        if let csrf = cookieValue("login_aliyunid_csrf", cookie) ?? cookieValue("csrf", cookie) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return data
    }

    private static func resolveSECToken(
        headers: CookieHeaders, region: Region, session: URLSession
    ) async -> String? {
        var request = URLRequest(url: region.dashboard)
        request.timeoutInterval = 10
        request.setValue(headers.dashboard, forHTTPHeaderField: "Cookie")
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://\(region.dashboard.host ?? "")/", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let (data, response) = try? await session.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let html = String(data: data, encoding: .utf8), let token = extractSECToken(html) {
            return token
        }

        let userInfo = URL(string: region.gateway)!.appending(path: "tool/user/info.json")
        var infoRequest = URLRequest(url: userInfo)
        infoRequest.timeoutInterval = 10
        infoRequest.setValue(headers.dashboard, forHTTPHeaderField: "Cookie")
        infoRequest.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        infoRequest.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await session.data(for: infoRequest),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let root = try? rootObject(data),
           let token = findString(keys: ["secToken", "sec_token"], in: root) { return token }
        return cookieValue("sec_token", headers.dashboard) ?? cookieValue("sec_token", headers.api)
    }

    private static func automaticCookieHeaders(region: Region) -> CookieHeaders? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        let browsers: [Browser] = [.chrome, .chromeBeta, .brave, .edge, .arc, .firefox, .safari]
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let names = Set(cookies.map(\.name))
                guard names.contains("login_aliyunid_ticket"),
                      names.contains("login_aliyunid_pk") || names.contains("login_current_pk")
                        || names.contains("login_aliyunid") else { continue }
                let apiURL = quotaURL(region: region)
                let api = cookieHeader(cookies, url: apiURL)
                let dashboard = cookieHeader(cookies, url: region.dashboard)
                if let api, let dashboard { return CookieHeaders(api: api, dashboard: dashboard) }
            }
        }
        return nil
    }

    private static func quotaBase(region: Region) -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = URL(string: clean(environment["ALIBABA_TOKEN_PLAN_QUOTA_URL"] ?? "")),
           override.scheme?.lowercased() == "https" {
            var components = URLComponents(url: override, resolvingAgainstBaseURL: false)!
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.url?.absoluteString ?? region.quotaGateway
        }
        if let override = URL(string: clean(environment["ALIBABA_TOKEN_PLAN_HOST"] ?? "")),
           override.scheme?.lowercased() == "https" { return override.absoluteString }
        return region.quotaGateway
    }

    private static func quotaURL(region: Region) -> URL {
        URL(string: quotaBase(region: region))!.appending(path: "data/api.json")
    }

    private static func cookieHeader(_ cookies: [HTTPCookie], url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let pairs = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return domainMatches && path.hasPrefix(cookiePath) && (!cookie.isSecure || url.scheme == "https")
        }.map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    private static func usage(windows: [UsageWindow], plan: String?, now: Date) -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "alibabatokenplan"), state: .ready, windows: windows,
            balance: nil, plan: plan, updatedAt: now, message: nil
        )
    }

    private static func rootObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = expand(object) as? [String: Any]
        else { throw UsageCollectionError.unreadableResponse }
        return root
    }

    private static func throwIfError(_ root: [String: Any]) throws {
        if boolean(root["successResponse"]) == false { throw UsageCollectionError.unreadableResponse }
        if let status = findInt(keys: ["statusCode", "status_code", "code"], in: root),
           status != 0, status != 200 { throw UsageCollectionError.requestFailed(status) }
        if findBooleans(keys: ["Success", "success"], in: root).contains(false) {
            throw UsageCollectionError.unreadableResponse
        }
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
        "remainingQuota", "remainQuota", "remainingCredits", "remainingCredit",
        "availableCredits", "balance", "remaining", "availableAmount", "remainAmount",
        "totalSurplusValue", "TotalSurplusValue", "surplusValue", "SurplusValue",
        "cycleSurplusValue", "CycleSurplusValue",
    ]
    private static let countKeys = [
        "totalCount", "TotalCount", "subscriptionTotalNumber", "SubscriptionTotalNumber",
    ]
    private static let resetKeys = [
        "nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd", "billCycleEndTime",
        "expireTime", "expirationTime", "endTime", "validEndTime", "instanceEndTime", "EndTime",
        "cycleEndTime", "CycleEndTime", "nearestExpireDate", "NearestExpireDate",
    ]

    private static func expand(_ value: Any) -> Any {
        if let string = value as? String, let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) { return expand(decoded) }
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
            for child in array { if let found = findDictionary(containing: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findString(keys: [String], in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let direct = string(dictionary, keys) { return direct }
            for child in dictionary.values { if let found = findString(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findString(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findDate(keys: [String], in value: Any) -> Date? {
        if let dictionary = value as? [String: Any] {
            if let direct = date(dictionary, keys) { return direct }
            for child in dictionary.values { if let found = findDate(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findDate(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findInt(keys: [String], in value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let value = number(dictionary[key]),
                   value >= Double(Int.min),
                   value <= Double(Int.max) {
                    return Int(value)
                }
            }
            for child in dictionary.values { if let found = findInt(keys: keys, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findInt(keys: keys, in: child) { return found } }
        }
        return nil
    }

    private static func findBooleans(keys: [String], in value: Any) -> [Bool] {
        if let dictionary = value as? [String: Any] {
            return keys.compactMap { boolean(dictionary[$0]) }
                + dictionary.values.flatMap { findBooleans(keys: keys, in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { findBooleans(keys: keys, in: $0) } }
        return []
    }

    private static func findValue(key: String, in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let found = dictionary[key] { return found }
            for child in dictionary.values { if let found = findValue(key: key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findValue(key: key, in: child) { return found } }
        }
        return nil
    }

    private static func double(_ dictionary: [String: Any], _ keys: [String]) -> Double? {
        keys.lazy.compactMap { number(dictionary[$0]) }.first
    }

    private static func string(_ dictionary: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { value in
            guard let text = dictionary[value] as? String else { return nil }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }.first
    }

    private static func date(_ dictionary: [String: Any], _ keys: [String]) -> Date? {
        keys.lazy.compactMap { parsedDate(dictionary[$0]) }.first
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: ""))
                .flatMap { $0.isFinite ? $0 : nil }
        }
        return nil
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard let value = number(value), (0...1).contains(value) else { return nil }
        return value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        guard let text = value as? String else { return nil }
        switch text.lowercased() {
        case "true", "1", "yes", "active", "valid", "normal": return true
        case "false", "0", "no", "inactive", "invalid", "expired": return false
        default: return nil
        }
    }

    private static func parsedDate(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let number = number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }

    private static func cookieValue(_ name: String, _ header: String) -> String? {
        for segment in header.split(separator: ";") {
            let parts = segment.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, parts[0] == name, !parts[1].isEmpty { return parts[1] }
        }
        return nil
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

    private static func displayPlan(_ code: String) -> String {
        switch code {
        case "lite": "Lite"
        case "standard": "Standard"
        case "pro": "Pro"
        case "max": "Max"
        default: code
        }
    }
}
