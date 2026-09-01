import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct FireworksUsageTests {
    @Test
    func sumsRatedLineItemsWithoutCreatingQuotaWindows() throws {
        let data = Data("""
        {
          "lineItems": [
            {"totalCost":{"currencyCode":"USD","nanos":492256016,"units":"0"}},
            {"totalCost":{"currencyCode":"USD","nanos":33292280,"units":"1"}}
          ],
          "usageBuckets": []
        }
        """.utf8)

        let summary = try FireworksUsageFetcher.parseSummary(data: data)
        let snapshot = FireworksUsageSnapshot(
            summary: summary,
            accountSlug: "team",
            accountSlugWasDiscovered: false
        ).toProviderUsage()

        #expect(abs((summary.last30DaysSpend ?? -1) - 1.525548296) < 0.000000001)
        #expect(summary.currencyCode == "USD")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.additionalWindows.isEmpty)
        #expect(snapshot.balance == nil)
        #expect(snapshot.providerCost?.used == summary.last30DaysSpend)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Last 30 days")
    }

    @Test
    func sumsOnlyTheFirstRatedCurrency() throws {
        let data = Data("""
        {"lineItems":[
          {"totalCost":{"currencyCode":"USD","nanos":100000000,"units":"1"}},
          {"totalCost":{"currencyCode":"EUR","nanos":900000000,"units":"9"}},
          {"totalCost":{"currencyCode":"USD","nanos":250000000,"units":"0"}}
        ]}
        """.utf8)

        let summary = try FireworksUsageFetcher.parseSummary(data: data)

        #expect(summary.currencyCode == "USD")
        #expect(abs((summary.last30DaysSpend ?? -1) - 1.35) < 0.000000001)
    }

    @Test
    func acceptsEmptyRatedUsageWithoutSynthesizingSpend() throws {
        let summary = try FireworksUsageFetcher.parseSummary(
            data: Data(#"{"lineItems":[],"usageBuckets":[]}"#.utf8)
        )
        let usage = FireworksUsageSnapshot(
            summary: summary,
            accountSlug: "team",
            accountSlugWasDiscovered: false
        ).toProviderUsage()

        #expect(summary.last30DaysSpend == nil)
        #expect(summary.currencyCode == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.windows.isEmpty)
    }

    @Test
    func rejectsMalformedRootAndUnsafeAccountSlugs() {
        #expect(throws: FireworksUsageError.self) {
            try FireworksUsageFetcher.parseSummary(data: Data(#"[{"lineItems":[]}]"#.utf8))
        }
        for slug in ["sp ace", "has/slash", "has?query", "has#fragment", "percent%2F", "coléon"] {
            #expect(throws: FireworksUsageError.invalidAccountSlug(slug)) {
                try FireworksUsageFetcher.resolveSummaryURL(accountSlug: slug)
            }
        }
        for slug in ["x0mh0x", "acct-1_x.d"] {
            let url = try? FireworksUsageFetcher.resolveSummaryURL(accountSlug: slug)
            #expect(url?.path == "/v1/accounts/\(slug)/billing/summary")
        }
    }

    @Test
    func cleansAndPrioritizesConfiguredCredentials() {
        let environment = [
            "FIREWORKS_API_KEY": "env-key",
            "FIREWORKS_KEY": "legacy-key",
            "FIREWORKS_ACCOUNT_SLUG": "' env-team '",
        ]
        #expect(FireworksUsageFetcher.resolvedAPIKey(
            configured: "\" configured-key \"",
            environment: environment
        ) == "configured-key")
        #expect(FireworksUsageFetcher.resolvedAPIKey(configured: nil, environment: environment) == "env-key")
        #expect(FireworksUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["FIREWORKS_KEY": "legacy-key"]
        ) == "legacy-key")
        #expect(FireworksUsageFetcher.resolvedAccountSlug(
            configured: "configured-team",
            environment: environment
        ) == "configured-team")
        #expect(FireworksUsageFetcher.resolvedAccountSlug(
            configured: nil,
            environment: environment
        ) == "env-team")
        #expect(ProviderCatalog.byID[ProviderID(rawValue: "fireworks")]?.environmentKeys == [
            "FIREWORKS_API_KEY", "FIREWORKS_KEY",
        ])
    }

    @Test
    func fetchSendsBoundedBillingRequest() async throws {
        let session = makeSession { request in
            let url = try #require(request.url)
            #expect(url.path == "/v1/accounts/x0mh0x/billing/summary")
            #expect(url.query?.contains("startTime=") == true)
            #expect(url.query?.contains("endTime=") == true)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fw-test-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return response(
                request,
                status: 200,
                body: #"{"lineItems":[{"totalCost":{"currencyCode":"USD","nanos":500000000,"units":"0"}}]}"#
            )
        }

        let snapshot = try await FireworksUsageFetcher.fetch(
            apiKey: "fw-test-key",
            accountSlug: "x0mh0x",
            session: session,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.accountSlug == "x0mh0x")
        #expect(!snapshot.accountSlugWasDiscovered)
        #expect(snapshot.summary.last30DaysSpend == 0.5)
    }

    @Test
    func mapsAuthenticationRateLimitAndServerErrors() async throws {
        for (status, expected) in [
            (401, FireworksUsageError.authenticationRejected),
            (403, FireworksUsageError.authenticationRejected),
            (429, FireworksUsageError.rateLimited),
            (500, FireworksUsageError.apiError(500)),
        ] {
            let session = makeSession { request in response(request, status: status, body: "{}") }
            await #expect(throws: expected) {
                try await FireworksUsageFetcher.fetch(
                    apiKey: "fw-test-key",
                    accountSlug: "x0mh0x",
                    session: session
                )
            }
        }
    }

    @Test
    func missingSlugDiscoversSingleAccountBeforeBilling() async throws {
        let session = makeSession { request in
            switch request.url?.path {
            case "/v1/accounts":
                response(request, status: 200, body: #"{"accounts":[{"name":"accounts/discovered-team"}]}"#)
            case "/v1/accounts/discovered-team/billing/summary":
                response(
                    request,
                    status: 200,
                    body: #"{"lineItems":[{"totalCost":{"currencyCode":"USD","nanos":250000000,"units":"2"}}]}"#
                )
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await FireworksUsageFetcher.fetch(
            apiKey: "fw-test-key",
            accountSlug: nil,
            session: session
        )

        #expect(snapshot.accountSlug == "discovered-team")
        #expect(snapshot.accountSlugWasDiscovered)
        #expect(snapshot.summary.last30DaysSpend == 2.25)
    }

    @Test
    func rejectsRepeatedAccountPageToken() async {
        let session = makeSession { request in
            response(
                request,
                status: 200,
                body: #"{"accounts":[],"nextPageToken":"repeated"}"#
            )
        }

        await #expect(throws: FireworksUsageError.parseFailed(
            "Accounts API returned a repeated page token"
        )) {
            try await FireworksUsageFetcher.fetch(
                apiKey: "fw-test-key",
                accountSlug: nil,
                session: session
            )
        }
    }

    @Test
    func configured404RecoversOnlyWhenOneAccountIsVisible() async throws {
        let session = makeSession { request in
            switch request.url?.path {
            case "/v1/accounts/old-slug/billing/summary":
                response(request, status: 404, body: "{}")
            case "/v1/accounts":
                response(request, status: 200, body: #"{"accounts":[{"name":"accounts/current-slug"}]}"#)
            case "/v1/accounts/current-slug/billing/summary":
                response(
                    request,
                    status: 200,
                    body: #"{"lineItems":[{"totalCost":{"currencyCode":"USD","nanos":0,"units":"1"}}]}"#
                )
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await FireworksUsageFetcher.fetch(
            apiKey: "fw-test-key",
            accountSlug: "old-slug",
            session: session
        )

        #expect(snapshot.accountSlug == "current-slug")
        #expect(snapshot.accountSlugWasDiscovered)
        #expect(snapshot.summary.last30DaysSpend == 1)
    }

    @Test
    func emptyBillingResponseValidatesConfiguredAccount() async throws {
        let validSession = makeSession { request in
            if request.url?.path == "/v1/accounts" {
                return response(request, status: 200, body: #"{"accounts":[{"name":"accounts/team"}]}"#)
            }
            return response(request, status: 200, body: #"{"lineItems":[]}"#)
        }
        let snapshot = try await FireworksUsageFetcher.fetch(
            apiKey: "fw-test-key",
            accountSlug: "team",
            session: validSession
        )
        #expect(snapshot.summary.last30DaysSpend == nil)

        let invalidSession = makeSession { request in
            if request.url?.path == "/v1/accounts" {
                return response(request, status: 200, body: #"{"accounts":[{"name":"accounts/other"}]}"#)
            }
            return response(request, status: 200, body: #"{"lineItems":[]}"#)
        }
        await #expect(throws: FireworksUsageError.accountNotFound("team")) {
            try await FireworksUsageFetcher.fetch(
                apiKey: "fw-test-key",
                accountSlug: "team",
                session: invalidSession
            )
        }
    }

    @Test
    func accountDiscoveryIsPaginatedDeduplicatedAndSorted() async throws {
        let session = makeSession { request in
            if request.url?.query == "pageToken=next" {
                return response(
                    request,
                    status: 200,
                    body: #"{"accounts":[{"accountId":"alpha"},{"id":"alpha"}]}"#
                )
            }
            return response(
                request,
                status: 200,
                body: #"{"accounts":[{"name":"accounts/zeta"}],"nextPageToken":"next"}"#
            )
        }

        await #expect(throws: FireworksUsageError.multipleAccountsFound(["alpha", "zeta"])) {
            try await FireworksUsageFetcher.fetch(
                apiKey: "fw-test-key",
                accountSlug: nil,
                session: session
            )
        }
    }

    @Test
    func requiresAPIKey() async {
        await #expect(throws: FireworksUsageError.missingCredentials) {
            try await FireworksUsageFetcher.fetch(
                apiKey: "  ",
                accountSlug: "team",
                session: URLSession(configuration: .ephemeral)
            )
        }
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FireworksTestURLProtocol.self]
        FireworksTestURLProtocol.handler = handler
        return URLSession(configuration: configuration)
    }

    private func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let url = request.url ?? URL(string: "https://api.fireworks.ai")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, Data(body.utf8))
    }
}

private final class FireworksTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
