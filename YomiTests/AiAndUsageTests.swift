import Foundation
import Testing
@testable import Yomi

@Suite("ai& usage", .serialized)
struct AiAndUsageTests {
    @Test
    func requestAndSinglePageSpendMatchReference() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AiAndTestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.aiand.com/logs?range=30days&limit=100")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(#"{"data":[{"cost":"7.02344000","currency":"jpy"},{"cost":"1.10000000","currency":"jpy"},{"cost":null,"currency":"jpy"}],"has_more":false}"#.utf8))
        }
        defer { AiAndTestURLProtocol.handler = nil }
        let usage = try await AiAndUsageFetcher.fetch(
            apiKey: "fixture-key", session: Self.session(), environment: [:], now: now
        )
        #expect(usage.windows.isEmpty)
        #expect(abs((usage.providerCost?.used ?? 0) - 8.12344) < 0.000000001)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.currencyCode == "JPY")
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.updatedAt == now)
    }

    @Test
    func paginationUsesBothEncodedCursors() async throws {
        let requestCount = TestLockedValue(0)
        AiAndTestURLProtocol.handler = { request in
            let count = requestCount.withValue { value in
                value += 1
                return value
            }
            if count == 1 {
                return (200, Data(#"{"data":[{"cost":"12","currency":"jpy"}],"has_more":true,"next_after":"2026-07-17 10:24:30.094374+00","next_after_id":"row-2"}"#.utf8))
            }
            #expect(request.url?.absoluteString == "https://api.aiand.com/logs?range=30days&limit=100&after=2026-07-17%2010:24:30.094374%2B00&after_id=row-2")
            return (200, Data(#"{"data":[{"cost":"0.5","currency":"jpy"}],"has_more":false}"#.utf8))
        }
        defer { AiAndTestURLProtocol.handler = nil }
        let usage = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        #expect(requestCount.value == 2)
        #expect(usage.providerCost?.used == 12.5)
    }

    @Test
    func pageCapAndMissingCursorsMarkSpendPartial() async throws {
        AiAndTestURLProtocol.handler = { _ in
            (200, Data(#"{"data":[{"cost":"1","currency":"usd"}],"has_more":true}"#.utf8))
        }
        defer { AiAndTestURLProtocol.handler = nil }
        let missingCursor = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        #expect(missingCursor.providerCost?.period == "Last 30 days (partial)")

        let count = TestLockedValue(0)
        AiAndTestURLProtocol.handler = { _ in
            let page = count.withValue { value in
                value += 1
                return value
            }
            return (200, Data("{\"data\":[{\"cost\":\"1\",\"currency\":\"usd\"}],\"has_more\":true,\"next_after\":\"cursor-\(page)\",\"next_after_id\":\"id-\(page)\"}".utf8))
        }
        let capped = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        #expect(count.value == AiAndUsageFetcher.maxPages)
        #expect(capped.providerCost?.used == 10)
        #expect(capped.providerCost?.period == "Last 30 days (partial)")
    }

    @Test
    func mixedCurrencyAndEmptyRowsDoNotInventSpend() async throws {
        AiAndTestURLProtocol.handler = { _ in
            (200, Data(#"{"data":[{"cost":"9.5","currency":"jpy"},{"cost":"4","currency":"usd"}],"has_more":false}"#.utf8))
        }
        defer { AiAndTestURLProtocol.handler = nil }
        let mixed = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        #expect(mixed.providerCost?.used == 9.5)
        #expect(mixed.providerCost?.currencyCode == "JPY")

        AiAndTestURLProtocol.handler = { _ in (200, Data(#"{"data":[],"has_more":false}"#.utf8)) }
        let empty = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        #expect(empty.providerCost == nil)
        #expect(empty.windows.isEmpty)
    }

    @Test(arguments: [(401, AiAndUsageError.unauthorized), (402, .insufficientCredits), (429, .rateLimited), (500, .apiError(500))])
    func statusMapping(status: Int, expected: AiAndUsageError) async {
        AiAndTestURLProtocol.handler = { _ in (status, Data()) }
        defer { AiAndTestURLProtocol.handler = nil }
        await #expect(throws: expected) {
            _ = try await AiAndUsageFetcher.fetch(apiKey: "key", session: Self.session(), environment: [:])
        }
    }

    @Test
    func credentialsAndMalformedPayloadFailClosed() async {
        await #expect(throws: AiAndUsageError.missingCredentials) {
            _ = try await AiAndUsageFetcher.fetch(apiKey: "  ", session: Self.session(), environment: [:])
        }
        AiAndTestURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer quoted")
            return (200, Data(#"{"object":"list"}"#.utf8))
        }
        defer { AiAndTestURLProtocol.handler = nil }
        await #expect(throws: AiAndUsageError.self) {
            _ = try await AiAndUsageFetcher.fetch(apiKey: " 'quoted' ", session: Self.session(), environment: [:])
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AiAndTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

nonisolated final class TestLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }

    var value: Value {
        lock.withLock { storage }
    }
}

private nonisolated final class AiAndTestURLProtocol: URLProtocol {
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
