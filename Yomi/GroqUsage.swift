import Foundation
import SweetCookieKit

nonisolated enum GroqUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingSession
    case invalidSession(String)
    case invalidEndpoint(String)
    case consoleAccessDenied(String)
    case consoleAPIError(String)
    case consoleParseFailed(String)
    case metricsAccessDenied(String)
    case metricsAPIError(String)
    case metricsParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return AppLocalization.text(
                "缺少 Groq API Key。请在设置中添加，或设置 GROQ_API_KEY。",
                "Missing Groq API key. Add one in Settings or set GROQ_API_KEY."
            )
        case .missingSession:
            return AppLocalization.text(
                "未找到 Groq Console 会话。请先在浏览器登录 console.groq.com。",
                "No Groq console session found. Sign in at console.groq.com in your browser."
            )
        case let .invalidSession(message):
            return AppLocalization.text(
                "Groq Console 会话无效：\(message)",
                "Groq console session is invalid: \(message)"
            )
        case let .invalidEndpoint(key):
            return AppLocalization.text(
                "Groq 接口覆盖 \(key) 必须使用 HTTPS 或裸主机名。",
                "Groq endpoint override \(key) must use HTTPS or a bare host."
            )
        case let .consoleAccessDenied(message):
            return AppLocalization.text(
                "Groq Console 访问被拒绝：\(message)",
                "Groq console access denied: \(message)"
            )
        case let .consoleAPIError(message):
            return AppLocalization.text("Groq Console 接口错误：\(message)", "Groq console API error: \(message)")
        case let .consoleParseFailed(message):
            return AppLocalization.text("Groq Console 解析错误：\(message)", "Groq console parse error: \(message)")
        case let .metricsAccessDenied(message):
            return AppLocalization.text(
                "Groq 指标访问被拒绝：\(message)",
                "Groq metrics access denied: \(message)"
            )
        case let .metricsAPIError(message):
            return AppLocalization.text("Groq 指标接口错误：\(message)", "Groq metrics API error: \(message)")
        case let .metricsParseFailed(message):
            return AppLocalization.text("Groq 指标解析错误：\(message)", "Groq metrics parse error: \(message)")
        }
    }
}

nonisolated struct GroqConsoleSessionInfo: Sendable, Equatable {
    let sessionToken: String?
    let directJWT: String?
    let sourceLabel: String

    var cookieHeader: String {
        var pairs: [String] = []
        if let sessionToken { pairs.append("stytch_session=\(sessionToken)") }
        if let directJWT { pairs.append("stytch_session_jwt=\(directJWT)") }
        return pairs.joined(separator: "; ")
    }
}

