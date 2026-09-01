import Foundation
import SweetCookieKit

nonisolated enum CodexUsageError: LocalizedError, Equatable {
    case missingAPICredential
    case missingOAuthCredential
    case missingWebSession
    case oauthRefreshRequired
    case cliUnavailable
    case unauthorized
    case requestFailed(Int)
    case invalidResponse
    case rpcFailed(String)
    case rpcTimedOut(String)

    var allowsAutomaticFallback: Bool {
        switch self {
        case .missingAPICredential, .missingOAuthCredential, .oauthRefreshRequired, .unauthorized,
             .cliUnavailable:
            true
        case .missingWebSession, .requestFailed, .invalidResponse, .rpcFailed, .rpcTimedOut:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPICredential:
            AppLocalization.text(
                "未找到 Codex PAT，请在 auth.json 配置 personal_access_token",
                "No Codex PAT was found. Add personal_access_token to auth.json."
            )
        case .missingOAuthCredential:
            AppLocalization.text(
                "未找到 Codex OAuth 凭据，请运行 codex login",
                "No Codex OAuth credentials were found. Run codex login."
            )
        case .missingWebSession:
            AppLocalization.text(
                "未找到 ChatGPT 浏览器会话，请先登录 chatgpt.com",
                "No ChatGPT browser session was found. Sign in to chatgpt.com first."
            )
        case .oauthRefreshRequired:
            AppLocalization.text(
                "Codex OAuth 凭据需要由 Codex CLI 刷新",
                "Codex OAuth credentials require a refresh by the Codex CLI."
            )
        case .cliUnavailable:
            AppLocalization.text("未找到 Codex CLI", "Codex CLI was not found.")
        case .unauthorized:
            AppLocalization.text(
                "Codex 凭据已失效，请重新登录",
                "Codex credentials were rejected. Sign in again."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Codex 请求失败（HTTP \(status)）",
                "Codex request failed (HTTP \(status))."
            )
        case .invalidResponse:
            AppLocalization.text("无法解析 Codex 用量", "Could not parse Codex usage.")
        case let .rpcFailed(message):
            AppLocalization.text("Codex CLI RPC 失败：\(message)", "Codex CLI RPC failed: \(message)")
        case let .rpcTimedOut(method):
            AppLocalization.text(
                "Codex CLI RPC 等待 \(method) 超时",
                "Codex CLI RPC timed out waiting for \(method)."
            )
        }
    }
}

nonisolated enum CodexUsageSource: String, Sendable, CaseIterable {
    case automatic
    case web
    case cli
    case oauth
    case api

    static func selected(by source: ProviderSource) -> Self {
        switch source {
        case .automatic: .automatic
        case .cookie: .web
        case .command: .cli
        case .account: .oauth
        case .token: .api
        case .endpoint: .automatic
        }
    }

    var strategyOrder: [Self] {
        switch self {
        case .automatic: [.api, .oauth, .cli]
        case .web, .cli, .oauth, .api: [self]
        }
    }
}

nonisolated struct CodexAuthSnapshot: Sendable, Equatable {
    let personalAccessToken: String?
    let apiKey: String?
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date?
    let expiresAt: Date?

    var oauthToken: String? { apiKey ?? accessToken }

    func oauthNeedsRefresh(now: Date) -> Bool {
        if apiKey != nil { return false }
        if let expiresAt { return expiresAt.timeIntervalSince(now) <= 5 * 60 }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }
}

