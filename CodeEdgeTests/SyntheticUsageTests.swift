import Foundation
import Testing
@testable import CodeEdge

@Suite("Synthetic usage", .serialized)
struct SyntheticUsageTests {
    @Test
    func genericQuotaFixtureMatchesCodexBarGolden() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let data = Data(#"""
        {
          "plan": "Starter",
          "quotas": [
            { "name": "Monthly", "limit": 1000, "used": 250, "reset_at": "2025-01-01T00:00:00Z" },
            { "name": "Daily", "max": 200, "remaining": 50, "window_minutes": 1440 }
          ]
        }
        """#.utf8)

        let usage = try SyntheticUsageFetcher.parse(data, now: now).toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Five-hour quota", "Weekly quota"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.75])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(usage.windows[1].detail == "1 day window")
        #expect(usage.plan == "Starter")
        #expect(usage.updatedAt == now)
    }

    @Test
    func missingRollingLaneKeepsWeeklyAndSearchSlots() throws {
        let data = Data(#"""
        {
          "weeklyTokenLimit": {
            "nextRegenAt": "2026-04-17T05:19:30.000Z",
            "percentRemaining": 98.0,
            "maxCredits": "$36.00",
            "remainingCredits": "$35.30",
            "nextRegenCredits": "$0.72"
          },
          "search": { "hourly": {
            "limit": 250,
            "requests": 2,
            "renewsAt": "2026-04-17T04:30:01.494Z"
          }}
        }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)
        let usage = snapshot.toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Weekly quota", "Search hourly"])
        #expect(usage.windows.map(\.usedFraction) == [0.02, 0.008])
        #expect(snapshot.slots[1]?.cost?.limit == 36)
        #expect(abs((snapshot.slots[1]?.cost?.used ?? 0) - 0.7) < 0.000_000_1)
        #expect(snapshot.slots[1]?.cost?.remaining == 35.3)
        #expect(usage.providerCost == nil)
        #expect(usage.balance == nil)
        #expect(usage.windows[0].detail == AppLocalization.text(
            "下次恢复后剩余 100%", "100% left after next regen"
        ))
    }

    @Test
    func knownSlotsPreserveTheirPositionsAndRegenMetadata() throws {
        let data = Data(#"""
        {
          "rollingFiveHourLimit": {"percentUsed": 0.4, "windowHours": 5},
          "weeklyTokenLimit": {"used": 30, "remaining": 70, "tickPercent": 0.05},
          "search": {"hourly": {"percent_remaining": 25, "reset_at": 1780000100}}
        }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)
        let usage = snapshot.toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Five-hour quota", "Weekly quota", "Search hourly"])
        #expect(usage.windows.map(\.usedFraction) == [0.4, 0.3, 0.75])
        #expect(usage.windows[0].detail == "5 hours window")
        #expect(snapshot.slots[1]?.nextRegenFraction == 0.05)
        #expect(usage.windows[1].detail == nil)
        #expect(usage.windows[2].resetsAt == Date(timeIntervalSince1970: 1_780_000_100))
    }

    @Test
    func genericTraversalUsesSortedNestedEntriesAndOnlyShowsThreeLanes() throws {
        let data = Data(#"""
        {
          "usage": {
            "z": {"percent": 90},
            "a": [{"remaining": 9, "used": 1}, {"usedPercent": 20}],
            "m": {"percentRemaining": 70},
            "zz": {"percentUsed": 40, "maxCredits": 10, "usedCredits": 4}
          }
        }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)
        let usage = snapshot.toProviderUsage()
        let cost = snapshot.slots.compactMap { $0?.cost }.first

        #expect(usage.windows.map(\.usedFraction) == [0.1, 0.2, 0.3])
        #expect(cost?.used == 4)
        #expect(cost?.limit == 10)
        #expect(usage.providerCost == nil)
    }

    @Test
    func arrayRootAndAliasesAreAccepted() throws {
        let data = Data(#"""
        [
          {"usage_percent": "50", "periodSeconds": 3600},
          {"allowance": 80, "available": 60}
        ]
        """#.utf8)

        let usage = try SyntheticUsageFetcher.parse(data).toProviderUsage()

        #expect(usage.windows.map(\.usedFraction) == [0.5, 0.25])
        #expect(usage.windows[0].detail == "1 hour window")
    }

    @Test
    func searchDoesNotReviveLegacySubscriptionCounter() throws {
        let data = Data(#"""
        {
          "subscription": { "limit": 500, "requests": 0 },
          "search": { "hourly": { "limit": 250, "requests": 5 } }
        }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)

        #expect(snapshot.slots[0] == nil)
        #expect(snapshot.slots[1] == nil)
        #expect(snapshot.slots[2]?.usedFraction == 0.02)
    }

    @Test
    func subscriptionOnlyResponsesRetainLegacyCounter() throws {
        let snapshot = try SyntheticUsageFetcher.parse(Data(#"{ "subscription": { "limit": 500, "requests": 10 } }"#.utf8))

        #expect(snapshot.slots.count == 1)
        #expect(snapshot.slots[0]?.usedFraction == 0.02)
    }

    @Test(arguments: [false, true])
    func planWeeklyQuotaIgnoresRetiredSubscriptionAndPreservesSearch(wrapped: Bool) throws {
        let body = #"""
        {
          "subscription": { "limit": 500, "requests": 0, "renewsAt": "2026-10-31T15:15:05.743Z" },
          "rollingFiveHourLimit": { "percentRemaining": 50 },
          "search": {
            "hourly": { "limit": 250, "requests": 0, "renewsAt": "2026-10-31T11:15:05.743Z" }
          },
          "planWeeklyLimit": {
            "nextRegenAt": "2026-10-31T12:14:13.000Z",
            "percentRemaining": 99.47981765714286,
            "nextRegenPercent": 2
          }
        }
        """#
        let snapshot = try SyntheticUsageFetcher.parse(Data((wrapped ? "{\"data\":\(body)}" : body).utf8))
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.slots[0] == nil)
        let weekly = try #require(snapshot.slots[1])
        #expect(abs(weekly.usedFraction - 0.0052018234285714) < 0.000_000_01)
        #expect(weekly.resetsAt == ISO8601DateFormatter().date(from: "2026-10-31T12:14:13Z"))
        #expect(weekly.nextRegenFraction == 0.02)
        #expect(snapshot.slots[2]?.usedFraction == 0)
        #expect(usage.providerCost == nil)
        #expect(usage.windows.map(\.label) == ["Weekly quota", "Search hourly"])
        #expect(usage.windows[0].detail == AppLocalization.text(
            "下次恢复后剩余 100%", "100% left after next regen"
        ))
    }

    @Test(arguments: [0.0, 0.5, 1.0, 100.0])
    func planWeeklyPercentagesUsePercentagePointsNearExhaustion(remaining: Double) throws {
        let data = Data(#"""
        { "planWeeklyLimit": { "percentRemaining": \#(remaining), "nextRegenPercent": 0.5 } }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)

        #expect(snapshot.slots[0] == nil)
        #expect(abs((snapshot.slots[1]?.usedFraction ?? -1) - (100 - remaining) / 100) < 0.000_000_1)
        #expect(snapshot.slots[1]?.nextRegenFraction == 0.005)
        #expect(snapshot.slots[2] == nil)
    }

    @Test
    func legacyRollingAndWeeklyQuotasRetainFractionalPercentages() throws {
        let data = Data(#"""
        {
          "rollingFiveHourLimit": { "percentRemaining": 0.75, "tickPercent": 0.02 },
          "weeklyTokenLimit": { "percentRemaining": 0.98 },
          "search": { "hourly": { "limit": 250, "requests": 5 } }
        }
        """#.utf8)

        let snapshot = try SyntheticUsageFetcher.parse(data)

        #expect(snapshot.slots[0]?.usedFraction == 0.25)
        #expect(snapshot.slots[0]?.nextRegenFraction == 0.02)
        #expect(abs((snapshot.slots[1]?.usedFraction ?? -1) - 0.02) < 0.000_000_1)
        #expect(snapshot.slots[2]?.usedFraction == 0.02)
    }

    @Test
    func malformedOrMissingQuotaDoesNotInventUsage() {
        #expect(throws: SyntheticUsageError.self) {
            _ = try SyntheticUsageFetcher.parse(Data(#"{"status":"ok"}"#.utf8))
        }
        #expect(throws: SyntheticUsageError.self) {
            _ = try SyntheticUsageFetcher.parse(Data(#"{"quotas":[{"used":3}]}"#.utf8))
        }
        #expect(throws: SyntheticUsageError.self) {
            _ = try SyntheticUsageFetcher.parse(Data("true".utf8))
        }
    }

    @Test
    func environmentKeyStripsMatchingQuotesAndBuildsExactRequest() async throws {
        let recorder = SyntheticRequestRecorder()
        SyntheticTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, #"{"quotas":[{"percentUsed":25}]}"#)
        }
        defer { SyntheticTestURLProtocol.handler = nil }

        let usage = try await SyntheticUsageFetcher.fetch(
            apiKey: nil,
            session: Self.session(),
            environment: ["SYNTHETIC_API_KEY": "\"fixture-key\""]
        )

        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.synthetic.new/v2/quotas")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(usage.windows.first?.usedFraction == 0.25)
    }

    @Test(arguments: [401, 403])
    func unauthorizedResponsesAreInvalidCredentials(status: Int) async {
        SyntheticTestURLProtocol.handler = { _ in (status, "denied") }
        defer { SyntheticTestURLProtocol.handler = nil }

        await #expect(throws: SyntheticUsageError.invalidCredentials) {
            _ = try await SyntheticUsageFetcher.fetch(
                apiKey: "fixture-key",
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func otherHTTPFailuresKeepTheirStatus() async {
        SyntheticTestURLProtocol.handler = { _ in (429, "limited") }
        defer { SyntheticTestURLProtocol.handler = nil }

        await #expect(throws: SyntheticUsageError.requestFailed(429)) {
            _ = try await SyntheticUsageFetcher.fetch(
                apiKey: "fixture-key",
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func missingCredentialsStopsBeforeNetwork() async {
        await #expect(throws: SyntheticUsageError.missingCredentials) {
            _ = try await SyntheticUsageFetcher.fetch(
                apiKey: nil,
                session: Self.session(),
                environment: [:]
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class SyntheticRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private nonisolated final class SyntheticTestURLProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
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
