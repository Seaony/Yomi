import Foundation
import Testing
@testable import Yomi

@Suite("Venice usage", .serialized)
struct VeniceUsageTests {
    @Test
    func mapsDiemAllocationExactly() throws {
        let usage = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":90.5,"usd":null},"diemEpochAllocation":100}
        """)
        #expect(usage.windows[0].usedFraction == 0.095)
        #expect(usage.windows[0].detail == "DIEM 90.50 / 100.00 epoch allocation")
        #expect(usage.balance == "DIEM 90.50")
    }

    @Test
    func currencyPrecedenceMatchesReference() throws {
        let usd = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"USD","balances":{"diem":50,"usd":12.34},"diemEpochAllocation":100}
        """)
        #expect(usd.windows[0].detail == "$12.34 USD remaining")
        let bundled = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"BUNDLED_CREDITS","balances":{"diem":50,"usd":10},"diemEpochAllocation":100}
        """)
        #expect(bundled.windows[0].usedFraction == 0.5)
        #expect(bundled.windows[0].detail == "DIEM 50.00 / 100.00 epoch allocation")
    }

    @Test
    func acceptsStringNumbersAndClampsAllocationProgress() throws {
        let strings = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":"90.50","usd":"25.75"},"diemEpochAllocation":"100"}
        """)
        #expect(strings.windows[0].usedFraction == 0.095)
        let over = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":150,"usd":null},"diemEpochAllocation":100}
        """)
        #expect(over.windows[0].usedFraction == 0)
        #expect(over.windows[0].detail == "DIEM 150.00 / 100.00 epoch allocation")
    }

    @Test
    func fallsBackBetweenDiemUSDAndExhausted() throws {
        let diem = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":50,"usd":null},"diemEpochAllocation":null}
        """)
        #expect(diem.windows[0].detail == "DIEM 50.00 remaining")
        let usd = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":null,"balances":{"diem":null,"usd":15.5},"diemEpochAllocation":null}
        """)
        #expect(usd.windows[0].detail == "$15.50 USD remaining")
        let empty = try Self.parse("""
        {"canConsume":true,"consumptionCurrency":"USD","balances":{"diem":0,"usd":0},"diemEpochAllocation":null}
        """)
        #expect(empty.windows[0].usedFraction == 1)
        #expect(empty.windows[0].detail == "No Venice API balance available")
    }

    @Test
    func nonConsumableAlwaysReportsExhausted() throws {
        let usage = try Self.parse("""
        {"canConsume":false,"consumptionCurrency":"USD","balances":{"diem":null,"usd":100},"diemEpochAllocation":null}
        """)
        #expect(usage.windows[0].usedFraction == 1)
        #expect(usage.windows[0].detail == "Balance unavailable for API calls")
    }

    @Test
    func rejectsMalformedContracts() {
        #expect(throws: VeniceUsageError.invalidResponse) { _ = try VeniceUsageFetcher.parse(Data("[]".utf8)) }
        #expect(throws: VeniceUsageError.invalidField("canConsume")) {
            _ = try VeniceUsageFetcher.parse(Data(#"{"canConsume":"true","balances":{}}"#.utf8))
        }
        #expect(throws: VeniceUsageError.invalidField("balances")) {
            _ = try VeniceUsageFetcher.parse(Data(#"{"canConsume":true,"balances":[]}"#.utf8))
        }
        #expect(throws: VeniceUsageError.invalidField("balances.usd")) {
            _ = try VeniceUsageFetcher.parse(Data(#"{"canConsume":true,"balances":{"usd":"nope"}}"#.utf8))
        }
    }

    @Test
    func resolvesStoredKeyThenDocumentedAliases() {
        #expect(VeniceUsageFetcher.resolvedAPIKey(
            configured: " stored ",
            environment: ["VENICE_API_KEY": "environment"]
        ) == "stored")
        #expect(VeniceUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["VENICE_API_KEY": " 'primary' ", "VENICE_KEY": "fallback"]
        ) == "primary")
        #expect(VeniceUsageFetcher.resolvedAPIKey(configured: nil, environment: ["VENICE_KEY": " fallback "]) == "fallback")
    }

    @Test
    func fetchUsesExactBillingEndpointAndBearerToken() async throws {
        VeniceTestURLProtocol.handler = { request in
            #expect(request.url == VeniceUsageFetcher.endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer venice-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(#"{"canConsume":true,"consumptionCurrency":"USD","balances":{"diem":null,"usd":1},"diemEpochAllocation":null}"#.utf8))
        }
        defer { VeniceTestURLProtocol.handler = nil }
        let usage = try await VeniceUsageFetcher.fetch(apiKey: "venice-test", session: Self.session(), environment: [:])
        #expect(usage.windows[0].detail == "$1.00 USD remaining")
    }

    private static func parse(_ json: String) throws -> ProviderUsage {
        try VeniceUsageFetcher.parse(Data(json.utf8)).toProviderUsage()
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VeniceTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class VeniceTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
