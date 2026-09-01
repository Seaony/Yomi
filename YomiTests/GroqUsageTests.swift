import Foundation
import Testing
@testable import Yomi

@Suite("Groq usage", .serialized)
struct GroqUsageTests {
    @Test
    func decodesOrganizationClaimsAndRejectsMalformedJWTs() {
        #expect(GroqUsageFetcher.organizationID(fromJWT: Self.jwt(orgID: "org_abc123")) == "org_abc123")
        #expect(GroqUsageFetcher.organizationID(fromJWT: Self.jwt(stytchSlug: "org_slug9")) == "org_slug9")
        #expect(GroqUsageFetcher.organizationID(fromJWT: "not-a-jwt") == nil)
        #expect(GroqUsageFetcher.organizationID(fromJWT: "only.two") == nil)
    }

    @Test
    func parsesOnlyGroqSessionCookies() throws {
        let session = try #require(GroqUsageFetcher.session(
            fromCookieHeader: "Cookie: stytch_session=opaque123; stytch_session_jwt=jwt.abc.def; other=x"
        ))
        #expect(session.sessionToken == "opaque123")
        #expect(session.directJWT == "jwt.abc.def")
        #expect(session.cookieHeader == "stytch_session=opaque123; stytch_session_jwt=jwt.abc.def")
        #expect(GroqUsageFetcher.session(fromCookieHeader: "other=x") == nil)
        #expect(GroqUsageFetcher.session(fromCookieHeader: "stytch_session=") == nil)
    }

    @Test
    func environmentSessionPrefersOpaqueTokenWithJWTFallback() throws {
        let session = try #require(GroqUsageFetcher.environmentSession([
            "GROQ_SESSION_TOKEN": " opaque ",
            "GROQ_SESSION_JWT": " direct ",
        ]))
        #expect(session.sessionToken == "opaque")
        #expect(session.directJWT == "direct")
        #expect(GroqUsageFetcher.environmentSession(["GROQ_SESSION_JWT": " direct "])?.directJWT == "direct")
        #expect(GroqUsageFetcher.environmentSession([:]) == nil)
    }

    @Test
    func aggregatesActivityRowsIntoDailyModelBuckets() throws {
        let json = Data("""
        {"object":"list","data":[
          {"organization_name":"Personal","model":"llama","timestamp":1783900800,
           "num_requests":3,"n_context_tokens_total":100,"n_non_cached_context_tokens_total":80,
           "n_generated_tokens_total":40,"cost":0.01},
          {"organization_name":"Personal","model":"gpt-oss","timestamp":1783901000,
           "num_requests":2,"n_context_tokens_total":50,"n_non_cached_context_tokens_total":50,
           "n_generated_tokens_total":10,"cost":0.02},
          {"organization_name":"Personal","model":"llama","timestamp":1783987200,
           "num_requests":1,"n_context_tokens_total":10,"n_non_cached_context_tokens_total":10,
           "n_generated_tokens_total":5,"cost":0.005}
        ]}
        """.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let snapshot = try GroqUsageFetcher.parseActivity(
            json,
            historyDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_783_987_200),
            calendar: calendar
        )
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.organizationName == "Personal")
        let first = try #require(snapshot.daily.first)
        #expect(first.requests == 5)
        #expect(first.inputTokens == 130)
        #expect(first.cachedInputTokens == 20)
        #expect(first.outputTokens == 50)
        #expect(first.totalTokens == 200)
        #expect(abs(first.costUSD - 0.03) < 1e-12)
        #expect(first.models.map(\.name) == ["llama", "gpt-oss"])
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(abs((usage.providerCost?.used ?? -1) - 0.035) < 1e-12)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.last30Days?.tokens == 215)
        #expect(usage.details.map(\.id) == ["groq-spend", "groq-requests", "groq-tokens"])
    }

    @Test
    func activityParsingUsesStrictRequiredTypesAndSafeDefaults() throws {
        let snapshot = try GroqUsageFetcher.parseActivity(
            Data(#"{"data":[{"timestamp":1,"model":"","n_context_tokens_total":10,"n_non_cached_context_tokens_total":20}]}"#.utf8),
            historyDays: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(snapshot.daily[0].models[0].name == "unknown")
        #expect(snapshot.daily[0].cachedInputTokens == 0)
        #expect(snapshot.daily[0].inputTokens == 20)
        #expect(throws: GroqUsageError.self) {
            _ = try GroqUsageFetcher.parseActivity(
                Data(#"{"data":[{"timestamp":"1"}]}"#.utf8),
                historyDays: 30,
                updatedAt: Date(),
                calendar: .current
            )
        }
        #expect(throws: GroqUsageError.self) {
            _ = try GroqUsageFetcher.parseActivity(
                Data(#"{"data":{}}"#.utf8),
                historyDays: 30,
                updatedAt: Date(),
                calendar: .current
            )
        }
    }

    @Test
    func parsesPrometheusScalarsAndStatusErrors() throws {
        let value = try GroqUsageFetcher.parsePrometheusScalar(Data("""
        {"status":"success","data":{"result":[
          {"value":[1710000000,"2.5"]},
          {"value":[1710000000,1.5]},
          {"value":null}
        ]}}
        """.utf8))
        #expect(value == 4)
        #expect(try GroqUsageFetcher.parsePrometheusScalar(
            Data(#"{"status":"success","data":{"result":[]}}"#.utf8)
        ) == 0)
        #expect(throws: GroqUsageError.metricsAPIError("bad query")) {
            _ = try GroqUsageFetcher.parsePrometheusScalar(
                Data(#"{"status":"error","error":"bad query"}"#.utf8)
            )
        }
        #expect(throws: GroqUsageError.self) {
            _ = try GroqUsageFetcher.parsePrometheusScalar(Data(#"{"status":1}"#.utf8))
        }
    }

    @Test
    func prometheusRatesDoNotBecomeQuotaOrPacePresentation() {
        let usage = GroqMetricsUsageSnapshot(
            requestRatePerSecond: 2,
            inputTokenRatePerSecond: 100,
            outputTokenRatePerSecond: 50,
            promptCacheHitRatePerSecond: 3,
            updatedAt: Date(timeIntervalSince1970: 1)
        ).toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)
        #expect(usage.providerCost == nil)
    }

    @Test
    func endpointOverridesMatchCodexBarSecurityRules() throws {
        #expect(try GroqUsageFetcher.resolvedAPIURL(environment: [:]).absoluteString == "https://api.groq.com/v1")
        #expect(try GroqUsageFetcher.resolvedAPIURL(
            environment: ["GROQ_API_URL": "groq.test/v1"]
        ).absoluteString == "https://groq.test/v1")
        #expect(try GroqUsageFetcher.resolvedAPIURL(
            environment: ["GROQ_API_URL": "localhost:8080/v1"]
        ).absoluteString == "https://localhost:8080/v1")
        #expect(try GroqUsageFetcher.resolvedAPIURL(
            environment: ["GROQ_API_URL": "https://[::1]:8443/v1"]
        ).absoluteString == "https://[::1]:8443/v1")
        for invalid in [
            "http://attacker.test/v1",
            "https://user:pass@proxy.test/v1",
            "https://proxy.test%2f.attacker.test/v1",
            "https://bad host/v1",
            "https://bad%20host/v1",
        ] {
            #expect(throws: GroqUsageError.invalidEndpoint("GROQ_API_URL")) {
                _ = try GroqUsageFetcher.resolvedAPIURL(environment: ["GROQ_API_URL": invalid])
            }
        }
    }

    @Test
    func APIOnlyModeSendsTheFourExactPrometheusQueries() async throws {
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value
            let value: String = switch query {
            case "sum(model_project_id_status_code:requests:rate5m)": "2"
            case "sum(model_project_id:tokens_in:rate5m)": "100"
            case "sum(model_project_id:tokens_out:rate5m)": "50"
            case "sum(model_project_id:prompt_cache_hits:rate5m)": "3"
            default: throw URLError(.badURL)
            }
            return (200, Data(#"{"status":"success","data":{"result":[{"value":[1,"\#(value)"]}]}}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        let usage = try await GroqUsageFetcher.fetch(
            configuredAPIKey: "gsk-test",
            source: .token,
            session: Self.session(),
            allowBrowserImport: false,
            environment: ["GROQ_API_URL": "https://groq.test/v1"]
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)
        #expect(recorder.requests.count == 4)
        #expect(recorder.requests.allSatisfy { $0.url?.path == "/v1/metrics/prometheus/api/v1/query" })
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test"
                && $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })
    }

    @Test
    func APIOnlyModeResolvesConfiguredThenEnvironmentKey() async throws {
        let authorization = GroqStringBox()
        GroqTestURLProtocol.handler = { request in
            authorization.set(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"status":"success","data":{"result":[]}}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        _ = try await GroqUsageFetcher.fetch(
            configuredAPIKey: nil,
            source: .token,
            session: Self.session(),
            allowBrowserImport: false,
            environment: ["GROQ_API_KEY": "' env-key '"]
        )
        #expect(authorization.value == "Bearer env-key")
        await #expect(throws: GroqUsageError.missingCredentials) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: nil,
                source: .token,
                session: Self.session(),
                allowBrowserImport: false,
                environment: [:]
            )
        }
    }

    @Test(arguments: [401, 403, 500])
    func metricsHTTPFailuresKeepExactCategories(status: Int) async {
        GroqTestURLProtocol.handler = { _ in (status, Data(" denied ".utf8)) }
        defer { GroqTestURLProtocol.handler = nil }
        let expected: GroqUsageError = status == 401 || status == 403
            ? .metricsAccessDenied("denied")
            : .metricsAPIError("HTTP 500: denied")
        await #expect(throws: expected) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: "gsk",
                source: .token,
                session: Self.session(),
                allowBrowserImport: false,
                environment: [:]
            )
        }
    }

    @Test
    func directJWTCallsExactConsoleActivityEndpoint() async throws {
        let jwt = Self.jwt(orgID: "org_123")
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data(#"{"data":[{"organization_name":"Team","model":"llama","timestamp":1800000000,"num_requests":1,"n_context_tokens_total":2,"n_generated_tokens_total":3,"cost":0.04}]}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        let usage = try await GroqUsageFetcher.fetch(
            configuredAPIKey: nil,
            source: .cookie,
            session: Self.session(),
            allowBrowserImport: false,
            environment: ["GROQ_SESSION_JWT": jwt],
            historyDays: 400,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/platform/v1/organizations/org_123/activity")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == [
            "start_date", "end_date",
        ])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 20)
        #expect(usage.providerCost?.period == "Last 365 days")
        #expect(usage.providerCost?.used == 0.04)
    }

    @Test
    func opaqueSessionRefreshesThroughExactStytchRequest() async throws {
        let jwt = Self.jwt(orgID: "org_refresh")
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.host == "stytch.test" {
                return (200, Data(#"{"data":{"session_jwt":"\#(jwt)"}}"#.utf8))
            }
            return (200, Data(#"{"data":[]}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        _ = try await GroqUsageFetcher.fetch(
            configuredAPIKey: nil,
            source: .cookie,
            session: Self.session(),
            allowBrowserImport: false,
            environment: [
                "GROQ_SESSION_TOKEN": "opaque",
                "GROQ_STYTCH_PUBLIC_TOKEN": "public-test",
                "GROQ_STYTCH_URL": "https://stytch.test",
            ]
        )
        #expect(recorder.requests.count == 2)
        let refresh = recorder.requests[0]
        #expect(refresh.url?.path == "/sdk/v1/b2b/sessions/authenticate")
        #expect(refresh.httpMethod == "POST")
        let credential = Data("public-test:opaque".utf8).base64EncodedString()
        #expect(refresh.value(forHTTPHeaderField: "Authorization") == "Basic \(credential)")
        #expect(refresh.value(forHTTPHeaderField: "Origin") == "https://console.groq.com")
        #expect(refresh.value(forHTTPHeaderField: "X-SDK-Parent-Host") == "https://console.groq.com")
        #expect(refresh.value(forHTTPHeaderField: "X-SDK-Client")?.isEmpty == false)
        let body = try #require(refresh.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["session_token"] as? String == "opaque")
        #expect(object["session_duration_minutes"] as? Int == 30)
        #expect(recorder.requests[1].url?.path == "/platform/v1/organizations/org_refresh/activity")
    }

    @Test
    func failedStytchRefreshFallsBackToDirectJWT() async throws {
        let jwt = Self.jwt(orgID: "org_direct")
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.host == "api.stytchb2b.groq.com" {
                return (500, Data("refresh failed".utf8))
            }
            return (200, Data(#"{"data":[]}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        _ = try await GroqUsageFetcher.fetch(
            configuredAPIKey: nil,
            source: .cookie,
            session: Self.session(),
            cachedCookieHeader: "stytch_session=opaque; stytch_session_jwt=\(jwt)",
            allowBrowserImport: false,
            environment: [:]
        )
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].url?.path == "/platform/v1/organizations/org_direct/activity")
    }

    @Test(arguments: [401, 500, 200])
    func stytchFailuresKeepExactCategories(status: Int) async {
        let body = status == 200 ? #"{"data":{}}"# : " stytch failed "
        GroqTestURLProtocol.handler = { _ in (status, Data(body.utf8)) }
        defer { GroqTestURLProtocol.handler = nil }
        let expected: GroqUsageError = switch status {
        case 401: .consoleAccessDenied(" stytch failed ")
        case 500: .consoleAPIError("Stytch HTTP 500:  stytch failed ")
        default: .consoleParseFailed("Stytch response missing session_jwt")
        }
        await #expect(throws: expected) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: nil,
                source: .cookie,
                session: Self.session(),
                allowBrowserImport: false,
                environment: ["GROQ_SESSION_TOKEN": "opaque"]
            )
        }
    }

    @Test(arguments: [401, 403])
    func consoleAuthorizationFailuresStayDistinct(status: Int) async {
        GroqTestURLProtocol.handler = { _ in (status, Data(" denied ".utf8)) }
        defer { GroqTestURLProtocol.handler = nil }
        await #expect(throws: GroqUsageError.consoleAccessDenied("denied")) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: nil,
                source: .cookie,
                session: Self.session(),
                allowBrowserImport: false,
                environment: ["GROQ_SESSION_JWT": Self.jwt(orgID: "org")]
            )
        }
    }

    @Test
    func consoleServerAndParseFailuresDoNotFallBackToMetrics() async {
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            return (500, Data("broken".utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        await #expect(throws: GroqUsageError.consoleAPIError("HTTP 500: broken")) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: "gsk-fallback",
                source: .automatic,
                session: Self.session(),
                allowBrowserImport: false,
                environment: ["GROQ_SESSION_JWT": Self.jwt(orgID: "org")]
            )
        }
        #expect(recorder.requests.count == 1)

        recorder.removeAll()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data(#"{"data":{}}"#.utf8))
        }
        await #expect(throws: GroqUsageError.self) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: "gsk-fallback",
                source: .automatic,
                session: Self.session(),
                allowBrowserImport: false,
                environment: ["GROQ_SESSION_JWT": Self.jwt(orgID: "org")]
            )
        }
        #expect(recorder.requests.count == 1)
    }

    @Test
    func automaticModeFallsBackToMetricsOnlyForSessionFailures() async throws {
        GroqTestURLProtocol.handler = { _ in
            (200, Data(#"{"status":"success","data":{"result":[]}}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        let usage = try await GroqUsageFetcher.fetch(
            configuredAPIKey: "gsk-fallback",
            source: .automatic,
            session: Self.session(),
            allowBrowserImport: false,
            environment: [:]
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)

        await #expect(throws: GroqUsageError.missingSession) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: "gsk-unused",
                source: .cookie,
                session: Self.session(),
                allowBrowserImport: false,
                environment: [:]
            )
        }
    }

    @Test
    func malformedConsoleJWTTriggersAutomaticMetricsFallback() async throws {
        let recorder = GroqRequestRecorder()
        GroqTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data(#"{"status":"success","data":{"result":[]}}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        let usage = try await GroqUsageFetcher.fetch(
            configuredAPIKey: "gsk-fallback",
            source: .automatic,
            session: Self.session(),
            allowBrowserImport: false,
            environment: ["GROQ_SESSION_JWT": "malformed.jwt.value"]
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)
        #expect(recorder.requests.count == 4)
        #expect(recorder.requests.allSatisfy { $0.url?.path.contains("prometheus") == true })
    }

    @Test
    func invalidCachedSessionIsClearedBeforeAutomaticMetricsFallback() async throws {
        let updates = GroqStringArrayBox()
        GroqTestURLProtocol.handler = { request in
            if request.url?.path.contains("/activity") == true {
                return (401, Data("expired".utf8))
            }
            return (200, Data(#"{"status":"success","data":{"result":[]}}"#.utf8))
        }
        defer { GroqTestURLProtocol.handler = nil }
        _ = try await GroqUsageFetcher.fetch(
            configuredAPIKey: "gsk-fallback",
            source: .automatic,
            session: Self.session(),
            cachedCookieHeader: "stytch_session_jwt=\(Self.jwt(orgID: "org"))",
            allowBrowserImport: false,
            cacheUpdate: { updates.append($0) },
            environment: [:]
        )
        #expect(updates.values == [nil])
    }

    @Test
    func successfulCachedSessionIsPersistedAgain() async throws {
        let cached = "stytch_session_jwt=\(Self.jwt(orgID: "org"))"
        let updates = GroqStringArrayBox()
        GroqTestURLProtocol.handler = { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        defer { GroqTestURLProtocol.handler = nil }
        _ = try await GroqUsageFetcher.fetch(
            configuredAPIKey: nil,
            source: .automatic,
            session: Self.session(),
            cachedCookieHeader: cached,
            allowBrowserImport: false,
            cacheUpdate: { updates.append($0) },
            environment: [:]
        )
        #expect(updates.values == [cached])
    }

    @Test
    func networkCancellationPropagatesWithoutBecomingFakeUsage() async {
        GroqTestURLProtocol.handler = { _ in throw URLError(.cancelled) }
        defer { GroqTestURLProtocol.handler = nil }
        await #expect(throws: URLError.self) {
            _ = try await GroqUsageFetcher.fetch(
                configuredAPIKey: "gsk",
                source: .token,
                session: Self.session(),
                allowBrowserImport: false,
                environment: [:]
            )
        }
    }

    @Test
    func browserImportCacheUsesFiveSecondTTLAndCanBeInvalidated() {
        let cache = GroqImportSessionCache(ttl: 5)
        let loads = GroqIntBox()
        let first = GroqConsoleSessionInfo(sessionToken: "first", directJWT: nil, sourceLabel: "Chrome")
        let second = GroqConsoleSessionInfo(sessionToken: "second", directJWT: nil, sourceLabel: "Chrome")
        #expect(cache.sessions(now: Date(timeIntervalSince1970: 0)) {
            loads.increment()
            return [first]
        } == [first])
        #expect(cache.sessions(now: Date(timeIntervalSince1970: 4)) {
            loads.increment()
            return [second]
        } == [first])
        #expect(cache.sessions(now: Date(timeIntervalSince1970: 5)) {
            loads.increment()
            return [second]
        } == [second])
        cache.invalidate()
        #expect(cache.sessions(now: Date(timeIntervalSince1970: 6)) {
            loads.increment()
            return [first]
        } == [first])
        #expect(loads.value == 3)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jwt(orgID: String) -> String {
        encodedJWT(#"{"https://groq.com/organization":{"id":"\#(orgID)"}}"#)
    }

    private static func jwt(stytchSlug: String) -> String {
        encodedJWT(#"{"https://stytch.com/organization":{"slug":"\#(stytchSlug)"}}"#)
    }

    private static func encodedJWT(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

private final class GroqRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            recorded.httpBody = data
        }
        lock.withLock { storage.append(recorded) }
    }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

private final class GroqStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    var value: String? { lock.withLock { storage } }
    func set(_ value: String?) { lock.withLock { storage = value } }
}

private final class GroqStringArrayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    var values: [String?] { lock.withLock { storage } }
    func append(_ value: String?) { lock.withLock { storage.append(value) } }
}

private final class GroqIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class GroqTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
