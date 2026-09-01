import Foundation
import Testing
@testable import Yomi

@Suite("LLM Proxy usage", .serialized)
struct LLMProxyUsageTests {
    @Test
    func parsesQuotaStatsAndPresentation() throws {
        let now = Date(timeIntervalSince1970: 1)
        let usage = try LLMProxyUsageFetcher.parse(Data(Self.fixture.utf8), now: now)
        #expect(usage.windows.map(\.id) == ["llmproxy-quota"])
        #expect(usage.windows[0].usedFraction == 0.58)
        #expect(usage.details.first { $0.id == "llmproxy-requests" }?.value == "160")
        #expect(usage.details.first { $0.id == "llmproxy-tokens" }?.value == "7,000")
        #expect(usage.providerCost?.used == 15.5)
        #expect(usage.plan == nil)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func quotaURLAcceptsRootAndVersionedBases() throws {
        #expect(LLMProxyUsageFetcher.quotaStatsURL(URL(string: "https://proxy.example.com")!).absoluteString == "https://proxy.example.com/v1/quota-stats")
        #expect(LLMProxyUsageFetcher.quotaStatsURL(URL(string: "https://proxy.example.com/v1")!).absoluteString == "https://proxy.example.com/v1/quota-stats")
    }

    @Test
    func requestAndTokenScalarsNeverCreateProgressWindowsWithoutQuota() throws {
        let usage = try LLMProxyUsageFetcher.parse(
            Data(#"{"providers":{},"summary":{"total_requests":12,"total_tokens":345}}"#.utf8),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(usage.windows.isEmpty)
        #expect(usage.details.map(\.value) == ["12", "345"])
    }

    @Test(arguments: [
        "https://proxy.example.com",
        "http://127.0.0.1:8080",
        "http://10.0.0.2:8080",
        "http://router.local:8080",
    ])
    func endpointSecurityAcceptsDocumentedHosts(raw: String) {
        #expect(ProviderEndpointValidator.privateNetworkURL(raw) != nil)
    }

    @Test(arguments: [
        "http://example.com",
        "https://user:pass@example.com",
        "localhost:8080",
    ])
    func endpointSecurityRejectsUnsafeValues(raw: String) {
        #expect(ProviderEndpointValidator.privateNetworkURL(raw) == nil)
    }

    @Test
    func exactRequestUsesBearerAndEndpoint() async throws {
        LLMProxyTestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://proxy.example.com/v1/quota-stats")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer proxy-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(Self.fixture.utf8))
        }
        defer { LLMProxyTestURLProtocol.handler = nil }
        _ = try await LLMProxyUsageFetcher.fetch(
            apiKey: "proxy-key", endpointOverride: "https://proxy.example.com",
            session: Self.session(), environment: [:]
        )
    }

    @Test
    func missingConfigurationAndMalformedPayloadFailClosed() async {
        await #expect(throws: LLMProxyUsageError.missingCredentials) {
            _ = try await LLMProxyUsageFetcher.fetch(apiKey: nil, endpointOverride: nil, session: Self.session(), environment: [:])
        }
        await #expect(throws: LLMProxyUsageError.missingBaseURL) {
            _ = try await LLMProxyUsageFetcher.fetch(apiKey: "key", endpointOverride: nil, session: Self.session(), environment: [:])
        }
        #expect(throws: LLMProxyUsageError.self) {
            _ = try LLMProxyUsageFetcher.parse(Data(#"{"summary":{}}"#.utf8), now: Date())
        }
    }

    private static let fixture = #"{"providers":{"openai":{"credential_count":3,"active_count":2,"exhausted_count":1,"total_requests":120,"tokens":{"input_cached":1000,"input_uncached":2000,"output":3000},"approx_cost":12.5,"quota_groups":{"default":{"remaining_percent":42,"reset_time":"2026-05-18T12:00:00.123Z"}}},"anthropic":{"credential_count":1,"active_count":1,"exhausted_count":0,"total_requests":40,"tokens":{"input_cached":0,"input_uncached":500,"output":500},"approx_cost":3.0,"quota_groups":[{"remaining_percent":80}]}},"summary":{"total_requests":160,"total_tokens":7000,"approx_cost":15.5}}"#

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLMProxyTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LLMProxyTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
