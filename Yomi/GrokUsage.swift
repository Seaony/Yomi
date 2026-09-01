import Foundation
import SweetCookieKit

nonisolated enum GrokUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case unsupportedCredential
    case cliUnavailable
    case cliFailure(String)
    case requestFailed(Int, String)
    case rpcFailed(Int, String)
    case parseFailed
    case teamUsageUnsupported

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Grok 登录或浏览器会话", "Grok requires a login or browser session")
        case .invalidCredentials:
            AppLocalization.text("Grok 凭据已失效，请运行 grok login 或重新登录 grok.com", "Grok credentials were rejected. Run grok login or sign in to grok.com again")
        case .unsupportedCredential:
            AppLocalization.text("Grok 不接受 xAI Management API Key", "Grok does not accept xAI Management API keys")
        case .cliUnavailable:
            AppLocalization.text("未找到 Grok CLI", "Grok CLI was not found")
        case let .cliFailure(message):
            AppLocalization.text("Grok CLI 失败：\(message)", "Grok CLI failed: \(message)")
        case let .requestFailed(status, body):
            AppLocalization.text("Grok 请求失败（HTTP \(status)）：\(body)", "Grok request failed (HTTP \(status)): \(body)")
        case let .rpcFailed(status, message):
            AppLocalization.text("Grok RPC 失败（\(status)）：\(message)", "Grok RPC failed (\(status)): \(message)")
        case .parseFailed:
            AppLocalization.text("无法解析 Grok 用量", "Could not parse Grok usage")
        case .teamUsageUnsupported:
            AppLocalization.text("当前 Grok 账单接口不提供团队用量", "Grok team usage is unavailable from the current billing surface")
        }
    }
}

nonisolated struct GrokCredentials: Sendable, Equatable {
    let accessToken: String
    let authMode: String?
    let email: String?
    let teamID: String?
    let principalType: String?
    let expiresAt: Date?

    var isExpired: Bool { expiresAt.map { Date() >= $0 } ?? false }
    var isTeam: Bool {
        principalType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("team") == .orderedSame
    }
    var fallbackPlan: String? {
        switch authMode?.lowercased() {
        case "oidc": "SuperGrok"
        case "session": "session"
        case let value?: value
        case nil: nil
        }
    }
}

nonisolated enum GrokCredentialRoute: Equatable {
    case oauth(String)
    case cookie(String)
    case none

    static func resolve(_ raw: String?) -> Self {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return .none }
        if let cookie = normalizedCookie(value) { return .cookie(cookie) }
        var token = value
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { return .none }
        if token.lowercased().hasPrefix("xai-") { return .none }
        return token.contains("=") ? .none : .oauth(token)
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs = value.split(separator: ";").compactMap { part -> String? in
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = item.firstIndex(of: "="), separator != item.startIndex else { return nil }
            return item
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }
}

