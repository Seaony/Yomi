import Foundation
import SweetCookieKit
import Testing
@testable import Yomi

@Suite("ZoomMate usage", .serialized)
struct ZoomMateUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test
    func manualCaptureAcceptsExactFirstPartyStatusAndConstrainsHeadersToCapturedHost() throws {
        let raw = #"curl 'https://zoommate.zoom.us/ai-computer/api/v1/credits/status' -H 'authorization: token' -H 'cookie: leaf=x' -H 'user-agent: Captured' -H 'origin: https://evil.example' -H 'referer: https://evil.example/path' -H 'x-extra: nope'"#
        let context = try #require(ZoomMateUsageFetcher.requestContext(from: raw))
        #expect(context.authorization == "Bearer token")
        #expect(context.preferredHost == "zoommate.zoom.us")
        #expect(context.cookieHeaders.header(forHost: "zoommate.zoom.us") == "leaf=x")
        #expect(context.cookieHeaders.header(forHost: "ai.zoom.us") == nil)
        #expect(context.headers == ["User-Agent": "Captured"])
    }

    @Test(arguments: [
        "",
        #"curl 'http://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'Authorization: x'"#,
        #"curl 'https://evil.example/ai-computer/api/v1/credits/status' -H 'Authorization: x'"#,
        #"curl 'https://ai.zoom.us:443/ai-computer/api/v1/credits/status' -H 'Authorization: x'"#,
        #"curl 'https://user@ai.zoom.us/ai-computer/api/v1/credits/status' -H 'Authorization: x'"#,
        #"curl 'https://ai.zoom.us/ai-computer/api/v1/credits/history' -H 'Authorization: x'"#,
        #"curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status?q=1' -H 'Authorization: x'"#,
        #"curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status#x' -H 'Authorization: x'"#,
        #"curl --location 'https://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'Authorization: x'"#,
        #"curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'Cookie: x=1'"#,
    ])
    func manualCaptureRejectsAnythingOutsideExactContract(raw: String) {
        #expect(ZoomMateUsageFetcher.requestContext(from: raw) == nil)
    }

    @Test
    func bearerNormalizationAndExpiryMatchMintedJWTContract() {
        let jwt = Self.jwt(exp: 1_900_000_000)
        #expect(ZoomMateUsageFetcher.bearerHeaderValue(from: jwt) == "Bearer \(jwt)")
        #expect(ZoomMateUsageFetcher.bearerHeaderValue(from: "bearer \(jwt)") == "bearer \(jwt)")
        #expect(ZoomMateUsageFetcher.expiry(fromJWT: jwt) == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(ZoomMateUsageFetcher.expiry(fromJWT: "not-a-jwt") == nil)
    }

    @Test
    func cookieScopeNeverLeaksHostOnlyLeafCookiesAcrossFailoverHosts() {
        let records = [
            Self.record(domain: "zoom.us", scope: .domain, name: "parent"),
            Self.record(domain: "zoom.us", scope: .hostOnly, name: "parent-host"),
            Self.record(domain: "ai.zoom.us", scope: .hostOnly, name: "ai"),
            Self.record(domain: "zoommate.zoom.us", scope: .hostOnly, name: "mate"),
            Self.record(domain: "marketing.zoom.us", scope: .hostOnly, name: "marketing"),
        ]
        let headers = ZoomMateCookieImporter.cookieHeaders(from: records)
        #expect(headers.header(forHost: "ai.zoom.us") == "parent=fake; ai=fake")
        #expect(headers.header(forHost: "zoommate.zoom.us") == "parent=fake; mate=fake")
        #expect(ZoomMateCookieImporter.isSendable(
            cookieDomain: "zoom.us", scope: .domain, toHost: "not-zoom.example"
        ) == false)
    }

    @Test
    func cookieStorageIsCanonicalAndIgnoresUnapprovedHosts() throws {
        let headers = ZoomMateCookieHeaders(headersByHost: [
            "zoommate.zoom.us": " mate=1 ", "ai.zoom.us": "ai=1", "evil.example": "x=1",
        ])
        let encoded = try #require(headers.encodedForStorage())
        #expect(encoded == #"{"headersByHost":{"ai.zoom.us":"ai=1","zoommate.zoom.us":"mate=1"}}"#)
        #expect(ZoomMateCookieHeaders.decodeFromStorage(encoded) == headers)
    }

    @Test
    func snapshotAlwaysMapsExactlyOneCreditsWindow() {
        let start = Int64((Self.now - 86_400).timeIntervalSince1970 * 1_000)
        let end = Int64((Self.now + 86_400).timeIntervalSince1970 * 1_000)
        let usage = ZoomMateUsageSnapshot(
            creditStatus: ZoomMateCreditStatus(
                budgetCap: 100, usedCredit: 38, remainingCredit: 62,
                cycleStartDate: start, cycleEndDate: end, isUnlimited: false
            ),
            updatedAt: Self.now
        ).toProviderUsage(accountEmail: "user@example.com", language: .english)
        #expect(usage.windows.count == 1)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.windows[0].id == "zoommate-credits")
        #expect(usage.windows[0].label == "Credits")
        #expect(usage.windows[0].usedFraction == 0.38)
        #expect(usage.windows[0].resetsAt == Self.now + 86_400)
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: [
        ZoomMateCreditStatus(budgetCap: 0, usedCredit: 12, cycleEndDate: 1_900_000_000_000),
        ZoomMateCreditStatus(budgetCap: 100, usedCredit: 12, cycleEndDate: 1_900_000_000_000, isUnlimited: true),
    ])
    func unlimitedOrZeroBudgetNeverInventsAQuotaPercentage(status: ZoomMateCreditStatus) {
        let window = ZoomMateUsageSnapshot(creditStatus: status, updatedAt: Self.now).toProviderUsage().windows[0]
        #expect(window.usedFraction == 0)
        #expect(window.resetsAt == nil)
    }

    @Test
    func statusRequestUsesExactHeadersAndParsesOnlyCreditStatus() async throws {
        let recorder = ZoomMateRequestRecorder()
        ZoomMateTestURLProtocol.recorder = recorder
        ZoomMateTestURLProtocol.handler = { request in
            #expect(request.url?.host == "ai.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/credits/status")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ai-cookie=1")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://zoommate.zoom.us")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://zoommate.zoom.us")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-site")
            return (200, #"{"data":{"credit_status":{"budget_cap":100,"used_credit":25,"remaining_credit":75,"cycle_end_date":1900000000000}}}"#)
        }
        defer { Self.resetProtocol() }
        let snapshot = try await ZoomMateUsageFetcher.fetchCreditsStatus(
            context: Self.context(), session: Self.session(), now: Self.now
        )
        #expect(snapshot.creditStatus.budgetCap == 100)
        #expect(snapshot.creditStatus.usedCredit == 25)
        #expect(recorder.requests.count == 1)
    }

    @Test
    func statusFailsOverOnTransportAndNonAuthHTTPButNotAuthOrParse() async throws {
        var attempts: [String] = []
        ZoomMateTestURLProtocol.handler = { request in
            attempts.append(request.url!.host!)
            if request.url?.host == "ai.zoom.us" { return (500, "{}") }
            return (200, #"{"data":{"credit_status":{"budget_cap":10,"used_credit":1}}}"#)
        }
        _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: Self.context(), session: Self.session())
        #expect(attempts == ["ai.zoom.us", "zoommate.zoom.us"])

        for (status, body) in [(401, "{}"), (200, #"{"data":{}}"#)] {
            attempts = []
            ZoomMateTestURLProtocol.handler = { request in
                attempts.append(request.url!.host!)
                return (status, body)
            }
            await #expect(throws: ZoomMateUsageError.self) {
                _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(
                    context: Self.context(), session: Self.session()
                )
            }
            #expect(attempts == ["ai.zoom.us"])
        }
        Self.resetProtocol()
    }

    @Test
    func manualCaptureStartsOnCapturedHostAndDropsLeafCookieDuringFailover() async throws {
        let raw = #"curl 'https://zoommate.zoom.us/ai-computer/api/v1/credits/status' -H 'Authorization: token' -H 'Cookie: leaf=1'"#
        let context = try #require(ZoomMateUsageFetcher.requestContext(from: raw))
        var cookies: [String?] = []
        ZoomMateTestURLProtocol.handler = { request in
            cookies.append(request.value(forHTTPHeaderField: "Cookie"))
            return request.url?.host == "zoommate.zoom.us"
                ? (500, "{}")
                : (200, #"{"data":{"credit_status":{"budget_cap":100,"used_credit":5}}}"#)
        }
        defer { Self.resetProtocol() }
        _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, session: Self.session())
        #expect(cookies.count == 2)
        #expect(cookies[0] == "leaf=1")
        #expect(cookies[1] == nil)
    }

    @Test
    func loginBootstrapMintsBearerAndOptionalEmailUsingHostScopedCookie() async throws {
        let jwt = Self.jwt(exp: 1_900_000_000)
        ZoomMateTestURLProtocol.handler = { request in
            #expect(request.url?.path == "/ai-computer/api/v1/login")
            #expect(request.url?.query == "continue=https://zoommate.zoom.us/")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ai-cookie=1")
            return (200, "{\"data\":{\"nak\":\"\(jwt)\",\"user_profile\":{\"email\":\" user@example.com \"}}}")
        }
        defer { Self.resetProtocol() }
        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeaders: Self.context().cookieHeaders, session: Self.session()
        )
        #expect(minted.bearerToken == jwt)
        #expect(minted.accountEmail == "user@example.com")
    }

    @Test
    func bearerCacheReusesValidJWTAndRefreshesInsideSkew() async throws {
        let cache = ZoomMateBearerTokenCache()
        let headers = ZoomMateCookieHeaders(headersByHost: ["ai.zoom.us": "unique=session"])
        let firstNow = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = Self.jwt(exp: Int(firstNow.timeIntervalSince1970 + 3_600))
        var mints = 0
        ZoomMateTestURLProtocol.handler = { _ in
            mints += 1
            return (200, "{\"data\":{\"nak\":\"\(jwt)\"}}")
        }
        defer { Self.resetProtocol() }
        _ = try await ZoomMateUsageFetcher.requestContext(
            forCookieHeaders: headers, cache: cache, session: Self.session(), now: firstNow
        )
        _ = try await ZoomMateUsageFetcher.requestContext(
            forCookieHeaders: headers, cache: cache, session: Self.session(), now: firstNow + 120
        )
        #expect(mints == 1)
        _ = try await ZoomMateUsageFetcher.requestContext(
            forCookieHeaders: headers, cache: cache, session: Self.session(), now: firstNow + 3_550
        )
        #expect(mints == 2)
    }

    @Test
    func tokenWithoutExpiryIsNeverCached() async throws {
        let cache = ZoomMateBearerTokenCache()
        let headers = ZoomMateCookieHeaders(headersByHost: ["ai.zoom.us": "uncached=session"])
        var mints = 0
        ZoomMateTestURLProtocol.handler = { _ in
            mints += 1
            return (200, #"{"data":{"nak":"opaque-token"}}"#)
        }
        defer { Self.resetProtocol() }
        _ = try await ZoomMateUsageFetcher.requestContext(forCookieHeaders: headers, cache: cache, session: Self.session())
        _ = try await ZoomMateUsageFetcher.requestContext(forCookieHeaders: headers, cache: cache, session: Self.session())
        #expect(mints == 2)
    }

    @Test
    func historyUsesExactQueryAndPaginatesWithinOneHost() async throws {
        var pages: [String] = []
        ZoomMateTestURLProtocol.handler = { request in
            #expect(request.url?.host == "ai.zoom.us")
            let query = request.url!.query!
            pages.append(query)
            #expect(query.contains("app_id=demo_app"))
            #expect(query.contains("limit=2"))
            #expect(query.contains("sort_by=time"))
            #expect(query.contains("sort_order=desc"))
            #expect(query.contains("start_time="))
            #expect(query.contains("end_time="))
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "page" }!.value!
            if page == "0" {
                return (200, #"{"data":{"records":[{"session_id":"a","cost":1,"time":"2025-06-15T00:00:00Z"},{"session_id":"b","cost":2,"time":"2025-06-14T00:00:00Z"}],"total":3}}"#)
            }
            return (200, #"{"data":{"records":[{"session_id":"c","cost":3,"time":"2025-06-13T00:00:00Z"}],"total":3}}"#)
        }
        defer { Self.resetProtocol() }
        let history = try await ZoomMateUsageFetcher.fetchHistory(
            context: Self.context(),
            startTime: Date(timeIntervalSince1970: 1_749_000_000),
            endTime: Self.now,
            limit: 2,
            session: Self.session(),
            now: Self.now
        )
        #expect(history.records.map(\.sessionID) == ["a", "b", "c"])
        #expect(pages.count == 2)
    }

    @Test
    func historyStopsOnFullyStalePageEvenWhenTotalIsLarge() async throws {
        var calls = 0
        ZoomMateTestURLProtocol.handler = { _ in
            calls += 1
            return (200, #"{"data":{"records":[{"cost":1,"time":"2020-01-01T00:00:00Z"}],"total":999}}"#)
        }
        defer { Self.resetProtocol() }
        _ = try await ZoomMateUsageFetcher.fetchHistory(
            context: Self.context(), startTime: Self.now - 86_400, endTime: Self.now, session: Self.session()
        )
        #expect(calls == 1)
    }

    @Test
    func dailyHistoryExcludesDeletedNegativeMalformedAndOlderRecordsButCountsRunning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let history = ZoomMateCreditsHistorySnapshot(records: [
            .init(cost: 1.25, time: "2025-06-15T15:00:00Z"),
            .init(cost: 2, time: "2025-06-15T16:00:00.123Z", isRunning: true),
            .init(cost: 9, time: "2025-06-15T17:00:00Z", isDeleted: true),
            .init(cost: -1, time: "2025-06-15T18:00:00Z"),
            .init(cost: 4, time: "malformed"),
            .init(cost: 8, time: "2020-01-01T00:00:00Z"),
        ], creditStatus: nil, updatedAt: Self.now)
        let breakdown = history.dailyBreakdown(calendar: calendar, now: Self.now)
        #expect(breakdown == [ZoomMateCreditDailyBreakdown(day: "2025-06-15", totalCreditsUsed: 3.25)])
        #expect(history.todayCreditsUsed(calendar: calendar, now: Self.now) == 3.25)
    }

    @Test
    func historyFailureIsNonFatalAndNeverAddsFakeWindows() async throws {
        let capture = #"curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'Authorization: token'"#
        ZoomMateTestURLProtocol.handler = { request in
            if request.url?.path == ZoomMateUsageFetcher.creditsStatusPath {
                return (200, #"{"data":{"credit_status":{"budget_cap":100,"used_credit":20}}}"#)
            }
            return (500, "{}")
        }
        defer { Self.resetProtocol() }
        let usage = try await ZoomMateUsageFetcher.fetch(
            credential: capture, source: .cookie, session: Self.session(), now: Self.now
        )
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Credits")
        #expect(usage.details.isEmpty)
    }

    @Test
    func automaticModeWithoutValidatedCacheOrUserInitiatedImportFailsClosed() async {
        await #expect(throws: ZoomMateUsageError.noSession) {
            _ = try await ZoomMateUsageFetcher.fetch(
                credential: nil,
                source: .automatic,
                session: Self.session(),
                cachedCookieHeaders: nil,
                allowBrowserImport: false
            )
        }
    }

    private static func context() -> ZoomMateUsageFetcher.RequestContext {
        ZoomMateUsageFetcher.RequestContext(
            authorization: "Bearer token",
            cookieHeaders: ZoomMateCookieHeaders(headersByHost: [
                "ai.zoom.us": "ai-cookie=1", "zoommate.zoom.us": "mate-cookie=1",
            ])
        )
    }

    private static func jwt(exp: Int) -> String {
        func encode(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"none"}"#)).\(encode("{\"exp\":\(exp)}")).sig"
    }

    private static func record(
        domain: String, scope: BrowserCookieScope, name: String, value: String = "fake"
    ) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: domain, name: name, path: "/", value: value,
            expires: nil, isSecure: true, isHTTPOnly: true, scope: scope
        )
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoomMateTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func resetProtocol() {
        ZoomMateTestURLProtocol.handler = nil
        ZoomMateTestURLProtocol.recorder = nil
    }
}

private final class ZoomMateRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class ZoomMateTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var recorder: ZoomMateRequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, recorder) = Self.lock.withLock { (Self.handler, Self.recorder) }
        recorder?.append(request)
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
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
