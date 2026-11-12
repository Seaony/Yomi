import Foundation
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct SiliconFlowUsageTests {
    private static let contract = """
    {"code":20000,"message":"OK","status":true,"data":{"id":"user","name":"hidden",
    "email":"hidden@example.com","balance":"0.88","status":"normal",
    "chargeBalance":"88.00","totalBalance":"88.88"}}
    """

    @Test
    func contractShowsCNYBalanceWithoutQuotaOrIdentity() throws {
        let usage = try SiliconFlowUsageFetcher.parse(Data(Self.contract.utf8), currency: "CNY")

        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "CN¥88.88")
        #expect(usage.details.first { $0.id == "siliconflow-balance" }?.value == "CN¥88.88")
        #expect(usage.details.first { $0.id == "siliconflow-purchased" }?.value == "CN¥88.00")
        #expect(usage.details.first { $0.id == "siliconflow-bonus" }?.value == "CN¥0.88")
        #expect(usage.details.first { $0.id == "siliconflow-status" } == nil)
        #expect(!usage.details.map(\.value).joined().contains("hidden"))
    }

    @Test
    func internationalOverdueBalanceKeepsNegativeTotalAndStatus() throws {
        let body = """
        {"code":20000,"status":true,"data":{"balance":"0.00","chargeBalance":"0.00",
        "totalBalance":"-1.50","status":"overdue"}}
        """
        let usage = try SiliconFlowUsageFetcher.parse(Data(body.utf8), currency: "USD")

        #expect(usage.balance == "-$1.50")
        #expect(usage.details.first { $0.id == "siliconflow-status" }?.value == "overdue")
        #expect(usage.windows.isEmpty)
    }

    @Test(arguments: [
        "not-json",
        "[]",
        "{}",
        #"{"code":20000,"status":true,"data":{}}"#,
        #"{"code":20000,"status":true,"data":{"totalBalance":"88.88.1"}}"#,
        #"{"code":20000,"status":false,"data":{"totalBalance":"1"}}"#,
        #"{"code":1,"status":true,"data":{"totalBalance":"1"}}"#,
        #"{"code":true,"status":true,"data":{"totalBalance":"1"}}"#,
        #"{"code":20000,"status":true,"data":{"totalBalance":"1e2","balance":"0","chargeBalance":"0"}}"#,
        #"{"code":20000,"status":true,"data":{"totalBalance":"1","balance":"abc"}}"#,
        #"{"code":20000,"status":true,"data":{"totalBalance":true}}"#,
        #"{"code":20000,"status":true,"data":{"totalBalance":"1","status":"not normal!"}}"#,
    ])
    func malformedResponsesFail(body: String) {
        #expect(throws: SiliconFlowUsageError.parseFailure) {
            try SiliconFlowUsageFetcher.parse(Data(body.utf8), currency: "CNY")
        }
    }

    @Test
    func bodyCodesMapToRefusedAndAuthErrors() {
        #expect(throws: SiliconFlowUsageError.balanceQueryRefused) {
            try SiliconFlowUsageFetcher.parse(Data(#"{"code":20092,"status":false}"#.utf8), currency: "CNY")
        }
        #expect(throws: SiliconFlowUsageError.authenticationExpired) {
            try SiliconFlowUsageFetcher.parse(Data(#"{"code":30014,"message":"x"}"#.utf8), currency: "CNY")
        }
    }

    @Test
    func originDefaultsToChinaAndRejectsEveryOtherHost() {
        #expect(SiliconFlowUsageFetcher.resolvedOrigin(configured: nil, environment: [:]) == SiliconFlowUsageFetcher.chinaOrigin)
        #expect(SiliconFlowUsageFetcher.normalizedOrigin("api.siliconflow.cn/v1") == SiliconFlowUsageFetcher.chinaOrigin)
        #expect(SiliconFlowUsageFetcher.normalizedOrigin("https://api.siliconflow.com/v1/") == SiliconFlowUsageFetcher.internationalOrigin)
        for raw in [
            "http://api.siliconflow.cn",
            "https://user:secret@api.siliconflow.cn",
            "https://api.siliconflow.cn.evil.com",
            "https://api.siliconflow.cn/v1/user/info",
            "https://api.siliconflow.cn?q=1",
            "https://api.siliconflow.cn#frag",
            "https://api.siliconflow.cn:443",
            "https://example.com",
        ] {
            #expect(SiliconFlowUsageFetcher.normalizedOrigin(raw) == nil, "accepted \(raw)")
        }
    }

    @Test
    func configuredOriginWinsOverEnvironment() {
        let environment = ["SILICONFLOW_BASE_URL": "https://api.siliconflow.com/v1/"]
        #expect(SiliconFlowUsageFetcher.resolvedOrigin(configured: nil, environment: environment) == SiliconFlowUsageFetcher.internationalOrigin)
        #expect(SiliconFlowUsageFetcher.resolvedOrigin(configured: "https://api.siliconflow.cn/v1", environment: environment) == SiliconFlowUsageFetcher.chinaOrigin)
        #expect(SiliconFlowUsageFetcher.resolvedOrigin(configured: "https://untrusted.example", environment: environment) == nil)
    }

    @Test
    func requestUsesBearerGETAndRegionalCurrency() async throws {
        SiliconFlowTestURLProtocol.reset(body: Self.contract)
        let usage = try await SiliconFlowUsageFetcher.fetch(
            apiKey: "sk-fixture", origin: "https://api.siliconflow.com", session: Self.session(), environment: [:]
        )

        let request = try #require(SiliconFlowTestURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.siliconflow.com/v1/user/info")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-fixture")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(SiliconFlowTestURLProtocol.requestCount == 1)
        #expect(usage.balance == "$88.88")
    }

    @Test
    func invalidOriginFailsBeforeSendingKey() async {
        SiliconFlowTestURLProtocol.reset(body: Self.contract)
        await #expect(throws: SiliconFlowUsageError.invalidOrigin) {
            try await SiliconFlowUsageFetcher.fetch(
                apiKey: "sk-fixture", origin: "https://evil.example", session: Self.session(), environment: [:]
            )
        }
        #expect(SiliconFlowTestURLProtocol.requestCount == 0)
    }

    @Test
    func missingKeyFailsBeforeRequest() async {
        SiliconFlowTestURLProtocol.reset(body: Self.contract)
        await #expect(throws: SiliconFlowUsageError.missingCredentials) {
            try await SiliconFlowUsageFetcher.fetch(apiKey: nil, origin: nil, session: Self.session(), environment: [:])
        }
        #expect(SiliconFlowTestURLProtocol.requestCount == 0)
    }

    @Test(arguments: [
        (401, SiliconFlowUsageError.authenticationExpired),
        (403, SiliconFlowUsageError.authenticationExpired),
        (410, SiliconFlowUsageError.balanceQueryRefused),
        (429, SiliconFlowUsageError.rateLimited),
        (500, SiliconFlowUsageError.providerUnavailable(500)),
        (404, SiliconFlowUsageError.apiFailure(404)),
    ])
    func httpFailuresAreClassified(status: Int, expected: SiliconFlowUsageError) async {
        SiliconFlowTestURLProtocol.reset(body: "private-response-marker", status: status)
        await #expect(throws: expected) {
            try await SiliconFlowUsageFetcher.fetch(apiKey: "sk-fixture", origin: nil, session: Self.session(), environment: [:])
        }
        #expect(expected.errorDescription?.contains("private-response-marker") == false)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiliconFlowTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class SiliconFlowTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requestCount = 0

    static func reset(body: String, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
        lastRequest = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