nonisolated enum GrokCredentialsStore {
    static func authURL(environment: [String: String]) -> URL {
        let root = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        return root.appendingPathComponent("auth.json")
    }

    static func load(environment: [String: String]) -> GrokCredentials? {
        guard let data = try? Data(contentsOf: authURL(environment: environment)) else { return nil }
        return try? parse(data)
    }

    static func parse(_ data: Data) throws -> GrokCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.parseFailed
        }
        var oidc: (String, [String: Any])?
        var legacy: (String, [String: Any])?
        for (scope, raw) in root {
            guard let entry = raw as? [String: Any], let token = entry["key"] as? String, !token.isEmpty else {
                continue
            }
            if scope.hasPrefix("https://auth.x.ai::") { oidc = (token, entry) }
            else if scope == "https://accounts.x.ai/sign-in" || scope.contains("/sign-in") {
                legacy = (token, entry)
            }
        }
        guard let selected = oidc ?? legacy else { throw GrokUsageError.missingCredentials }
        return GrokCredentials(
            accessToken: selected.0,
            authMode: nonEmpty(selected.1["auth_mode"] as? String),
            email: nonEmpty(selected.1["email"] as? String),
            teamID: nonEmpty(selected.1["team_id"] as? String),
            principalType: nonEmpty(selected.1["principal_type"] as? String),
            expiresAt: isoDate(selected.1["expires_at"] as? String)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

nonisolated struct GrokBillingResponse: Decodable, Sendable, Equatable {
    struct Cycle: Decodable, Sendable, Equatable {
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }
    struct Amount: Decodable, Sendable, Equatable { let val: Int? }
    struct Usage: Decodable, Sendable, Equatable { let totalUsed: Amount? }
    let billingCycle: Cycle?
    let monthlyLimit: Amount?
    let usage: Usage?

    var usedPercent: Double? {
        guard let limit = monthlyLimit?.val, limit > 0, let used = usage?.totalUsed?.val else { return nil }
        return min(100, max(0, Double(used) / Double(limit) * 100))
    }
    var resetsAt: Date? { isoDate(billingCycle?.billingPeriodEnd) }
    var windowMinutes: Int? {
        guard let start = isoDate(billingCycle?.billingPeriodStart), let end = resetsAt, end > start else { return nil }
        return Int(end.timeIntervalSince(start) / 60)
    }
}

nonisolated struct GrokBillingSnapshot: Sendable, Equatable {
    let usedPercent: Double?
    let resetsAt: Date?
    let plan: String?
    let percentWasPublished: Bool

    init(usedPercent: Double?, resetsAt: Date?, plan: String? = nil, percentWasPublished: Bool = true) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.plan = plan
        self.percentWasPublished = percentWasPublished
    }
}

nonisolated enum GrokPlan {
    static func display(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        switch value.lowercased().filter(\.isLetter) {
        case "supergrokheavy", "heavy": return "SuperGrok Heavy"
        case "supergrok": return "SuperGrok"
        default: return value
        }
    }
}

