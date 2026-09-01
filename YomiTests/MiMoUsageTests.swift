import Foundation
import SweetCookieKit
import Testing
@testable import Yomi

@Suite("Xiaomi MiMo usage", .serialized)
struct MiMoUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_742_771_200)

    @Test
    func cookieNormalizerKeepsOnlyRequiredAndKnownCookies() {
        let raw = """
        curl 'https://platform.xiaomimimo.com/api/v1/balance' \\
          -H 'Cookie: userId=123; api-platform_serviceToken=svc-token; ignored=value; api-platform_ph=ph-token'
        """

        #expect(MiMoCookieHeader.normalized(from: raw)
            == "api-platform_ph=ph-token; api-platform_serviceToken=svc-token; userId=123")
        #expect(MiMoCookieHeader.normalized(from: "Cookie: userId=123") == nil)
        #expect(MiMoCookieHeader.normalized(
            from: "api-platform_serviceToken=; userId=123"
        ) == nil)
    }

    @Test
    func cookieBuilderHonorsDomainPathExpiryAndSpecificity() throws {
        let cookies = try [
            makeCookie(name: "userId", value: "root", domain: "xiaomimimo.com"),
            makeCookie(name: "userId", value: "api", domain: "platform.xiaomimimo.com", path: "/api"),
            makeCookie(
                name: "api-platform_serviceToken",
                value: "partial",
                domain: "platform.xiaomimimo.com",
                path: "/api/v1/bal"
            ),
            makeCookie(
                name: "api-platform_serviceToken",
                value: "valid",
                domain: "platform.xiaomimimo.com",
                path: "/api"
            ),
            makeCookie(
                name: "api-platform_ph",
                value: "expired",
                domain: "platform.xiaomimimo.com",
                expires: Self.now.addingTimeInterval(-1)
            ),
        ]

        #expect(MiMoCookieHeader.header(from: cookies, now: Self.now)
            == "api-platform_serviceToken=valid; userId=api")
    }

    @Test
    func balanceParsingPreservesPaidAndGrantedComponents() throws {
        let snapshot = try MiMoUsageFetcher.parseBalance(Data(#"""
        {
          "code": 0,
          "message": "",
          "data": {
            "balance": "50.00",
            "currency": "USD",
            "giftBalance": "20.00",
            "cashBalance": "30.00"
          }
        }
        """#.utf8), now: Self.now)

        #expect(snapshot.balance == 50)
        #expect(snapshot.cashBalance == 30)
        #expect(snapshot.giftBalance == 20)
        #expect(snapshot.updatedAt == Self.now)
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$50.00")
        #expect(usage.details == [UsageDetail(
            id: "mimo-balance",
            label: "Balance",
            value: "$50.00 (Paid: $30.00 / Granted: $20.00)"
        )])
    }

    @Test
    func malformedOptionalBalanceComponentsAreIgnored() throws {
        let snapshot = try MiMoUsageFetcher.parseBalance(Data(#"""
        {"code":0,"message":"","data":{"balance":"25.51","currency":"USD","giftBalance":"","cashBalance":"unknown"}}
        """#.utf8))

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.cashBalance == nil)
        #expect(snapshot.giftBalance == nil)
    }

    @Test
    func tokenPlanDetailUsesUTCAndUsageUsesFirstMonthlyItem() throws {
        let detail = try MiMoUsageFetcher.parseTokenPlanDetail(Data(#"""
        {"code":0,"message":"","data":{"planCode":"standard","currentPeriodEnd":"2026-05-04 23:59:59","expired":false}}
        """#.utf8))
        let usage = try MiMoUsageFetcher.parseTokenPlanUsage(Data(#"""
        {
          "code":0,
          "data":{"monthUsage":{"percent":0.99,"items":[
            {"name":"month_total_token","used":10100158,"limit":200000000,"percent":0.0505},
            {"name":"ignored","used":1,"limit":1,"percent":1}
          ]}}
        }
        """#.utf8))

        #expect(detail.planCode == "standard")
        #expect(detail.periodEnd?.timeIntervalSince1970 == 1_777_939_199)
        #expect(detail.expired == false)
        #expect(usage.used == 10_100_158)
        #expect(usage.limit == 200_000_000)
        #expect(usage.percent == 0.0505)
    }

    @Test
    func combinedSnapshotCreatesExactlyOneMonthlyCreditsWindow() throws {
        let snapshot = try MiMoUsageFetcher.parseCombined(
            balanceData: Data(#"{"code":0,"message":"","data":{"balance":"25.51","currency":"USD","cashBalance":"20","giftBalance":"5.51"}}"#.utf8),
            tokenDetailData: Data(#"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-05-04 23:59:59","expired":false}}"#.utf8),
            tokenUsageData: Data(#"{"code":0,"data":{"monthUsage":{"percent":0.0505,"items":[{"name":"month_total_token","used":10100158,"limit":200000000,"percent":0.0505}]}}}"#.utf8),
            now: Self.now
        )
        let usage = snapshot.toProviderUsage()

        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "mimo-token-plan")
        #expect(usage.windows[0].label == "Credits")
        #expect(abs(usage.windows[0].usedFraction - 0.0505) < 0.000_001)
        #expect(usage.windows[0].detail == "10,100,158 / 200,000,000 Credits")
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.plan == "Standard")
        #expect(usage.balance == "$25.51")
    }

    @Test
    func missingOrMalformedOptionalPlanPayloadDoesNotInventQuota() throws {
        let balance = Data(#"{"code":0,"data":{"balance":"0","currency":"USD"}}"#.utf8)
        for optional: Data? in [nil, Data(#"{"status":"ok"}"#.utf8)] {
            let snapshot = try MiMoUsageFetcher.parseCombined(
                balanceData: balance,
                tokenDetailData: optional,
                tokenUsageData: optional,
                now: Self.now
            )
            #expect(snapshot.toProviderUsage().windows.isEmpty)
            #expect(snapshot.toProviderUsage().balance == "$0.00")
        }
    }

    @Test(arguments: [401, 403, 500])
    func balancePayloadErrorsNeverProduceUsage(code: Int) {
        #expect(throws: MiMoUsageError.self) {
            _ = try MiMoUsageFetcher.parseBalance(Data(
                #"{"code":#(code),"message":"denied","data":null}"#.utf8
            ))
        }
    }

    @Test
    func endpointOverrideAcceptsHTTPSAndBareHostsButRejectsUnsafeValues() throws {
        #expect(try MiMoUsageFetcher.resolvedBaseURL(
            configured: nil,
            environment: ["MIMO_API_URL": "mimo.test/api/v1"]
        ).absoluteString == "https://mimo.test/api/v1")
        #expect(try MiMoUsageFetcher.resolvedBaseURL(
            configured: "https://mimo.test:8443/api/v1",
            environment: [:]
        ).absoluteString == "https://mimo.test:8443/api/v1")
        for value in [
            "http://attacker.test/api/v1",
            "https://user:pass@attacker.test/api/v1",
            "https://attacker.test%2f.safe.test/api/v1",
            "https://bad host/api/v1",
        ] {
            #expect(throws: MiMoUsageError.invalidEndpointOverride) {
                _ = try MiMoUsageFetcher.resolvedBaseURL(configured: value, environment: [:])
            }
        }
    }

    @Test
    func fetchUsesAllThreeExactEndpointsAndBrowserHeaders() async throws {
        let recorder = MiMoRequestRecorder()
        MiMoTestURLProtocol.handler = { request in
            recorder.append(request)
            let path = try #require(request.url?.path)
            switch path {
            case "/api/v1/balance":
                return (200, #"{"code":0,"data":{"balance":"25.51","currency":"USD"}}"#)
            case "/api/v1/tokenPlan/detail":
                return (200, #"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-05-04 23:59:59","expired":false}}"#)
            case "/api/v1/tokenPlan/usage":
                return (200, #"{"code":0,"data":{"monthUsage":{"percent":0.1,"items":[{"name":"month_total_token","used":10,"limit":100,"percent":0.1}]}}}"#)
            default:
                throw URLError(.badURL)
            }
        }
        defer { MiMoTestURLProtocol.handler = nil }

        let snapshot = try await MiMoUsageFetcher.fetchUsage(
            cookieHeader: "Cookie: userId=123; api-platform_serviceToken=svc-token",
            baseURL: URL(string: "https://mimo.test/api/v1")!,
            session: makeSession(),
            now: Self.now
        )

        #expect(snapshot.tokenPercent == 0.1)
        let requests = recorder.requests
        #expect(Set(requests.compactMap(\.url?.path)) == [
            "/api/v1/balance", "/api/v1/tokenPlan/detail", "/api/v1/tokenPlan/usage",
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie")
                == "api-platform_serviceToken=svc-token; userId=123"
        })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Origin") == "https://platform.xiaomimimo.com"
                && $0.value(forHTTPHeaderField: "Referer")
                    == "https://platform.xiaomimimo.com/#/console/balance"
                && $0.value(forHTTPHeaderField: "x-timeZone") == "UTC+01:00"
                && $0.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9"
        })
    }

    @Test
    func optionalFailuresPreserveRequiredBalance() async throws {
        MiMoTestURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/balance") == true {
                return (200, #"{"code":0,"data":{"balance":"9.50","currency":"USD"}}"#)
            }
            return (500, "optional failure")
        }
        defer { MiMoTestURLProtocol.handler = nil }

        let usage = try await MiMoUsageFetcher.fetchUsage(
            cookieHeader: "userId=123; api-platform_serviceToken=svc-token",
            baseURL: URL(string: "https://mimo.test/api/v1")!,
            session: makeSession(),
            now: Self.now
        ).toProviderUsage()

        #expect(usage.balance == "$9.50")
        #expect(usage.windows.isEmpty)
    }

    @Test(arguments: [302, 401, 403, 429])
    func fetchMapsHTTPFailuresWithoutInventingUsage(status: Int) async {
        MiMoTestURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/balance") == true { return (status, "denied") }
            return (200, "{}")
        }
        defer { MiMoTestURLProtocol.handler = nil }

        await #expect(throws: Error.self) {
            _ = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: "userId=123; api-platform_serviceToken=svc-token",
                baseURL: URL(string: "https://mimo.test/api/v1")!,
                session: makeSession()
            )
        }
    }

    @Test
    func manualModeRejectsInvalidCookieBeforeNetworkRequest() async {
        MiMoTestURLProtocol.handler = { _ in
            Issue.record("Invalid manual cookie must not issue a request")
            return (200, "{}")
        }
        defer { MiMoTestURLProtocol.handler = nil }

        await #expect(throws: MiMoUsageError.invalidCookie) {
            _ = try await MiMoUsageFetcher.fetch(
                credential: "foo=bar",
                source: .cookie,
                session: makeSession(),
                environment: [:]
            )
        }
    }

    @Test
    func localFallbackIsClearlyLabeledAndNeverBecomesAQuotaWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yomi-mimo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        try Data(#"""
        {
          "updated_at":"2026-06-03T05:04:03.123456+00:00",
          "sessions_scanned":42,
          "windows":{
            "today":{"input":1000,"output":500,"cache_read":0,"cache_create":0},
            "week":{"input":30000,"output":10000,"cache_read":60000,"cache_create":10000},
            "all_time":{"input":1000000,"output":500000,"cache_read":0,"cache_create":0}
          }
        }
        """#.utf8).write(to: file)

        let usage = try #require(MiMoLocalUsageFallback.snapshot(
            path: file.path,
            now: Date(timeIntervalSince1970: 1_783_398_400)
        ))

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == nil)
        #expect(usage.plan == nil)
        #expect(usage.today?.tokens == 1_500)
        #expect(usage.weeklyEstimate?.tokens == 110_000)
        #expect(usage.last30Days == nil)
        #expect(usage.details.isEmpty)
    }

    private func makeCookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: expires,
        ]))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiMoTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MiMoRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { stored }
    }

    func append(_ request: URLRequest) {
        lock.withLock { stored.append(request) }
    }
}

private final class MiMoTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
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
