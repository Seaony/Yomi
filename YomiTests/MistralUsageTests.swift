import Foundation
import Testing
@testable import Yomi

@Suite("Mistral usage", .serialized)
struct MistralUsageTests {
    private nonisolated static let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!

    @Test
    func parsesBillingTokensCostsDatesAndDailyModels() throws {
        let snapshot = try MistralUsageFetcher.parseUsage(data: Data(Self.billingJSON.utf8), updatedAt: Self.now)

        #expect(snapshot.totalInputTokens == 120)
        #expect(snapshot.totalOutputTokens == 40)
        #expect(snapshot.totalCachedTokens == 10)
        #expect(snapshot.modelCount == 1)
        #expect(abs(snapshot.totalCost - 0.00028) < 0.000_000_1)
        #expect(snapshot.currency == "EUR")
        #expect(snapshot.currencySymbol == "€")
        #expect(snapshot.daily.map(\.day) == ["2026-07-15", "2026-07-16"])
        #expect(snapshot.daily.last?.totalTokens == 150)
        #expect(snapshot.daily.last?.models.first?.name == "mistral-small-latest")
        #expect(snapshot.startDate == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        #expect(snapshot.endDate == ISO8601DateFormatter().date(from: "2026-07-31T23:59:59Z"))
    }

