import Foundation

nonisolated enum WayfinderSettingsError: LocalizedError, Equatable, Sendable {
    case invalidEndpointOverride(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            AppLocalization.text(
                "Wayfinder 网关地址覆盖 \(key) 无效。仅允许 HTTPS，或回环地址使用 HTTP，且不能包含认证信息。",
                "Wayfinder gateway URL override \(key) is invalid. Use HTTPS, or HTTP for loopback only, without credentials."
            )
        }
    }
}

nonisolated enum WayfinderUsageError: LocalizedError, Equatable, Sendable {
    case gatewayUnreachable
    case apiError(Int)
    case parseFailed(String)
    case unexpectedRedirect

    var errorDescription: String? {
        switch self {
        case .gatewayUnreachable:
            AppLocalization.text(
                "无法连接 Wayfinder 网关。请运行 `wayfinder-router serve`（默认 http://127.0.0.1:8088）或修正网关地址。",
                "Could not reach the Wayfinder gateway. Start `wayfinder-router serve` (default http://127.0.0.1:8088) or fix the Gateway URL."
            )
        case let .apiError(statusCode):
            AppLocalization.text(
                "Wayfinder 网关返回 HTTP \(statusCode)。",
                "Wayfinder gateway returned HTTP \(statusCode)."
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Wayfinder 网关响应：\(message)",
                "Could not parse Wayfinder gateway response: \(message)"
            )
        case .unexpectedRedirect:
            AppLocalization.text(
                "Wayfinder 网关请求被重定向到不同来源。",
                "Wayfinder gateway request was redirected to a different origin."
            )
        }
    }
}