nonisolated struct GroqConsoleUsageSnapshot: Sendable, Equatable {
    struct ModelBreakdown: Sendable, Equatable {
        let name: String
        let requests: Int
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let costUSD: Double
    }

    struct DailyBucket: Sendable, Equatable {
        let day: String
        let startTime: Date
        let endTime: Date
        let costUSD: Double
        let requests: Int
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let models: [ModelBreakdown]
    }

    let daily: [DailyBucket]
    let updatedAt: Date
    let historyDays: Int
    let organizationName: String?

    init(
        daily: [DailyBucket],
        updatedAt: Date,
        historyDays: Int,
        organizationName: String?
    ) {
        self.daily = daily.sorted { $0.startTime < $1.startTime }
        self.updatedAt = updatedAt
        self.historyDays = max(1, min(365, historyDays))
        self.organizationName = organizationName
    }

    var historyPeriodLabel: String {
        historyDays == 1 ? "Today" : "Last \(historyDays) days"
    }

    var windowCostUSD: Double {
        daily.reduce(0) { $0 + $1.costUSD }
    }

    func toProviderUsage() -> ProviderUsage {
        let currentBuckets = daily.filter { $0.startTime <= updatedAt && updatedAt < $0.endTime }
        let historyBuckets = Array(daily.suffix(max(1, historyDays)))
        let todayTokens = currentBuckets.reduce(0) { $0 + $1.totalTokens }
        let todayCost = currentBuckets.reduce(0) { $0 + $1.costUSD }
        let historyRequests = historyBuckets.reduce(0) { $0 + $1.requests }
        let historyTokens = historyBuckets.reduce(0) { $0 + $1.totalTokens }
        let historyCost = historyBuckets.reduce(0) { $0 + $1.costUSD }
        let details = [
            UsageDetail(id: "groq-spend", label: "Spend", value: Self.usd(historyCost)),
            UsageDetail(id: "groq-requests", label: "Requests", value: Self.count(historyRequests)),
            UsageDetail(id: "groq-tokens", label: "Tokens", value: Self.count(historyTokens)),
        ]
        return ProviderUsage(
            id: ProviderID(rawValue: "groq"),
            state: .ready,
            windows: [],
            today: DailyTokenUsage(tokens: Int64(todayTokens), valueUSD: todayCost),
            last30Days: DailyTokenUsage(tokens: Int64(historyTokens), valueUSD: historyCost),
            providerCost: ProviderCostSummary(
                used: windowCostUSD,
                limit: 0,
                currencyCode: "USD",
                period: historyPeriodLabel,
                balance: nil
            ),
            details: details,
            updatedAt: updatedAt
        )
    }

    private static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

nonisolated struct GroqMetricsUsageSnapshot: Sendable, Equatable {
    let requestRatePerSecond: Double
    let inputTokenRatePerSecond: Double
    let outputTokenRatePerSecond: Double
    let promptCacheHitRatePerSecond: Double
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        return ProviderUsage(
            id: ProviderID(rawValue: "groq"),
            state: .ready,
            windows: [],
            additionalWindows: [],
            details: [],
            updatedAt: updatedAt
        )
    }

}