    @Test
    func nonTokenUnitsContributeCostButNotTokenTotals() throws {
        let json = """
        {
          "libraries_api":{"pages":{"models":{"ocr":{"input":[{
            "billing_metric":"pages","billing_display_name":"OCR pages","billing_group":"input",
            "timestamp":"2026-07-16","value":42
          }]}}}},
          "currency":"EUR","currency_symbol":"€",
          "prices":[{"billing_metric":"pages","billing_group":"input","price":"0.01"}]
        }
        """
        let snapshot = try MistralUsageFetcher.parseUsage(data: Data(json.utf8), updatedAt: Self.now)

        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.daily.first?.totalTokens == 0)
        #expect(snapshot.totalCost == 0.42)
        #expect(snapshot.daily.first?.cost == 0.42)
    }

    @Test
    func missingCurrencyStaysExplicitlyUnknown() throws {
        let snapshot = try MistralUsageFetcher.parseUsage(data: Data("{}".utf8), updatedAt: Self.now)
        #expect(snapshot.currency == "XXX")
        #expect(snapshot.currencySymbol == "¤")
        #expect(snapshot.totalCost == 0)
    }

    @Test
    func nonfiniteOrOverflowingPricesNeverCreateNonfiniteCost() throws {
        for price in ["NaN", "Infinity", "1e308"] {
            let json = """
            {"completion":{"models":{"model":{"input":[
              {"billing_metric":"tokens","billing_group":"input","timestamp":"2026-07-16","value":2}
            ]}}},"prices":[{"billing_metric":"tokens","billing_group":"input","price":"\(price)"}]}
            """
            let snapshot = try MistralUsageFetcher.parseUsage(data: Data(json.utf8), updatedAt: Self.now)
            #expect(snapshot.totalCost == 0)
            #expect(snapshot.totalCost.isFinite)
            #expect(snapshot.daily.first?.cost == 0)
        }
    }

    @Test
    func parsesCreditsAndRejectsNonfiniteAvailableBalance() throws {
        let credits = try MistralUsageFetcher.parseCredits(data: Data("""
        {"wallet_amount":12.5,"credit_notes_amount":2.25,"ongoing_usage_balance":1.5,"currency":"USD"}
        """.utf8))
        #expect(credits.availableAmount == 13.25)
        #expect(MistralUsageFetcher.currency(credits.availableAmount, code: credits.currency) == "$13.25")

        #expect(throws: MistralUsageError.self) {
            _ = try MistralUsageFetcher.parseCredits(data: Data("""
            {"wallet_amount":1e308,"credit_notes_amount":1e308,"ongoing_usage_balance":0,"currency":"USD"}
            """.utf8))
        }
    }

    @Test
    func parsesVibeMonthlyPlanAndRejectsOutOfRangePercent() throws {
        let value = try MistralUsageFetcher.parseVibeUsage(data: Self.vibe(37.5))
        #expect(value.usedPercent == 37.5)
        #expect(value.resetsAt == ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))

        #expect(throws: MistralUsageError.self) {
            _ = try MistralUsageFetcher.parseVibeUsage(data: Self.vibe(101))
        }
    }

    @Test
    func cookieNormalizationRequiresOrySessionAndAcceptsDocumentedForms() {
        #expect(MistralUsageFetcher.normalizedCookie(
            "Cookie: ory_session_test=abc; csrftoken=csrf"
        ) == "ory_session_test=abc; csrftoken=csrf")
        #expect(MistralUsageFetcher.normalizedCookie(
            "curl 'https://admin.mistral.ai' -H 'Cookie: ory_session_test=abc; csrftoken=csrf'"
        ) == "ory_session_test=abc; csrftoken=csrf")
        #expect(MistralUsageFetcher.normalizedCookie("csrftoken=csrf") == nil)
        #expect(MistralUsageFetcher.normalizedCookie("ory_session_test=abc\r\nX-Leak: x") == nil)
    }

    @Test
    func browserImportConfigurationMatchesReferenceExactly() {
        #expect(MistralUsageFetcher.cookieDomains == [
            "mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "console.mistral.ai",
        ])
        #expect(MistralUsageFetcher.browserOrder == [.chrome, .firefox, .safari])
    }

    @Test
    func consoleCookieHeaderForwardsOnlyCSRFAndOrySessions() {
        let header = MistralUsageFetcher.consoleCookieHeader(
            csrfToken: "csrf",
            adminCookieHeader: "csrftoken=csrf; ory_session_a=one; admin_secret=drop; ory_session_b=two"
        )
        #expect(header == "csrftoken=csrf; ory_session_a=one; ory_session_b=two")
        #expect(!header.contains("admin_secret"))
    }

    @Test
    func usageRequestUsesCurrentUTCMonthAndExactWebHeaders() async throws {
        let recorder = MistralRequestRecorder()
        MistralTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data(Self.billingJSON.utf8))
        }
        defer { MistralTestURLProtocol.handler = nil }

        _ = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            csrfToken: "csrf",
            session: Self.session(),
            now: Self.now,
            timeout: 7
        )
        let request = try #require(recorder.requests.first)
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

        #expect(request.url?.host == "admin.mistral.ai")
        #expect(request.url?.path == "/api/billing/v2/usage")
        #expect(Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            == ["month": "7", "year": "2026"])
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 7)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc; csrftoken=csrf")
        #expect(request.value(forHTTPHeaderField: "X-CSRFTOKEN") == "csrf")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://admin.mistral.ai")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://admin.mistral.ai/organization/usage")
    }

    @Test
    func creditsRequestUsesExactEndpointAndExistingSession() async throws {
        let recorder = MistralRequestRecorder()
        MistralTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data("""
            {"wallet_amount":3,"credit_notes_amount":4,"ongoing_usage_balance":0,"currency":"EUR"}
            """.utf8))
        }
        defer { MistralTestURLProtocol.handler = nil }

        let credits = try await MistralUsageFetcher.fetchCredits(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            csrfToken: "csrf",
            session: Self.session()
        )
        let request = try #require(recorder.requests.first)
        #expect(request.url == MistralUsageFetcher.creditsURL)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc; csrftoken=csrf")
        #expect(request.value(forHTTPHeaderField: "X-CSRFTOKEN") == "csrf")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://admin.mistral.ai/organization/billing")
        #expect(credits.availableAmount == 7)
    }

    @Test
    func vibeRequestUsesExactEndpointAndRestrictedCookies() async throws {
        let recorder = MistralRequestRecorder()
        MistralTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Self.vibe(12.5))
        }
        defer { MistralTestURLProtocol.handler = nil }

        let vibe = try await MistralUsageFetcher.fetchVibeUsage(
            csrfToken: " csrf ",
            cookieHeader: "ory_session_test=abc; csrftoken=csrf; admin_secret=drop",
            session: Self.session(),
            timeout: 2
        )
        let request = try #require(recorder.requests.first)
        #expect(request.url == MistralUsageFetcher.vibeURL)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 2)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "csrftoken=csrf; ory_session_test=abc")
        #expect(request.value(forHTTPHeaderField: "X-CSRFToken") == "csrf")
        #expect(vibe.usedPercent == 12.5)
    }

    @Test
    func optionalCreditsAndVibeFailuresNeverDiscardPrimaryBilling() async throws {
        let recorder = MistralRequestRecorder()
        MistralTestURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/api/billing/v2/usage" { return (200, Data(Self.billingJSON.utf8)) }
            return (500, Data("private optional response".utf8))
        }
        defer { MistralTestURLProtocol.handler = nil }

        let snapshot = try await MistralUsageFetcher.fetchSnapshot(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            session: Self.session(),
            now: Self.now
        )

        #expect(snapshot.totalInputTokens == 120)
        #expect(snapshot.credits == nil)
        #expect(snapshot.vibeUsage == nil)
        #expect(recorder.requests.map { $0.url?.host ?? "" } == [
            "admin.mistral.ai", "console.mistral.ai", "admin.mistral.ai",
        ])
    }

    @Test
    func invalidImportedSessionsRotateInOrderAndCacheOnlySuccessfulHeader() async throws {
        let recorder = MistralRequestRecorder()
        let cache = MistralCacheRecorder()
        MistralTestURLProtocol.handler = { request in
            recorder.append(request)
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            return cookie == "ory_session_safari=valid"
                ? (200, Data(Self.billingJSON.utf8))
                : (401, Data())
        }
        defer { MistralTestURLProtocol.handler = nil }

        let usage = try await MistralUsageFetcher.fetchFromSessions(
            [
                .init(cookieHeader: "ory_session_chrome=stale", sourceLabel: "Chrome"),
                .init(cookieHeader: "ory_session_firefox=stale", sourceLabel: "Firefox"),
                .init(cookieHeader: "ory_session_safari=valid", sourceLabel: "Safari"),
            ],
            session: Self.session(),
            cacheUpdate: { cache.append($0) },
            now: Self.now
        )

        #expect(usage.state == .ready)
        #expect(recorder.requests
            .filter { $0.url?.path == "/api/billing/v2/usage" }
            .map { $0.value(forHTTPHeaderField: "Cookie") ?? "" } == [
            "ory_session_chrome=stale", "ory_session_firefox=stale", "ory_session_safari=valid",
        ])
        #expect(cache.values.count == 1)
        #expect(cache.values[0] == "ory_session_safari=valid")
    }

    @Test
    func authenticationStatusesStayDistinctFromOtherAPIErrors() async {
        for status in [401, 403] {
            MistralTestURLProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: MistralUsageError.invalidCredentials) {
                _ = try await MistralUsageFetcher.fetchUsage(
                    cookieHeader: "ory_session_test=bad",
                    csrfToken: nil,
                    session: Self.session(),
                    now: Self.now
                )
            }
        }
        MistralTestURLProtocol.handler = { _ in (429, Data()) }
        await #expect(throws: MistralUsageError.apiError("HTTP 429")) {
            _ = try await MistralUsageFetcher.fetchUsage(
                cookieHeader: "ory_session_test=abc",
                csrfToken: nil,
                session: Self.session(),
                now: Self.now
            )
        }
        MistralTestURLProtocol.handler = nil
    }

    @Test
    func mapsBalanceSpendMonthlyPlanAndTokenDataWithoutInventingQuota() throws {
        let primary = try MistralUsageFetcher.parseUsage(data: Data(Self.billingJSON.utf8), updatedAt: Self.now)
        let snapshot = MistralUsageSnapshot(
            totalCost: primary.totalCost,
            currency: primary.currency,
            currencySymbol: primary.currencySymbol,
            totalInputTokens: primary.totalInputTokens,
            totalOutputTokens: primary.totalOutputTokens,
            totalCachedTokens: primary.totalCachedTokens,
            modelCount: primary.modelCount,
            daily: primary.daily,
            credits: MistralCredits(
                walletAmount: 10,
                creditNotesAmount: 2.5,
                ongoingUsageBalance: 1,
                currency: "USD"
            ),
            vibeUsage: MistralVibeUsage(
                usedPercent: 25,
                resetsAt: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
            ),
            startDate: primary.startDate,
            endDate: primary.endDate,
            updatedAt: primary.updatedAt
        )
        let usage = snapshot.toProviderUsage()

        #expect(usage.id == ProviderID(rawValue: "mistral"))
        #expect(usage.windows.map(\.id) == ["mistral-monthly-plan"])
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.balance == "$11.50")
        #expect(usage.details.map(\.id) == ["mistral-balance", "mistral-api-spend", "mistral-monthly-tokens"])
        #expect(usage.today?.tokens == 150)
        #expect(usage.today?.valueUSD == nil)
        #expect(usage.last30Days?.tokens == 170)
    }

    private nonisolated static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MistralTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func vibe(_ percent: Double) -> Data {
        Data("""
        [{"result":{"data":{"json":{"usage_percentage":\(percent),"reset_at":"2026-08-01T00:00:00Z"}}}}]
        """.utf8)
    }

    private nonisolated static let billingJSON = """
    {
      "completion":{"models":{"mistral-small::2506":{
        "input":[
          {"billing_metric":"small","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2026-07-15","value":20,"value_paid":20},
          {"billing_metric":"small","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2026-07-16","value":100,"value_paid":100}
        ],
        "cached":[{"billing_metric":"small","billing_display_name":"mistral-small-latest","billing_group":"cached","timestamp":"2026-07-16","value":10}],
        "output":[{"billing_metric":"small","billing_display_name":"mistral-small-latest","billing_group":"output","timestamp":"2026-07-16","value":40}]
      }}},
      "ocr":{"models":{}},"connectors":{"models":{}},"audio":{"models":{}},
      "libraries_api":{"pages":{"models":{}},"tokens":{"models":{}}},
      "fine_tuning":{"training":{},"storage":{}},
      "currency":"EUR","currency_symbol":"€",
      "start_date":"2026-07-01T00:00:00Z","end_date":"2026-07-31T23:59:59Z",
      "prices":[
        {"billing_metric":"small","billing_group":"input","price":"0.000001"},
        {"billing_metric":"small","billing_group":"cached","price":"0.000002"},
        {"billing_metric":"small","billing_group":"output","price":"0.0000035"}
      ]
    }
    """
}

private nonisolated final class MistralRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private nonisolated final class MistralCacheRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    var values: [String?] { lock.withLock { storage } }
    func append(_ value: String?) { lock.withLock { storage.append(value) } }
}

private nonisolated final class MistralTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
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