nonisolated enum CodexAuthStore {
    static func authURL(environment: [String: String]) -> URL {
        if let configured = cleaned(environment["CODEX_HOME"]) {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        let home = cleaned(environment["HOME"])
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/auth.json")
    }

    static func load(environment: [String: String]) throws -> CodexAuthSnapshot {
        let url = authURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else { throw CodexUsageError.missingOAuthCredential }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> CodexAuthSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        let tokens = root["tokens"] as? [String: Any]
        let accessToken = string(tokens, "access_token", "accessToken")
        let refreshToken = string(tokens, "refresh_token", "refreshToken")
        let idToken = string(tokens, "id_token", "idToken")
        let explicitAccountID = string(tokens, "account_id", "accountId")
        return CodexAuthSnapshot(
            personalAccessToken: cleaned(root["personal_access_token"] as? String)
                ?? cleaned(root["personalAccessToken"] as? String),
            apiKey: cleaned(root["OPENAI_API_KEY"] as? String),
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: explicitAccountID ?? accountID(fromJWT: idToken ?? accessToken),
            lastRefresh: date(root["last_refresh"]),
            expiresAt: expiration(fromJWT: accessToken)
        )
    }

    static func accountID(fromJWT token: String?) -> String? {
        guard let payload = jwtPayload(token) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return cleaned(auth?["chatgpt_account_id"] as? String)
            ?? cleaned(auth?["account_id"] as? String)
            ?? cleaned(payload["chatgpt_account_id"] as? String)
            ?? cleaned(payload["account_id"] as? String)
    }

    static func expiration(fromJWT token: String?) -> Date? {
        guard let payload = jwtPayload(token), let seconds = number(payload["exp"]), seconds.isFinite else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token = cleaned(token) else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ object: [String: Any]?, _ keys: String...) -> String? {
        for key in keys {
            if let value = cleaned(object?[key] as? String) { return value }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = cleaned(value as? String) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: string) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

nonisolated enum CodexUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void
    typealias StrategyLoader = @Sendable (CodexUsageSource) async throws -> ProviderUsage

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let whoamiURL = URL(
        string: "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami"
    )!
    static let browserDomains = ["chatgpt.com", "openai.com"]
    private static let descriptor = ProviderDescriptor(
        id: ProviderID(rawValue: "codex"), name: "Codex", shortName: "Codex",
        primaryLabel: "Session", secondaryLabel: "Weekly", metricKind: .quota,
        preferredSources: [], environmentKeys: [], defaultEndpoint: nil,
        symbol: "terminal", hue: 0, defaultEnabled: true)

    static func fetch(
        source: ProviderSource,
        configuredCredential: String?,
        cachedCookieHeader: String?,
        allowBrowserImport: Bool,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        cacheUpdate: @escaping CacheUpdate = { _ in },
        cliLoader: @escaping @Sendable ([String: String]) async throws -> ProviderUsage = fetchCLI
    ) async throws -> ProviderUsage {
        let selected = CodexUsageSource.selected(by: source)
        return try await execute(order: selected.strategyOrder) { strategy in
            switch strategy {
            case .api:
                return try await fetchAPI(
                    configuredCredential: configuredCredential,
                    session: session,
                    environment: environment,
                    now: now
                )
            case .oauth:
                do {
                    return try await fetchOAuth(session: session, environment: environment, now: now)
                } catch CodexUsageError.oauthRefreshRequired {
                    return try await cliLoader(environment)
                }
            case .cli:
                return try await cliLoader(environment)
            case .web:
                return try await fetchWeb(
                    manualCookie: configuredCredential,
                    cachedCookie: cachedCookieHeader,
                    allowBrowserImport: allowBrowserImport,
                    session: session,
                    now: now,
                    cacheUpdate: cacheUpdate
                )
            case .automatic:
                throw CodexUsageError.invalidResponse
            }
        }
    }

    static func execute(order: [CodexUsageSource], loader: StrategyLoader) async throws -> ProviderUsage {
        var lastError: Error = CodexUsageError.missingOAuthCredential
        for (index, source) in order.enumerated() {
            do {
                return try await loader(source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let canContinue = index < order.count - 1
                    && (error as? CodexUsageError)?.allowsAutomaticFallback == true
                if !canContinue { throw error }
            }
        }
        throw lastError
    }

    static func fetchAPI(
        configuredCredential: String?,
        session: URLSession,
        environment: [String: String],
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let configured = normalizedBearer(configuredCredential)
        let auth = try? CodexAuthStore.load(environment: environment)
        guard let token = configured ?? auth?.personalAccessToken else {
            throw CodexUsageError.missingAPICredential
        }
        let userAgent = codexCLIUserAgent(environment: environment)
        var whoami = URLRequest(
            url: whoamiURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        applyPATHeaders(&whoami, token: token, userAgent: userAgent)
        let whoamiData = try await perform(whoami, session: session)
        guard let identity = try? JSONSerialization.jsonObject(with: whoamiData) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        let accountID = cleaned(identity["chatgpt_account_id"] as? String)
        var request = URLRequest(
            url: resolvedUsageURL(environment: environment),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        applyPATHeaders(&request, token: token, userAgent: userAgent)
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let data = try await perform(request, session: session)
        var usage = try parseUsage(data, now: now)
        if usage.plan == nil {
            usage.plan = cleaned(identity["chatgpt_plan_type"] as? String).flatMap(displayPlan)
        }
        return usage
    }

    static func fetchOAuth(
        session: URLSession,
        environment: [String: String],
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let auth = try CodexAuthStore.load(environment: environment)
        guard let token = auth.oauthToken else { throw CodexUsageError.missingOAuthCredential }
        if auth.oauthNeedsRefresh(now: now) { throw CodexUsageError.oauthRefreshRequired }
        var request = URLRequest(
            url: resolvedUsageURL(environment: environment),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let data = try await perform(request, session: session)
        return try parseUsage(data, now: now)
    }

    static func fetchWeb(
        manualCookie: String?,
        cachedCookie: String?,
        allowBrowserImport: Bool,
        session: URLSession,
        now: Date = Date(),
        cacheUpdate: @escaping CacheUpdate = { _ in }
    ) async throws -> ProviderUsage {
        var candidates: [(header: String, cached: Bool)] = []
        if let manual = normalizedCookie(manualCookie) { candidates.append((manual, false)) }
        if let cached = normalizedCookie(cachedCookie), !candidates.contains(where: { $0.header == cached }) {
            candidates.append((cached, true))
        }
        if allowBrowserImport {
            for imported in automaticCookieHeaders() where !candidates.contains(where: { $0.header == imported }) {
                candidates.append((imported, false))
            }
        }
        guard !candidates.isEmpty else { throw CodexUsageError.missingWebSession }

        var lastError: Error = CodexUsageError.missingWebSession
        for candidate in candidates {
            do {
                var request = URLRequest(
                    url: usageURL,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 4)
                request.setValue(candidate.header, forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
                let data = try await perform(request, session: session)
                let usage = try parseUsage(data, now: now)
                if manualCookie == nil { await cacheUpdate(candidate.header) }
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if candidate.cached, error as? CodexUsageError == .unauthorized { await cacheUpdate(nil) }
            }
        }
        throw lastError
    }

    static func fetchCLI(environment: [String: String]) async throws -> ProviderUsage {
        let response = try await CodexRPCUsageClient.fetch(environment: environment)
        var windows = [
            rpcWindow(response.rateLimits.primary, id: "codex-primary", fallbackLabel: "Session"),
            rpcWindow(response.rateLimits.secondary, id: "codex-secondary", fallbackLabel: "Weekly"),
        ].compactMap { $0 }
        windows = normalizeWindows(windows)
        guard !windows.isEmpty || response.rateLimits.credits?.balance != nil else {
            throw CodexUsageError.invalidResponse
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "codex"),
            state: .ready,
            windows: windows,
            balance: response.rateLimits.credits?.balance,
            plan: response.rateLimits.planType.flatMap(displayPlan),
            details: [],
            updatedAt: Date()
        )
    }

    static func parseRPCResponse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let response: CodexRPCRateLimitsResponse
        do {
            response = try JSONDecoder().decode(CodexRPCRateLimitsResponse.self, from: data)
        } catch {
            throw CodexUsageError.invalidResponse
        }
        var windows = [
            rpcWindow(response.rateLimits.primary, id: "codex-primary", fallbackLabel: "Session"),
            rpcWindow(response.rateLimits.secondary, id: "codex-secondary", fallbackLabel: "Weekly"),
        ].compactMap { $0 }
        windows = normalizeWindows(windows)
        guard !windows.isEmpty || response.rateLimits.credits?.balance != nil else {
            throw CodexUsageError.invalidResponse
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: .ready, windows: windows,
            balance: response.rateLimits.credits?.balance,
            plan: response.rateLimits.planType.flatMap(displayPlan),
            details: [], updatedAt: now)
    }

    static func resolvedUsageURL(environment: [String: String]) -> URL {
        let fallback = usageURL
        let root: URL
        if let configured = cleaned(environment["CODEX_HOME"]) {
            root = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let home = cleaned(environment["HOME"])
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            root = home.appendingPathComponent(".codex", isDirectory: true)
        }
        guard let contents = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8),
              let base = chatGPTBaseURL(in: contents)
        else { return fallback }
        var normalized = base
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if (normalized.hasPrefix("https://chatgpt.com") || normalized.hasPrefix("https://chat.openai.com")),
           !normalized.contains("/backend-api") {
            normalized += "/backend-api"
        }
        let path = normalized.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: normalized + path) ?? fallback
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        var value = cleaned(raw)
        if value?.lowercased().hasPrefix("cookie:") == true {
            value = String(value!.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs = value?.split(separator: ";").compactMap { component -> String? in
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let token = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || token.isEmpty ? nil : "\(name)=\(token)"
        } ?? []
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    static func automaticCookieHeaders() -> [String] {
        let query = BrowserCookieQuery(domains: browserDomains)
        let client = BrowserCookieClient()
        let preferred = [Browser.safari, Browser.chrome, Browser.firefox]
        let order = preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
        var headers: [String] = []
        for browser in order {
            guard let stores = try? client.records(matching: query, in: browser) else { continue }
            for store in stores {
                let cookies = BrowserCookieClient.makeHTTPCookies(store.records, origin: query.origin)
                let header = cookies.sorted { $0.name < $1.name }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                if !header.isEmpty, !headers.contains(header) { headers.append(header) }
            }
        }
        return headers
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return data
            case 401, 403: throw CodexUsageError.unauthorized
            default: throw CodexUsageError.requestFailed(http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexUsageError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private static func parseUsage(_ data: Data, now: Date) throws -> ProviderUsage {
        var usage = try UsageParser.parse(data, descriptor: descriptor)
        usage.updatedAt = now
        return usage
    }

    private static func applyPATHeaders(_ request: inout URLRequest, token: String, userAgent: String) {
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
    }

    private static func codexCLIUserAgent(environment: [String: String]) -> String {
        let version = cleaned(environment["CODEX_CLI_VERSION"])
        let versionPart = version.map { "/\($0)" } ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return "codex_cli_rs\(versionPart) (Mac OS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(architecture))"
    }

    private static func normalizedBearer(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func chatGPTBaseURL(in contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return cleaned(value)
        }
        return nil
    }

    private static func rpcWindow(
        _ value: CodexRPCRateLimitWindow?, id: String, fallbackLabel: String
    ) -> UsageWindow? {
        guard let value, value.usedPercent.isFinite else { return nil }
        let label = switch value.windowDurationMins {
        case 300: "Session"
        case 10_080: "Weekly"
        default: fallbackLabel
        }
        return UsageWindow(
            id: id, label: label, usedFraction: value.usedPercent / 100,
            resetsAt: value.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, detail: nil)
    }

    private static func normalizeWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.first { $0.label == "Weekly" }.map { [$0] } ?? []
    }

    private static func displayPlan(_ raw: String) -> String? {
        UsageParser.displayPlan(raw, descriptor: descriptor)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

nonisolated struct CodexRPCRateLimitsResponse: Decodable, Sendable, Equatable {
    let rateLimits: CodexRPCRateLimitSnapshot
}

nonisolated struct CodexRPCRateLimitSnapshot: Decodable, Sendable, Equatable {
    let primary: CodexRPCRateLimitWindow?
    let secondary: CodexRPCRateLimitWindow?
    let credits: CodexRPCCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary, credits, planType
        case planTypeSnake = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try? container.decodeIfPresent(CodexRPCRateLimitWindow.self, forKey: .primary)
        secondary = try? container.decodeIfPresent(CodexRPCRateLimitWindow.self, forKey: .secondary)
        credits = try? container.decodeIfPresent(CodexRPCCredits.self, forKey: .credits)
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
    }
}

nonisolated struct CodexRPCRateLimitWindow: Decodable, Sendable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

nonisolated struct CodexRPCCredits: Decodable, Sendable, Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

private nonisolated final class CodexRPCUsageClient: @unchecked Sendable {
    private enum RaceResult: Sendable {
        case message([String: String])
        case timeout
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 1

    static func fetch(environment: [String: String]) async throws -> CodexRPCRateLimitsResponse {
        guard let binary = resolveBinary(environment: environment) else { throw CodexUsageError.cliUnavailable }
        let client = CodexRPCUsageClient(binary: binary, environment: environment)
        try client.start()
        defer { client.shutdown() }
        _ = try await client.request(
            method: "initialize",
            params: ["clientInfo": ["name": "yomi", "version": "1"]],
            timeout: 8)
        try client.notify(method: "initialized")
        let message = try await client.request(method: "account/rateLimits/read", timeout: 4)
        guard let result = message["result"] else { throw CodexUsageError.invalidResponse }
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(CodexRPCRateLimitsResponse.self, from: data)
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.invalidResponse
        }
    }

    private init(binary: String, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    private func start() throws {
        do { try process.run() }
        catch { throw CodexUsageError.rpcFailed(error.localizedDescription) }
    }

    private func shutdown() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params])
        while true {
            let message = try await readMessage(method: method, timeout: timeout)
            guard number(message["id"]) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "Unknown RPC error"
                throw CodexUsageError.rpcFailed(text)
            }
            return message
        }
    }

    private func notify(method: String) throws {
        try send(["method": method, "params": [:]])
    }

    private func send(_ payload: [String: Any]) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexUsageError.rpcFailed(error.localizedDescription)
        }
    }

    private func readMessage(method: String, timeout: TimeInterval) async throws -> [String: Any] {
        let handle = output.fileHandleForReading
        let process = process
        return try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                let data = try Self.readLine(handle)
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CodexUsageError.invalidResponse
                }
                let encoded = try JSONSerialization.data(withJSONObject: object)
                return .message(["json": encoded.base64EncodedString()])
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return .timeout
            }
            guard let first = try await group.next() else { throw CodexUsageError.invalidResponse }
            group.cancelAll()
            switch first {
            case let .message(box):
                guard let encoded = box["json"], let data = Data(base64Encoded: encoded),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw CodexUsageError.invalidResponse }
                return object
            case .timeout:
                if process.isRunning { process.terminate() }
                throw CodexUsageError.rpcTimedOut(method)
            }
        }
    }

    private static func readLine(_ handle: FileHandle) throws -> Data {
        var line = Data()
        while true {
            guard let data = try handle.read(upToCount: 1), !data.isEmpty else {
                throw CodexUsageError.rpcFailed("Codex app-server closed stdout")
            }
            if data[0] == 0x0A { return line }
            line.append(data)
            if line.count > 2 * 1024 * 1024 { throw CodexUsageError.invalidResponse }
        }
    }

    private static func resolveBinary(environment: [String: String]) -> String? {
        if let explicit = environment["CODEX_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty, FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        let paths = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
        for directory in paths {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("codex").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func number(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        default: nil
        }
    }
}
