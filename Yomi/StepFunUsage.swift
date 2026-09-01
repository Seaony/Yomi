import Foundation

nonisolated enum StepFunUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case loginFailed(String)
    case tokenRefreshFailed(String)
    case deviceRegistrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未找到 StepFun 凭据，请配置账号密码或 STEPFUN_USERNAME、STEPFUN_PASSWORD",
                "StepFun credentials were not found. Configure a username and password or STEPFUN_USERNAME and STEPFUN_PASSWORD."
            )
        case .missingToken:
            AppLocalization.text("未找到 StepFun Oasis-Token", "StepFun Oasis-Token was not found.")
        case let .networkError(message):
            AppLocalization.text("StepFun 网络错误：\(message)", "StepFun network error: \(message)")
        case let .apiError(message):
            AppLocalization.text("StepFun 接口错误：\(message)", "StepFun API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 StepFun 返回数据：\(message)", "Failed to parse StepFun response: \(message)")
        case let .loginFailed(message):
            AppLocalization.text("StepFun 登录失败：\(message)", "StepFun login failed: \(message)")
        case let .tokenRefreshFailed(message):
            AppLocalization.text("StepFun Token 刷新失败：\(message)", "StepFun token refresh failed: \(message)")
        case let .deviceRegistrationFailed(message):
            AppLocalization.text("StepFun 设备注册失败：\(message)", "StepFun device registration failed: \(message)")
        }
    }
}

nonisolated struct StepFunFlexibleNumber: Decodable, Sendable, Equatable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = Double(value)
        } else if let value = try? container.decode(Double.self) {
            self.value = value
        } else if let value = try? container.decode(String.self), let number = Double(value) {
            self.value = number
        } else {
            value = 0
        }
    }
}

nonisolated struct StepFunFlexibleTimestamp: Decodable, Sendable, Equatable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self), let timestamp = Int64(value) {
            self.value = timestamp
        } else if let value = try? container.decode(Int64.self) {
            self.value = value
        } else {
            value = 0
        }
    }
}

nonisolated struct StepFunPlanCreditBucket: Decodable, Sendable, Equatable {
    let creditTotal: StepFunFlexibleNumber?
    let creditResidual: StepFunFlexibleNumber?
    let expireAt: StepFunFlexibleTimestamp?
    let nextResetAt: StepFunFlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case creditTotal = "credit_total"
        case creditResidual = "credit_residual"
        case expireAt = "expire_at"
        case nextResetAt = "next_reset_at"
    }
}

nonisolated struct StepFunPlanCreditRateLimit: Decodable, Sendable, Equatable {
    let subscriptionCreditLeftRate: StepFunFlexibleNumber?
    let subscriptionCreditResetTime: StepFunFlexibleTimestamp?
    let topupCreditLeftRate: StepFunFlexibleNumber?
    let creditBuckets: [StepFunPlanCreditBucket]?

    enum CodingKeys: String, CodingKey {
        case subscriptionCreditLeftRate = "subscription_credit_left_rate"
        case subscriptionCreditResetTime = "subscription_credit_reset_time"
        case topupCreditLeftRate = "topup_credit_left_rate"
        case creditBuckets = "credit_buckets"
    }

    var totalCreditLeftRate: Double? {
        if let creditBuckets, !creditBuckets.isEmpty {
            let balances = creditBuckets.compactMap { bucket -> (total: Double, residual: Double)? in
                guard let total = bucket.creditTotal?.value,
                      let residual = bucket.creditResidual?.value,
                      total.isFinite,
                      residual.isFinite,
                      total > 0,
                      residual >= 0,
                      residual <= total
                else { return nil }
                return (total, residual)
            }
            if balances.count == creditBuckets.count {
                let total = balances.reduce(0.0) { $0 + $1.total }
                let residual = balances.reduce(0.0) { $0 + $1.residual }
                return residual / total
            }
        }
        return subscriptionCreditLeftRate?.value ?? topupCreditLeftRate?.value
    }
}

