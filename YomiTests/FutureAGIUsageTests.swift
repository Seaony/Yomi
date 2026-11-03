import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct FutureAGIUsageTests {
    private static let fixture = #"""
    {"status":true,"result":{"plan_display_name":"Free","billing_period_start":"2026-10-01",
    "billing_period_end":"2026-11-01","total_estimated_cost":1.25,"dimensions":[
    {"key":"ai_credits","display_name":"AI credits","display_unit":"credits","current_usage":500,"free_allowance":2000},
    {"key":"gateway_requests","display_name":"Gateway requests","display_unit":"requests",
    "current_usage":150000,"free_allowance":100000},
    {"key":"storage","display_name":"Storage","display_unit":"GB","current_usage":0.5,"free_allowance":1}]}}
    """#

    @Test
    func allowancesBecomeWindowsAndOverageIsCapped() throws {
        let usage = try FutureAGIUsageFetcher.parse(Data(Self.fixture.utf8))

        #expect(usage.plan == "Free")
        #expect(usage.windows.map(\.id) == ["futureagi-ai_credits", "futureagi-gateway_requests"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 1])
        #expect(usage.details.first { $0.id == "futureagi-storage" }?.value == "0.5 / 1 GB")
        #expect(usage.details.first { $0.id == "futureagi-estimated-cost" }?.value == "$1.25")
    }

    @Test
    func requestSendsBothKeys() async throws {
        FutureAGITestURLProtocol.body = Data(Self.fixture.utf8)
        FutureAGITestURLProtocol.lastRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FutureAGITestURLProtocol.self]

        _ = try await FutureAGIUsageFetcher.fetch(
            apiKey: "api-fixture", secretKey: "secret-fixture",
            session: URLSession(configuration: configuration), environment: [:]
        )

        let request = try #require(FutureAGITestURLProtocol.lastRequest)
        #expect(request.url == FutureAGIUsageFetcher.overviewURL)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "api-fixture")
        #expect(request.value(forHTTPHeaderField: "X-Secret-Key") == "secret-fixture")
    }

    @Test
    func missingSecretKeyFailsBeforeRequest() async {
        await #expect(throws: FutureAGIUsageError.missingCredentials) {
            try await FutureAGIUsageFetcher.fetch(apiKey: "api-fixture", secretKey: nil, session: .shared, environment: [:])
        }
    }
}

private nonisolated final class FutureAGITestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
