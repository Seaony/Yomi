import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct T3ChatUsageTests {
    @Test
    func dynamicBaseBandLabelIsLocalizedWithoutChangingBandName() {
        #expect(AppCopy(language: .simplifiedChinese).usageLabel("Base - Standard") == "基础 - Standard")
        #expect(AppCopy(language: .english).usageLabel("Base - Standard") == "Base - Standard")
    }

    private static let now = Date(timeIntervalSince1970: 1_778_000_000)
    private static let baseResetMilliseconds: TimeInterval = 1_779_366_216_920
    private static let subscriptionEndSeconds: TimeInterval = 1_780_763_009

    private static let sampleResponse = [
        #"{"json":{"0":[[0],[null,0,0]]}}"#,
        #"{"json":[0,0,[[{"result":0}],["result",0,1]]]}"#,
        #"{"json":[2,0,[[{"subTier":"pro","subscription":{"productId":"pro","productName":"pro","status":"active","currentPeriodStart":1778084609000,"currentPeriodEnd":1780763009000,"canceledAt":null,"trialEndsAt":null},"lifetimeBalance":0,"usageBand":"max","billingNextResetAt":1779366216920,"usageFourHourPercentage":12.5,"usageMonthPercentage":34.25,"usageFourHourNextResetAt":1779366216920,"usagePeriodPercentage":44,"usageWindowNextResetAt":1779366216920}]]]}"#,
    ].joined(separator: "\n")

    @Test
    func parsesJSONLinesAndMapsExactWindows() throws {
        let snapshot = try T3ChatUsageFetcher.parseJSONLines(Self.sampleResponse, now: Self.now)
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.customerData.subscription?.status == "active")
        #expect(usage.windows.map(\.label) == ["Base - max", "Overage"])
        #expect(usage.windows.map(\.usedFraction) == [0.125, 0.3425])
        #expect(usage.windows[0].resetsAt?.timeIntervalSince1970 == Self.baseResetMilliseconds / 1000)
        #expect(usage.windows[1].resetsAt?.timeIntervalSince1970 == Self.subscriptionEndSeconds)
        #expect(usage.plan == "Pro")
        #expect(usage.providerCost == nil)
        #expect(usage.today == nil)
    }

    @Test
    func usesDocumentedPercentageAndResetFallbacks() throws {
        let response = Self.customerDataResponse(
            #"{"subTier":"free-tier","usageFourHourPercentage":5,"usagePeriodPercentage":65,"usageWindowNextResetAt":1780000100}"#
        )
        let usage = try T3ChatUsageFetcher.parseJSONLines(response, now: Self.now).toProviderUsage()

        #expect(usage.windows.map { $0.usedFraction } == [0.05, 0.65])
        #expect(usage.windows[0].resetsAt?.timeIntervalSince1970 == 1_780_000_100)
        #expect(usage.windows[1].resetsAt == nil)
        #expect(usage.plan == "Free Tier")
    }

    @Test
    func overageResetIgnoresBillingNextReset() throws {
        let response = Self.customerDataResponse(
            #"{"usageMonthPercentage":20,"billingNextResetAt":1779366216920}"#
        )
        let usage = try T3ChatUsageFetcher.parseJSONLines(response).toProviderUsage()

        #expect(usage.windows[1].usedFraction == 0.2)
        #expect(usage.windows[1].resetsAt == nil)
    }

    @Test
    func percentagesClampAndEpochAcceptsSecondsOrMilliseconds() throws {
        let response = Self.customerDataResponse(
            #"{"usageFourHourPercentage":-5,"usageMonthPercentage":150,"usageFourHourNextResetAt":1780000100000,"subscription":{"currentPeriodEnd":1780000200}}"#
        )
        let usage = try T3ChatUsageFetcher.parseJSONLines(response).toProviderUsage()

        #expect(usage.windows.map { $0.usedFraction } == [0, 1])
        #expect(usage.windows[0].resetsAt?.timeIntervalSince1970 == 1_780_000_100)
        #expect(usage.windows[1].resetsAt?.timeIntervalSince1970 == 1_780_000_200)
    }

    @Test
    func unrelatedOrMalformedPayloadDoesNotCreateQuota() {
        #expect(throws: T3ChatUsageError.self) {
            try T3ChatUsageFetcher.parseJSONLines(#"{"status":"ok","percentage":10}"#)
        }
        #expect(throws: T3ChatUsageError.self) {
            try T3ChatUsageFetcher.parseJSONLines("not-json\n[]")
        }
    }

    @Test
    func requestUsesExactEndpointHeadersAndCookie() async throws {
        T3ChatURLProtocolStub.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "t3.chat")
            #expect(request.url?.path == "/api/trpc/getCustomerData")
            #expect(request.url?.query?.contains("batch=1") == true)
            #expect(request.url?.query?.contains("input=") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc; other=two")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://t3.chat")
            #expect(request.value(forHTTPHeaderField: "trpc-accept") == "application/jsonl")
            #expect(request.value(forHTTPHeaderField: "x-trpc-source") == "web-client")
            #expect(request.value(forHTTPHeaderField: "x-trpc-batch") == "true")
            #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
            return (200, [:], Self.sampleResponse)
        }
        defer { T3ChatURLProtocolStub.handler = nil }

        let context = try #require(T3ChatUsageFetcher.requestContext(from: "Cookie: session=abc; other=two"))
        let snapshot = try await T3ChatUsageFetcher.fetchCustomerData(
            context: context,
            session: makeSession(),
            now: Self.now
        )

        #expect(snapshot.customerData.planName == "Pro")
    }

    @Test
    func fullCurlForwardsOnlyAllowedFingerprintHeaders() async throws {
        let curl = """
        curl 'https://t3.chat/api/trpc/getCustomerData?batch=1&input=ignored' \\
          -H 'User-Agent: Mozilla/5.0 Firefox/151.0' \\
          --header "Referer: https://t3.chat/settings/customization" \\
          -H 'X-Deployment-Id: dpl_test' \\
          -H 'x-client-context: context-value' \\
          -H 'Authorization: Bearer must-not-forward' \\
          -H 'Cookie: session=abc; cf_clearance=token'
        """
        let context = try #require(T3ChatUsageFetcher.requestContext(from: curl))
        #expect(context.cookieHeader == "session=abc; cf_clearance=token")
        #expect(context.headers["User-Agent"] == "Mozilla/5.0 Firefox/151.0")
        #expect(context.headers["Referer"] == "https://t3.chat/settings/customization")
        #expect(context.headers["X-Deployment-Id"] == "dpl_test")
        #expect(context.headers["x-client-context"] == "context-value")
        #expect(context.headers["Authorization"] == nil)
        #expect(context.headers["Cookie"] == nil)
    }

    @Test
    func curlParserSupportsAnsiAndEqualsHeaderForms() throws {
        let curl = """
        curl 'https://t3.chat/api/trpc/getCustomerData' \\
          --header=$'User-Agent: Browser\\'s Agent' \\
          --header='X-Deployment-Id: dpl_test' \\
          -H 'Cookie: session=abc'
        """
        let context = try #require(T3ChatUsageFetcher.requestContext(from: curl))
        #expect(context.headers["User-Agent"] == "Browser's Agent")
        #expect(context.headers["X-Deployment-Id"] == "dpl_test")
        #expect(context.cookieHeader == "session=abc")
    }

    @Test
    func blankOrMalformedCookieIsRejected() {
        #expect(T3ChatUsageFetcher.requestContext(from: nil) == nil)
        #expect(T3ChatUsageFetcher.requestContext(from: "not-a-cookie") == nil)
        #expect(T3ChatUsageFetcher.normalizeCookie("Cookie: session=abc; foo=bar") == "session=abc; foo=bar")
    }

    @Test
    func manualCookieModeDoesNotFallBackToBrowserImport() async {
        await #expect(throws: T3ChatUsageError.missingSession) {
            try await T3ChatUsageFetcher.fetch(
                cookieHeaderOverride: "not-a-cookie",
                source: .cookie,
                session: makeSession()
            )
        }
    }

    @Test(arguments: [401, 403])
    func unauthorizedResponseMeansExpiredSession(status: Int) async {
        T3ChatURLProtocolStub.handler = { _ in (status, [:], "unauthorized") }
        defer { T3ChatURLProtocolStub.handler = nil }
        await #expect(throws: T3ChatUsageError.sessionExpired) {
            try await T3ChatUsageFetcher.fetchCustomerData(
                context: .init(cookieHeader: "session=abc", headers: [:]),
                session: makeSession()
            )
        }
    }

    @Test
    func vercelChallengeHasDedicatedError() async {
        T3ChatURLProtocolStub.handler = { _ in
            (429, ["x-vercel-mitigated": "challenge"], "checkpoint")
        }
        defer { T3ChatURLProtocolStub.handler = nil }
        await #expect(throws: T3ChatUsageError.vercelChallenge) {
            try await T3ChatUsageFetcher.fetchCustomerData(
                context: .init(cookieHeader: "session=abc", headers: [:]),
                session: makeSession()
            )
        }
    }

    @Test
    func ordinaryHTTPAndSuccessfulMalformedResponseRemainDistinct() async {
        T3ChatURLProtocolStub.handler = { _ in (500, [:], "failed") }
        await #expect(throws: T3ChatUsageError.requestFailed(500)) {
            try await T3ChatUsageFetcher.fetchCustomerData(
                context: .init(cookieHeader: "session=abc", headers: [:]),
                session: makeSession()
            )
        }
        T3ChatURLProtocolStub.handler = { _ in (200, [:], #"{"status":"ok"}"#) }
        await #expect(throws: T3ChatUsageError.self) {
            try await T3ChatUsageFetcher.fetchCustomerData(
                context: .init(cookieHeader: "session=abc", headers: [:]),
                session: makeSession()
            )
        }
        T3ChatURLProtocolStub.handler = nil
    }

    private static func customerDataResponse(_ customerDataJSON: String) -> String {
        #"{"json":[2,0,[[\#(customerDataJSON)]]]}"# + "\n"
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3ChatURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class T3ChatURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
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
