import Foundation
import Testing
@testable import Yomi

@Suite("Neuralwatt usage", .serialized)
struct NeuralWattUsageTests {
    @Test
    func fullQuotaMapsSubscriptionAllowanceBalanceAndPlanExactly() throws {
        let now = Date(timeIntervalSince1970: 123)
        let snapshot = try NeuralWattUsageFetcher.parseSnapshot(Data(Self.fullQuota.utf8), updatedAt: now)
        let usage = snapshot.providerUsage()

        #expect(snapshot.creditUsedPercent == 25)
        #expect(snapshot.effectiveRemainingCredits == 75)
        #expect(snapshot.currentMonthCostUSD == 12.5)
        #expect(snapshot.currentMonthEnergyKWh == 4.25)
        #expect(snapshot.rateLimitTier == "tier_2")
        #expect(usage.windows == [UsageWindow(
            id: "subscription",
            label: "Subscription",
            usedFraction: 0.25,
            resetsAt: Self.date("2026-10-01T00:00:00.123Z"),
            detail: "50 / 200 kWh"
        )])
        #expect(usage.additionalWindows == [UsageWindow(
            id: "key-allowance",
            label: "Key Monthly",
            usedFraction: 0.25,
            resetsAt: nil,
            detail: nil
        )])
        #expect(usage.providerCost == ProviderCostSummary(
            used: 75,
            limit: 0,
            currencyCode: "USD",
            period: "Neuralwatt prepaid balance",
            balance: 75
        ))
        #expect(usage.plan == "Pro Energy plan")
        #expect(usage.balance == nil)
        #expect(usage.details.isEmpty)
        #expect(usage.updatedAt == now)
    }

    @Test
    func prepaidBalanceNeverBecomesQuotaWindow() throws {
        let snapshot = try Self.snapshot(#"{"balance":{"credits_remaining_usd":51,"accounting_method":"prepaid"},"subscription":null}"#)
        let usage = snapshot.providerUsage()

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.providerCost?.used == 51)
        #expect(usage.providerCost?.balance == 51)
        #expect(usage.plan == nil)
    }

    @Test
    func zeroPrepaidBalanceDoesNotExhaustSubscription() throws {
        let snapshot = try Self.snapshot(#"{"balance":{"credits_remaining_usd":0},"subscription":{"kwh_included":100,"kwh_used":25,"kwh_remaining":75}}"#)
        let usage = snapshot.providerUsage()

        #expect(snapshot.creditUsedPercent == 100)
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.providerCost?.used == 0)
        #expect(usage.providerCost?.balance == 0)
    }

    @Test(arguments: [
        (#"{"balance":{"credits_remaining_usd":70,"credits_used_usd":30}}"#, 70.0, 100.0, 30.0),
        (#"{"balance":{"total_credits_usd":100,"credits_used_usd":30}}"#, 70.0, 100.0, 30.0),
        (#"{"balance":{"total_credits_usd":100,"credits_remaining_usd":70}}"#, 70.0, 100.0, 30.0),
    ])
    func creditTotalsUseDocumentedFallbacks(
        body: String,
        remaining: Double,
        total: Double,
        used: Double
    ) throws {
        let snapshot = try Self.snapshot(body)
        #expect(snapshot.effectiveRemainingCredits == remaining)
        #expect(snapshot.effectiveTotalCredits == total)
        #expect(snapshot.effectiveUsedCredits == used)
        #expect(snapshot.creditUsedPercent == 30)
    }

    @Test
    func subscriptionCanDeriveIncludedAndUsedKilowattHours() throws {
        let deriveTotal = try Self.snapshot(#"{"balance":{"credits_remaining_usd":1},"subscription":{"kwh_used":12.5,"kwh_remaining":37.5}}"#).providerUsage()
        let deriveUsed = try Self.snapshot(#"{"balance":{"credits_remaining_usd":1},"subscription":{"kwh_included":50,"kwh_remaining":37.5}}"#).providerUsage()

        #expect(deriveTotal.windows.first?.usedFraction == 0.25)
        #expect(deriveTotal.windows.first?.detail == "12.50 / 50 kWh")
        #expect(deriveUsed.windows.first?.usedFraction == 0.25)
        #expect(deriveUsed.windows.first?.detail == "12.50 / 50 kWh")
    }

    @Test
    func blockedKeyAllowanceIsExhaustedWithoutNumericLimit() throws {
        let snapshot = try Self.snapshot(#"{"balance":{"credits_remaining_usd":1},"key":{"name":"key one","allowance":{"blocked":true}}}"#)
        let window = snapshot.providerUsage().additionalWindows.first

        #expect(snapshot.keyAllowanceUsedPercent == 100)
        #expect(window?.label == "Key Allowance")
        #expect(window?.usedFraction == 1)
    }

    @Test
    func nonrenewingSubscriptionStillKeepsPeriodResetInYomiWindow() throws {
        let usage = try Self.snapshot(#"{"balance":{"credits_remaining_usd":1},"subscription":{"auto_renew":false,"current_period_end":"2026-12-01T00:00:00Z","kwh_included":10,"kwh_used":1}}"#).providerUsage()
        #expect(usage.windows.first?.resetsAt == Self.date("2026-12-01T00:00:00Z"))
    }

    @Test(arguments: [
        #"{}"#,
        #"{"balance":null}"#,
        #"{"balance":{}}"#,
        #"{"balance":{"credits_remaining_usd":-1,"credits_used_usd":-2,"total_credits_usd":0}}"#,
        #"{"balance":{"credits_remaining_usd":"1"}}"#,
    ])
    func invalidOrMissingBalanceFailsClosed(body: String) {
        #expect(throws: NeuralWattUsageError.self) {
            _ = try Self.snapshot(body)
        }
    }

    @Test
    func APIKeyResolutionUsesConfiguredThenEnvironmentAndCleansQuotes() {
        #expect(NeuralWattUsageFetcher.resolvedAPIKey(
            configured: "  'configured' ",
            environment: ["NEURALWATT_API_KEY": "environment"]
        ) == "configured")
        #expect(NeuralWattUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["NEURALWATT_API_KEY": " \"environment\" "]
        ) == "environment")
        #expect(NeuralWattUsageFetcher.resolvedAPIKey(configured: " ", environment: [:]) == nil)
        #expect(NeuralWattUsageFetcher.minimumAccountRefreshInterval == 1)
    }

    @Test
    func endpointOverrideAcceptsHTTPSBareHostPortAndIPv6() throws {
        #expect(try NeuralWattUsageFetcher.resolvedAPIURL(
            environment: ["NEURALWATT_API_URL": "https://quota.test/proxy"]
        ).absoluteString == "https://quota.test/proxy")
        #expect(try NeuralWattUsageFetcher.resolvedAPIURL(
            environment: ["NEURALWATT_API_URL": "quota.test"]
        ).absoluteString == "https://quota.test")
        #expect(try NeuralWattUsageFetcher.resolvedAPIURL(
            environment: ["NEURALWATT_API_URL": "localhost:8443"]
        ).absoluteString == "https://localhost:8443")
        #expect(try NeuralWattUsageFetcher.resolvedAPIURL(
            environment: ["NEURALWATT_API_URL": "https://[::1]:8443/v1"]
        ).absoluteString == "https://[::1]:8443/v1")
    }

    @Test(arguments: [
        "http://attacker.test",
        "https://user:pass@proxy.test/v1",
        "https://proxy.test%2f.attacker.test/v1",
        "https://bad host/v1",
        "https://bad%20host/v1",
        "https://bad%09host/v1",
    ])
    func endpointOverrideRejectsInsecureOrMalformedValues(endpoint: String) {
        #expect(throws: NeuralWattSettingsError.invalidEndpointOverride("NEURALWATT_API_URL")) {
            _ = try NeuralWattUsageFetcher.resolvedAPIURL(
                environment: ["NEURALWATT_API_URL": endpoint]
            )
        }
    }

    @Test
    func quotaURLMatchesVersionedBaseRule() {
        #expect(NeuralWattUsageFetcher.quotaURL(
            baseURL: URL(string: "https://api.neuralwatt.com")!
        ).absoluteString == "https://api.neuralwatt.com/v1/quota")
        #expect(NeuralWattUsageFetcher.quotaURL(
            baseURL: URL(string: "https://quota.test/v1/")!
        ).absoluteString == "https://quota.test/v1/quota")
        #expect(NeuralWattUsageFetcher.quotaURL(
            baseURL: URL(string: "https://quota.test/proxy")!
        ).absoluteString == "https://quota.test/proxy/v1/quota")
    }

    @Test
    func fetchSendsExactRequestAndMapsResponse() async throws {
        let recorder = NeuralWattRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            return Self.httpResponse(request, status: 200, data: Data(Self.fullQuota.utf8))
        }
        defer { NeuralWattTestURLProtocol.handler = nil }
        let now = Date(timeIntervalSince1970: 456)

        let usage = try await NeuralWattUsageFetcher.fetch(
            apiKey: " fixture-key ",
            session: session,
            environment: ["NEURALWATT_API_URL": "https://quota.test/v1/"],
            now: now,
            sleeper: { _ in }
        )
        let request = recorder.requests.first

        #expect(recorder.requests.count == 1)
        #expect(request?.url?.absoluteString == "https://quota.test/v1/quota")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.timeoutInterval == 15)
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.updatedAt == now)
    }

    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func transientHTTPStatusRetriesExactlyOnce(status: Int) async throws {
        let recorder = NeuralWattRequestRecorder()
        let delays = NeuralWattDelayRecorder()
        let session = Self.session { request in
            recorder.append(request)
            if recorder.requests.count == 1 {
                return Self.httpResponse(
                    request,
                    status: status,
                    headers: ["Retry-After": "12"],
                    data: Data()
                )
            }
            return Self.httpResponse(request, status: 200, data: Data(#"{"balance":{"credits_remaining_usd":1}}"#.utf8))
        }
        defer { NeuralWattTestURLProtocol.handler = nil }

        _ = try await NeuralWattUsageFetcher.fetch(
            apiKey: "key",
            session: session,
            environment: [:],
            sleeper: { delay in delays.append(delay) }
        )

        #expect(recorder.requests.count == 2)
        #expect(delays.values == [10])
    }

    @Test
    func transientNetworkFailureRetriesOnceWithBaseDelay() async throws {
        let recorder = NeuralWattRequestRecorder()
        let delays = NeuralWattDelayRecorder()
        let session = Self.session { request in
            recorder.append(request)
            if recorder.requests.count == 1 { throw URLError(.timedOut) }
            return Self.httpResponse(request, status: 200, data: Data(#"{"balance":{"credits_remaining_usd":1}}"#.utf8))
        }
        defer { NeuralWattTestURLProtocol.handler = nil }

        _ = try await NeuralWattUsageFetcher.fetch(
            apiKey: "key",
            session: session,
            environment: [:],
            sleeper: { delay in delays.append(delay) }
        )

        #expect(recorder.requests.count == 2)
        #expect(delays.values == [1])
    }

    @Test(arguments: [401, 403])
    func authenticationFailureMapsToMissingCredentials(status: Int) async {
        let session = Self.session { request in
            Self.httpResponse(request, status: status, data: Data(#"{"secret":"not exposed"}"#.utf8))
        }
        defer { NeuralWattTestURLProtocol.handler = nil }

        await #expect(throws: NeuralWattUsageError.missingCredentials) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: "bad",
                session: session,
                environment: [:],
                sleeper: { _ in }
            )
        }
    }

    @Test
    func nonretryableHTTPAndNetworkFailuresUseExactCategories() async {
        let httpSession = Self.session { request in
            Self.httpResponse(request, status: 418, data: Data(#"{"secret":"not exposed"}"#.utf8))
        }
        await #expect(throws: NeuralWattUsageError.apiError("HTTP 418")) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: "key", session: httpSession, environment: [:], sleeper: { _ in }
            )
        }

        let networkSession = Self.session { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: NeuralWattUsageError.self) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: "key", session: networkSession, environment: [:], sleeper: { _ in }
            )
        }
        NeuralWattTestURLProtocol.handler = nil
    }

    @Test
    func cancellationPropagatesAndPreflightFailuresDoNotNetwork() async {
        let recorder = NeuralWattRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            throw URLError(.cancelled)
        }
        defer { NeuralWattTestURLProtocol.handler = nil }

        await #expect(throws: CancellationError.self) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: "key", session: session, environment: [:], sleeper: { _ in }
            )
        }
        await #expect(throws: NeuralWattUsageError.missingCredentials) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: nil, session: session, environment: [:], sleeper: { _ in }
            )
        }
        await #expect(throws: NeuralWattSettingsError.invalidEndpointOverride("NEURALWATT_API_URL")) {
            _ = try await NeuralWattUsageFetcher.fetch(
                apiKey: "key",
                session: session,
                environment: ["NEURALWATT_API_URL": "http://bad.test"],
                sleeper: { _ in }
            )
        }
        #expect(recorder.requests.count == 1)
    }

    private static func snapshot(_ body: String) throws -> NeuralWattUsageSnapshot {
        try NeuralWattUsageFetcher.parseSnapshot(Data(body.utf8), updatedAt: Date(timeIntervalSince1970: 1))
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        NeuralWattTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeuralWattTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(
        _ request: URLRequest,
        status: Int,
        headers: [String: String]? = nil,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
            data
        )
    }

    private static let fullQuota = #"""
    {
      "snapshot_at": "2026-09-01T01:02:03Z",
      "balance": {
        "credits_remaining_usd": 75,
        "total_credits_usd": 100,
        "credits_used_usd": 25,
        "accounting_method": "prepaid"
      },
      "usage": {
        "lifetime": {"cost_usd": 80, "requests": 1000, "tokens": 500000, "energy_kwh": 30},
        "current_month": {"cost_usd": 12.5, "requests": 200, "tokens": 100000, "energy_kwh": 4.25}
      },
      "limits": {"overage_limit_usd": 20, "rate_limit_tier": "tier_2"},
      "subscription": {
        "plan": "pro_energy",
        "status": "active",
        "billing_interval": "monthly",
        "current_period_start": "2026-09-01T00:00:00Z",
        "current_period_end": "2026-10-01T00:00:00.123Z",
        "auto_renew": false,
        "kwh_included": 200,
        "kwh_used": 50,
        "kwh_remaining": 150,
        "in_overage": false
      },
      "key": {
        "name": "primary",
        "allowance": {
          "limit_usd": 20,
          "period": "monthly",
          "spent_usd": 5,
          "remaining_usd": 15,
          "blocked": false
        }
      }
    }
    """#
}

private nonisolated final class NeuralWattRequestRecorder: @unchecked Sendable {
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

private nonisolated final class NeuralWattDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: TimeInterval) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private nonisolated final class NeuralWattTestURLProtocol: URLProtocol {
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