nonisolated struct StepFunRateLimitResponse: Decodable, Sendable, Equatable {
    let status: Int?
    let code: Int?
    let message: String?
    let desc: String?
    let fiveHourUsageLeftRate: StepFunFlexibleNumber?
    let weeklyUsageLeftRate: StepFunFlexibleNumber?
    let fiveHourUsageResetTime: StepFunFlexibleTimestamp?
    let weeklyUsageResetTime: StepFunFlexibleTimestamp?
    let planFamily: StepFunFlexibleNumber?
    let planCreditRateLimit: StepFunPlanCreditRateLimit?

    enum CodingKeys: String, CodingKey {
        case status
        case code
        case message
        case desc
        case fiveHourUsageLeftRate = "five_hour_usage_left_rate"
        case weeklyUsageLeftRate = "weekly_usage_left_rate"
        case fiveHourUsageResetTime = "five_hour_usage_reset_time"
        case weeklyUsageResetTime = "weekly_usage_reset_time"
        case planFamily = "plan_family"
        case planCreditRateLimit = "plan_credit_rate_limit"
    }

    var isSuccess: Bool { status == 1 }

    var isCreditPlan: Bool {
        let hasLiveWindow = (fiveHourUsageResetTime?.value ?? 0) > 0
            || (weeklyUsageResetTime?.value ?? 0) > 0
        if hasLiveWindow { return false }
        let hasCreditPool = planCreditRateLimit?.subscriptionCreditLeftRate != nil
            || planCreditRateLimit?.topupCreditLeftRate != nil
            || !(planCreditRateLimit?.creditBuckets?.isEmpty ?? true)
        if hasCreditPool { return true }
        return planFamily.map { $0.value == 2 } ?? false
    }
}

nonisolated struct StepFunUsageSnapshot: Sendable, Equatable {
    let fiveHourUsageLeftRate: Double
    let weeklyUsageLeftRate: Double
    let fiveHourUsageResetTime: Date
    let weeklyUsageResetTime: Date
    let planName: String?
    let updatedAt: Date
    let creditLeftRate: Double?
    let creditResetTime: Date?
    let isCreditPlan: Bool
}

