import Foundation
import Testing
@testable import Yomi

@Suite("Wayfinder usage", .serialized)
struct WayfinderUsageTests {
    @Test
    func liveGatewayPayloadsMapToDetailOnlyUsage() throws {
        let now = Date(timeIntervalSince1970: 1)
        let snapshot = try Self.snapshot(updatedAt: now)
        let usage = snapshot.providerUsage()

        #expect(snapshot.gatewayStatus == "ok")
        #expect(!snapshot.offline)
        #expect(!snapshot.dryRun)
        #expect(snapshot.modelCount == 2)
        #expect(snapshot.requests == 14)
        #expect(snapshot.tokens == 1_028)
        #expect(snapshot.saved == 0.005694)
        #expect(snapshot.savedPct == 61.5)
        #expect(snapshot.routes.map(\.name) == ["local", "cloud"])
        #expect(snapshot.savedSummary == "<$0.01 · 61.5%")
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.providerCost == nil)
        #expect(usage.balance == nil)
        #expect(usage.plan == nil)
        #expect(usage.details.map(\.id) == ["wayfinder-requests", "wayfinder-tokens", "wayfinder-saved"])
        #expect(usage.details.map(\.value) == ["14", "1K", "<$0.01 · 61.5%"])
        #expect(usage.updatedAt == now)
    }

    @Test
    func gatewayStateRemainsInternalAndIsNotPresentedAsPlan() throws {
        let offline = try Self.snapshot(
            health: #"{"status":"degraded","offline":true,"missing_keys":["a"]}"#,
            models: #"{"models":[],"dry_run":true}"#
        )
        let dryRun = try Self.snapshot(
            health: #"{"status":"ok","offline":false}"#,
            models: #"{"models":[],"dry_run":true}"#
        )
        let degraded = try Self.snapshot(
            health: #"{"status":"degraded","offline":false,"missing_keys":["a","b"]}"#
        )

        #expect(offline.offline)
        #expect(dryRun.dryRun)
        #expect(degraded.missingKeys == ["a", "b"])
        #expect(offline.providerUsage().plan == nil)
        #expect(dryRun.providerUsage().plan == nil)
        #expect(degraded.providerUsage().plan == nil)
    }

    @Test
    func zeroAndUnpricedSavingsNeverCreateCostOrQuota() throws {
        let zero = try Self.snapshot(savings: Self.savingsZeros)
        let unpriced = try Self.snapshot(savings: Self.savingsUnpriced)

        #expect(zero.savedSummary == nil)
        #expect(zero.providerUsage().providerCost == nil)
        #expect(unpriced.savedSummary?.hasPrefix("40%") == true)
        #expect(unpriced.savedSummary?.contains("$") == false)
        #expect(unpriced.providerUsage().windows.isEmpty)
    }

    @Test
    func routesRemainInternalAndSortByRequestsThenName() throws {
        let savings = #"{"priced":true,"requests":20,"tokens":1,"realized":1,"baseline":2,"saved":1,"saved_pct":50,"by_route":{"zeta":{"requests":5,"saved":0,"tokens":1},"alpha":{"requests":5,"saved":0,"tokens":1},"custom-primary":{"requests":10,"saved":1,"tokens":1}}}"#
        let snapshot = try Self.snapshot(savings: savings)

        #expect(snapshot.routes.map(\.name) == ["custom-primary", "alpha", "zeta"])
        #expect(!snapshot.providerUsage().details.contains { $0.id == "wayfinder-routed" })
    }

    @Test
    func coreRequestAndTokenCountsAreCompactedWithoutRouteComposition() throws {
        let savings = #"{"priced":false,"requests":12345,"tokens":1,"realized":1,"baseline":2,"saved":1,"saved_pct":50,"by_route":{"a":{"requests":12345,"saved":0,"tokens":1},"b":{"requests":1000,"saved":0,"tokens":1},"c":{"requests":999,"saved":0,"tokens":1},"d":{"requests":10,"saved":0,"tokens":1},"e":{"requests":9,"saved":0,"tokens":1},"f":{"requests":8,"saved":0,"tokens":1}}}"#
        let details = try Self.snapshot(savings: savings).providerUsage().details
        #expect(details.map(\.id) == ["wayfinder-requests", "wayfinder-tokens", "wayfinder-saved"])
        #expect(details.map(\.value) == ["12K", "1", "50%"])
    }

    @Test
    func metricsParsingIsBestEffortAndSupportsLabels() {
        #expect(WayfinderUsageFetcher.averageDecisionMilliseconds("") == nil)
        #expect(WayfinderUsageFetcher.averageDecisionMilliseconds(
            "wayfinder_router_decision_latency_seconds_sum 1.5\n"
        ) == nil)
        #expect(WayfinderUsageFetcher.averageDecisionMilliseconds(
            "wayfinder_router_decision_latency_seconds_sum 1.5\n" +
                "wayfinder_router_decision_latency_seconds_count 0\n"
        ) == nil)
        #expect(WayfinderUsageFetcher.averageDecisionMilliseconds(
            "wayfinder_router_decision_latency_seconds_sum{route=\"all\"} 2.0\n" +
                "wayfinder_router_decision_latency_seconds_count{route=\"all\"} 4\n"
        ) == 500)
    }

    @Test
    func strictPayloadTypesReportTheFailingRequiredEndpoint() {
        #expect(throws: WayfinderUsageError.self) {
            _ = try WayfinderUsageFetcher.makeSnapshot(
                healthData: Data(#"{"status":"ok","offline":"false"}"#.utf8),
                modelsData: Data(Self.models.utf8),
                savingsData: Data(Self.savings30d.utf8),
                metricsText: nil,
                updatedAt: Date()
            )
        }
        do {
            _ = try WayfinderUsageFetcher.makeSnapshot(
                healthData: Data(Self.health.utf8),
                modelsData: Data(#"{"models":[],"dry_run":"false"}"#.utf8),
                savingsData: Data(Self.savings30d.utf8),
                metricsText: nil,
                updatedAt: Date()
            )
            Issue.record("Expected parse failure")
        } catch let error as WayfinderUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Unexpected error")
                return
            }
            #expect(message.hasPrefix("/router/models:"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func endpointURLsPreservePrefixesAndReplaceQuery() {
        #expect(WayfinderUsageFetcher.endpointURL(
            baseURL: URL(string: "http://127.0.0.1:8088")!, path: "healthz"
        ).absoluteString == "http://127.0.0.1:8088/healthz")
        #expect(WayfinderUsageFetcher.endpointURL(
            baseURL: URL(string: "https://wayfinder.test/wf/?old=1")!, path: "v1/savings"
        ).absoluteString == "https://wayfinder.test/wf/v1/savings")
        #expect(WayfinderUsageFetcher.dashboardURL(
            baseURL: URL(string: "http://localhost:9191/wayfinder/?old=1#fragment")!
        ).absoluteString == "http://localhost:9191/wayfinder/router")
    }

    @Test
    func configuredGatewayPrecedesEnvironmentAndCleansQuotes() throws {
        #expect(try WayfinderUsageFetcher.resolvedBaseURL(
            configured: " 'http://localhost:9191/wf' ",
            environment: ["WAYFINDER_GATEWAY_URL": "https://environment.test"]
        ).absoluteString == "http://localhost:9191/wf")
        #expect(try WayfinderUsageFetcher.resolvedBaseURL(
            environment: ["WAYFINDER_GATEWAY_URL": " \"https://wayfinder.test\" "]
        ).absoluteString == "https://wayfinder.test")
        #expect(try WayfinderUsageFetcher.resolvedBaseURL(environment: [:]) == WayfinderUsageFetcher.defaultBaseURL)
    }

    @Test(arguments: [
        "http://127.0.0.1:9090",
        "http://localhost:8088",
        "http://[::1]:8088",
        "https://wayfinder.test",
    ])
    func gatewayAllowsHTTPSOrLoopbackHTTP(endpoint: String) throws {
        #expect(try WayfinderUsageFetcher.resolvedBaseURL(configured: endpoint, environment: [:]).absoluteString == endpoint)
    }

    @Test(arguments: [
        "wayfinder.test",
        "http://192.168.1.5:8088",
        "http://attacker.test",
        "http://user@127.0.0.1:8088",
        "https://user:pass@wayfinder.test",
        "https://wayfinder.test%2f.attacker.test",
    ])
    func gatewayRejectsUnsafeOrMalformedOverrides(endpoint: String) {
        #expect(throws: WayfinderSettingsError.invalidEndpointOverride("WAYFINDER_GATEWAY_URL")) {
            _ = try WayfinderUsageFetcher.resolvedBaseURL(configured: endpoint, environment: [:])
        }
    }

    @Test
    func fetchPollsOnlyReadOnlyEndpointsWithoutCredentials() async throws {
        let recorder = WayfinderRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            let body: Data = switch request.url?.path {
            case "/healthz": Data(Self.health.utf8)
            case "/router/models": Data(Self.models.utf8)
            case "/v1/savings": Data(Self.savings30d.utf8)
            case "/metrics": Data(Self.metrics.utf8)
            default: Data()
            }
            return Self.response(request, status: 200, data: body)
        }
        defer { WayfinderTestURLProtocol.handler = nil }

        let snapshot = try await WayfinderUsageFetcher.fetch(
            baseURL: URL(string: "http://127.0.0.1:8088")!,
            session: session,
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(snapshot.requests == 14)
        #expect(recorder.requests.map { $0.url?.path } == ["/healthz", "/router/models", "/v1/savings", "/metrics"])
        #expect(recorder.requests[2].url?.query == "period=30d")
        #expect(recorder.requests.allSatisfy { $0.httpMethod == "GET" && $0.timeoutInterval == 5 })
        #expect(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(recorder.requests.allSatisfy { $0.httpBody == nil })
    }

    @Test
    func metricsFailureIsOptional() async throws {
        let session = Self.session { request in
            if request.url?.path == "/metrics" { throw URLError(.cannotConnectToHost) }
            let body: Data = switch request.url?.path {
            case "/healthz": Data(Self.health.utf8)
            case "/router/models": Data(Self.models.utf8)
            case "/v1/savings": Data(Self.savings30d.utf8)
            default: Data()
            }
            return Self.response(request, status: 200, data: body)
        }
        defer { WayfinderTestURLProtocol.handler = nil }

        let snapshot = try await WayfinderUsageFetcher.fetch(
            baseURL: WayfinderUsageFetcher.defaultBaseURL, session: session
        )
        #expect(snapshot.avgDecisionMs == nil)
        #expect(snapshot.providerUsage().details.last?.id == "wayfinder-saved")
    }

    @Test
    func requiredNetworkAndHTTPFailuresKeepExactCategories() async {
        let unreachable = Self.session { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: WayfinderUsageError.gatewayUnreachable) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: unreachable
            )
        }
        let serverError = Self.session { request in Self.response(request, status: 500, data: Data()) }
        await #expect(throws: WayfinderUsageError.apiError(500)) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: serverError
            )
        }
        WayfinderTestURLProtocol.handler = nil
    }

    @Test
    func requiredAndOptionalCancellationRemainCancellation() async {
        let required = Self.session { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: required
            )
        }
        let optional = Self.session { request in
            if request.url?.path == "/metrics" { throw URLError(.cancelled) }
            let body: Data = switch request.url?.path {
            case "/healthz": Data(Self.health.utf8)
            case "/router/models": Data(Self.models.utf8)
            case "/v1/savings": Data(Self.savings30d.utf8)
            default: Data()
            }
            return Self.response(request, status: 200, data: body)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: optional
            )
        }
        WayfinderTestURLProtocol.handler = nil
    }

    @Test
    func crossOriginRedirectIsRejectedIncludingPortChanges() async {
        let attacker = Self.session { request in
            let response = HTTPURLResponse(
                url: URL(string: "http://attacker.test/healthz")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.health.utf8))
        }
        await #expect(throws: WayfinderUsageError.unexpectedRedirect) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: attacker
            )
        }

        let otherPort = Self.session { request in
            let response = HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:9090\(request.url?.path ?? "")")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.health.utf8))
        }
        await #expect(throws: WayfinderUsageError.unexpectedRedirect) {
            _ = try await WayfinderUsageFetcher.fetch(
                baseURL: WayfinderUsageFetcher.defaultBaseURL, session: otherPort
            )
        }
        WayfinderTestURLProtocol.handler = nil
    }

    private static func snapshot(
        health: String = Self.health,
        models: String = Self.models,
        savings: String = Self.savings30d,
        metrics: String? = Self.metrics,
        updatedAt: Date = Date(timeIntervalSince1970: 1)
    ) throws -> WayfinderUsageSnapshot {
        try WayfinderUsageFetcher.makeSnapshot(
            healthData: Data(health.utf8),
            modelsData: Data(models.utf8),
            savingsData: Data(savings.utf8),
            metricsText: metrics,
            updatedAt: updatedAt
        )
    }

    private static func session(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        WayfinderTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WayfinderTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
    }

    private static let health = #"{"status":"ok","models":["cloud","local"],"offline":false}"#
    private static let models = #"{"models":[{"name":"local"},{"name":"cloud"}],"dry_run":false}"#
    private static let savings30d = #"{"period_days":30,"unit":"usd","priced":true,"requests":14,"tokens":1028,"realized":0.003558,"baseline":0.009252,"saved":0.005694,"saved_pct":61.5,"by_route":{"cloud":{"requests":4,"saved":0,"tokens":366},"local":{"requests":10,"saved":0.005694,"tokens":662}}}"#
    private static let savingsZeros = #"{"priced":true,"requests":0,"tokens":0,"realized":0,"baseline":0,"saved":0,"saved_pct":0,"by_route":{}}"#
    private static let savingsUnpriced = #"{"priced":false,"requests":5,"tokens":420,"realized":1.8,"baseline":3,"saved":1.2,"saved_pct":40,"by_route":{"local":{"requests":4,"saved":1.2,"tokens":320},"cloud":{"requests":1,"saved":0,"tokens":100}}}"#
    private static let metrics = "wayfinder_router_decision_latency_seconds_sum 0.00112602\nwayfinder_router_decision_latency_seconds_count 14\n"
}

private nonisolated final class WayfinderRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private nonisolated final class WayfinderTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
