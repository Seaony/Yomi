import Foundation
import Testing
@testable import Yomi

@Suite("ClawRouter usage", .serialized)
struct ClawRouterUsageTests {
    @Test
    func budgetedPayloadMapsExactMonthlyBudgetAndCoreDetails() throws {
        let usage = try ClawRouterUsageFetcher.parse(Data(Self.budgeted.utf8)).toProviderUsage()
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "clawrouter-monthly-budget")
        #expect(usage.windows[0].usedFraction == 0.00024)
        #expect(usage.windows[0].detail == "$0.006000 / $25.00")
        #expect(usage.providerCost?.used == 0.006)
        #expect(usage.providerCost?.limit == 25)
        #expect(usage.providerCost?.balance == 24.994)
        #expect(usage.plan == nil)
        #expect(usage.details.map(\.id) == [
            "clawrouter-requests", "clawrouter-tokens", "clawrouter-actual-cost", "clawrouter-budget",
        ])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(usage.windows[0].resetsAt == DateComponents(
            calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 8, day: 1
        ).date)
    }

    @Test
    func unmeteredPayloadKeepsActualSpendWithoutFakeLimitOrWindow() throws {
        let usage = try ClawRouterUsageFetcher.parse(Data(Self.unmetered.utf8)).toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.plan == nil)
        #expect(usage.providerCost?.used == 1.25)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.details.map(\.id) == [
            "clawrouter-requests", "clawrouter-tokens", "clawrouter-actual-cost",
        ])
    }

    @Test
    func rootAndVersionedURLsNormalizeToTheSameUsagePath() throws {
        #expect(try ClawRouterUsageFetcher.usageURL(
            configured: "https://router.test", environment: [:]
        ).absoluteString == "https://router.test/v1/usage")
        #expect(try ClawRouterUsageFetcher.usageURL(
            configured: "router.test/v1", environment: [:]
        ).absoluteString == "https://router.test/v1/usage")
        #expect(throws: ClawRouterUsageError.invalidEndpoint) {
            _ = try ClawRouterUsageFetcher.usageURL(configured: "http://router.test", environment: [:])
        }
    }

    @Test
    func fetchUsesExactEndpointAndBearerAuthentication() async throws {
        ClawRouterTestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://router.test/v1/usage")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer router-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(Self.budgeted.utf8))
        }
        defer { ClawRouterTestURLProtocol.handler = nil }
        let usage = try await ClawRouterUsageFetcher.fetch(
            apiKey: "router-key", endpointOverride: "router.test", session: Self.session(), environment: [:]
        )
        #expect(usage.windows.count == 1)
    }

    @Test(arguments: [401, 403, 429, 500, 400])
    func HTTPFailuresPreserveDistinctMeaning(status: Int) async {
        ClawRouterTestURLProtocol.handler = { _ in (status, Data()) }
        defer { ClawRouterTestURLProtocol.handler = nil }
        do {
            _ = try await ClawRouterUsageFetcher.fetch(
                apiKey: "key", endpointOverride: nil, session: Self.session(), environment: [:]
            )
            Issue.record("Expected failure")
        } catch let error as ClawRouterUsageError {
            switch status {
            case 401, 403: #expect(error == .unauthorized)
            case 429: #expect(error == .rateLimited)
            case 500: #expect(error == .providerUnavailable(500))
            default: #expect(error == .apiFailure(400))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["not-json", #"{"budget":{}}"#])
    func malformedPayloadsFailClosed(body: String) {
        #expect(throws: ClawRouterUsageError.self) {
            _ = try ClawRouterUsageFetcher.parse(Data(body.utf8))
        }
    }

    @Test
    func everyAccountingNumberMustBeAnIntegerMicrounit() {
        let fractional = Self.budgeted.replacingOccurrences(of: "\"spentMicros\":6000", with: "\"spentMicros\":6000.5")
        #expect(throws: ClawRouterUsageError.self) {
            _ = try ClawRouterUsageFetcher.parse(Data(fractional.utf8))
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClawRouterTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static let budgeted = #"""
    {
      "budget":{"configured":true,"ledger":"durable_object","windowKey":"openclaw/policy/2026-07","limitMicros":25000000,"spentMicros":6000,"remainingMicros":24994000},
      "usage":{"summary":{"requestCount":6,"successCount":5,"errorCount":1,"inputTokens":50000,"outputTokens":4191,"totalTokens":54191,"actualCostMicros":6000},
      "providers":[
        {"provider":"anthropic","requestCount":2,"successCount":2,"errorCount":0,"totalTokens":12191,"actualCostMicros":2000},
        {"provider":"openai","requestCount":4,"successCount":3,"errorCount":1,"totalTokens":42000,"actualCostMicros":4000}
      ]}
    }
    """#

    private static let unmetered = #"""
    {
      "budget":{"configured":false,"ledger":"unmetered","windowKey":null,"limitMicros":null,"spentMicros":null,"remainingMicros":null},
      "usage":{"summary":{"requestCount":3,"successCount":3,"errorCount":0,"inputTokens":0,"outputTokens":0,"totalTokens":0,"actualCostMicros":1250000},
      "providers":[
        {"provider":"tavily","requestCount":2,"successCount":2,"errorCount":0,"totalTokens":0,"actualCostMicros":250000},
        {"provider":"replicate","requestCount":1,"successCount":1,"errorCount":0,"totalTokens":0,"actualCostMicros":1000000}
      ]}
    }
    """#
}

private final class ClawRouterTestURLProtocol: URLProtocol {
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
