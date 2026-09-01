import Foundation
import Testing
@testable import Yomi

@Suite("Poe usage", .serialized)
struct PoeUsageTests {
    @Test(arguments: [("1500", 1500.0), ("\"2500\"", 2500.0)])
    func balanceNeverCreatesRateWindows(raw: String, expected: Double) throws {
        let balance = try PoeUsageFetcher.parseBalance(Data("{\"current_point_balance\":\(raw)}".utf8))
        let usage = PoeUsageFetcher.providerUsage(balance: balance, entries: [], now: Date())
        #expect(balance == expected)
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "\(Int(expected).formatted(.number.grouping(.automatic))) points")
        #expect(usage.details == [UsageDetail(
            id: "poe-current-balance", label: "Current balance",
            value: "\(Int(expected).formatted(.number.grouping(.automatic))) points"
        )])
    }

    @Test
    func absentBalanceProducesNoInventedValue() throws {
        #expect(try PoeUsageFetcher.parseBalance(Data("{}".utf8)) == nil)
    }

    @Test
    func historyFailurePreservesRequiredBalance() async throws {
        PoeTestURLProtocol.handler = { request in
            request.url == PoeUsageFetcher.balanceURL
                ? (200, Data(#"{"current_point_balance":1500}"#.utf8))
                : (500, Data())
        }
        defer { PoeTestURLProtocol.handler = nil }
        let usage = try await PoeUsageFetcher.fetch(apiKey: "test", session: Self.session(), environment: [:])
        #expect(usage.balance == "1,500 points")
        #expect(usage.details.count == 1)
    }

    @Test
    func paginatesAndBuildsUTCUsageSummaries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        PoeTestURLProtocol.handler = { request in
            if request.url == PoeUsageFetcher.balanceURL {
                return (200, Data(#"{"current_point_balance":300}"#.utf8))
            }
            return (200, Data("""
            {"data":[
              {"creation_time":"\(recent)","cost_points":100,"cost_usd":0.25,"bot_name":"GPT-4o","usage_type":"chat"},
              {"creation_time":"\(recent)","points":200,"bot_name":"Claude","usage_type":"chat"}
            ],"next_cursor":null}
            """.utf8))
        }
        defer { PoeTestURLProtocol.handler = nil }
        let usage = try await PoeUsageFetcher.fetch(
            apiKey: "test", session: Self.session(), environment: [:], now: now
        )
        #expect(usage.details.first { $0.label == "Today" }?.value == "300 points · 2 requests · $0.25")
        #expect(usage.details.first { $0.label == "Last 7 days" }?.value == "300 points · 2 requests · $0.25")
        #expect(usage.details.first { $0.label == "Top model" } == nil)
        #expect(usage.details.first { $0.label == "Usage mix" } == nil)
    }

    @Test
    func parserAcceptsTimestampUnitsAndRejectsInvalidNumericFields() throws {
        let cutoff = Date(timeIntervalSince1970: 0)
        let page = try PoeUsageFetcher.parseHistoryPage(Data("""
        {"data":[
          {"creation_time":1800000000,"cost_points":1},
          {"creation_time":1800000000000,"cost_points":2},
          {"creation_time":1800000000000000,"cost_points":3}
        ]}
        """.utf8), cutoff: cutoff)
        #expect(page.entries.count == 3)
        #expect(Set(page.entries.map(\.date)).count == 1)
        #expect(throws: PoeUsageError.self) {
            _ = try PoeUsageFetcher.parseHistoryPage(
                Data(#"{"data":[{"creation_time":1800000000,"cost_points":"nope"}]}"#.utf8),
                cutoff: cutoff
            )
        }
    }

    @Test
    func requestUsesExactEndpointsAndBearerToken() async throws {
        PoeTestURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer poe-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return request.url == PoeUsageFetcher.balanceURL
                ? (200, Data(#"{"current_point_balance":1}"#.utf8))
                : (200, Data(#"{"data":[]}"#.utf8))
        }
        defer { PoeTestURLProtocol.handler = nil }
        _ = try await PoeUsageFetcher.fetch(apiKey: "poe-key", session: Self.session(), environment: [:])
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PoeTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class PoeTestURLProtocol: URLProtocol, @unchecked Sendable {
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
