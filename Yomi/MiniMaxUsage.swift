import Foundation
import SweetCookieKit

nonisolated enum MiniMaxRegion: String, Sendable {
    case global
    case chinaMainland = "cn"

    var platformHost: String {
        switch self {
        case .global: "platform.minimax.io"
        case .chinaMainland: "platform.minimaxi.com"
        }
    }

    var webHost: String {
        switch self {
        case .global: "www.minimax.io"
        case .chinaMainland: "www.minimaxi.com"
        }
    }

    var apiHost: String {
        switch self {
        case .global: "api.minimax.io"
        case .chinaMainland: "api.minimaxi.com"
        }
    }
}

nonisolated enum MiniMaxUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case invalidEndpoint(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 MiniMax 凭据。请添加 Coding Plan API Key，或登录 MiniMax 后使用浏览器会话。",
                "Missing MiniMax credentials. Add a Coding Plan API key or use a signed-in browser session."
            )
        case .invalidCredentials:
            AppLocalization.text("MiniMax 凭据无效或已过期。", "MiniMax credentials are invalid or expired.")
        case let .invalidEndpoint(key):
            AppLocalization.text("MiniMax 接口配置无效：\(key)", "Invalid MiniMax endpoint override: \(key)")
        case let .apiError(message):
            AppLocalization.text("MiniMax 接口错误：\(message)", "MiniMax API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 MiniMax 用量：\(message)", "Failed to parse MiniMax usage: \(message)")
        }
    }
}