nonisolated enum StepFunTokenNormalizer {
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("Oasis-Token=") {
            let parts = trimmed.components(separatedBy: "Oasis-Token=")
            if parts.count > 1 {
                let token = parts[1].components(separatedBy: ";").first ?? parts[1]
                return token.trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }
}

nonisolated enum StepFunUsageFetcher {
    typealias CachedTokenUpdater = @Sendable (String?) async -> Void
    typealias ManualTokenUpdater = @Sendable (String) async -> Void

    enum TokenSource: Sendable, Equatable {
        case manual
        case cached
        case settingsLogin
        case environmentToken
        case environmentLogin
    }

    struct ResolvedToken: Sendable, Equatable {
        let token: String
        let source: TokenSource
    }

    private struct PlanStatusResponse: Decodable {
        let status: Int?
        let subscription: Subscription?

        var planName: String? {
            subscription?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct Subscription: Decodable {
        let name: String?
        let planType: Int?
        let status: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case planType = "plan_type"
            case status
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: TokenPair?
        let refreshToken: TokenPair?
    }

    private struct TokenPair: Decodable {
        let raw: String
    }

    static let platformURL = URL(string: "https://platform.stepfun.com")!
    static let usageURL = URL(
        string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
    )!
    static let planStatusURL = URL(
        string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus"
    )!
    static let registerDeviceURL = URL(
        string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RegisterDevice"
    )!
    static let loginURL = URL(
        string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/SignInByPassword"
    )!
    static let refreshTokenURL = URL(
        string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RefreshToken"
    )!
    static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    static let appID = "10300"
    static let timeout: TimeInterval = 15

    private static let baseHeaders: [String: String] = [
        "content-type": "application/json",
        "oasis-appid": appID,
        "oasis-platform": "web",
        "oasis-webid": defaultWebID,
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ]

    static func fetch(
        source: ProviderSource,
        configuredUsername: String?,
        configuredSecret: String?,
        cachedToken: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession,
        cachedTokenUpdater: CachedTokenUpdater? = nil,
        manualTokenUpdater: ManualTokenUpdater? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let resolved = try await resolveToken(
            source: source,
            configuredUsername: configuredUsername,
            configuredSecret: configuredSecret,
            cachedToken: cachedToken,
            environment: environment,
            session: session,
            allowCached: true,
            cachedTokenUpdater: cachedTokenUpdater
        )
        do {
            let snapshot = try await fetchUsage(token: resolved.token, session: session, now: now)
            return providerUsage(snapshot)
        } catch let error where isAuthenticationFailure(error) {
            return try await recoverFromAuthenticationFailure(
                original: resolved,
                originalError: error,
                source: source,
                configuredUsername: configuredUsername,
                configuredSecret: configuredSecret,
                environment: environment,
                session: session,
                cachedTokenUpdater: cachedTokenUpdater,
                manualTokenUpdater: manualTokenUpdater,
                now: now
            )
        }
    }

    static func cleanedEnvironmentValue(_ key: String, environment: [String: String]) -> String? {
        cleaned(environment[key])
    }

    static func resolveToken(
        source: ProviderSource,
        configuredUsername: String?,
        configuredSecret: String?,
        cachedToken: String?,
        environment: [String: String],
        session: URLSession,
        allowCached: Bool,
        cachedTokenUpdater: CachedTokenUpdater? = nil
    ) async throws -> ResolvedToken {
        if source == .token {
            guard let token = cleaned(configuredSecret) else { throw StepFunUsageError.missingToken }
            return ResolvedToken(token: StepFunTokenNormalizer.normalize(token), source: .manual)
        }
        guard source == .automatic || source == .account else {
            throw StepFunUsageError.missingCredentials
        }
        if allowCached, let token = cleaned(cachedToken) {
            return ResolvedToken(token: StepFunTokenNormalizer.normalize(token), source: .cached)
        }
        if let username = cleaned(configuredUsername), let password = cleaned(configuredSecret) {
            let token = try await login(username: username, password: password, session: session)
            await cachedTokenUpdater?(token)
            return ResolvedToken(token: token, source: .settingsLogin)
        }
        if let token = cleanedEnvironmentValue("STEPFUN_TOKEN", environment: environment) {
            return ResolvedToken(token: StepFunTokenNormalizer.normalize(token), source: .environmentToken)
        }
        if let username = cleanedEnvironmentValue("STEPFUN_USERNAME", environment: environment),
           let password = cleanedEnvironmentValue("STEPFUN_PASSWORD", environment: environment) {
            let token = try await login(username: username, password: password, session: session)
            await cachedTokenUpdater?(token)
            return ResolvedToken(token: token, source: .environmentLogin)
        }
        throw StepFunUsageError.missingCredentials
    }

    static func login(username: String, password: String, session: URLSession) async throws -> String {
        guard let username = cleaned(username), let password = cleaned(password) else {
            throw StepFunUsageError.missingCredentials
        }
        let ingressCookie = try await getIngressCookie(session: session)
        let anonymousToken = try await registerDevice(ingressCookie: ingressCookie, session: session)
        return try await signInByPassword(
            username: username,
            password: password,
            ingressCookie: ingressCookie,
            anonymousToken: anonymousToken,
            session: session
        )
    }

    static func refreshToken(_ rawToken: String, session: URLSession) async throws -> String {
        let token = StepFunTokenNormalizer.normalize(rawToken)
        guard !token.isEmpty else { throw StepFunUsageError.missingToken }
        let webID = webID(forToken: token)
        var request = authenticatedRequest(url: refreshTokenURL, token: token, webID: webID)
        request.setValue(token, forHTTPHeaderField: "Oasis-Token")
        let (data, response) = try await response(for: request, session: session)
        guard response.statusCode == 200 else {
            throw StepFunUsageError.tokenRefreshFailed("HTTP \(response.statusCode)")
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("RefreshToken response: \(error.localizedDescription)")
        }
        guard let accessToken = cleaned(decoded.accessToken?.raw) else {
            throw StepFunUsageError.tokenRefreshFailed("No access token in refresh response")
        }
        return combinedToken(accessToken: accessToken, refreshToken: cleaned(decoded.refreshToken?.raw))
    }

    static func fetchUsage(
        token rawToken: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> StepFunUsageSnapshot {
        let token = StepFunTokenNormalizer.normalize(rawToken)
        guard !token.isEmpty else { throw StepFunUsageError.missingToken }
        let webID = webID(forToken: token)
        let request = authenticatedRequest(url: usageURL, token: token, webID: webID)
        let (data, response) = try await response(for: request, session: session)
        guard response.statusCode == 200 else {
            throw StepFunUsageError.apiError("HTTP \(response.statusCode)")
        }
        var snapshot = try parseSnapshot(data, now: now)
        if let planName = try? await queryPlanStatus(token: token, session: session) {
            snapshot = StepFunUsageSnapshot(
                fiveHourUsageLeftRate: snapshot.fiveHourUsageLeftRate,
                weeklyUsageLeftRate: snapshot.weeklyUsageLeftRate,
                fiveHourUsageResetTime: snapshot.fiveHourUsageResetTime,
                weeklyUsageResetTime: snapshot.weeklyUsageResetTime,
                planName: planName,
                updatedAt: snapshot.updatedAt,
                creditLeftRate: snapshot.creditLeftRate,
                creditResetTime: snapshot.creditResetTime,
                isCreditPlan: snapshot.isCreditPlan
            )
        }
        return snapshot
    }

    static func parseSnapshot(_ data: Data, now: Date = Date()) throws -> StepFunUsageSnapshot {
        let decoded: StepFunRateLimitResponse
        do {
            decoded = try JSONDecoder().decode(StepFunRateLimitResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed(error.localizedDescription)
        }
        guard decoded.isSuccess else {
            let message = [decoded.message, decoded.desc]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? decoded.code.map(String.init) ?? "unknown"
            throw StepFunUsageError.apiError(message)
        }
        let fiveHourRate = decoded.fiveHourUsageLeftRate?.value ?? 0
        let weeklyRate = decoded.weeklyUsageLeftRate?.value ?? 0
        let fiveHourReset = decoded.fiveHourUsageResetTime?.value ?? 0
        let weeklyReset = decoded.weeklyUsageResetTime?.value ?? 0
        if !decoded.isCreditPlan {
            guard decoded.fiveHourUsageLeftRate != nil,
                  decoded.weeklyUsageLeftRate != nil,
                  decoded.fiveHourUsageResetTime != nil,
                  decoded.weeklyUsageResetTime != nil
            else {
                throw StepFunUsageError.parseFailed("Missing usage rate or reset time fields")
            }
        }
        let creditResetTime = decoded.planCreditRateLimit?.subscriptionCreditResetTime.flatMap {
            $0.value > 0 ? Date(timeIntervalSince1970: TimeInterval($0.value)) : nil
        }
        return StepFunUsageSnapshot(
            fiveHourUsageLeftRate: fiveHourRate,
            weeklyUsageLeftRate: weeklyRate,
            fiveHourUsageResetTime: Date(timeIntervalSince1970: TimeInterval(fiveHourReset)),
            weeklyUsageResetTime: Date(timeIntervalSince1970: TimeInterval(weeklyReset)),
            planName: nil,
            updatedAt: now,
            creditLeftRate: decoded.planCreditRateLimit?.totalCreditLeftRate,
            creditResetTime: creditResetTime,
            isCreditPlan: decoded.isCreditPlan
        )
    }

    static func providerUsage(_ snapshot: StepFunUsageSnapshot) -> ProviderUsage {
        let plan = cleaned(snapshot.planName)
        let windows: [UsageWindow]
        if snapshot.isCreditPlan, let creditLeftRate = snapshot.creditLeftRate {
            windows = [UsageWindow(
                id: "stepfun-credits",
                label: "Credits",
                usedFraction: clamped(1 - creditLeftRate),
                resetsAt: snapshot.creditResetTime,
                detail: nil
            )]
        } else {
            windows = [
                UsageWindow(
                    id: "stepfun-five-hour",
                    label: "5h Window",
                    usedFraction: clamped(1 - snapshot.fiveHourUsageLeftRate),
                    resetsAt: snapshot.fiveHourUsageResetTime,
                    detail: nil
                ),
                UsageWindow(
                    id: "stepfun-weekly",
                    label: "Weekly Window",
                    usedFraction: clamped(1 - snapshot.weeklyUsageLeftRate),
                    resetsAt: snapshot.weeklyUsageResetTime,
                    detail: nil
                ),
            ]
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "stepfun"),
            state: .ready,
            windows: windows,
            plan: plan,
            updatedAt: snapshot.updatedAt,
            message: nil
        )
    }

    static func webID(forToken token: String) -> String {
        for half in token.components(separatedBy: "...").reversed() {
            if let deviceID = extractDeviceID(from: half), !deviceID.isEmpty { return deviceID }
        }
        return defaultWebID
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case let StepFunUsageError.apiError(message) = error else { return false }
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("401")
            || lower.contains("403")
            || lower.contains("unauthorized")
            || lower.contains("unauthenticated")
            || lower.contains("invalid credentials")
            || lower.contains("invalid token")
            || lower.contains("token expired")
            || lower.contains("expired token")
    }

    private static func recoverFromAuthenticationFailure(
        original: ResolvedToken,
        originalError: Error,
        source: ProviderSource,
        configuredUsername: String?,
        configuredSecret: String?,
        environment: [String: String],
        session: URLSession,
        cachedTokenUpdater: CachedTokenUpdater?,
        manualTokenUpdater: ManualTokenUpdater?,
        now: Date
    ) async throws -> ProviderUsage {
        let refreshed: String
        do {
            refreshed = try await refreshToken(original.token, session: session)
        } catch {
            if original.source == .cached {
                await cachedTokenUpdater?(nil)
                let fallback: ResolvedToken?
                do {
                    fallback = try await resolveToken(
                        source: source,
                        configuredUsername: configuredUsername,
                        configuredSecret: configuredSecret,
                        cachedToken: nil,
                        environment: environment,
                        session: session,
                        allowCached: false,
                        cachedTokenUpdater: cachedTokenUpdater
                    )
                } catch StepFunUsageError.missingCredentials {
                    fallback = nil
                } catch StepFunUsageError.missingToken {
                    fallback = nil
                }
                if let fallback {
                    do {
                        let snapshot = try await fetchUsage(token: fallback.token, session: session, now: now)
                        return providerUsage(snapshot)
                    } catch {
                        if !isAuthenticationFailure(error) { throw error }
                    }
                }
            }
            if let loginToken = try await loginTokenIfAvailable(
                originalSource: original.source,
                configuredUsername: configuredUsername,
                configuredSecret: configuredSecret,
                environment: environment,
                session: session,
                cachedTokenUpdater: cachedTokenUpdater
            ) {
                let snapshot = try await fetchUsage(token: loginToken, session: session, now: now)
                return providerUsage(snapshot)
            }
            throw actionableAuthenticationError(for: original.source, originalError: originalError)
        }

        switch original.source {
        case .manual:
            await manualTokenUpdater?(refreshed)
        case .cached, .settingsLogin, .environmentLogin:
            await cachedTokenUpdater?(refreshed)
        case .environmentToken:
            break
        }

        do {
            let snapshot = try await fetchUsage(token: refreshed, session: session, now: now)
            return providerUsage(snapshot)
        } catch let retryError where isAuthenticationFailure(retryError) {
            if let loginToken = try await loginTokenIfAvailable(
                originalSource: original.source,
                configuredUsername: configuredUsername,
                configuredSecret: configuredSecret,
                environment: environment,
                session: session,
                cachedTokenUpdater: cachedTokenUpdater
            ) {
                let snapshot = try await fetchUsage(token: loginToken, session: session, now: now)
                return providerUsage(snapshot)
            }
            throw actionableAuthenticationError(for: original.source, originalError: originalError)
        }
    }

    private static func loginTokenIfAvailable(
        originalSource: TokenSource,
        configuredUsername: String?,
        configuredSecret: String?,
        environment: [String: String],
        session: URLSession,
        cachedTokenUpdater: CachedTokenUpdater?
    ) async throws -> String? {
        if originalSource == .manual { return nil }
        if let username = cleaned(configuredUsername), let password = cleaned(configuredSecret) {
            let token = try await login(username: username, password: password, session: session)
            await cachedTokenUpdater?(token)
            return token
        }
        if let username = cleanedEnvironmentValue("STEPFUN_USERNAME", environment: environment),
           let password = cleanedEnvironmentValue("STEPFUN_PASSWORD", environment: environment) {
            let token = try await login(username: username, password: password, session: session)
            await cachedTokenUpdater?(token)
            return token
        }
        return nil
    }

    private static func actionableAuthenticationError(
        for source: TokenSource,
        originalError: Error
    ) -> StepFunUsageError {
        let suffix = switch source {
        case .manual:
            "Refresh the Oasis-Token, or switch StepFun to username/password authentication."
        case .environmentToken:
            "Refresh STEPFUN_TOKEN, or configure STEPFUN_USERNAME and STEPFUN_PASSWORD."
        case .cached, .settingsLogin, .environmentLogin:
            "Refresh the StepFun credentials and try again."
        }
        let message: String
        if case let StepFunUsageError.apiError(value) = originalError {
            message = value
        } else {
            message = originalError.localizedDescription
        }
        return .apiError("\(message). \(suffix)")
    }

    private static func getIngressCookie(session: URLSession) async throws -> String {
        var request = URLRequest(url: platformURL)
        request.httpMethod = "GET"
        applyBaseHeaders(to: &request)
        let (_, response) = try await response(for: request, session: session)
        for (key, rawValue) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            let value = String(describing: rawValue)
            guard let cookie = cookieValue(named: "INGRESSCOOKIE", in: value) else { continue }
            return cookie
        }
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: platformURL),
           let cookie = cookies.first(where: { $0.name == "INGRESSCOOKIE" }) {
            return cookie.value
        }
        throw StepFunUsageError.loginFailed("Could not obtain INGRESSCOOKIE")
    }

    private static func registerDevice(ingressCookie: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: registerDeviceURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        applyBaseHeaders(to: &request)
        request.setValue("INGRESSCOOKIE=\(ingressCookie)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await response(for: request, session: session)
        guard response.statusCode == 200 else {
            throw StepFunUsageError.deviceRegistrationFailed("HTTP \(response.statusCode)")
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("RegisterDevice response: \(error.localizedDescription)")
        }
        guard let accessToken = cleaned(decoded.accessToken?.raw) else {
            throw StepFunUsageError.deviceRegistrationFailed("No access token in RegisterDevice response")
        }
        return combinedToken(accessToken: accessToken, refreshToken: cleaned(decoded.refreshToken?.raw))
    }

    private static func signInByPassword(
        username: String,
        password: String,
        ingressCookie: String,
        anonymousToken: String,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        applyBaseHeaders(to: &request)
        let webID = webID(forToken: anonymousToken)
        request.setValue(webID, forHTTPHeaderField: "oasis-webid")
        request.setValue(
            "Oasis-Token=\(anonymousToken); Oasis-Webid=\(webID); INGRESSCOOKIE=\(ingressCookie)",
            forHTTPHeaderField: "Cookie"
        )
        let (data, response) = try await response(for: request, session: session)
        guard response.statusCode == 200 else {
            throw StepFunUsageError.loginFailed("HTTP \(response.statusCode)")
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("SignInByPassword response: \(error.localizedDescription)")
        }
        guard let accessToken = cleaned(decoded.accessToken?.raw) else {
            throw StepFunUsageError.loginFailed("No access token in login response")
        }
        return combinedToken(accessToken: accessToken, refreshToken: cleaned(decoded.refreshToken?.raw))
    }

    private static func queryPlanStatus(token: String, session: URLSession) async throws -> String? {
        let webID = webID(forToken: token)
        let request = authenticatedRequest(url: planStatusURL, token: token, webID: webID)
        let (data, response) = try await response(for: request, session: session)
        guard response.statusCode == 200 else { return nil }
        guard let decoded = try? JSONDecoder().decode(PlanStatusResponse.self, from: data) else { return nil }
        return decoded.planName
    }

    private static func authenticatedRequest(url: URL, token: String, webID: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        applyBaseHeaders(to: &request)
        request.setValue(webID, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func applyBaseHeaders(to request: inout URLRequest) {
        for (key, value) in baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = timeout
    }

    private static func response(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw StepFunUsageError.networkError("Invalid HTTP response")
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StepFunUsageError {
            throw error
        } catch {
            throw StepFunUsageError.networkError(error.localizedDescription)
        }
    }

    private static func extractDeviceID(from token: String) -> String? {
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
        while payload.count % 4 != 0 { payload.append("=") }
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["device_id"] as? String
    }

    private static func combinedToken(accessToken: String, refreshToken: String?) -> String {
        guard let refreshToken, !refreshToken.isEmpty else { return accessToken }
        return "\(accessToken)...\(refreshToken)"
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        guard let range = header.range(of: "\(name)=") else { return nil }
        let remainder = header[range.upperBound...]
        let value = remainder.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return cleaned(value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
