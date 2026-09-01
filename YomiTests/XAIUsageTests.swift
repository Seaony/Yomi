import Foundation
import Testing
@testable import Yomi

@Suite("xAI usage", .serialized)
struct XAIUsageTests {
    @Test(arguments: [
        (#"{"total":{"val":"2500"}}"#, -25.0),
        (#"{"total":{"val":"0"}}"#, 0.0),
        (#"{"total":{"val":"-333"}}"#, 3.33),
    ])
    func prepaidLedgerSignAndCentConversionMatchReference(body: String, expected: Double) throws {
        #expect(try XAIUsageFetcher.parseBalance(Data(body.utf8)) == expected)
    }

    @Test
    func malformedBalanceFailsClosed() {
        #expect(throws: XAIUsageError.self) {
            _ = try XAIUsageFetcher.parseBalance(Data(#"{"total":{"val":"n/a"}}"#.utf8))
        }
    }

    @Test
    func usageHistoryAggregatesSeriesByUTCDay() throws {
        let history = try XAIUsageFetcher.parseHistory(Data(Self.usageFixture.utf8))
        #expect(history.daily.map(\.day) == ["2027-01-13", "2027-01-14", "2027-01-15"])
        #expect(abs(history.daily[0].value - 1.25973725) < 0.000000001)
        #expect(history.daily.dropFirst().map(\.value) == [0.5, 0])
        #expect(history.partial == false)
    }

    @Test
    func providerUsageKeepsBalanceSeparateFromSpendHistoryAndNeverMakesQuota() {
        let history = (
            daily: [XAIUsageFetcher.DailySpend(day: "2027-01-15", value: 1.76)],
            partial: false
        )
        let usage = XAIUsageFetcher.providerUsage(balance: 10, history: history, now: Date())
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$10.00")
        #expect(usage.providerCost?.used == 10)
        #expect(usage.providerCost?.period == "Prepaid credits")
        #expect(usage.plan == nil)
        #expect(usage.details.first { $0.id == "xai-history" }?.value == "$1.76")
    }

    @Test
    func balanceAndUsageRequestsMatchOfficialContract() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = XAIRequestRecorder()
        XAITestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/v1/billing/teams/team-1234/prepaid/balance":
                #expect(request.httpMethod == "GET")
                return (200, Data(#"{"total":{"val":"-1000"}}"#.utf8))
            case "/v1/billing/teams/team-1234/usage":
                #expect(request.httpMethod == "POST")
                let root = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
                let analytics = try #require(root["analyticsRequest"] as? [String: Any])
                let range = try #require(analytics["timeRange"] as? [String: Any])
                #expect(range["startTime"] as? String == "2026-12-17 00:00:00")
                #expect(range["endTime"] as? String == "2027-01-15 08:00:00")
                #expect(range["timezone"] as? String == "Etc/GMT")
                #expect(analytics["timeUnit"] as? String == "TIME_UNIT_DAY")
                return (200, Data(Self.usageFixture.utf8))
            default: throw URLError(.badURL)
            }
        }
        defer { XAITestURLProtocol.handler = nil }
        let usage = try await XAIUsageFetcher.fetch(
            apiKey: "fixture-key", teamID: "team-1234", session: Self.session(), environment: [:], now: now
        )
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.allSatisfy { $0.url?.host == "management-api.x.ai" })
        #expect(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
        #expect(usage.balance == "$10.00")
    }

    @Test(arguments: [401, 403])
    func authenticationFailuresRemainFatal(status: Int) async {
        XAITestURLProtocol.handler = { _ in (status, Data()) }
        defer { XAITestURLProtocol.handler = nil }
        await #expect(throws: XAIUsageError.unauthorized) {
            _ = try await XAIUsageFetcher.fetch(
                apiKey: "bad", teamID: "team", session: Self.session(), environment: [:]
            )
        }
    }

    @Test
    func optionalHistoryFailurePreservesRequiredBalance() async throws {
        XAITestURLProtocol.handler = { request in
            request.url?.path.hasSuffix("/prepaid/balance") == true
                ? (200, Data(#"{"total":{"val":"-1000"}}"#.utf8))
                : (500, Data())
        }
        defer { XAITestURLProtocol.handler = nil }
        let usage = try await XAIUsageFetcher.fetch(
            apiKey: "key", teamID: "team", session: Self.session(), environment: [:]
        )
        #expect(usage.balance == "$10.00")
        #expect(usage.windows.isEmpty)
        #expect(usage.message == nil)
    }

    @Test
    func missingAndInvalidTeamIDsFailBeforeNetworking() async {
        await #expect(throws: XAIUsageError.missingTeamID) {
            _ = try await XAIUsageFetcher.fetch(
                apiKey: "key", teamID: nil, session: Self.session(), environment: [:]
            )
        }
        await #expect(throws: XAIUsageError.invalidTeamID) {
            _ = try await XAIUsageFetcher.fetch(
                apiKey: "key", teamID: "team/other", session: Self.session(), environment: [:]
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XAITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let usageFixture = #"""
    {"timeSeries":[
      {"dataPoints":[
        {"timestamp":"2027-01-13T00:00:00Z","values":[0.75973725]},
        {"timestamp":"2027-01-14T00:00:00Z","values":[0.5]},
        {"timestamp":"2027-01-15T00:00:00Z","values":[0]}
      ]},
      {"dataPoints":[
        {"timestamp":"2027-01-13T00:00:00Z","values":[0.5]},
        {"timestamp":"2027-01-14T00:00:00Z","values":[0]},
        {"timestamp":"2027-01-15T00:00:00Z","values":[0]}
      ]}
    ],"limitReached":false}
    """#
}

private final class XAIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class XAITestURLProtocol: URLProtocol, @unchecked Sendable {
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