nonisolated struct WayfinderUsageSnapshot: Codable, Sendable, Equatable {
    struct RouteSummary: Codable, Sendable, Equatable {
        let name: String
        let requests: Int
        let saved: Double
        let tokens: Int
    }

    let gatewayStatus: String
    let offline: Bool
    let dryRun: Bool
    let missingKeys: [String]
    let modelCount: Int
    let requests: Int
    let tokens: Int
    let realized: Double
    let baseline: Double
    let saved: Double
    let savedPct: Double
    let priced: Bool
    let routes: [RouteSummary]
    let avgDecisionMs: Double?
    let updatedAt: Date

    var savedSummary: String? {
        guard requests > 0, saved > 0 else { return nil }
        let percent = "\(Self.percentText(savedPct))%"
        guard priced else { return percent }
        let amount = saved < 0.01 ? "<$0.01" : Self.currency(saved)
        return "\(amount) · \(percent)"
    }

    func providerUsage() -> ProviderUsage {
        var details = [
            UsageDetail(
                id: "wayfinder-requests",
                label: AppLocalization.text("请求", "Requests"),
                value: Self.compactCount(requests)
            ),
            UsageDetail(
                id: "wayfinder-tokens",
                label: AppLocalization.text("Token", "Tokens"),
                value: Self.compactCount(tokens)
            ),
        ]
        if let savedSummary {
            details.append(UsageDetail(
                id: "wayfinder-saved",
                label: AppLocalization.text("节省", "Saved"),
                value: savedSummary
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "wayfinder"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            providerCost: nil,
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func compactCount(_ value: Int) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        let units: [(Int, Double, String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "K"),
        ]
        for (threshold, divisor, suffix) in units where absValue >= threshold {
            let scaled = Double(absValue) / divisor
            var formatted = scaled >= 10 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
            if formatted.hasSuffix(".0") { formatted.removeLast(2) }
            return "\(sign)\(formatted)\(suffix)"
        }
        return "\(value)"
    }

    private static func percentText(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

private nonisolated struct WayfinderHealthResponse: Decodable {
    let status: String
    let offline: Bool
    let missingKeys: [String]?

    private enum CodingKeys: String, CodingKey {
        case status, offline
        case missingKeys = "missing_keys"
    }
}

private nonisolated struct WayfinderModelsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
    let dryRun: Bool

    private enum CodingKeys: String, CodingKey {
        case models
        case dryRun = "dry_run"
    }
}

private nonisolated struct WayfinderSavingsResponse: Decodable {
    struct RouteBucket: Decodable {
        let requests: Int
        let saved: Double
        let tokens: Int
    }

    let priced: Bool
    let requests: Int
    let tokens: Int
    let realized: Double
    let baseline: Double
    let saved: Double
    let savedPct: Double
    let byRoute: [String: RouteBucket]

    private enum CodingKeys: String, CodingKey {
        case priced, requests, tokens, realized, baseline, saved
        case savedPct = "saved_pct"
        case byRoute = "by_route"
    }
}

nonisolated enum WayfinderUsageFetcher {
    static let baseURLEnvironmentKey = "WAYFINDER_GATEWAY_URL"
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8088")!
    static let savingsPeriod = "30d"
    static let decisionLatencyMetric = "wayfinder_router_decision_latency_seconds"

    static func resolvedBaseURL(
        configured: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let raw = cleaned(configured) ?? cleaned(environment[baseURLEnvironmentKey]) else {
            return defaultBaseURL
        }
        guard let url = validatedURLAllowingLoopbackHTTP(raw) else {
            throw WayfinderSettingsError.invalidEndpointOverride(baseURLEnvironmentKey)
        }
        return url
    }

    static func dashboardURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/router"
        components.query = nil
        components.fragment = nil
        return components.url ?? baseURL
    }

    static func endpointURL(baseURL: URL, path: String) -> URL {
        endpointURL(baseURL: baseURL, path: path, queryItems: [])
    }

    static func fetch(
        configuredBaseURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        updatedAt: Date = Date()
    ) async throws -> ProviderUsage {
        let baseURL = try resolvedBaseURL(configured: configuredBaseURL, environment: environment)
        return try await fetch(baseURL: baseURL, session: isolatedSession, updatedAt: updatedAt).providerUsage()
    }

    static func fetch(
        baseURL: URL,
        session: URLSession,
        updatedAt: Date = Date()
    ) async throws -> WayfinderUsageSnapshot {
        let healthData = try await get(path: "healthz", baseURL: baseURL, session: session)
        let modelsData = try await get(path: "router/models", baseURL: baseURL, session: session)
        let savingsData = try await get(
            path: "v1/savings",
            queryItems: [URLQueryItem(name: "period", value: savingsPeriod)],
            baseURL: baseURL,
            session: session
        )
        let metricsData: Data?
        do {
            metricsData = try await get(path: "metrics", baseURL: baseURL, session: session)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            metricsData = nil
        }
        return try makeSnapshot(
            healthData: healthData,
            modelsData: modelsData,
            savingsData: savingsData,
            metricsText: metricsData.flatMap { String(data: $0, encoding: .utf8) },
            updatedAt: updatedAt
        )
    }

    static func makeSnapshot(
        healthData: Data,
        modelsData: Data,
        savingsData: Data,
        metricsText: String?,
        updatedAt: Date
    ) throws -> WayfinderUsageSnapshot {
        let health: WayfinderHealthResponse = try decode(healthData, endpoint: "/healthz")
        let models: WayfinderModelsResponse = try decode(modelsData, endpoint: "/router/models")
        let savings: WayfinderSavingsResponse = try decode(savingsData, endpoint: "/v1/savings")
        return WayfinderUsageSnapshot(
            gatewayStatus: health.status,
            offline: health.offline,
            dryRun: models.dryRun,
            missingKeys: health.missingKeys ?? [],
            modelCount: models.models.count,
            requests: savings.requests,
            tokens: savings.tokens,
            realized: savings.realized,
            baseline: savings.baseline,
            saved: savings.saved,
            savedPct: savings.savedPct,
            priced: savings.priced,
            routes: savings.byRoute.map { name, bucket in
                WayfinderUsageSnapshot.RouteSummary(
                    name: name,
                    requests: bucket.requests,
                    saved: bucket.saved,
                    tokens: bucket.tokens
                )
            }.sorted {
                $0.requests != $1.requests ? $0.requests > $1.requests : $0.name < $1.name
            },
            avgDecisionMs: metricsText.flatMap(averageDecisionMilliseconds),
            updatedAt: updatedAt
        )
    }

    static func averageDecisionMilliseconds(_ text: String) -> Double? {
        var sum: Double?
        var count: Double?
        for line in text.split(separator: "\n") {
            if let value = metricValue(line: line, name: "\(decisionLatencyMetric)_sum") {
                sum = value
            } else if let value = metricValue(line: line, name: "\(decisionLatencyMetric)_count") {
                count = value
            }
        }
        guard let sum, let count, count > 0 else { return nil }
        return sum / count * 1_000
    }

    private static func get(
        path: String,
        queryItems: [URLQueryItem] = [],
        baseURL: URL,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: endpointURL(baseURL: baseURL, path: path, queryItems: queryItems))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw WayfinderUsageError.gatewayUnreachable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WayfinderUsageError.gatewayUnreachable
        }
        try validateSameOrigin(responseURL: httpResponse.url, requestURL: request.url)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WayfinderUsageError.apiError(httpResponse.statusCode)
        }
        return data
    }

    private static func endpointURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? baseURL
    }

    private static func validateSameOrigin(responseURL: URL?, requestURL: URL?) throws {
        guard let requestURL,
              let responseURL,
              requestURL.scheme?.lowercased() == responseURL.scheme?.lowercased(),
              requestURL.host?.lowercased() == responseURL.host?.lowercased(),
              effectivePort(requestURL) == effectivePort(responseURL) else {
            throw WayfinderUsageError.unexpectedRedirect
        }
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    private static func decode<T: Decodable>(_ data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WayfinderUsageError.parseFailed("\(endpoint): \(error.localizedDescription)")
        }
    }

    private static func metricValue(line: Substring, name: String) -> Double? {
        guard line.hasPrefix(name) else { return nil }
        let rest = line.dropFirst(name.count)
        guard let first = rest.first, first == " " || first == "{" else { return nil }
        guard let token = rest.split(separator: " ").last else { return nil }
        return Double(token)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func validatedURLAllowingLoopbackHTTP(_ raw: String) -> URL? {
        guard hasExplicitScheme(raw),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil,
              let host = validatedHost(url),
              scheme == "https" || isLoopbackHost(host) else { return nil }
        return url
    }

    private static func validatedHost(_ url: URL) -> String? {
        guard let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url) else { return nil }
        return decodedHost
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
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

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              octets.dropFirst().allSatisfy({ UInt8($0) != nil }) else { return false }
        return first == 127
    }

    private static func hostHasNoEncodedDelimiters(
        _ encodedHost: String,
        decodedHost: String,
        url: URL
    ) -> Bool {
        if decodedHost.contains(":") {
            guard encodedHost == decodedHost,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["),
                  componentHost.hasSuffix("]") else { return false }
            let address = componentHost.dropFirst().dropLast()
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let decodedDelimiters = CharacterSet(charactersIn: "/\\?#@:")
        guard decodedHost.rangeOfCharacter(from: decodedDelimiters) == nil else { return false }
        let encodedDelimiters = ["%2f", "%5c", "%3f", "%23", "%40", "%3a"]
        return !encodedDelimiters.contains { encodedHost.contains($0) }
    }

    private static let isolatedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
