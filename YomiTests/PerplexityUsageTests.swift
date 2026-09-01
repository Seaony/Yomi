import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct PerplexityUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_740_000_000)
    private static let future: TimeInterval = 1_750_000_000
    private static let past: TimeInterval = 1_700_000_000
    private static let renewal: TimeInterval = 1_743_000_000

    @Test
    func parsesAllPoolsAndMapsExactDisplayOrder() throws {
        let snapshot = try parse(
            balance: 23_065,
            purchasedField: 0,
            grants: """
            {"type":"recurring","amount_cents":10000,"expires_at_ts":\(Self.future)},
            {"type":"purchased","amount_cents":40000},
            {"type":"promotional","amount_cents":55000,"expires_at_ts":\(Self.future)}
            """,
            usage: 81_935
        )
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.recurringUsed == 10_000)
        #expect(snapshot.purchasedUsed == 40_000)
        #expect(snapshot.promoUsed == 31_935)
        #expect(usage.windows.map(\.label) == ["Credits", "Bonus credits", "Purchased"])
        #expect(usage.windows[0].usedFraction == 1)
        #expect(abs(usage.windows[1].usedFraction - 31_935.0 / 55_000.0) < 0.000_001)
        #expect(usage.windows[2].usedFraction == 1)
        #expect(usage.windows[0].resetsAt?.timeIntervalSince1970 == Self.renewal)
        #expect(usage.windows[1].resetsAt == nil)
        #expect(usage.windows[2].resetsAt == nil)
        #expect(usage.plan == "Max")
        #expect(usage.balance == nil)
        #expect(usage.providerCost == nil)
    }

    @Test
    func waterfallUsesRecurringThenPurchasedThenPromotional() throws {
        let snapshot = try parse(
            purchasedField: 3_000,
            grants: """
            {"type":"recurring","amount_cents":5000},
            {"type":"promotional","amount_cents":4000,"expires_at_ts":\(Self.future)}
            """,
            usage: 9_000
        )

        #expect(snapshot.recurringUsed == 5_000)
        #expect(snapshot.purchasedUsed == 3_000)
        #expect(snapshot.promoUsed == 1_000)
    }

    @Test
    func expiredPromotionalGrantIsExcluded() throws {
        let snapshot = try parse(
            grants: """
            {"type":"recurring","amount_cents":10000},
            {"type":"promotional","amount_cents":5000,"expires_at_ts":\(Self.past)}
            """,
            usage: 1_000
        )

        #expect(snapshot.promoTotal == 0)
        #expect(snapshot.promoUsed == 0)
        #expect(snapshot.promoExpiration == nil)
    }

    @Test
    func purchasedCreditsUseLargerOfGrantAndTopLevelField() throws {
        let grantWins = try parse(
            purchasedField: 3_000,
            grants: """
            {"type":"recurring","amount_cents":5000},
            {"type":"purchased","amount_cents":8000}
            """,
            usage: 0
        )
        let fieldWins = try parse(
            purchasedField: 9_000,
            grants: #"{"type":"purchased","amount_cents":8000}"#,
            usage: 0
        )

        #expect(grantWins.purchasedTotal == 8_000)
        #expect(fieldWins.purchasedTotal == 9_000)
    }

    @Test
    func onlyFallbackPoolsOmitFakeRecurringWindow() throws {
        let usage = try parse(
            purchasedField: 2_000,
            grants: #"{"type":"promotional","amount_cents":4000}"#,
            usage: 0
        ).toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Bonus credits", "Purchased"])
        #expect(usage.windows.map(\.usedFraction) == [0, 0])
        #expect(usage.plan == nil)
    }

    @Test
    func emptyPoolsKeepThreeFullyDepletedWindows() throws {
        let usage = try parse(grants: "", usage: 0).toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Credits", "Bonus credits", "Purchased"])
        #expect(usage.windows.map(\.usedFraction) == [1, 1, 1])
        #expect(usage.windows[0].detail == "0/0 credits")
    }

    @Test
    func planInferenceMatchesRecurringAllotmentThresholds() throws {
        let none = try parse(grants: "", usage: 0)
        let pro = try parse(grants: #"{"type":"recurring","amount_cents":1000}"#, usage: 0)
        let max = try parse(grants: #"{"type":"recurring","amount_cents":5000}"#, usage: 0)

        #expect(none.planName == nil)
        #expect(pro.planName == "Pro")
        #expect(max.planName == "Max")
    }

    @Test
    func camelCasePluginPayloadMatchesNativePayload() throws {
        let data = Data("""
        {
          "balanceCents": 7250,
          "renewalDateTs": \(Self.renewal),
          "currentPeriodPurchasedCents": 0,
          "creditGrants": [
            {"type":"recurring","amountCents":10000,"expiresAtTs":\(Self.future)}
          ],
          "totalUsageCents": 2750
        }
        """.utf8)
        let snapshot = try PerplexityUsageFetcher.parse(data: data, now: Self.now)

        #expect(snapshot.recurringTotal == 10_000)
        #expect(snapshot.recurringUsed == 2_750)
        #expect(snapshot.balanceCents == 7_250)
    }

    @Test
    func malformedOrIncompletePayloadDoesNotCreateQuota() {
        #expect(throws: PerplexityUsageError.unreadableResponse) {
            try PerplexityUsageFetcher.parse(data: Data(#"{"balance_cents":"bad"}"#.utf8))
        }
        #expect(throws: PerplexityUsageError.unreadableResponse) {
            try PerplexityUsageFetcher.parse(data: Data(#"{"status":"ok"}"#.utf8))
        }
    }

    @Test
    func promoExpiryUsesEarliestActiveGrantAndEnglishMonth() throws {
        let firstExpiry: TimeInterval = 1_768_478_400
        let snapshot = try parse(
            grants: """
            {"type":"promotional","amount_cents":200,"expires_at_ts":\(firstExpiry + 86400)},
            {"type":"promotional","amount_cents":300,"expires_at_ts":\(firstExpiry)}
            """,
            usage: 0,
            now: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let promo = try #require(snapshot.toProviderUsage().windows.first { $0.label == "Bonus credits" })

        #expect(snapshot.promoExpiration?.timeIntervalSince1970 == firstExpiry)
        #expect(promo.detail?.contains("Jan") == true)
        #expect(PerplexityUsageFetcher.promoExpiryFormatter.locale.identifier == "en_US_POSIX")
    }

    @Test
    func bareTokenTriesEverySupportedCookieName() {
        let cookie = PerplexityUsageFetcher.cookieOverride(from: "bare-token")

        #expect(cookie?.name == PerplexityUsageFetcher.defaultSessionCookieName)
        #expect(cookie?.token == "bare-token")
        #expect(cookie?.requestCookieNames == PerplexityUsageFetcher.supportedSessionCookieNames)
    }

    @Test
    func cookieHeaderPrefersAuthJSAndPreservesOriginalName() {
        let cookie = PerplexityUsageFetcher.cookieOverride(
            from: "__Secure-next-auth.session-token=legacy; AuthJS.Session-Token=live"
        )

        #expect(cookie?.name == "AuthJS.Session-Token")
        #expect(cookie?.token == "live")
    }

    @Test
    func chunkedSessionCookieIsReassembledInIndexOrder() {
        let cookie = PerplexityUsageFetcher.cookieOverride(
            from: "authjs.session-token.1=chunk-b; authjs.session-token.0=chunk-a"
        )

        #expect(cookie?.name == "authjs.session-token")
        #expect(cookie?.token == "chunk-achunk-b")
        #expect(PerplexityUsageFetcher.cookieOverride(
            from: "authjs.session-token.0=chunk-a; authjs.session-token.2=chunk-c"
        ) == nil)
    }

    @Test
    func environmentAliasesPreserveCookieNameAndQuoteCleaning() {
        let cookie = PerplexityUsageFetcher.environmentCookieOverride([
            "PERPLEXITY_COOKIE": "authjs.session-token=cookie-token",
        ])
        let bare = PerplexityUsageFetcher.environmentCookieOverride([
            "PERPLEXITY_SESSION_TOKEN": "'bare-token'",
            "PERPLEXITY_COOKIE": "authjs.session-token=ignored",
        ])

        #expect(cookie?.name == "authjs.session-token")
        #expect(cookie?.token == "cookie-token")
        #expect(bare?.token == "bare-token")
        #expect(bare?.requestCookieNames == PerplexityUsageFetcher.supportedSessionCookieNames)
    }

    @Test
    func httpCookieArraySupportsChunkedSession() throws {
        let cookies = try [
            #require(makeCookie(name: "__Secure-authjs.session-token.0", value: "chunk-a")),
            #require(makeCookie(name: "__Secure-authjs.session-token.1", value: "chunk-b")),
        ]
        let cookie = PerplexityUsageFetcher.sessionCookie(from: cookies)

        #expect(cookie?.name == "__Secure-authjs.session-token")
        #expect(cookie?.token == "chunk-achunk-b")
    }

    @Test
    func requestMatchesCreditsEndpointAndRequiredHeaders() async throws {
        PerplexityTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "authjs.session-token=session-token")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.perplexity.ai")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.perplexity.ai/account/usage")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/143.0.0.0") == true)
            return (200, Self.payload(grants: "", usage: 0))
        }
        defer { PerplexityTestURLProtocol.handler = nil }

        let snapshot = try await PerplexityUsageFetcher.fetchCredits(
            sessionToken: "session-token",
            cookieName: "authjs.session-token",
            session: makeSession(),
            now: Self.now
        )

        #expect(snapshot.totalUsageCents == 0)
    }

    @Test(arguments: [401, 403])
    func unauthorizedResponseMeansExpiredSession(status: Int) async {
        PerplexityTestURLProtocol.handler = { _ in (status, "denied") }
        defer { PerplexityTestURLProtocol.handler = nil }

        await #expect(throws: PerplexityUsageError.invalidSession) {
            try await PerplexityUsageFetcher.fetchCredits(
                sessionToken: "bad",
                session: makeSession()
            )
        }
    }

    @Test
    func nonAuthHTTPAndMalformedSuccessRemainDistinct() async {
        PerplexityTestURLProtocol.handler = { _ in (429, "limited") }
        await #expect(throws: PerplexityUsageError.requestFailed(429)) {
            try await PerplexityUsageFetcher.fetchCredits(
                sessionToken: "token",
                session: makeSession()
            )
        }

        PerplexityTestURLProtocol.handler = { _ in (200, #"{"status":"ok"}"#) }
        await #expect(throws: PerplexityUsageError.unreadableResponse) {
            try await PerplexityUsageFetcher.fetchCredits(
                sessionToken: "token",
                session: makeSession()
            )
        }
        PerplexityTestURLProtocol.handler = nil
    }

    @Test
    func bareManualTokenFallsBackAcrossSupportedCookieNames() async throws {
        nonisolated(unsafe) var attempted: [String] = []
        PerplexityTestURLProtocol.handler = { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            attempted.append(cookie)
            if cookie.hasPrefix("authjs.session-token=") {
                return (200, Self.payload(grants: "", usage: 0))
            }
            return (403, "denied")
        }
        defer { PerplexityTestURLProtocol.handler = nil }

        _ = try await PerplexityUsageFetcher.fetch(
            credential: "bare-token",
            source: .cookie,
            session: makeSession(),
            now: Self.now
        )

        #expect(attempted == [
            "__Secure-authjs.session-token=bare-token",
            "authjs.session-token=bare-token",
        ])
    }

    @Test
    func manualModeRejectsInvalidCookieWithoutAnyRequest() async {
        PerplexityTestURLProtocol.handler = { _ in
            Issue.record("Invalid manual cookie must not issue a request")
            return (200, Self.payload(grants: "", usage: 0))
        }
        defer { PerplexityTestURLProtocol.handler = nil }

        await #expect(throws: PerplexityUsageError.invalidCookie) {
            try await PerplexityUsageFetcher.fetch(
                credential: "foo=bar",
                source: .cookie,
                session: makeSession()
            )
        }
    }

    private func parse(
        balance: Double = 0,
        purchasedField: Double = 0,
        grants: String,
        usage: Double,
        now: Date = Self.now
    ) throws -> PerplexityUsageFetcher.Snapshot {
        try PerplexityUsageFetcher.parse(
            data: Data(Self.payload(
                balance: balance,
                purchasedField: purchasedField,
                grants: grants,
                usage: usage
            ).utf8),
            now: now
        )
    }

    private static func payload(
        balance: Double = 0,
        purchasedField: Double = 0,
        grants: String,
        usage: Double
    ) -> String {
        """
        {
          "balance_cents": \(balance),
          "renewal_date_ts": \(renewal),
          "current_period_purchased_cents": \(purchasedField),
          "credit_grants": [\(grants)],
          "total_usage_cents": \(usage)
        }
        """
    }

    private func makeCookie(name: String, value: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: "www.perplexity.ai",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
        ])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerplexityTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class PerplexityTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