nonisolated enum MiniMaxUsageFetcher {
    struct Credential: Sendable, Equatable {
        let cookie: String?
        let bearerToken: String?
        let groupID: String?
        let apiToken: String?
    }

    struct Quota: Sendable, Equatable {
        let service: String
        let label: String
        let usedFraction: Double
        let used: Int
        let limit: Int
        let unlimited: Bool
        let resetsAt: Date?
        let detail: String
        let weekly: Bool
    }

    struct Snapshot: Sendable {
        var plan: String?
        var quotas: [Quota]
        var pointsBalance: Double?
        var todayTokens: Int64?
        var last30DaysTokens: Int64?
        var todayCash: Double?
        var last30DaysCash: Double?
        var subscriptionExpiresAt: Date?
        var subscriptionRenewsAt: Date?
        var billingDetails: [UsageDetail]
        let updatedAt: Date

        func toProviderUsage() -> ProviderUsage {
            let ordered = quotas.enumerated().sorted { lhs, rhs in
                let left = Self.rank(lhs.element, index: lhs.offset)
                let right = Self.rank(rhs.element, index: rhs.offset)
                return left < right
            }.map(\.element)
            let windows = ordered.map { quota in
                UsageWindow(
                    id: "minimax-\(Self.slug(quota.service))-\(quota.weekly ? "weekly" : Self.slug(quota.label))",
                    label: quota.label,
                    usedFraction: quota.usedFraction,
                    resetsAt: quota.resetsAt,
                    detail: quota.detail
                )
            }
            let providerCost: ProviderCostSummary? = if let pointsBalance,
                                                        pointsBalance.isFinite,
                                                        pointsBalance >= 0 {
                ProviderCostSummary(
                    used: pointsBalance,
                    limit: 0,
                    currencyCode: "Points",
                    period: "MiniMax points balance",
                    balance: pointsBalance
                )
            } else {
                nil
            }
            let pointsText = pointsBalance.flatMap { value in
                value.isFinite ? "\(Self.number(value)) points" : nil
            }
            return ProviderUsage(
                id: ProviderID(rawValue: "minimax"),
                state: .ready,
                windows: windows,
                balance: pointsText,
                plan: plan,
                today: todayTokens.map { DailyTokenUsage(tokens: $0, valueUSD: nil) },
                last30Days: last30DaysTokens.map { DailyTokenUsage(tokens: $0, valueUSD: nil) },
                providerCost: providerCost,
                details: billingDetails,
                updatedAt: updatedAt,
                message: nil
            )
        }

        private static func rank(_ quota: Quota, index: Int) -> (Int, Int, Int) {
            let normalized = quota.service.lowercased()
            let isText = normalized == "general" || normalized.contains("text generation")
            return (isText ? 0 : 1, quota.weekly ? 1 : 0, index)
        }

        private static func slug(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        }

        private static func number(_ value: Double) -> String {
            guard value.isFinite else { return "—" }
            if value == value.rounded(), value >= Double(Int.min), value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(format: "%.2f", value)
        }

    }

    private struct BillingRecord {
        let date: Date
        let tokens: Int64
        let cash: Double?
    }

    private static let timeout: TimeInterval = 15
    private static let cookieDomains = [
        "platform.minimax.io", "openplatform.minimax.io", "minimax.io",
        "platform.minimaxi.com", "openplatform.minimaxi.com", "minimaxi.com",
    ]

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        region rawRegion: String?,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        let region = region(from: rawRegion)
        let configured = credential(from: rawCredential)
        let environmentAPIKey = apiToken(environment: environment)

        if source == .token {
            guard let token = configured.apiToken ?? environmentAPIKey else {
                throw MiniMaxUsageError.missingCredentials
            }
            guard apiKeyKind(token) != .standard else {
                throw MiniMaxUsageError.missingCredentials
            }
            return try await fetchAPI(token: token, region: region, session: session, now: now).toProviderUsage()
        }

        if source == .cookie {
            guard let cookie = configured.cookie else { throw MiniMaxUsageError.missingCredentials }
            return try await fetchWeb(
                cookie: cookie,
                bearer: configured.bearerToken,
                groupID: configured.groupID,
                region: region,
                session: session,
                now: now,
                environment: environment
            ).toProviderUsage()
        }

        if let token = configured.apiToken ?? environmentAPIKey,
           apiKeyKind(token) != .standard {
            do {
                return try await fetchAPI(token: token, region: region, session: session, now: now).toProviderUsage()
            } catch MiniMaxUsageError.invalidCredentials {
                // Continue with browser sessions so an expired key does not hide a valid signed-in account.
            }
        }

        var webCredentials: [Credential] = []
        if configured.cookie != nil { webCredentials.append(configured) }
        if let environmentCookie = cookieValue(environment: environment) {
            webCredentials.append(credential(from: environmentCookie))
        }
        webCredentials += automaticCredentials()
        var lastError: Error?
        for item in deduplicated(webCredentials) {
            guard let cookie = item.cookie else { continue }
            do {
                return try await fetchWeb(
                    cookie: cookie,
                    bearer: item.bearerToken,
                    groupID: item.groupID,
                    region: region,
                    session: session,
                    now: now,
                    environment: environment
                ).toProviderUsage()
            } catch MiniMaxUsageError.invalidCredentials {
                lastError = MiniMaxUsageError.invalidCredentials
            } catch MiniMaxUsageError.parseFailed {
                lastError = MiniMaxUsageError.parseFailed("浏览器会话未返回可用额度")
            }
        }
        if let lastError { throw lastError }

        if let token = configured.apiToken ?? environmentAPIKey, apiKeyKind(token) != .standard {
            return try await fetchAPI(token: token, region: region, session: session, now: now).toProviderUsage()
        }
        throw MiniMaxUsageError.missingCredentials
    }

    static func fetchAPI(
        token: String,
        region: MiniMaxRegion,
        session: URLSession,
        now: Date = Date()
    ) async throws -> Snapshot {
        let cleaned = clean(token)
        guard !cleaned.isEmpty else { throw MiniMaxUsageError.missingCredentials }
        if region == .chinaMainland {
            return try await fetchAPIOnce(token: cleaned, region: region, session: session, now: now)
        }
        do {
            return try await fetchAPIOnce(token: cleaned, region: .global, session: session, now: now)
        } catch MiniMaxUsageError.invalidCredentials {
            do {
                return try await fetchAPIOnce(token: cleaned, region: .chinaMainland, session: session, now: now)
            } catch {
                throw MiniMaxUsageError.invalidCredentials
            }
        }
    }

    static func fetchAPIOnce(
        token: String,
        region: MiniMaxRegion,
        session: URLSession,
        now: Date
    ) async throws -> Snapshot {
        let urls = [
            URL(string: "https://\(region.apiHost)/v1/token_plan/remains")!,
            URL(string: "https://\(region.apiHost)/v1/api/openplatform/coding_plan/remains")!,
        ]
        var officialCredentialFailure = false
        var lastError: Error?
        for (index, url) in urls.enumerated() {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("CodexBar", forHTTPHeaderField: "MM-API-Source")
            do {
                let data = try await responseData(request, session: session)
                return try parse(data: data, now: now)
            } catch let error as MiniMaxUsageError {
                lastError = error
                if index == 0, shouldTryLegacy(after: error) {
                    if error == .invalidCredentials { officialCredentialFailure = true }
                    continue
                }
                if officialCredentialFailure { throw MiniMaxUsageError.invalidCredentials }
                throw error
            } catch {
                if let cancellation = cancellationError(error) { throw cancellation }
                lastError = error
                if index == 0 { continue }
                throw error
            }
        }
        if officialCredentialFailure { throw MiniMaxUsageError.invalidCredentials }
        throw lastError ?? MiniMaxUsageError.parseFailed("缺少 MiniMax 用量接口")
    }

    static func fetchWeb(
        cookie: String,
        bearer: String?,
        groupID: String?,
        region: MiniMaxRegion,
        session: URLSession,
        now: Date,
        environment: [String: String]
    ) async throws -> Snapshot {
        let normalized = normalizedCookie(cookie)
        guard !normalized.isEmpty else { throw MiniMaxUsageError.missingCredentials }
        try validateEndpointOverrides(environment)
        let codingURL = try endpoint(
            overrideKey: "MINIMAX_CODING_PLAN_URL",
            hostKey: "MINIMAX_HOST",
            defaultURL: "https://\(region.platformHost)/user-center/payment/coding-plan?cycle_type=3",
            pathForHost: "/user-center/payment/coding-plan?cycle_type=3",
            environment: environment
        )
        var snapshot: Snapshot?
        do {
            let data = try await webRequest(
                url: codingURL,
                cookie: normalized,
                bearer: bearer,
                referer: codingURL.deletingQuery(),
                accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                session: session
            )
            snapshot = try parseWebResponse(data: data, now: now)
        } catch MiniMaxUsageError.invalidCredentials {
            throw MiniMaxUsageError.invalidCredentials
        } catch {
            if let cancellation = cancellationError(error) { throw cancellation }
            snapshot = nil
        }

        if snapshot?.quotas.isEmpty != false {
            var remainsError: Error?
            for url in try remainsURLs(region: region, environment: environment) {
                do {
                    let target = appendingGroupID(groupID, to: url)
                    let data = try await webRequest(
                        url: target,
                        cookie: normalized,
                        bearer: bearer,
                        referer: codingURL.deletingQuery(),
                        accept: "application/json, text/plain, */*",
                        session: session
                    )
                    var parsed = try parse(data: data, now: now)
                    if parsed.plan == nil { parsed.plan = snapshot?.plan }
                    snapshot = parsed
                    remainsError = nil
                    break
                } catch MiniMaxUsageError.invalidCredentials {
                    throw MiniMaxUsageError.invalidCredentials
                } catch {
                    if let cancellation = cancellationError(error) { throw cancellation }
                    remainsError = error
                }
            }
            if snapshot?.quotas.isEmpty != false, let remainsError { throw remainsError }
        }
        guard var result = snapshot, !result.quotas.isEmpty else {
            throw MiniMaxUsageError.parseFailed("缺少 MiniMax 额度窗口")
        }

        if let groupID {
            do {
                let metadata = try await subscriptionMetadata(
                    cookie: normalized,
                    groupID: groupID,
                    region: region,
                    session: session,
                    environment: environment
                )
                if result.plan == nil { result.plan = metadata.plan }
                result.subscriptionExpiresAt = metadata.expiresAt
                result.subscriptionRenewsAt = metadata.renewsAt
            } catch {
                if let cancellation = cancellationError(error) { throw cancellation }
            }
        }
        do {
            let billing = try await billingSummary(
                cookie: normalized,
                bearer: bearer,
                region: region,
                session: session,
                now: now,
                environment: environment
            )
            result.todayTokens = billing.todayTokens
            result.last30DaysTokens = billing.last30DaysTokens
            result.todayCash = billing.todayCash
            result.last30DaysCash = billing.last30DaysCash
            result.billingDetails = billing.details
        } catch MiniMaxUsageError.invalidCredentials where bearer != nil {
            throw MiniMaxUsageError.invalidCredentials
        } catch {
            if let cancellation = cancellationError(error) { throw cancellation }
        }
        return result
    }

    static func parse(data: Data, now: Date = Date()) throws -> Snapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MiniMaxUsageError.parseFailed(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw MiniMaxUsageError.parseFailed("响应不是 JSON 对象")
        }
        try validateBaseResponse(root)
        if let serviceSnapshot = parseServicePayload(root, now: now) { return serviceSnapshot }
        let payload = dictionary(root["data"]) ?? root
        try validateBaseResponse(payload)
        let remains = array(payload["model_remains"] ?? payload["modelRemains"])
        guard !remains.isEmpty else {
            throw MiniMaxUsageError.parseFailed("缺少 model_remains")
        }

        var quotas: [Quota] = []
        for value in remains {
            guard let item = dictionary(value) else { continue }
            let modelName = string(item["model_name"]) ?? "general"
            let service = mappedService(modelName)
            if let interval = makeQuota(
                service: service,
                windowOverride: nil,
                total: integer(item["current_interval_total_count"]),
                remaining: integer(item["current_interval_usage_count"]),
                remainingPercent: number(item["current_interval_remaining_percent"]),
                status: integer(item["current_interval_status"]),
                start: integer(item["start_time"]),
                end: integer(item["end_time"]),
                remainsTime: integer(item["remains_time"]),
                boostPermille: integer(item["interval_boost_permill"] ?? item["interval_boost_permille"]),
                now: now
            ) {
                quotas.append(interval)
            }
            if isTextModel(modelName), let weekly = makeQuota(
                service: service,
                windowOverride: "Weekly",
                total: integer(item["current_weekly_total_count"]),
                remaining: integer(item["current_weekly_usage_count"]),
                remainingPercent: number(item["current_weekly_remaining_percent"]),
                status: integer(item["current_weekly_status"]),
                start: integer(item["weekly_start_time"]),
                end: integer(item["weekly_end_time"]),
                remainsTime: integer(item["weekly_remains_time"]),
                boostPermille: integer(item["weekly_boost_permill"] ?? item["weekly_boost_permille"]),
                now: now
            ) {
                quotas.append(weekly)
            }
        }
        guard !quotas.isEmpty else { throw MiniMaxUsageError.parseFailed("未找到有效额度窗口") }
        let plan = firstString(payload, keys: [
            "current_subscribe_title", "plan_name", "combo_title", "current_plan_title",
        ]) ?? dictionary(payload["current_combo_card"]).flatMap { string($0["title"]) }
            ?? inferredPlan(remains)
        let points = firstNumber(payload, keys: [
            "points_balance", "point_balance", "credits_balance", "credit_balance", "balance",
        ])
        return Snapshot(
            plan: plan,
            quotas: quotas,
            pointsBalance: points,
            todayTokens: nil,
            last30DaysTokens: nil,
            todayCash: nil,
            last30DaysCash: nil,
            subscriptionExpiresAt: nil,
            subscriptionRenewsAt: nil,
            billingDetails: [],
            updatedAt: now
        )
    }

    static func credential(from raw: String?) -> Credential {
        let cleaned = clean(raw ?? "")
        guard !cleaned.isEmpty else {
            return Credential(cookie: nil, bearerToken: nil, groupID: nil, apiToken: nil)
        }
        if !cleaned.contains("=") && !cleaned.localizedCaseInsensitiveContains("cookie:") {
            let token = cleaned.replacingOccurrences(
                of: "^Bearer\\s+",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            return Credential(cookie: nil, bearerToken: nil, groupID: nil, apiToken: token)
        }
        let cookie = normalizedCookie(extractCookieHeader(cleaned) ?? cleaned)
        let bearer = firstMatch(
            #"(?i)authorization:\s*bearer\s+([A-Za-z0-9._\-+=/]+)"#,
            in: cleaned
        )
        let group = firstMatch(#"(?i)x-group-id:\s*([0-9]{4,})"#, in: cleaned)
            ?? firstMatch(#"(?i)minimax_group_id_v2=([0-9]{4,})"#, in: cleaned)
            ?? firstMatch(#"(?i)group[_]?id=([0-9]{4,})"#, in: cleaned)
        return Credential(
            cookie: cookie.isEmpty ? nil : cookie,
            bearerToken: bearer,
            groupID: group,
            apiToken: nil
        )
    }

    static func apiToken(environment: [String: String]) -> String? {
        for key in ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"] {
            let value = clean(environment[key] ?? "")
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func region(from raw: String?) -> MiniMaxRegion {
        switch clean(raw ?? "").lowercased() {
        case "cn", "china", "china mainland", "mainland", "中国", "中国大陆": .chinaMainland
        default: .global
        }
    }

    private enum APIKeyKind { case codingPlan, standard, unknown }

    private static func apiKeyKind(_ token: String) -> APIKeyKind {
        if token.hasPrefix("sk-cp-") { return .codingPlan }
        if token.hasPrefix("sk-api-") { return .standard }
        return .unknown
    }

    private static func shouldTryLegacy(after error: MiniMaxUsageError) -> Bool {
        switch error {
        case .invalidCredentials, .parseFailed: true
        case let .apiError(message): message.contains("HTTP 404") || message.contains("HTTP 405")
        default: false
        }
    }

    private static func responseData(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw MiniMaxUsageError.invalidCredentials }
            throw MiniMaxUsageError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func cancellationError(_ error: Error) -> Error? {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled { return urlError }
        return nil
    }

    private static func webRequest(
        url: URL,
        cookie: String,
        bearer: String?,
        referer: URL,
        accept: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(origin(url).absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        return try await responseData(request, session: session)
    }

    private static func parseWebResponse(data: Data, now: Date) throws -> Snapshot {
        if let first = data.first, first == UInt8(ascii: "{") { return try parse(data: data, now: now) }
        let html = String(decoding: data, as: UTF8.self)
        if looksSignedOut(html) { throw MiniMaxUsageError.invalidCredentials }
        if let next = nextData(in: html), let result = try? parse(data: next, now: now) { return result }
        let text = visibleText(html)
        let plan = firstMatch(#"(?i)Coding\s*Plan\s*([A-Za-z0-9][A-Za-z0-9\s._-]{0,32})"#, in: text)
        guard let amountRaw = firstMatch(
            #"(?i)available\s+usage[:\s]*([0-9][0-9,]*)\s*prompts?"#,
            in: text
        ), let amount = Int(amountRaw.replacingOccurrences(of: ",", with: "")) else {
            if plan != nil {
                return Snapshot(
                    plan: plan,
                    quotas: [],
                    pointsBalance: nil,
                    todayTokens: nil,
                    last30DaysTokens: nil,
                    todayCash: nil,
                    last30DaysCash: nil,
                    subscriptionExpiresAt: nil,
                    subscriptionRenewsAt: nil,
                    billingDetails: [],
                    updatedAt: now
                )
            }
            throw MiniMaxUsageError.parseFailed("页面未包含 Coding Plan 数据")
        }
        let percent = firstMatch(#"(?i)([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used"#, in: text)
            .flatMap(Double.init)
        guard let percent else {
            return Snapshot(
                plan: plan,
                quotas: [],
                pointsBalance: nil,
                todayTokens: nil,
                last30DaysTokens: nil,
                todayCash: nil,
                last30DaysCash: nil,
                subscriptionExpiresAt: nil,
                subscriptionRenewsAt: nil,
                billingDetails: [],
                updatedAt: now
            )
        }
        let used = Int((Double(amount) * percent / 100).rounded())
        return Snapshot(
            plan: plan,
            quotas: [Quota(
                service: "general",
                label: "Window",
                usedFraction: min(1, max(0, percent / 100)),
                used: used,
                limit: amount,
                unlimited: false,
                resetsAt: nil,
                detail: "\(used) / \(amount)",
                weekly: false
            )],
            pointsBalance: nil,
            todayTokens: nil,
            last30DaysTokens: nil,
            todayCash: nil,
            last30DaysCash: nil,
            subscriptionExpiresAt: nil,
            subscriptionRenewsAt: nil,
            billingDetails: [],
            updatedAt: now
        )
    }

    private static func parseServicePayload(_ root: [String: Any], now: Date) -> Snapshot? {
        let payload = dictionary(root["data"]) ?? root
        let services = array(payload["services"])
        guard !services.isEmpty else { return nil }
        var quotas: [Quota] = []
        for value in services {
            guard let item = dictionary(value),
                  let service = string(item["service_type"]),
                  let label = string(item["window_type"]),
                  let used = integer(item["usage"]),
                  let limit = integer(item["limit"]), limit > 0 else { continue }
            let fraction = min(1, max(0, (number(item["percent"]) ?? Double(used) / Double(limit) * 100) / 100))
            let range = string(item["time_range"]) ?? ""
            let reset = resetDate(timeRange: range, label: label, now: now)
            quotas.append(Quota(
                service: mappedService(service),
                label: label,
                usedFraction: fraction,
                used: used,
                limit: limit,
                unlimited: false,
                resetsAt: reset,
                detail: "\(used) / \(limit)" + (range.isEmpty ? "" : " • \(range)"),
                weekly: label.caseInsensitiveCompare("Weekly") == .orderedSame
            ))
        }
        guard !quotas.isEmpty else { return nil }
        return Snapshot(
            plan: nil,
            quotas: quotas,
            pointsBalance: firstNumber(payload, keys: ["points_balance", "balance"]),
            todayTokens: nil,
            last30DaysTokens: nil,
            todayCash: nil,
            last30DaysCash: nil,
            subscriptionExpiresAt: nil,
            subscriptionRenewsAt: nil,
            billingDetails: [],
            updatedAt: now
        )
    }

    private static func makeQuota(
        service: String,
        windowOverride: String?,
        total: Int?,
        remaining: Int?,
        remainingPercent: Double?,
        status: Int?,
        start: Int?,
        end: Int?,
        remainsTime: Int?,
        boostPermille: Int?,
        now: Date
    ) -> Quota? {
        let weekly = windowOverride?.caseInsensitiveCompare("Weekly") == .orderedSame
        let unlimited = weekly && status == 3 && isTextService(service) && (remainingPercent ?? 0) >= 100
        let unavailable = status == 3
            && (total ?? 0) == 0
            && (remaining ?? 0) == 0
            && (remainingPercent ?? 0) >= 100
            && !unlimited
        if unavailable { return nil }

        let startDate = epochDate(start)
        let endDate = epochDate(end)
        let durationHours = if let startDate, let endDate {
            endDate.timeIntervalSince(startDate) / 3600
        } else { 0.0 }
        let label: String = if weekly {
            "Weekly"
        } else if durationHours >= 23, durationHours <= 25 {
            "Today"
        } else if durationHours >= 4, durationHours <= 6 {
            "5 hours"
        } else if durationHours >= 1 {
            "\(Int(durationHours)) hours"
        } else {
            "Window"
        }
        if unlimited {
            return Quota(
                service: service,
                label: label,
                usedFraction: 0,
                used: 0,
                limit: 0,
                unlimited: true,
                resetsAt: nil,
                detail: "Unlimited",
                weekly: weekly
            )
        }

        let usedFraction: Double
        let usedValue: Int
        let limitValue: Int
        if let remainingPercent {
            usedFraction = min(1, max(0, (100 - remainingPercent) / 100))
            limitValue = boostPermille.map { max(1, Int((Double($0) / 10).rounded())) } ?? 100
            usedValue = Int((usedFraction * Double(limitValue)).rounded())
        } else if let total, total > 0, let remaining {
            limitValue = total
            usedValue = max(0, total - remaining)
            usedFraction = min(1, max(0, Double(usedValue) / Double(total)))
        } else {
            return nil
        }
        let reset = resolvedReset(end: endDate, remainsTime: remainsTime, now: now)
        let range = formattedRange(start: startDate, end: endDate, weekly: weekly)
        var detail = "\(usedValue) / \(limitValue)"
        if let range { detail += " • \(range)" }
        return Quota(
            service: service,
            label: label,
            usedFraction: usedFraction,
            used: usedValue,
            limit: limitValue,
            unlimited: false,
            resetsAt: reset,
            detail: detail,
            weekly: weekly
        )
    }

    private static func validateBaseResponse(_ root: [String: Any]) throws {
        guard let base = dictionary(root["base_resp"] ?? root["baseResp"]) else { return }
        let status = integer(base["status_code"] ?? base["statusCode"]) ?? 0
        guard status != 0 else { return }
        let message = string(base["status_msg"] ?? base["statusMessage"]) ?? "status_code \(status)"
        let lower = message.lowercased()
        if status == 1004 || lower.contains("cookie") || lower.contains("login") || lower == "invalid api key" {
            throw MiniMaxUsageError.invalidCredentials
        }
        throw MiniMaxUsageError.apiError(message)
    }

    private struct SubscriptionMetadata {
        let plan: String?
        let expiresAt: Date?
        let renewsAt: Date?
    }

    private static func subscriptionMetadata(
        cookie: String,
        groupID: String,
        region: MiniMaxRegion,
        session: URLSession,
        environment: [String: String]
    ) async throws -> SubscriptionMetadata {
        let base = clean(environment["MINIMAX_HOST"] ?? "").isEmpty
            ? "https://\(region.webHost)"
            : try validatedBase(environment["MINIMAX_HOST"]!, key: "MINIMAX_HOST").absoluteString
        var components = URLComponents(string: base)!
        components.path = "/v1/api/openplatform/charge/combo/cycle_audio_resource_package"
        components.queryItems = [
            URLQueryItem(name: "biz_line", value: "2"),
            URLQueryItem(name: "cycle_type", value: "3"),
            URLQueryItem(name: "resource_package_type", value: "7"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(groupID, forHTTPHeaderField: "x-group-id")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let data = try await responseData(request, session: session)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw MiniMaxUsageError.parseFailed("订阅信息格式无效") }
        try validateBaseResponse(root)
        let currentStrings = collectCurrentSubscriptionStrings(root)
        let plan = bestTokenPlan(in: currentStrings) ?? bestTokenPlan(in: collectStrings(root))
        return SubscriptionMetadata(
            plan: plan,
            expiresAt: findDate(root, keys: ["current_subscribe_end_time_ts", "current_subscribe_end_time"]),
            renewsAt: findDate(root, keys: ["renewal_trigger_time_ts", "renewal_date"])
        )
    }

    private static func bestTokenPlan(in strings: [String]) -> String? {
        strings.compactMap { value -> (Int, String)? in
            let lower = value.lowercased()
            if lower.contains("tokenplanplus") { return (0, value) }
            if lower.contains("tokenplanmax") { return (1, value) }
            if lower.contains("tokenplanultra") { return (2, value) }
            if lower.contains("token plan"), lower.contains("plus") || lower.contains("max") || lower.contains("ultra") {
                return (3, value)
            }
            return nil
        }.min { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1.count < rhs.1.count : lhs.0 < rhs.0
        }?.1
    }

    private static func collectCurrentSubscriptionStrings(_ value: Any) -> [String] {
        if let root = value as? [String: Any] {
            return root.flatMap { key, nested in
                let lower = key.lowercased()
                let direct = lower.contains("current_subscribe") || lower.contains("current_subscription")
                    || lower.contains("current_plan") ? collectStrings(nested) : []
                return direct + collectCurrentSubscriptionStrings(nested)
            }
        }
        if let values = value as? [Any] { return values.flatMap(collectCurrentSubscriptionStrings) }
        return []
    }

    private struct BillingSummary {
        let todayTokens: Int64
        let last30DaysTokens: Int64
        let todayCash: Double?
        let last30DaysCash: Double?
        let details: [UsageDetail]
    }

    private static func billingSummary(
        cookie: String,
        bearer: String?,
        region: MiniMaxRegion,
        session: URLSession,
        now: Date,
        environment: [String: String]
    ) async throws -> BillingSummary {
        var records: [BillingRecord] = []
        var page = 1
        var totalCount: Int?
        var receivedCount = 0
        while true {
            guard page <= 100 else {
                throw MiniMaxUsageError.parseFailed("Billing history returned too many pages")
            }
            let base = try endpoint(
                overrideKey: "MINIMAX_BILLING_HISTORY_URL",
                hostKey: "MINIMAX_HOST",
                defaultURL: "https://\(region.platformHost)/account/amount",
                pathForHost: "/account/amount",
                environment: environment
            )
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "aggregate", value: "false"),
            ]
            let data = try await webRequest(
                url: components.url!,
                cookie: cookie,
                bearer: bearer,
                referer: origin(base).appendingPathComponent("account"),
                accept: "application/json, text/plain, */*",
                session: session
            )
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else { break }
            try validateBaseResponse(root)
            totalCount = integer(root["total_cnt"]) ?? totalCount
            let values = array(root["charge_records"])
            if values.isEmpty { break }
            receivedCount += values.count
            let pageRecords = values.compactMap { billingRecord($0) }
            records += pageRecords
            if containsRecordBeforeWindow(pageRecords, now: now) { break }
            if let totalCount, receivedCount >= totalCount { break }
            page += 1
        }
        return aggregateBilling(records, now: now)
    }

    private static func billingRecord(_ value: Any) -> BillingRecord? {
        guard let item = dictionary(value) else { return nil }
        let result = string(item["result"] ?? item["status"])
        if let result, result.caseInsensitiveCompare("SUCCESS") != .orderedSame { return nil }
        guard let date = recordDate(item) else { return nil }
        let direct = integer(item["consume_token"])
        let tokenCount = direct.map(Int64.init)
            ?? Int64((integer(item["consume_input_token"]) ?? 0) + (integer(item["consume_output_token"]) ?? 0))
        return BillingRecord(
            date: date,
            tokens: max(0, tokenCount),
            cash: number(item["consume_cash_after_voucher"] ?? item["consume_cash"])
        )
    }

    private static func aggregateBilling(_ records: [BillingRecord], now: Date) -> BillingSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let filtered = records.filter { $0.date >= start && $0.date <= now }
        let todayRecords = filtered.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let cash = filtered.compactMap(\.cash)
        var details: [UsageDetail] = []
        let todayCashValues = todayRecords.compactMap(\.cash)
        if !todayCashValues.isEmpty {
            details.append(UsageDetail(
                id: "minimax-today-cash",
                label: "Today cash",
                value: String(format: "%.2f", todayCashValues.reduce(0, +))
            ))
        }
        if !cash.isEmpty {
            details.append(UsageDetail(
                id: "minimax-30d-cash",
                label: "30d cash",
                value: String(format: "%.2f", cash.reduce(0, +))
            ))
        }
        return BillingSummary(
            todayTokens: todayRecords.reduce(0) { $0 + $1.tokens },
            last30DaysTokens: filtered.reduce(0) { $0 + $1.tokens },
            todayCash: todayCashValues.isEmpty ? nil : todayCashValues.reduce(0, +),
            last30DaysCash: cash.isEmpty ? nil : cash.reduce(0, +),
            details: details
        )
    }

    private static func automaticCredentials() -> [Credential] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        let chromiumBrowsers: [Browser] = [
            .chrome, .chromeBeta, .chromeCanary, .edge, .edgeBeta, .edgeCanary,
            .brave, .braveBeta, .braveNightly, .vivaldi, .arc, .arcBeta, .arcCanary,
            .dia, .chatgptAtlas, .chromium, .helium,
        ]
        let browsers = chromiumBrowsers + [.firefox, .safari]
        let storageTokens = automaticStorageTokens(browsers: chromiumBrowsers)
        var result: [Credential] = []
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
            for group in groups.values {
                let sourceLabel = normalizedStorageLabel(group.map(\.label).min() ?? "")
                let cookies = group.flatMap {
                    BrowserCookieClient.makeHTTPCookies($0.records, origin: query.origin)
                }
                guard !cookies.isEmpty else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let cookieBearer = cookies.first { $0.name == "HERTZ-SESSION" }?.value
                let cookieGroupID = cookies.first { $0.name == "minimax_group_id_v2" }?.value
                for stored in storageTokens where normalizedStorageLabel(stored.label) == sourceLabel {
                    result.append(Credential(
                        cookie: header,
                        bearerToken: stored.token,
                        groupID: stored.groupID ?? cookieGroupID,
                        apiToken: nil
                    ))
                }
                result.append(Credential(
                    cookie: header,
                    bearerToken: cookieBearer,
                    groupID: cookieGroupID ?? cookieBearer.flatMap(groupIDFromJWT),
                    apiToken: nil
                ))
                result.append(Credential(cookie: header, bearerToken: nil, groupID: cookieGroupID, apiToken: nil))
            }
        }
        return result
    }

    private struct StoredToken {
        let token: String
        let groupID: String?
        let label: String
    }

    private static func automaticStorageTokens(browsers: [Browser]) -> [StoredToken] {
        let origins = [
            "https://platform.minimax.io", "https://www.minimax.io", "https://minimax.io",
            "https://platform.minimaxi.com", "https://www.minimaxi.com", "https://minimaxi.com",
        ]
        let roots = ChromiumProfileLocator.roots(
            for: browsers,
            homeDirectories: BrowserCookieClient.defaultHomeDirectories()
        )
        var result: [StoredToken] = []
        var seen = Set<String>()
        for root in roots {
            guard let profiles = try? FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for profile in profiles {
                guard (try? profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }
                let label = "\(root.labelPrefix) \(name)"
                let localStorage = profile.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
                var values: [String] = []
                if FileManager.default.fileExists(atPath: localStorage.path) {
                    for origin in origins {
                        values += ChromiumLocalStorageReader.readEntries(for: origin, in: localStorage).map(\.value)
                    }
                    values += ChromiumLocalStorageReader.readTextEntries(in: localStorage)
                        .filter {
                            let text = ($0.key + $0.value).lowercased()
                            return text.contains("minimax.io") || text.contains("minimaxi.com")
                                || text.contains("access_token") || text.contains("accesstoken")
                        }
                        .map(\.value)
                }
                values += sessionStorageValues(profile: profile, origins: origins)
                values += indexedDBValues(profile: profile)
                for value in values {
                    for token in accessTokens(in: value) where seen.insert(token).inserted {
                        result.append(StoredToken(
                            token: token,
                            groupID: groupIDFromJWT(token) ?? groupID(in: value),
                            label: label
                        ))
                    }
                }
            }
        }
        return result
    }

    private static func sessionStorageValues(profile: URL, origins: [String]) -> [String] {
        let directory = profile.appendingPathComponent("Session Storage")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = ChromiumLocalStorageReader.readTextEntries(in: directory)
        let mapIDs = Set(entries.compactMap { entry -> Int? in
            guard entry.key.hasPrefix("namespace-"),
                  origins.contains(where: { entry.key.localizedCaseInsensitiveContains($0) }) else { return nil }
            return Int(entry.value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        guard !mapIDs.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard entry.key.hasPrefix("map-") else { return nil }
            let parts = entry.key.split(separator: "-", maxSplits: 2)
            guard parts.count >= 2, let mapID = Int(parts[1]), mapIDs.contains(mapID) else { return nil }
            return entry.value
        }
    }

    private static func indexedDBValues(profile: URL) -> [String] {
        let directory = profile.appendingPathComponent("IndexedDB")
        guard let databases = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefixes = [
            "https_platform.minimax.io_", "https_www.minimax.io_", "https_minimax.io_",
            "https_platform.minimaxi.com_", "https_www.minimaxi.com_", "https_minimaxi.com_",
        ]
        return databases.filter { database in
            prefixes.contains { database.lastPathComponent.hasPrefix($0) }
                && database.lastPathComponent.hasSuffix(".indexeddb.leveldb")
        }.flatMap { database in
            ChromiumLocalStorageReader.readTextEntries(in: database).map(\.value)
        }
    }

    private static func normalizedStorageLabel(_ label: String) -> String {
        for suffix in [" (Network)", " (Session Storage)", " (IndexedDB)"] where label.hasSuffix(suffix) {
            return String(label.dropLast(suffix.count))
        }
        return label
    }

    static func accessTokens(in value: String) -> [String] {
        let patterns = [
            #"access_token[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"accessToken[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"id_token[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"idToken[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"([A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#,
        ]
        var result: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches where match.numberOfRanges >= 2 {
                guard let range = Range(match.range(at: 1), in: value) else { continue }
                let token = String(value[range])
                if token.count >= 60, seen.insert(token).inserted { result.append(token) }
            }
        }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            for token in collectAccessTokens(object) where token.count >= 60 && seen.insert(token).inserted {
                result.append(token)
            }
        }
        return result
    }

    private static func collectAccessTokens(_ value: Any) -> [String] {
        if let root = value as? [String: Any] {
            return root.flatMap { key, nested in
                if ["access_token", "accessToken", "id_token", "idToken", "token", "authToken", "authorization", "bearer"]
                    .contains(key), let token = string(nested) {
                    return [token]
                }
                if let encoded = nested as? String,
                   let data = encoded.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data) {
                    return collectAccessTokens(decoded)
                }
                return collectAccessTokens(nested)
            }
        }
        if let values = value as? [Any] { return values.flatMap(collectAccessTokens) }
        return []
    }

    static func groupIDFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["group_id", "groupId", "groupID", "gid", "tenant_id", "tenantId", "org_id", "orgId"] {
            if let value = string(claims[key]) { return longestDigitSequence(value) ?? value }
        }
        for (key, value) in claims where key.lowercased().contains("group") {
            if let value = string(value) { return longestDigitSequence(value) ?? value }
        }
        return nil
    }

    private static func groupID(in value: String) -> String? {
        firstMatch(#"(?i)(?:groupId|group_id|GroupID)[^0-9]+([0-9]{4,})"#, in: value)
    }

    private static func longestDigitSequence(_ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{4,}"#) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        return matches.compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }.max { $0.count < $1.count }
    }

    private static func cookieValue(environment: [String: String]) -> String? {
        for key in ["MINIMAX_COOKIE", "MINIMAX_COOKIE_HEADER"] {
            let value = clean(environment[key] ?? "")
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func deduplicated(_ values: [Credential]) -> [Credential] {
        var seen = Set<String>()
        return values.filter { value in
            guard let cookie = value.cookie else { return false }
            return seen.insert(cookie + "|" + (value.bearerToken ?? "")).inserted
        }
    }

    private static func remainsURLs(
        region: MiniMaxRegion,
        environment: [String: String]
    ) throws -> [URL] {
        if let raw = environment["MINIMAX_REMAINS_URL"], !clean(raw).isEmpty {
            return [try validatedURL(raw, key: "MINIMAX_REMAINS_URL")]
        }
        if let raw = environment["MINIMAX_HOST"], !clean(raw).isEmpty {
            let base = try validatedBase(raw, key: "MINIMAX_HOST")
            return [base.appendingPathComponent("v1/api/openplatform/coding_plan/remains")]
        }
        return [
            URL(string: "https://\(region.platformHost)/v1/api/openplatform/coding_plan/remains")!,
            URL(string: "https://\(region.webHost)/v1/api/openplatform/coding_plan/remains")!,
        ]
    }

    private static func endpoint(
        overrideKey: String,
        hostKey: String,
        defaultURL: String,
        pathForHost: String,
        environment: [String: String]
    ) throws -> URL {
        if let raw = environment[overrideKey], !clean(raw).isEmpty {
            return try validatedURL(raw, key: overrideKey)
        }
        if let raw = environment[hostKey], !clean(raw).isEmpty {
            let base = try validatedBase(raw, key: hostKey)
            guard let url = URL(string: pathForHost, relativeTo: base)?.absoluteURL else {
                throw MiniMaxUsageError.invalidEndpoint(hostKey)
            }
            return url
        }
        return URL(string: defaultURL)!
    }

    private static func validateEndpointOverrides(_ environment: [String: String]) throws {
        let strict = ["1", "true", "yes", "on"].contains(
            clean(environment["MINIMAX_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES"] ?? "").lowercased()
        )
        for key in [
            "MINIMAX_CODING_PLAN_URL", "MINIMAX_REMAINS_URL", "MINIMAX_BILLING_HISTORY_URL",
        ] where !clean(environment[key] ?? "").isEmpty {
            let url = try validatedURL(environment[key]!, key: key)
            if strict { try validateProviderOwnedHost(url, key: key) }
        }
        if !clean(environment["MINIMAX_HOST"] ?? "").isEmpty {
            let url = try validatedBase(environment["MINIMAX_HOST"]!, key: "MINIMAX_HOST")
            if strict { try validateProviderOwnedHost(url, key: "MINIMAX_HOST") }
        }
    }

    private static func validatedURL(_ raw: String, key: String) throws -> URL {
        let value = clean(raw)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw MiniMaxUsageError.invalidEndpoint(key)
        }
        guard let url = components.url else { throw MiniMaxUsageError.invalidEndpoint(key) }
        return url
    }

    private static func validateProviderOwnedHost(_ url: URL, key: String) throws {
        guard let host = url.host?.lowercased(),
              host == "minimax.io" || host.hasSuffix(".minimax.io")
                || host == "minimaxi.com" || host.hasSuffix(".minimaxi.com") else {
            throw MiniMaxUsageError.invalidEndpoint(key)
        }
    }

    private static func validatedBase(_ raw: String, key: String) throws -> URL {
        let value = clean(raw)
        return try validatedURL(value.contains("://") ? value : "https://\(value)", key: key)
    }

    private static func appendingGroupID(_ groupID: String?, to url: URL) -> URL {
        guard let groupID, !groupID.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "GroupId", value: groupID))
        components.queryItems = items
        return components.url ?? url
    }

    private static func normalizedCookie(_ raw: String) -> String {
        var value = clean(raw)
        if value.lowercased().hasPrefix("cookie:") {
            value = clean(String(value.dropFirst("cookie:".count)))
        }
        return value.split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let content = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !content.isEmpty else { return nil }
            return "\(name)=\(content)"
        }.joined(separator: "; ")
    }

    private static func extractCookieHeader(_ raw: String) -> String? {
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)cookie:\s*'([^']+)'"#,
            #"(?i)cookie:\s*\"([^\"]+)\""#,
            #"(?i)(?:--cookie|-b)\s*'([^']+)'"#,
            #"(?i)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern, in: raw) { return value }
        }
        return nil
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return clean(value).isEmpty ? nil : clean(value) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite,
                  number >= Double(Int.min),
                  number <= Double(Int.max)
            else { return nil }
            return Int(number)
        }
        if let value = value as? String { return Int(clean(value)) }
        return nil
    }
    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(clean(value)) }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func firstString(_ root: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(root[$0]) }.first
    }
    private static func firstNumber(_ root: [String: Any], keys: [String]) -> Double? {
        keys.lazy.compactMap { number(root[$0]) }.first
    }

    private static func mappedService(_ name: String) -> String {
        let lower = clean(name).lowercased()
        if lower == "general" || lower == "video" { return lower }
        if isTextModel(name) { return "Text Generation" }
        if lower.contains("speech") { return "Text to Speech" }
        if lower.contains("hailuo") && lower.contains("fast") { return "Image to Video" }
        if lower.contains("hailuo") { return "Text to Video" }
        if lower.hasPrefix("image-") { return "Image Generation" }
        if lower.contains("music") { return "Music Generation" }
        return name
    }

    private static func isTextModel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
    }
    private static func isTextService(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "general" || lower.contains("text generation")
    }

    private static func inferredPlan(_ remains: [Any]) -> String? {
        let items = remains.compactMap(dictionary)
        let hasText = items.contains { string($0["model_name"]).map(isTextModel) ?? false }
        let unavailableVideo = items.contains { item in
            string(item["model_name"])?.lowercased() == "video"
                && integer(item["current_interval_status"]) == 3
                && (integer(item["current_interval_total_count"]) ?? 0) == 0
                && (number(item["current_interval_remaining_percent"]) ?? 0) >= 100
        }
        return hasText && unavailableVideo ? "Plus" : nil
    }

    private static func epochDate(_ value: Int?) -> Date? {
        guard let value else { return nil }
        if value > 1_000_000_000_000 { return Date(timeIntervalSince1970: Double(value) / 1000) }
        if value > 1_000_000_000 { return Date(timeIntervalSince1970: Double(value)) }
        return nil
    }

    private static func resolvedReset(end: Date?, remainsTime: Int?, now: Date) -> Date? {
        if let end, end > now { return end }
        guard let remainsTime, remainsTime > 0 else { return nil }
        let seconds = remainsTime > 1_000_000 ? Double(remainsTime) / 1000 : Double(remainsTime)
        return now.addingTimeInterval(seconds)
    }

    private static func formattedRange(start: Date?, end: Date?, weekly: Bool) -> String? {
        guard let start, let end else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = weekly ? "MM/dd HH:mm" : "HH:mm"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))(UTC+8)"
    }

    private static func resetDate(timeRange: String, label: String, now: Date) -> Date? {
        if label.caseInsensitiveCompare("Today") == .orderedSame {
            let pieces = timeRange.components(separatedBy: " - ")
            guard let last = pieces.last else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return formatter.date(from: last)
        }
        return nil
    }

    private static func origin(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func visibleText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#, #"<[^>]+>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func looksSignedOut(_ html: String) -> Bool {
        let text = visibleText(html).lowercased()
        return text.contains("sign in") || text.contains("log in") || text.contains("登录") || text.contains("登入")
    }

    private static func nextData(in html: String) -> Data? {
        guard let range = html.range(of: #"<script[^>]*id=[\"']__NEXT_DATA__[\"'][^>]*>(.*?)</script>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let block = String(html[range])
        guard let start = block.firstIndex(of: ">"), let end = block.range(of: "</script>", options: .caseInsensitive)?.lowerBound else { return nil }
        return String(block[block.index(after: start)..<end]).data(using: .utf8)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return clean(String(text[range]))
    }

    private static func collectStrings(_ value: Any) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [Any] { return values.flatMap(collectStrings) }
        if let values = value as? [String: Any] { return values.values.flatMap(collectStrings) }
        return []
    }

    private static func findDate(_ value: Any, keys: [String]) -> Date? {
        if let root = value as? [String: Any] {
            for key in keys {
                if let raw = root[key], let date = dateValue(raw) { return date }
            }
            for nested in root.values {
                if let date = findDate(nested, keys: keys) { return date }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let date = findDate(nested, keys: keys) { return date }
            }
        }
        return nil
    }

    private static func dateValue(_ value: Any) -> Date? {
        if let numeric = number(value), numeric > 0 {
            return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1000 : numeric)
        }
        guard let text = string(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: text)
    }

    private static func recordDate(_ item: [String: Any]) -> Date? {
        if let raw = integer(item["created_at"]) { return epochDate(raw) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if let ymd = string(item["ymd"]) {
            for format in ["yyyy-MM-dd", "yyyyMMdd", "yyyy/MM/dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: ymd) { return date }
            }
        }
        if let time = string(item["consume_time"]) {
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: time) { return date }
            }
        }
        return nil
    }

    private static func containsRecordBeforeWindow(_ records: [BillingRecord], now: Date) -> Bool {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        return records.contains { $0.date < start }
    }
}

private extension URL {
    func deletingQuery() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.query = nil
        return components.url ?? self
    }
}