nonisolated enum GrokUsageFetcher {
    static let proxyURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let grpcURL = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

    typealias CLILoader = @Sendable ([String: String]) async throws -> GrokBillingResponse

    static func fetch(
        source: ProviderSource,
        credential: String?,
        cachedCookie: String?,
        allowBrowserImport: Bool,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        cacheUpdate: @escaping @Sendable (String?) async -> Void = { _ in },
        cliLoader: @escaping CLILoader = runCLI
    ) async throws -> ProviderUsage {
        let local = scanLocalUsage(environment: environment, now: now)
        let route = GrokCredentialRoute.resolve(credential)
        let credentials = resolvedCredentials(route: route, environment: environment)

        func usage(_ snapshot: GrokBillingSnapshot, credentials: GrokCredentials?, minutes: Int? = nil) -> ProviderUsage {
            providerUsage(snapshot: snapshot, credentials: credentials, windowMinutes: minutes, local: local, now: now)
        }

        switch source {
        case .account:
            do {
                let billing = try await cliLoader(environment)
                let tier = await settingsTier(credentials: credentials, session: session)
                return usage(
                    GrokBillingSnapshot(usedPercent: billing.usedPercent, resetsAt: billing.resetsAt, plan: tier),
                    credentials: credentials,
                    minutes: billing.windowMinutes)
            } catch let error as GrokUsageError where isCLITeamUsageUnavailable(error, credentials: credentials) {
                return await teamIdentityUsage(
                    credentials: credentials!, local: local, now: now, session: session)
            }
        case .token:
            guard let credentials, !credentials.isExpired else { throw GrokUsageError.missingCredentials }
            do {
                return usage(try await oauthBilling(credentials: credentials, session: session), credentials: credentials)
            } catch GrokUsageError.teamUsageUnsupported where credentials.isTeam {
                return await teamIdentityUsage(
                    credentials: credentials, local: local, now: now, session: session)
            }
        case .cookie:
            let manual = route.cookieValue ?? GrokCredentialRoute.normalizedCookie(credential)
            do {
                return usage(try await cookieBilling(
                    manual: manual,
                    cached: cachedCookie,
                    credentials: credentials,
                    allowBrowserImport: allowBrowserImport,
                    session: session,
                    cacheUpdate: cacheUpdate), credentials: nil)
            } catch GrokUsageError.teamUsageUnsupported where credentials?.isTeam == true {
                return await teamIdentityUsage(
                    credentials: credentials!, local: local, now: now, session: session)
            }
        case .automatic:
            do {
                let billing = try await cliLoader(environment)
                let tier = await settingsTier(credentials: credentials, session: session)
                return usage(
                    GrokBillingSnapshot(usedPercent: billing.usedPercent, resetsAt: billing.resetsAt, plan: tier),
                    credentials: credentials,
                    minutes: billing.windowMinutes)
            } catch is CancellationError { throw CancellationError() }
            catch {}
            if case .cookie = route {
                return usage(try await cookieBilling(
                    manual: route.cookieValue,
                    cached: cachedCookie,
                    credentials: credentials,
                    allowBrowserImport: allowBrowserImport,
                    session: session, cacheUpdate: cacheUpdate), credentials: nil)
            }
            if let credentials, !credentials.isExpired {
                do { return usage(try await oauthBilling(credentials: credentials, session: session), credentials: credentials) }
                catch GrokUsageError.teamUsageUnsupported where credentials.isTeam {
                    return await teamIdentityUsage(
                        credentials: credentials, local: local, now: now, session: session)
                }
                catch is CancellationError { throw CancellationError() }
                catch {}
            }
            do {
                return usage(try await cookieBilling(
                    manual: nil,
                    cached: cachedCookie,
                    credentials: credentials,
                    allowBrowserImport: allowBrowserImport,
                    session: session, cacheUpdate: cacheUpdate), credentials: nil)
            } catch is CancellationError { throw CancellationError() }
            catch {}
            if let credentials, !credentials.isExpired {
                return usage(try await fetchGRPC(bearer: credentials.accessToken, cookie: nil, session: session), credentials: credentials)
            }
            throw GrokUsageError.missingCredentials
        default:
            throw GrokUsageError.missingCredentials
        }
    }

    static func parseProxy(_ data: Data) throws -> GrokBillingSnapshot {
        struct Response: Decodable {
            struct Config: Decodable {
                struct Period: Decodable { let end: String? }
                struct Amount: Decodable { let val: Double? }
                let creditUsagePercent: Double?
                let currentPeriod: Period?
                let billingPeriodEnd: String?
                let onDemandCap: Amount?
                let onDemandUsed: Amount?
                let subscriptionTier: String?
            }
            let config: Config?
            let subscriptionTier: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let config = response.config else {
            throw GrokUsageError.parseFailed
        }
        let reset = isoDate(config.currentPeriod?.end) ?? isoDate(config.billingPeriodEnd)
        let plan = GrokPlan.display(config.subscriptionTier ?? response.subscriptionTier)
        if let percent = config.creditUsagePercent, percent.isFinite {
            return GrokBillingSnapshot(usedPercent: min(100, max(0, percent)), resetsAt: reset, plan: plan)
        }
        if let cap = config.onDemandCap?.val, cap > 0, let used = config.onDemandUsed?.val {
            return GrokBillingSnapshot(usedPercent: min(100, max(0, used / cap * 100)), resetsAt: reset, plan: plan)
        }
        guard reset != nil else { throw GrokUsageError.parseFailed }
        return GrokBillingSnapshot(usedPercent: nil, resetsAt: reset, plan: plan)
    }

    static func parseGRPC(_ data: Data, now: Date = Date()) throws -> GrokBillingSnapshot {
        try validateTrailers(data)
        var payloads = frames(data)
        if payloads.isEmpty, looksLikeProtobuf(data) { payloads = [data] }
        guard !payloads.isEmpty else { throw GrokUsageError.parseFailed }
        var fixed: [(path: [UInt64], value: Float, order: Int)] = []
        var vars: [(path: [UInt64], value: UInt64)] = []
        for payload in payloads { scan(payload, path: [], depth: 0, order: &fixed, vars: &vars) }
        let percent = fixed.filter { $0.path.last == 1 && $0.value.isFinite && (0...100).contains($0.value) }
            .min { $0.path.count == $1.path.count ? $0.order < $1.order : $0.path.count < $1.path.count }
            .map { Double($0.value) }
        let future = vars.compactMap { field -> (path: [UInt64], date: Date)? in
            guard (1_700_000_000...2_100_000_000).contains(field.value) else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(field.value))
            return date > now ? (field.path, date) : nil
        }
        let reset = future.filter { $0.path == [1, 5, 1] }.map(\.date).min() ?? future.map(\.date).min()
        let hasPeriod = vars.contains { $0.path.starts(with: [1, 6]) || ($0.path == [1, 8, 1] && ($0.value == 1 || $0.value == 2)) }
        let inferredZero = percent == nil && fixed.isEmpty && reset != nil && hasPeriod
        guard let used = percent ?? (inferredZero ? 0 : nil) else { throw GrokUsageError.parseFailed }
        return GrokBillingSnapshot(usedPercent: used, resetsAt: reset, percentWasPublished: percent != nil)
    }

    static func providerUsage(
        snapshot: GrokBillingSnapshot,
        credentials: GrokCredentials?,
        windowMinutes: Int?,
        local: (today: Int64?, last30: Int64?),
        now: Date,
        language: AppLanguage = AppLocalization.currentLanguage
    ) -> ProviderUsage {
        let plan = GrokPlan.display(snapshot.plan) ?? credentials?.fallbackPlan
        let windows: [UsageWindow]
        if let percent = snapshot.usedPercent {
            windows = [UsageWindow(
                id: "grok-credits",
                label: windowLabel(minutes: windowMinutes, reset: snapshot.resetsAt, now: now, language: language),
                usedFraction: min(1, max(0, percent / 100)),
                resetsAt: snapshot.resetsAt,
                detail: AppLocalization.text("Grok Credits", "Grok credits", language: language)
            )]
        } else {
            windows = []
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "grok"), state: .ready, windows: windows,
            plan: plan,
            today: local.today.map { DailyTokenUsage(tokens: $0, valueUSD: nil) },
            last30Days: local.last30.map { DailyTokenUsage(tokens: $0, valueUSD: nil) },
            details: [], updatedAt: now,
            message: snapshot.usedPercent == nil
                ? AppLocalization.text("Grok 账单没有报告用量百分比", "Grok billing did not report a usage percentage", language: language)
                : nil)
    }

    static func windowLabel(minutes: Int?, reset: Date?, now: Date, language: AppLanguage) -> String {
        let duration = minutes.map { TimeInterval($0) * 60 } ?? reset.map { $0.timeIntervalSince(now) }
        if let duration, duration > 3600 {
            let days = Int((duration / 86400).rounded(.toNearestOrAwayFromZero))
            if (4...12).contains(days) { return AppLocalization.text("每周", "Weekly", language: language) }
            if (20...45).contains(days) { return AppLocalization.text("每月", "Monthly", language: language) }
        }
        if minutes == nil, reset != nil { return AppLocalization.text("每周", "Weekly", language: language) }
        return "Credits"
    }

    private static func resolvedCredentials(route: GrokCredentialRoute, environment: [String: String]) -> GrokCredentials? {
        let environmentRoute = GrokCredentialRoute.resolve(environment["GROK_OAUTH_TOKEN"])
        let token = route.oauthValue ?? environmentRoute.oauthValue
        if let token {
            return GrokCredentials(accessToken: token, authMode: "oidc", email: nil, teamID: nil, principalType: nil, expiresAt: nil)
        }
        return GrokCredentialsStore.load(environment: environment)
    }

    private static func oauthBilling(credentials: GrokCredentials, session: URLSession) async throws -> GrokBillingSnapshot {
        let billing: GrokBillingSnapshot
        do {
            var proxy = try await fetchProxy(credentials: credentials, session: session)
            if proxy.usedPercent == nil {
                do {
                    let grpc = try await fetchGRPC(
                        bearer: credentials.accessToken,
                        cookie: nil,
                        session: session,
                        timeout: 6)
                    if let percent = grpc.usedPercent, grpc.percentWasPublished {
                        proxy = GrokBillingSnapshot(
                            usedPercent: percent,
                            resetsAt: proxy.resetsAt ?? grpc.resetsAt,
                            plan: proxy.plan,
                            percentWasPublished: true)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch let error as GrokUsageError {
                    if isTeamUsageUnavailable(error, credentials: credentials) {
                        throw GrokUsageError.teamUsageUnsupported
                    }
                } catch {}
            }
            billing = proxy
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            do {
                billing = try await fetchGRPC(
                    bearer: credentials.accessToken,
                    cookie: nil,
                    session: session)
            } catch let grpcError as GrokUsageError {
                if isTeamUsageUnavailable(grpcError, credentials: credentials) {
                    throw GrokUsageError.teamUsageUnsupported
                }
                throw grpcError
            }
        }
        let tier = await settingsTier(credentials: credentials, session: session)
        return GrokBillingSnapshot(
            usedPercent: billing.usedPercent, resetsAt: billing.resetsAt,
            plan: tier ?? billing.plan, percentWasPublished: billing.percentWasPublished)
    }

    private static func fetchProxy(credentials: GrokCredentials, session: URLSession) async throws -> GrokBillingSnapshot {
        guard !credentials.isExpired else { throw GrokUsageError.missingCredentials }
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let data = try await response(request, session: session)
        return try parseProxy(data)
    }

    private static func settingsTier(credentials: GrokCredentials?, session: URLSession) async -> String? {
        guard let credentials, !credentials.isExpired else { return nil }
        var request = URLRequest(url: settingsURL)
        request.httpMethod = "GET"; request.timeoutInterval = 2
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = try? await response(request, session: session),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return GrokPlan.display(root["subscription_tier_display"] as? String)
    }

    private static func cookieBilling(
        manual: String?, cached: String?, credentials: GrokCredentials?,
        allowBrowserImport: Bool, session: URLSession,
        cacheUpdate: @escaping @Sendable (String?) async -> Void
    ) async throws -> GrokBillingSnapshot {
        for header in [manual, GrokCredentialRoute.normalizedCookie(cached)].compactMap({ $0 }) {
            let bearer = credentials.flatMap { $0.isExpired ? nil : $0.accessToken }
            var lastError: Error?
            var teamError: GrokUsageError?
            let authAttempts: [String?] = bearer.map { [$0, nil] } ?? [nil]
            for token in authAttempts {
                do { return try await fetchGRPC(bearer: token, cookie: header, session: session) }
                catch let error as GrokUsageError {
                    if let credentials, isTeamUsageUnavailable(error, credentials: credentials) {
                        teamError = .teamUsageUnsupported
                    }
                    lastError = error
                }
            }
            if header == cached, lastError as? GrokUsageError == .invalidCredentials {
                await cacheUpdate(nil)
            }
            if let teamError,
               !(header == cached && lastError as? GrokUsageError == .invalidCredentials) {
                throw teamError
            }
            if let lastError, lastError as? GrokUsageError != .invalidCredentials { throw lastError }
        }
        guard allowBrowserImport else { throw GrokUsageError.missingCredentials }
        for header in importedChromeCookies() {
            let bearer = credentials.flatMap { $0.isExpired ? nil : $0.accessToken }
            let authAttempts: [String?] = bearer.map { [$0, nil] } ?? [nil]
            for token in authAttempts {
                do {
                    let snapshot = try await fetchGRPC(bearer: token, cookie: header, session: session)
                    await cacheUpdate(header)
                    return snapshot
                } catch {}
            }
        }
        throw GrokUsageError.missingCredentials
    }

    private static func teamIdentityUsage(
        credentials: GrokCredentials,
        local: (today: Int64?, last30: Int64?),
        now: Date,
        session: URLSession
    ) async -> ProviderUsage {
        var result = providerUsage(
            snapshot: GrokBillingSnapshot(
                usedPercent: nil,
                resetsAt: nil,
                plan: await settingsTier(credentials: credentials, session: session)),
            credentials: credentials,
            windowMinutes: nil,
            local: local,
            now: now)
        result.message = GrokUsageError.teamUsageUnsupported.errorDescription
        return result
    }

    private static func isCLITeamUsageUnavailable(
        _ error: GrokUsageError,
        credentials: GrokCredentials?
    ) -> Bool {
        guard credentials?.isTeam == true, case let .cliFailure(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("method not found")
    }

    private static func fetchGRPC(
        bearer: String?,
        cookie: String?,
        session: URLSession,
        timeout: TimeInterval = 15
    ) async throws -> GrokBillingSnapshot {
        var request = URLRequest(url: grpcURL)
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.httpBody = Data([0, 0, 0, 0, 0])
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let data = try await response(request, session: session)
        return try parseGRPC(data)
    }

    private static func isTeamUsageUnavailable(
        _ error: GrokUsageError,
        credentials: GrokCredentials
    ) -> Bool {
        guard credentials.isTeam,
              case let .rpcFailed(status, message) = error,
              status == 9 else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "no personal team" || normalized == "no personal team."
    }

    private static func response(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrokUsageError.parseFailed }
        if http.statusCode == 401 || http.statusCode == 403 { throw GrokUsageError.invalidCredentials }
        guard http.statusCode == 200 else {
            throw GrokUsageError.requestFailed(http.statusCode, String(data: data.prefix(400), encoding: .utf8) ?? "")
        }
        if let status = http.value(forHTTPHeaderField: "grpc-status"), let code = Int(status), code != 0 {
            throw code == 16 ? GrokUsageError.invalidCredentials : GrokUsageError.rpcFailed(code, http.value(forHTTPHeaderField: "grpc-message") ?? "")
        }
        return data
    }

    private static func importedChromeCookies() -> [String] {
        let query = BrowserCookieQuery(domains: ["grok.com"])
        let client = BrowserCookieClient()
        guard let sources = try? client.records(matching: query, in: .chrome) else { return [] }
        let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
        return groups.values.compactMap { group in
            let records = group.flatMap(\.records)
            let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
            guard cookies.contains(where: { $0.name == "sso" || $0.name == "sso-rw" }) else {
                return nil
            }
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            return GrokCredentialRoute.normalizedCookie(header)
        }
    }

    private static func runCLI(environment: [String: String]) async throws -> GrokBillingResponse {
        guard let executable = cliExecutable(environment: environment) else { throw GrokUsageError.cliUnavailable }
        let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "agent", "stdio"]
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let lines = GrokCLILineStream(handle: output.fileHandleForReading)
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        defer {
            lines.stop()
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "1", "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
            ]],
        ]
        let billing: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "x.ai/billing", "params": [:]]
        try sendCLI(initialize, to: input.fileHandleForWriting)
        _ = try await cliResponse(id: 1, timeout: 4, lines: lines)
        try sendCLI(billing, to: input.fileHandleForWriting)
        let root = try await cliResponse(id: 2, timeout: 3, lines: lines)
        if let error = root["error"] as? [String: Any] {
            throw GrokUsageError.cliFailure(error["message"] as? String ?? "JSON-RPC error")
        }
        guard let value = root["result"] else { throw GrokUsageError.parseFailed }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(GrokBillingResponse.self, from: data)
    }

    private static func sendCLI(_ payload: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        if let text = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\\/", with: "/") {
            data = Data(text.utf8)
        }
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func cliResponse(
        id: Int,
        timeout: TimeInterval,
        lines: GrokCLILineStream
    ) async throws -> [String: Any] {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while let line = await lines.next() {
                    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (root["id"] as? NSNumber)?.intValue == id else { continue }
                    return line
                }
                throw GrokUsageError.cliFailure("grok agent closed stdout")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GrokUsageError.cliFailure("JSON-RPC request timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw GrokUsageError.cliFailure("No JSON-RPC response")
            }
            return first
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.parseFailed
        }
        return root
    }

    private static func cliExecutable(environment: [String: String]) -> String? {
        if let path = environment["GROK_CLI_PATH"], FileManager.default.isExecutableFile(atPath: path) { return path }
        for directory in (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("grok").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func scanLocalUsage(environment: [String: String], now: Date) -> (today: Int64?, last30: Int64?) {
        let root = GrokCredentialsStore.authURL(environment: environment).deletingLastPathComponent()
            .appendingPathComponent("sessions")
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return (nil, nil)
        }
        let calendar = Calendar.current; let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        var todayTokens: Int64 = 0; var total: Int64 = 0; var any = false
        while let url = iterator.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard date >= cutoff, let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let tokens = Int64(root["totalTokensBeforeCompaction"] as? Int ?? 0)
                + Int64(root["contextTokensUsed"] as? Int ?? 0)
            total += tokens; any = true
            if calendar.startOfDay(for: date) == today { todayTokens += tokens }
        }
        return (any && todayTokens > 0 ? todayTokens : nil, any ? total : nil)
    }

    private static func frames(_ data: Data) -> [Data] {
        let bytes = [UInt8](data); var index = 0; var result: [Data] = []
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = Int(bytes[index + 1]) << 24 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
            let start = index + 5; let end = start + length
            guard end <= bytes.count else { return [] }
            if flags & 0x80 == 0 { result.append(Data(bytes[start..<end])) }
            index = end
        }
        return index == bytes.count ? result : []
    }

    private static func validateTrailers(_ data: Data) throws {
        let bytes = [UInt8](data); var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = Int(bytes[index + 1]) << 24 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
            let start = index + 5; let end = start + length
            guard end <= bytes.count else { return }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                var fields: [String: String] = [:]
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let value = String(line[line.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    fields[String(line[..<separator]).lowercased()] = value.removingPercentEncoding ?? value
                }
                if let raw = fields["grpc-status"], let status = Int(raw), status != 0 {
                    if status == 16 { throw GrokUsageError.invalidCredentials }
                    throw GrokUsageError.rpcFailed(status, fields["grpc-message"] ?? "")
                }
            }
            index = end
        }
    }

    private static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first >> 3 > 0 && [0, 1, 2, 5].contains(first & 7)
    }

    private static func scan(
        _ data: Data, path: [UInt64], depth: Int,
        order: inout [(path: [UInt64], value: Float, order: Int)],
        vars: inout [(path: [UInt64], value: UInt64)]
    ) {
        let bytes = [UInt8](data); var index = 0
        while index < bytes.count {
            let start = index
            guard let key = readVarint(bytes, index: &index), key != 0 else { index = start + 1; continue }
            let field = path + [key >> 3]
            switch key & 7 {
            case 0:
                if let value = readVarint(bytes, index: &index) { vars.append((field, value)) }
                else { index = start + 1 }
            case 1: guard index + 8 <= bytes.count else { return }; index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index), length <= UInt64(bytes.count - index) else {
                    index = start + 1; continue
                }
                let end = index + Int(length)
                if depth < 4 { scan(Data(bytes[index..<end]), path: field, depth: depth + 1, order: &order, vars: &vars) }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return }
                let bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
                order.append((field, Float(bitPattern: bits), order.count)); index += 4
            default: index = start + 1
            }
        }
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0; var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]; index += 1; value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }; shift += 7
        }
        return nil
    }
}

