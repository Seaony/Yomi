import Foundation
import SQLite3
import SweetCookieKit

enum FactoryUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case unauthorized
    case noSession
    case requestFailed(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text(
                "未找到 Droid API Key（FACTORY_API_KEY 或 ~/.factory/.env）",
                "No Droid API key found (FACTORY_API_KEY or ~/.factory/.env)"
            )
        case .unauthorized:
            AppLocalization.text(
                "Droid 认证失败，请更新 API Key 或重新登录 app.factory.ai",
                "Droid authentication failed; update the API key or sign in to app.factory.ai again"
            )
        case .noSession:
            AppLocalization.text(
                "未找到可用的 Droid 浏览器会话",
                "No usable Droid browser session was found"
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Droid 请求失败（HTTP \(status)）",
                "Droid request failed (HTTP \(status))"
            )
        case .unreadableResponse:
            AppLocalization.text(
                "无法解析 Droid 用量数据",
                "Could not parse Droid usage data"
            )
        }
    }
}

nonisolated enum FactoryUsageFetcher {
    private static let appBaseURL = URL(string: "https://app.factory.ai")!
    private static let authBaseURL = URL(string: "https://auth.factory.ai")!
    private static let apiBaseURL = URL(string: "https://api.factory.ai")!
    private static let workOSURL = URL(string: "https://api.workos.com/user_management/authenticate")!
    private static let workOSClientIDs = [
        "client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7",
        "client_01HNM792M5G5G1A2THWPXKFMXB",
    ]
    private static let factoryCookieDomains = ["factory.ai", "app.factory.ai", "auth.factory.ai"]
    private static let sessionCookieNames: Set<String> = [
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "__Host-authjs.csrf-token",
        "authjs.session-token",
        "session",
        "access-token",
    ]
    private static let authSessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
    ]
    private static let staleTokenCookieNames: Set<String> = ["access-token", "__recent_auth"]
    private static let legacySessionCookieNames: Set<String> = ["session", "wos-session"]

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let credential = clean(rawCredential)
        switch source {
        case .token:
            guard !credential.isEmpty else { throw FactoryUsageError.missingAPIKey }
            return try await fetch(apiKey: credential, session: session, now: now)
        case .cookie:
            guard let manual = manualCredentials(credential) else { throw FactoryUsageError.noSession }
            return try await fetch(manual: manual, session: session, now: now)
        case .automatic, .account, .command, .endpoint:
            let apiKey = !credential.isEmpty && manualCredentials(credential)?.cookieHeader == nil
                ? credential
                : resolvedAPIKey()
            if let apiKey, !apiKey.isEmpty {
                do {
                    return try await fetch(apiKey: apiKey, session: session, now: now)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    // Automatic mode follows Droid's API-first, web-fallback policy.
                }
            }
            if !credential.isEmpty, let manual = manualCredentials(credential) {
                return try await fetch(manual: manual, session: session, now: now)
            }
            return try await fetchWeb(session: session, now: now)
        }
    }

    static func fetch(apiKey rawKey: String, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        let apiKey = clean(rawKey)
        guard !apiKey.isEmpty else { throw FactoryUsageError.missingAPIKey }
        var lastError: Error?
        var authenticationError: Error?
        for baseURL in unique([apiBaseURL, appBaseURL]) {
            do {
                return try await fetchAuthenticated(
                    cookieHeader: "",
                    bearerToken: apiKey,
                    baseURL: baseURL,
                    session: session,
                    now: now
                )
            } catch FactoryUsageError.unauthorized {
                authenticationError = FactoryUsageError.unauthorized
                lastError = FactoryUsageError.unauthorized
            } catch {
                lastError = error
            }
        }
        if let authenticationError { throw authenticationError }
        throw lastError ?? FactoryUsageError.unauthorized
    }

    static func parseBillingLimits(
        data: Data,
        authData: Data,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let billing: BillingLimitsResponse
        let auth: AuthResponse
        do {
            billing = try decoder.decode(BillingLimitsResponse.self, from: data)
            auth = try decoder.decode(AuthResponse.self, from: authData)
        } catch {
            throw FactoryUsageError.unreadableResponse
        }
        guard billing.usesTokenRateLimitsBilling, let limits = billing.limits else {
            throw FactoryUsageError.unreadableResponse
        }
        return makeRateLimitUsage(billing: billing, limits: limits, auth: auth, now: now)
    }

    static func parseLegacyUsage(
        data: Data,
        authData: Data,
        bearerToken: String? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let response: LegacyUsageResponse
        let auth: AuthResponse
        do {
            response = try decoder.decode(LegacyUsageResponse.self, from: data)
            auth = try decoder.decode(AuthResponse.self, from: authData)
        } catch {
            throw FactoryUsageError.unreadableResponse
        }
        return makeLegacyUsage(response: response, auth: auth, bearerToken: bearerToken, now: now)
    }

    static func resolvedAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        if let value = cleanedValue(environment["FACTORY_API_KEY"]) { return value }
        let file = homeDirectory.appending(path: ".factory/.env")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \ .isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "FACTORY_API_KEY" else { continue }
            return cleanedValue(String(line[line.index(after: separator)...]))
        }
        return nil
    }

    static func clean(_ raw: String) -> String {
        cleanedValue(raw) ?? ""
    }

    static func manualCredentials(_ raw: String?) -> ManualCredentials? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let authorization = capture(
            #"(?i)(?:authorization\s*:\s*)?bearer\s+([A-Za-z0-9._~+/=-]+)"#,
            in: raw
        )
        let cookieText = raw
            .replacingOccurrences(
                of: #"(?im)^\s*authorization\s*:\s*bearer\s+[^\r\n]+\s*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)^\s*cookie\s*:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = cookiePairs(cookieText)
        let cookieHeader = pairs.isEmpty ? nil : pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let accessToken = pairs.first(where: { $0.name == "access-token" })?.value
        let bareToken: String? = {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.contains("="), !token.contains(";"), !token.contains(" "), !token.contains("\n"),
                  token.count >= 40 || token.split(separator: ".").count >= 3
            else { return nil }
            return token
        }()
        let bearer = authorization ?? accessToken ?? bareToken
        guard cookieHeader != nil || bearer != nil else { return nil }
        return ManualCredentials(cookieHeader: cookieHeader, bearerToken: bearer)
    }

    private static func fetchWeb(session: URLSession, now: Date) async throws -> ProviderUsage {
        var lastError: Error?
        if let stored = await FactorySessionStore.shared.load() {
            if let cookie = stored.cookieHeader {
                do {
                    return try await fetchCookieHeader(
                        cookie,
                        bearerToken: bearerToken(cookieHeader: cookie),
                        baseURLs: [appBaseURL],
                        session: session,
                        now: now
                    )
                } catch FactoryUsageError.unauthorized {
                    await FactorySessionStore.shared.clearCookieHeader()
                    lastError = FactoryUsageError.unauthorized
                } catch {
                    lastError = error
                }
            }
            if let bearer = stored.bearerToken {
                do {
                    return try await fetch(apiKey: bearer, session: session, now: now)
                } catch {
                    lastError = error
                }
            }
            if let refresh = stored.refreshToken {
                do {
                    return try await fetchWithWorkOSRefreshToken(
                        refresh,
                        organizationID: nil,
                        session: session,
                        now: now
                    )
                } catch {
                    lastError = error
                }
            }
        }

        for token in FactoryLocalStorageImporter.importTokens() {
            if let access = token.accessToken {
                do {
                    await FactorySessionStore.shared.set(bearerToken: access)
                    return try await fetch(apiKey: access, session: session, now: now)
                } catch {
                    lastError = error
                }
            }
            do {
                return try await fetchWithWorkOSRefreshToken(
                    token.refreshToken,
                    organizationID: token.organizationID,
                    session: session,
                    now: now
                )
            } catch {
                lastError = error
            }
        }

        let browserAttempts: [(factory: Bool, browsers: [Browser])] = [
            (true, [.safari]),
            (false, [.safari]),
            (true, [.chrome, .firefox]),
            (false, [.chrome, .firefox]),
        ]
        for attempt in browserAttempts {
            if attempt.factory {
                for cookies in importedCookieSessions(domains: factoryCookieDomains, browsers: attempt.browsers) {
                    let header = cookieHeader(cookies)
                    guard cookies.contains(where: { sessionCookieNames.contains($0.name) }) else { continue }
                    do {
                        let usage = try await fetchCookies(cookies, session: session, now: now)
                        await FactorySessionStore.shared.set(cookieHeader: header)
                        return usage
                    } catch {
                        lastError = error
                    }
                }
            } else {
                for cookies in importedCookieSessions(domains: ["workos.com"], browsers: attempt.browsers) {
                    do {
                        let auth = try await authenticateWorkOS(cookies: cookies, session: session)
                        await FactorySessionStore.shared.set(
                            bearerToken: auth.accessToken,
                            refreshToken: auth.refreshToken
                        )
                        return try await fetch(apiKey: auth.accessToken, session: session, now: now)
                    } catch {
                        lastError = error
                    }
                }
            }
        }
        throw lastError ?? FactoryUsageError.noSession
    }

    private static func fetch(manual: ManualCredentials, session: URLSession, now: Date) async throws -> ProviderUsage {
        var lastError: Error?
        if let cookieHeader = manual.cookieHeader {
            do {
                return try await fetchCookieHeader(
                    cookieHeader,
                    bearerToken: manual.bearerToken,
                    baseURLs: [appBaseURL, authBaseURL, apiBaseURL],
                    session: session,
                    now: now
                )
            } catch {
                lastError = error
            }
        }
        if let bearerToken = manual.bearerToken {
            return try await fetch(apiKey: bearerToken, session: session, now: now)
        }
        throw lastError ?? FactoryUsageError.noSession
    }

    private static func fetchCookies(
        _ cookies: [HTTPCookie],
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let domains = Set(cookies.map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var baseURLs: [URL] = []
        if domains.contains("auth.factory.ai") { baseURLs.append(authBaseURL) }
        baseURLs.append(contentsOf: [apiBaseURL, appBaseURL])
        let header = cookieHeader(cookies)
        let bearer = bearerToken(cookies: cookies)
        var lastError: Error?
        for baseURL in unique(baseURLs) {
            do {
                return try await fetchCookieHeader(
                    header,
                    bearerToken: bearer,
                    baseURLs: [baseURL],
                    cookies: cookies,
                    session: session,
                    now: now
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FactoryUsageError.noSession
    }

    private static func fetchCookieHeader(
        _ cookieHeader: String,
        bearerToken: String?,
        baseURLs: [URL],
        cookies: [HTTPCookie]? = nil,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var lastError: Error?
        for baseURL in unique(baseURLs) {
            do {
                return try await fetchAuthenticated(
                    cookieHeader: cookieHeader,
                    bearerToken: bearerToken,
                    baseURL: baseURL,
                    session: session,
                    now: now
                )
            } catch FactoryUsageError.unauthorized where bearerToken != nil {
                do {
                    return try await fetchAuthenticated(
                        cookieHeader: cookieHeader,
                        bearerToken: nil,
                        baseURL: baseURL,
                        session: session,
                        now: now
                    )
                } catch {
                    lastError = error
                }
            } catch FactoryUsageError.requestFailed(409) {
                guard let cookies else {
                    lastError = FactoryUsageError.requestFailed(409)
                    continue
                }
                let filters: [(HTTPCookie) -> Bool] = [
                    { !staleTokenCookieNames.contains($0.name) },
                    { !legacySessionCookieNames.contains($0.name) },
                    { !staleTokenCookieNames.contains($0.name) && !legacySessionCookieNames.contains($0.name) },
                    { authSessionCookieNames.contains($0.name) || $0.name == "__Host-authjs.csrf-token" },
                ]
                for filter in filters {
                    let filtered = cookies.filter(filter)
                    guard !filtered.isEmpty, filtered.count < cookies.count else { continue }
                    do {
                        return try await fetchAuthenticated(
                            cookieHeader: Self.cookieHeader(filtered),
                            bearerToken: Self.bearerToken(cookies: filtered),
                            baseURL: baseURL,
                            session: session,
                            now: now
                        )
                    } catch {
                        lastError = error
                    }
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FactoryUsageError.noSession
    }

    private static func fetchAuthenticated(
        cookieHeader: String,
        bearerToken: String?,
        baseURL: URL,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let authRequest = request(
            url: baseURL.appending(path: "api/app/auth/me"),
            cookieHeader: cookieHeader,
            bearerToken: bearerToken
        )
        let authData = try await responseData(authRequest, session: session)
        let auth: AuthResponse
        do {
            auth = try decoder.decode(AuthResponse.self, from: authData)
        } catch {
            throw FactoryUsageError.unreadableResponse
        }
        let userID = cleanedValue(auth.userProfile?.id) ?? jwtSubject(bearerToken)

        if let billingData = try? await optionalBillingLimits(
            cookieHeader: cookieHeader,
            bearerToken: bearerToken,
            session: session
        ), let billing = try? decoder.decode(BillingLimitsResponse.self, from: billingData),
           billing.usesTokenRateLimitsBilling, let limits = billing.limits {
            return makeRateLimitUsage(billing: billing, limits: limits, auth: auth, now: now)
        }

        var components = URLComponents(
            url: baseURL.appending(path: "api/organization/subscription/usage"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "useCache", value: "true")]
        if let userID { components?.queryItems?.append(URLQueryItem(name: "userId", value: userID)) }
        guard let usageURL = components?.url else { throw FactoryUsageError.unreadableResponse }
        let usageData = try await responseData(
            request(url: usageURL, cookieHeader: cookieHeader, bearerToken: bearerToken),
            session: session
        )
        let response: LegacyUsageResponse
        do {
            response = try decoder.decode(LegacyUsageResponse.self, from: usageData)
        } catch {
            throw FactoryUsageError.unreadableResponse
        }
        return makeLegacyUsage(response: response, auth: auth, bearerToken: bearerToken, now: now)
    }

    private static func optionalBillingLimits(
        cookieHeader: String,
        bearerToken: String?,
        session: URLSession
    ) async throws -> Data {
        try await responseData(
            request(
                url: apiBaseURL.appending(path: "api/billing/limits"),
                cookieHeader: cookieHeader,
                bearerToken: bearerToken
            ),
            session: session
        )
    }

    private static func request(url: URL, cookieHeader: String, bearerToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func responseData(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FactoryUsageError.unreadableResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw FactoryUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw FactoryUsageError.requestFailed(http.statusCode) }
        return data
    }

    private static func makeRateLimitUsage(
        billing: BillingLimitsResponse,
        limits: TokenRateLimits,
        auth: AuthResponse,
        now: Date
    ) -> ProviderUsage {
        let windows = [
            limits.standard.fiveHour.usageWindow(id: "factory-5h", label: "5-hour", now: now),
            limits.standard.weekly.usageWindow(id: "factory-weekly", label: "Weekly", now: now),
            limits.standard.monthly.usageWindow(id: "factory-monthly", label: "Monthly", now: now),
        ]
        let additional: [UsageWindow]
        if let core = limits.core, core.hasUsageData {
            additional = [
                core.fiveHour.usageWindow(id: "factory-core-5h", label: "Core 5h", now: now),
                core.weekly.usageWindow(id: "factory-core-7d", label: "Core 7-day", now: now),
                core.monthly.usageWindow(id: "factory-core-monthly", label: "Core Monthly", now: now),
            ]
        } else {
            additional = []
        }
        let balance = Double(billing.extraUsageBalanceCents) / 100
        let plan = displayPlan(auth: auth, overagePreference: billing.overagePreference)
        return ProviderUsage(
            id: ProviderID(rawValue: "factory"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: String(format: "$%.2f", balance),
            plan: plan,
            providerCost: ProviderCostSummary(
                used: balance,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                balance: balance
            ),
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    private static func makeLegacyUsage(
        response: LegacyUsageResponse,
        auth: AuthResponse,
        bearerToken: String?,
        now: Date
    ) -> ProviderUsage {
        let periodEnd = response.usage?.endDate.map(millisecondsDate)
        let standard = response.usage?.standard
        let premium = response.usage?.premium
        return ProviderUsage(
            id: ProviderID(rawValue: "factory"),
            state: .ready,
            windows: [
                UsageWindow(
                    id: "factory-standard",
                    label: "Standard",
                    usedFraction: legacyFraction(standard),
                    resetsAt: periodEnd,
                    detail: legacyDetail(standard)
                ),
                UsageWindow(
                    id: "factory-premium",
                    label: "Premium",
                    usedFraction: legacyFraction(premium),
                    resetsAt: periodEnd,
                    detail: legacyDetail(premium)
                ),
            ],
            balance: nil,
            plan: displayPlan(auth: auth, overagePreference: nil),
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    private static func legacyFraction(_ usage: TokenUsage?) -> Double {
        let used = usage?.userTokens ?? 0
        let allowance = usage?.totalAllowance ?? 0
        let unlimitedThreshold: Int64 = 1_000_000_000_000
        if let ratio = usage?.usedRatio, ratio.isFinite,
           !(ratio == 0 && used > 0 && allowance > 0 && allowance <= unlimitedThreshold) {
            if ratio >= -0.001, ratio <= 1.001 { return min(1, max(0, ratio)) }
            let allowanceReliable = allowance > 0 && allowance <= unlimitedThreshold
            if !allowanceReliable, ratio >= -0.1, ratio <= 100.1 { return min(1, max(0, ratio / 100)) }
        }
        if allowance > unlimitedThreshold { return min(1, Double(used) / 100_000_000) }
        guard allowance > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(allowance)))
    }

    private static func legacyDetail(_ usage: TokenUsage?) -> String? {
        guard let usage else { return nil }
        return "\(usage.userTokens ?? 0) / \(usage.totalAllowance ?? 0) tokens used"
    }

    private static func displayPlan(auth: AuthResponse, overagePreference _: String?) -> String? {
        var parts: [String] = []
        if let tier = cleanedValue(auth.organization?.subscription?.factoryTier) {
            parts.append("Factory \(tier.capitalized)")
        }
        if let plan = cleanedValue(auth.organization?.subscription?.orbSubscription?.plan?.name),
           !plan.lowercased().contains("factory") {
            parts.append(plan)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    private static func fetchWithWorkOSRefreshToken(
        _ refreshToken: String,
        organizationID: String?,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let auth = try await authenticateWorkOS(
            refreshToken: refreshToken,
            organizationID: organizationID,
            session: session
        )
        await FactorySessionStore.shared.set(
            bearerToken: auth.accessToken,
            refreshToken: auth.refreshToken
        )
        return try await fetch(apiKey: auth.accessToken, session: session, now: now)
    }

    private static func authenticateWorkOS(
        refreshToken: String,
        organizationID: String?,
        session: URLSession
    ) async throws -> WorkOSAuthResponse {
        var lastError: Error?
        for clientID in workOSClientIDs {
            var body: [String: Any] = [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
            if let organizationID { body["organization_id"] = organizationID }
            do {
                return try await authenticateWorkOS(body: body, cookieHeader: nil, session: session)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FactoryUsageError.unauthorized
    }

    private static func authenticateWorkOS(
        cookies: [HTTPCookie],
        session: URLSession
    ) async throws -> WorkOSAuthResponse {
        var lastError: Error?
        for clientID in workOSClientIDs {
            do {
                return try await authenticateWorkOS(
                    body: ["client_id": clientID, "grant_type": "refresh_token", "useCookie": true],
                    cookieHeader: cookieHeader(cookies),
                    session: session
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FactoryUsageError.unauthorized
    }

    private static func authenticateWorkOS(
        body: [String: Any],
        cookieHeader: String?,
        session: URLSession
    ) async throws -> WorkOSAuthResponse {
        var request = URLRequest(url: workOSURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await responseData(request, session: session)
        do {
            return try decoder.decode(WorkOSAuthResponse.self, from: data)
        } catch {
            throw FactoryUsageError.unreadableResponse
        }
    }

    private static func importedCookieSessions(domains: [String], browsers: [Browser]) -> [[HTTPCookie]] {
        let query = BrowserCookieQuery(domains: domains)
        let client = BrowserCookieClient()
        var sessions: [[HTTPCookie]] = []
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if !cookies.isEmpty { sessions.append(cookies) }
            }
        }
        return sessions
    }

    private static func cookiePairs(_ raw: String) -> [(name: String, value: String)] {
        raw.split(separator: ";").compactMap { component in
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value)
        }
    }

    private static func bearerToken(cookieHeader: String) -> String? {
        cookiePairs(cookieHeader).first(where: { $0.name == "access-token" })?.value
    }

    private static func bearerToken(cookies: [HTTPCookie]) -> String? {
        let access = cookies.first(where: { $0.name == "access-token" })?.value
        let auth = cookies.first(where: { authSessionCookieNames.contains($0.name) })?.value
        let legacy = cookies.first(where: { $0.name == "session" })?.value
        if let access, access.contains(".") { return access }
        if let auth, auth.contains(".") { return auth }
        if let legacy, legacy.contains(".") { return legacy }
        return access ?? auth
    }

    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func millisecondsDate(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }

    private static func cleanedValue(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'" {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func jwtSubject(_ token: String?) -> String? {
        jwtString(token, key: "sub")
    }

    private static func jwtString(_ token: String?, key: String) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return cleanedValue(object[key] as? String)
    }

    private static let decoder = JSONDecoder()

    struct ManualCredentials {
        let cookieHeader: String?
        let bearerToken: String?
    }

    struct AuthResponse: Decodable {
        let organization: Organization?
        let userProfile: UserProfile?
    }

    struct Organization: Decodable {
        let name: String?
        let subscription: Subscription?
    }

    struct Subscription: Decodable {
        let factoryTier: String?
        let orbSubscription: OrbSubscription?
    }

    struct OrbSubscription: Decodable {
        let plan: Plan?
    }

    struct Plan: Decodable {
        let name: String?
    }

    struct UserProfile: Decodable {
        let id: String?
        let email: String?
    }

    struct BillingLimitsResponse: Decodable {
        let usesTokenRateLimitsBilling: Bool
        let limits: TokenRateLimits?
        let extraUsageBalanceCents: Int
        let overagePreference: String?

        private enum CodingKeys: String, CodingKey {
            case usesTokenRateLimitsBilling, limits, extraUsageBalanceCents, overagePreference
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            usesTokenRateLimitsBilling = try values.decodeIfPresent(Bool.self, forKey: .usesTokenRateLimitsBilling) ?? false
            limits = try values.decodeIfPresent(TokenRateLimits.self, forKey: .limits)
            extraUsageBalanceCents = try values.decodeIfPresent(Int.self, forKey: .extraUsageBalanceCents) ?? 0
            overagePreference = try values.decodeIfPresent(String.self, forKey: .overagePreference)
        }
    }

    struct TokenRateLimits: Decodable {
        let standard: LimitPool
        let core: LimitPool?
    }

    struct LimitPool: Decodable {
        let fiveHour: BillingWindow
        let weekly: BillingWindow
        let monthly: BillingWindow

        var hasUsageData: Bool {
            [fiveHour, weekly, monthly].contains {
                $0.usedPercent > 0 || $0.windowEnd != nil || $0.secondsRemaining != nil
            }
        }
    }

    struct BillingWindow: Decodable {
        let usedPercent: Double
        let windowEnd: FlexibleDate?
        let secondsRemaining: Double?

        func usageWindow(id: String, label: String, now: Date) -> UsageWindow {
            let reset: Date? = if let secondsRemaining, secondsRemaining > 0 {
                now.addingTimeInterval(secondsRemaining)
            } else if let end = windowEnd?.date, end > now {
                end
            } else {
                nil
            }
            let stale = reset == nil && windowEnd != nil && secondsRemaining == nil
            return UsageWindow(
                id: id,
                label: label,
                usedFraction: stale ? 0 : min(1, max(0, usedPercent / 100)),
                resetsAt: reset,
                detail: nil
            )
        }
    }

    struct FlexibleDate: Decodable {
        let date: Date

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) {
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
                return
            }
            let text = try value.decode(String.self)
            if let number = Double(text) {
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
                return
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw FactoryUsageError.unreadableResponse
            }
            date = parsed
        }
    }

    struct LegacyUsageResponse: Decodable {
        let usage: LegacyUsageData?
        let userId: String?
    }

    struct LegacyUsageData: Decodable {
        let startDate: Int64?
        let endDate: Int64?
        let standard: TokenUsage?
        let premium: TokenUsage?
    }

    struct TokenUsage: Decodable {
        let userTokens: Int64?
        let orgTotalTokensUsed: Int64?
        let totalAllowance: Int64?
        let usedRatio: Double?
    }

    struct WorkOSAuthResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let organizationID: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case organizationID = "organization_id"
        }
    }
}

private actor FactorySessionStore {
    static let shared = FactorySessionStore()

    struct Snapshot: Codable {
        var cookieHeader: String?
        var bearerToken: String?
        var refreshToken: String?
    }

    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Yomi/factory-session.json")
    private var snapshot: Snapshot?
    private var loaded = false

    func load() -> Snapshot? {
        loadIfNeeded()
        return snapshot
    }

    func set(cookieHeader: String? = nil, bearerToken: String? = nil, refreshToken: String? = nil) {
        loadIfNeeded()
        var value = snapshot ?? Snapshot()
        if let cookieHeader { value.cookieHeader = cookieHeader }
        if let bearerToken { value.bearerToken = bearerToken }
        if let refreshToken { value.refreshToken = refreshToken }
        snapshot = value
        save()
    }

    func clearCookieHeader() {
        loadIfNeeded()
        snapshot?.cookieHeader = nil
        save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func save() {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private nonisolated enum FactoryLocalStorageImporter {
    struct Token {
        let refreshToken: String
        let accessToken: String?
        let organizationID: String?
    }

    static func importTokens() -> [Token] {
        var results: [Token] = []
        var seen = Set<String>()
        for database in safariDatabases() {
            guard let token = readSafariDatabase(database), seen.insert(token.refreshToken).inserted else { continue }
            results.append(token)
        }
        for directory in chromiumLevelDBDirectories() {
            guard let token = readLevelDB(directory), seen.insert(token.refreshToken).inserted else { continue }
            results.append(token)
        }
        return results
    }

    private static func chromiumLevelDBDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support")
        let roots = [
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Canary",
            "Arc/User Data",
            "Arc Beta/User Data",
            "Arc Canary/User Data",
            "Dia/User Data",
            "com.openai.atlas/browser-data/host",
            "Chromium",
            "net.imput.helium",
        ]
        var results: [URL] = []
        for relative in roots {
            let root = support.appending(path: relative, directoryHint: .isDirectory)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for profile in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }
                let levelDB = profile.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: levelDB.path) { results.append(levelDB) }
            }
        }
        return results
    }

    private static func safariDatabases() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent == "origin" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  text.contains("app.factory.ai") || text.contains("auth.factory.ai")
            else { continue }
            let database = file.deletingLastPathComponent()
                .appending(path: "LocalStorage/localstorage.sqlite3")
            if FileManager.default.fileExists(atPath: database.path) { results.append(database) }
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.path).inserted }
    }

    private static func readLevelDB(_ directory: URL) -> Token? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries.filter { ["ldb", "log"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for file in files {
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let token = token(text)
            else { continue }
            return token
        }
        return nil
    }

    private static func readSafariDatabase(_ database: URL) -> Token? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if connection != nil { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 250)
        let tables = tableNames(connection)
        let table = tables.contains("ItemTable") ? "ItemTable" : tables.contains("localstorage") ? "localstorage" : nil
        guard let table,
              let refresh = localStorageValue(connection, table: table, key: "workos:refresh-token"),
              !refresh.isEmpty
        else { return nil }
        let access = localStorageValue(connection, table: table, key: "workos:access-token")
        return Token(refreshToken: refresh, accessToken: access, organizationID: jwtOrganizationID(access))
    }

    private static func tableNames(_ connection: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "SELECT name FROM sqlite_master WHERE type='table'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { names.insert(String(cString: value)) }
        }
        return names
    }

    private static func localStorageValue(
        _ connection: OpaquePointer?,
        table: String,
        key: String
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "SELECT value FROM \(table) WHERE key = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            guard let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return String(data: data, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: .controlCharacters)
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
                ?? String(data: data, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters)
        default:
            return nil
        }
    }

    private static func token(_ text: String) -> Token? {
        guard text.contains("workos:refresh-token"),
              let refresh = capture(
                #"workos:refresh-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})"#,
                in: text
              )
        else { return nil }
        let access = capture(
            #"workos:access-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})"#,
            in: text
        )
        return Token(refreshToken: refresh, accessToken: access, organizationID: jwtOrganizationID(access))
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ).last, match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func jwtOrganizationID(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["org_id"] as? String
    }
}