nonisolated enum GroqUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    static let apiKeyEnvironmentKey = "GROQ_API_KEY"
    static let apiURLEnvironmentKey = "GROQ_API_URL"
    static let sessionJWTEnvironmentKey = "GROQ_SESSION_JWT"
    static let sessionTokenEnvironmentKey = "GROQ_SESSION_TOKEN"
    static let stytchPublicTokenEnvironmentKey = "GROQ_STYTCH_PUBLIC_TOKEN"
    static let stytchURLEnvironmentKey = "GROQ_STYTCH_URL"
    static let defaultAPIURL = URL(string: "https://api.groq.com/v1")!
    static let defaultStytchURL = URL(string: "https://api.stytchb2b.groq.com")!
    static let defaultStytchPublicToken = "public-token-live-58df57a9-a1f5-4066-bc0c-2ff942db684f"
    static let browserDomains = ["groq.com", "console.groq.com"]
    static let browserOrder = Browser.defaultImportOrder

    private static let stytchOrigin = "https://console.groq.com"
    private static let stytchSDKVersion = "5.43.0"
    private static let importCache = GroqImportSessionCache(ttl: 5)

    static func fetch(
        configuredAPIKey: String?,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        allowBrowserImport: Bool,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyDays: Int = 30,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment[apiKeyEnvironmentKey])
        switch source {
        case .token:
            guard let apiKey else { throw GroqUsageError.missingCredentials }
            return try await fetchMetrics(
                apiKey: apiKey,
                session: session,
                environment: environment,
                now: now
            ).toProviderUsage()
        case .automatic, .cookie:
            do {
                return try await fetchConsolePipeline(
                    environment: environment,
                    cachedCookieHeader: cachedCookieHeader,
                    allowBrowserImport: allowBrowserImport,
                    cacheUpdate: cacheUpdate,
                    session: session,
                    historyDays: historyDays,
                    now: now
                ).toProviderUsage()
            } catch {
                guard source == .automatic,
                      shouldFallbackToMetrics(error),
                      let apiKey else { throw error }
                return try await fetchMetrics(
                    apiKey: apiKey,
                    session: session,
                    environment: environment,
                    now: now
                ).toProviderUsage()
            }
        case .account, .command, .endpoint:
            throw GroqUsageError.missingCredentials
        }
    }

    static func session(fromCookieHeader raw: String?, sourceLabel: String = "manual") -> GroqConsoleSessionInfo? {
        guard let raw = cleaned(raw) else { return nil }
        let normalized = raw.lowercased().hasPrefix("cookie:")
            ? String(raw.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : raw
        var sessionToken: String?
        var directJWT: String?
        for component in normalized.split(separator: ";") {
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if name == "stytch_session" { sessionToken = String(value) }
            if name == "stytch_session_jwt" { directJWT = String(value) }
        }
        guard sessionToken != nil || directJWT != nil else { return nil }
        return GroqConsoleSessionInfo(
            sessionToken: sessionToken,
            directJWT: directJWT,
            sourceLabel: sourceLabel
        )
    }

    static func environmentSession(_ environment: [String: String]) -> GroqConsoleSessionInfo? {
        let token = cleaned(environment[sessionTokenEnvironmentKey])
        let jwt = cleaned(environment[sessionJWTEnvironmentKey])
        if let token {
            return GroqConsoleSessionInfo(sessionToken: token, directJWT: jwt, sourceLabel: "env")
        }
        if let jwt {
            return GroqConsoleSessionInfo(sessionToken: nil, directJWT: jwt, sourceLabel: "env")
        }
        return nil
    }

    static func organizationID(fromJWT jwt: String) -> String? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let organization = object["https://groq.com/organization"] as? [String: Any],
           let id = organization["id"] as? String,
           !id.isEmpty {
            return id
        }
        if let organization = object["https://stytch.com/organization"] as? [String: Any],
           let slug = organization["slug"] as? String,
           !slug.isEmpty {
            return slug
        }
        return nil
    }

    static func parseActivity(
        _ data: Data,
        historyDays: Int,
        updatedAt: Date,
        calendar: Calendar
    ) throws -> GroqConsoleUsageSnapshot {
        let rows: [ActivityRow]
        do {
            rows = try JSONDecoder().decode(ActivityResponse.self, from: data).data
        } catch {
            throw GroqUsageError.consoleParseFailed(error.localizedDescription)
        }
        return makeConsoleSnapshot(
            rows: rows,
            historyDays: historyDays,
            updatedAt: updatedAt,
            calendar: calendar
        )
    }

    static func parsePrometheusScalar(_ data: Data) throws -> Double {
        do {
            let response = try JSONDecoder().decode(PrometheusResponse.self, from: data)
            guard response.status == "success" else {
                throw GroqUsageError.metricsAPIError(response.error ?? "query failed")
            }
            return response.data?.result.compactMap { $0.value?.last?.doubleValue }.reduce(0, +) ?? 0
        } catch let error as GroqUsageError {
            throw error
        } catch {
            throw GroqUsageError.metricsParseFailed(error.localizedDescription)
        }
    }

    static func resolvedAPIURL(environment: [String: String]) throws -> URL {
        guard let raw = cleaned(environment[apiURLEnvironmentKey]) else { return defaultAPIURL }
        guard let url = normalizedHTTPSURL(raw) else {
            throw GroqUsageError.invalidEndpoint(apiURLEnvironmentKey)
        }
        return url
    }

    static func resolvedStytchURL(environment: [String: String]) throws -> URL {
        guard let raw = cleaned(environment[stytchURLEnvironmentKey]) else { return defaultStytchURL }
        guard let url = URL(string: raw) else {
            throw GroqUsageError.invalidSession("invalid Stytch URL")
        }
        return url
    }

    static func automaticSessions() -> [GroqConsoleSessionInfo] {
        importCache.sessions {
            let query = BrowserCookieQuery(domains: browserDomains)
            let client = BrowserCookieClient()
            var result: [GroqConsoleSessionInfo] = []
            for browser in browserOrder {
                guard let sources = try? client.records(matching: query, in: browser) else { continue }
                let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
                for group in groups.values.sorted(by: { mergedLabel($0) < mergedLabel($1) }) {
                    let records = mergedRecords(group)
                    let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                    let token = cookies.first { $0.name == "stytch_session" }?.value
                    let jwt = cookies.first { $0.name == "stytch_session_jwt" }?.value
                    guard token?.isEmpty == false || jwt?.isEmpty == false else { continue }
                    result.append(GroqConsoleSessionInfo(
                        sessionToken: token.flatMap(cleaned),
                        directJWT: jwt.flatMap(cleaned),
                        sourceLabel: mergedLabel(group)
                    ))
                }
            }
            return deduplicated(result)
        }
    }

    static func invalidateImportSessionCache() {
        importCache.invalidate()
    }

    static func mergedRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sources = sources.sorted { storePriority($0.store.kind) < storePriority($1.store.kind) }
        var merged: [String: BrowserCookieRecord] = [:]
        for source in sources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                if let existing = merged[key] {
                    if shouldReplace(existing: existing, candidate: record) { merged[key] = record }
                } else {
                    merged[key] = record
                }
            }
        }
        return Array(merged.values)
    }

    private static func fetchConsolePipeline(
        environment: [String: String],
        cachedCookieHeader: String?,
        allowBrowserImport: Bool,
        cacheUpdate: @escaping CacheUpdate,
        session: URLSession,
        historyDays: Int,
        now: Date
    ) async throws -> GroqConsoleUsageSnapshot {
        var candidates: [GroqConsoleSessionInfo] = []
        if let environmentSession = environmentSession(environment) {
            candidates.append(environmentSession)
        } else {
            if let cached = self.session(fromCookieHeader: cachedCookieHeader, sourceLabel: "Cache") {
                candidates.append(cached)
            }
            if allowBrowserImport { candidates.append(contentsOf: automaticSessions()) }
        }
        candidates = deduplicated(candidates)
        guard !candidates.isEmpty else { throw GroqUsageError.missingSession }

        var lastError: Error = GroqUsageError.missingSession
        for candidate in candidates {
            do {
                let jwt = try await resolveJWT(
                    candidate,
                    environment: environment,
                    session: session
                )
                let snapshot = try await fetchActivity(
                    sessionJWT: jwt,
                    historyDays: historyDays,
                    environment: environment,
                    session: session,
                    now: now
                )
                if candidate.sourceLabel != "env" { await cacheUpdate(candidate.cookieHeader) }
                return snapshot
            } catch {
                if candidate.sourceLabel == "Cache", shouldRetryNextSession(error) {
                    await cacheUpdate(nil)
                }
                guard shouldRetryNextSession(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private static func resolveJWT(
        _ candidate: GroqConsoleSessionInfo,
        environment: [String: String],
        session: URLSession
    ) async throws -> String {
        if let token = candidate.sessionToken.flatMap(cleaned) {
            do {
                return try await refreshSessionJWT(
                    sessionToken: token,
                    environment: environment,
                    session: session
                )
            } catch {
                if let directJWT = candidate.directJWT.flatMap(cleaned) { return directJWT }
                throw error
            }
        }
        if let directJWT = candidate.directJWT.flatMap(cleaned) { return directJWT }
        throw GroqUsageError.missingSession
    }

    private static func refreshSessionJWT(
        sessionToken: String,
        environment: [String: String],
        session: URLSession
    ) async throws -> String {
        let publicToken = cleaned(environment[stytchPublicTokenEnvironmentKey]) ?? defaultStytchPublicToken
        let baseURL = try resolvedStytchURL(environment: environment)
        let url = baseURL
            .appendingPathComponent("sdk")
            .appendingPathComponent("v1")
            .appendingPathComponent("b2b")
            .appendingPathComponent("sessions")
            .appendingPathComponent("authenticate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let credential = Data("\(publicToken):\(sessionToken)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stytchOrigin, forHTTPHeaderField: "Origin")
        request.setValue(stytchOrigin, forHTTPHeaderField: "X-SDK-Parent-Host")
        request.setValue(stytchSDKClientHeader(), forHTTPHeaderField: "X-SDK-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_token": sessionToken,
            "session_duration_minutes": 30,
        ])

        let (data, status) = try await response(
            for: request,
            session: session,
            nonHTTPError: .consoleAPIError("Non-HTTP response")
        )
        guard (200..<300).contains(status) else {
            let summary = String(bytes: data.prefix(300), encoding: .utf8) ?? ""
            if status == 401 || status == 403 { throw GroqUsageError.consoleAccessDenied(summary) }
            throw GroqUsageError.consoleAPIError("Stytch HTTP \(status): \(summary)")
        }
        guard let jwt = (try? JSONDecoder().decode(StytchResponse.self, from: data))?
            .data?.sessionJWT?.trimmingCharacters(in: .whitespacesAndNewlines),
            !jwt.isEmpty else {
            throw GroqUsageError.consoleParseFailed("Stytch response missing session_jwt")
        }
        return jwt
    }

    private static func fetchActivity(
        sessionJWT: String,
        historyDays: Int,
        environment: [String: String],
        session: URLSession,
        now: Date
    ) async throws -> GroqConsoleUsageSnapshot {
        let token = sessionJWT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GroqUsageError.missingSession }
        guard let organizationID = organizationID(fromJWT: token) else {
            throw GroqUsageError.invalidSession("session token is missing the organization claim")
        }
        let days = max(1, min(365, historyDays))
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? startOfToday
        let base = try resolvedAPIURL(environment: environment)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GroqUsageError.invalidSession("could not build activity URL")
        }
        components.path = "/platform/v1/organizations/\(organizationID)/activity"
        components.queryItems = [
            URLQueryItem(name: "start_date", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_date", value: String(Int(end.timeIntervalSince1970))),
        ]
        guard let url = components.url else {
            throw GroqUsageError.invalidSession("could not build activity URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await response(
            for: request,
            session: session,
            nonHTTPError: .consoleAPIError("Non-HTTP response")
        )
        guard (200..<300).contains(status) else {
            let summary = responseSummary(data)
            if status == 401 || status == 403 { throw GroqUsageError.consoleAccessDenied(summary) }
            throw GroqUsageError.consoleAPIError("HTTP \(status): \(summary)")
        }
        return try parseActivity(data, historyDays: days, updatedAt: now, calendar: calendar)
    }

    private static func fetchMetrics(
        apiKey: String,
        session: URLSession,
        environment: [String: String],
        now: Date
    ) async throws -> GroqMetricsUsageSnapshot {
        let baseURL = try resolvedAPIURL(environment: environment)
            .appendingPathComponent("metrics")
            .appendingPathComponent("prometheus")
        async let requests = queryScalar(
            "sum(model_project_id_status_code:requests:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            session: session
        )
        async let input = queryScalar(
            "sum(model_project_id:tokens_in:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            session: session
        )
        async let output = queryScalar(
            "sum(model_project_id:tokens_out:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            session: session
        )
        async let cache = queryScalar(
            "sum(model_project_id:prompt_cache_hits:rate5m)",
            apiKey: apiKey,
            baseURL: baseURL,
            session: session
        )
        return try await GroqMetricsUsageSnapshot(
            requestRatePerSecond: requests,
            inputTokenRatePerSecond: input,
            outputTokenRatePerSecond: output,
            promptCacheHitRatePerSecond: cache,
            updatedAt: now
        )
    }

    private static func queryScalar(
        _ query: String,
        apiKey: String,
        baseURL: URL,
        session: URLSession
    ) async throws -> Double {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/query"),
            resolvingAgainstBaseURL: false
        ) else { throw GroqUsageError.invalidEndpoint(apiURLEnvironmentKey) }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw GroqUsageError.invalidEndpoint(apiURLEnvironmentKey) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await response(
            for: request,
            session: session,
            nonHTTPError: .metricsAPIError("Non-HTTP response")
        )
        guard (200..<300).contains(status) else {
            let summary = responseSummary(data)
            if status == 401 || status == 403 { throw GroqUsageError.metricsAccessDenied(summary) }
            throw GroqUsageError.metricsAPIError("HTTP \(status): \(summary)")
        }
        return try parsePrometheusScalar(data)
    }

    private static func response(
        for request: URLRequest,
        session: URLSession,
        nonHTTPError: GroqUsageError
    ) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw nonHTTPError
        }
        return (data, http.statusCode)
    }

    private static func makeConsoleSnapshot(
        rows: [ActivityRow],
        historyDays: Int,
        updatedAt: Date,
        calendar: Calendar
    ) -> GroqConsoleUsageSnapshot {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var byDay: [String: DayAccumulator] = [:]
        var organizationName: String?
        for row in rows {
            if organizationName == nil, let name = row.organizationName, !name.isEmpty { organizationName = name }
            let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: row.timestamp))
            let key = formatter.string(from: dayStart)
            let modelName = row.model?.isEmpty == false ? row.model! : "unknown"
            let context = row.contextTokens ?? 0
            let nonCached = row.nonCachedContextTokens ?? context
            let cached = max(0, context - nonCached)
            let generated = row.generatedTokens ?? 0
            var day = byDay[key] ?? DayAccumulator(startTime: dayStart, models: [:])
            var model = day.models[modelName] ?? ModelAccumulator()
            model.requests += row.requests ?? 0
            model.inputTokens += nonCached
            model.cachedInputTokens += cached
            model.outputTokens += generated
            model.totalTokens += context + generated
            model.costUSD += row.cost ?? 0
            day.models[modelName] = model
            byDay[key] = day
        }
        let buckets = byDay.map { key, day in
            let models = day.models.map { name, value in
                GroqConsoleUsageSnapshot.ModelBreakdown(
                    name: name,
                    requests: value.requests,
                    inputTokens: value.inputTokens,
                    cachedInputTokens: value.cachedInputTokens,
                    outputTokens: value.outputTokens,
                    totalTokens: value.totalTokens,
                    costUSD: value.costUSD
                )
            }.sorted { $0.totalTokens > $1.totalTokens }
            return GroqConsoleUsageSnapshot.DailyBucket(
                day: key,
                startTime: day.startTime,
                endTime: calendar.date(byAdding: .day, value: 1, to: day.startTime) ?? day.startTime,
                costUSD: models.reduce(0) { $0 + $1.costUSD },
                requests: models.reduce(0) { $0 + $1.requests },
                inputTokens: models.reduce(0) { $0 + $1.inputTokens },
                cachedInputTokens: models.reduce(0) { $0 + $1.cachedInputTokens },
                outputTokens: models.reduce(0) { $0 + $1.outputTokens },
                totalTokens: models.reduce(0) { $0 + $1.totalTokens },
                models: models
            )
        }
        return GroqConsoleUsageSnapshot(
            daily: buckets,
            updatedAt: updatedAt,
            historyDays: historyDays,
            organizationName: organizationName
        )
    }

    private static func normalizedHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: hasExplicitURLScheme(raw) ? raw : "https://\(raw)"),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased()
        else { return nil }
        if decodedHost.contains(":") {
            guard encodedHost == decodedHost,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["), componentHost.hasSuffix("]") else { return nil }
        } else {
            let delimiters = CharacterSet(charactersIn: "/\\?#@:")
            guard decodedHost.rangeOfCharacter(from: delimiters) == nil else { return nil }
            for delimiter in ["%2f", "%5c", "%3f", "%23", "%40", "%3a"]
                where encodedHost.contains(delimiter) { return nil }
        }
        return url
    }

    private static func hasExplicitURLScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }),
           colon > authorityEnd { return false }
        let afterColon = raw.index(after: colon)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { ["/", "?", "#"].contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0)
        }
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: value)
    }

    private static func stytchSDKClientHeader() -> String {
        let blob = "{\"app\":{\"identifier\":\"console.groq.com\"},"
            + "\"sdk\":{\"identifier\":\"Stytch.js Javascript SDK\",\"version\":\"\(stytchSDKVersion)\"}}"
        return Data(blob.utf8).base64EncodedString()
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func shouldFallbackToMetrics(_ error: Error) -> Bool {
        switch error as? GroqUsageError {
        case .missingSession, .invalidSession, .consoleAccessDenied: true
        default: false
        }
    }

    private static func shouldRetryNextSession(_ error: Error) -> Bool {
        switch error as? GroqUsageError {
        case .invalidSession, .consoleAccessDenied: true
        default: false
        }
    }

    private static func mergedLabel(_ sources: [BrowserCookieStoreRecords]) -> String {
        guard let label = sources.map({ $0.label }).min() else { return "Unknown" }
        return label.hasSuffix(" (Network)")
            ? String(label.dropLast(" (Network)".count))
            : label
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }

    private static func deduplicated(_ sessions: [GroqConsoleSessionInfo]) -> [GroqConsoleSessionInfo] {
        var result: [GroqConsoleSessionInfo] = []
        for session in sessions where !result.contains(where: { $0.cookieHeader == session.cookieHeader }) {
            result.append(session)
        }
        return result
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

private nonisolated struct ActivityResponse: Decodable {
    let data: [ActivityRow]
}

private nonisolated struct ActivityRow: Decodable {
    let organizationName: String?
    let model: String?
    let timestamp: Double
    let requests: Int?
    let contextTokens: Int?
    let nonCachedContextTokens: Int?
    let generatedTokens: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case organizationName = "organization_name"
        case model, timestamp, cost
        case requests = "num_requests"
        case contextTokens = "n_context_tokens_total"
        case nonCachedContextTokens = "n_non_cached_context_tokens_total"
        case generatedTokens = "n_generated_tokens_total"
    }
}

private nonisolated struct StytchResponse: Decodable {
    struct Payload: Decodable {
        let sessionJWT: String?
        enum CodingKeys: String, CodingKey { case sessionJWT = "session_jwt" }
    }
    let data: Payload?
}

private nonisolated struct PrometheusResponse: Decodable {
    struct Payload: Decodable { let result: [Series] }
    struct Series: Decodable { let value: [PrometheusValue]? }
    enum PrometheusValue: Decodable {
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = try .string(container.decode(String.self))
            }
        }

        var doubleValue: Double? {
            switch self {
            case let .number(value): value
            case let .string(value): Double(value)
            }
        }
    }
    let status: String
    let data: Payload?
    let error: String?
}

private nonisolated struct ModelAccumulator {
    var requests = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var costUSD = 0.0
}

private nonisolated struct DayAccumulator {
    var startTime: Date
    var models: [String: ModelAccumulator]
}

nonisolated final class GroqImportSessionCache: @unchecked Sendable {
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entry: (sessions: [GroqConsoleSessionInfo], expiresAt: Date)?

    init(ttl: TimeInterval) { self.ttl = ttl }

    func sessions(
        now: Date = Date(),
        load: () -> [GroqConsoleSessionInfo]
    ) -> [GroqConsoleSessionInfo] {
        lock.lock()
        if let entry, entry.expiresAt > now {
            lock.unlock()
            return entry.sessions
        }
        lock.unlock()
        let loaded = load()
        lock.lock()
        entry = (loaded, now.addingTimeInterval(ttl))
        lock.unlock()
        return loaded
    }

    func invalidate() {
        lock.withLock { entry = nil }
    }
}