private nonisolated func isoDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: raw)
}

private extension GrokCredentialRoute {
    nonisolated var oauthValue: String? { if case let .oauth(value) = self { value } else { nil } }
    nonisolated var cookieValue: String? { if case let .cookie(value) = self { value } else { nil } }
}

private nonisolated final class GrokCLILineStream: @unchecked Sendable {
    private let handle: FileHandle
    private let continuation: AsyncStream<Data>.Continuation
    private let iterator: GrokCLILineIterator
    private let lock = NSLock()
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
        var captured: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { captured = $0 }
        continuation = captured
        iterator = GrokCLILineIterator(stream: stream)
        handle.readabilityHandler = { [weak self] readable in
            self?.append(readable.availableData)
        }
    }

    func next() async -> Data? { await iterator.next() }

    func stop() {
        handle.readabilityHandler = nil
        continuation.finish()
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else {
            continuation.finish()
            return
        }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.count > 1_048_576 {
            buffer.removeAll(keepingCapacity: false)
            lock.unlock()
            continuation.finish()
            return
        }
        lock.unlock()
        for line in lines { continuation.yield(line) }
    }
}

private actor GrokCLILineIterator {
    private var iterator: AsyncStream<Data>.Iterator

    init(stream: AsyncStream<Data>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> Data? {
        var current = iterator
        let value = await current.next()
        iterator = current
        return value
    }
}
