import Foundation
import Testing
@testable import Yomi

@Suite("Chutes usage", .serialized)
struct ChutesUsageTests {
    @Test
    func activeSubscriptionMapsRollingAndMonthlyExactly() async throws {
        let recorder = ChutesRequestRecorder()
        ChutesTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Data(#"""
            {
              "subscription":{"active":true,"plan_name":"Pro","current_period_end":"2026-07-01T00:00:00Z"},
              "monthly":{"used":250,"limit":1000,"resets_at":"2026-07-01T00:00:00Z","unit":"credits"},
              "rolling_window":{"requests":40,"limit":100,"window_minutes":240,"reset_at":"2026-06-13T18:00:00Z","unit":"requests"}
            }
            """#.utf8))
        }
        defer { ChutesTestURLProtocol.handler = nil }

        let usage = try await ChutesUsageFetcher.fetch(
            apiKey: " chutes-key ",
            endpointOverride: "https://chutes.test",
            session: Self.session(),
            environment: [:]
        )
        #expect(usage.windows.map(\.label) == ["4-hour quota", "Monthly quota"])
        #expect(usage.windows.map(\.usedFraction) == [0.4, 0.25])
        #expect(usage.windows.map(\.detail) == ["40/100 requests", "250/1000 credits"])
        #expect(usage.plan == "Pro")
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].url?.path == "/users/me/subscription_usage")
        #expect(recorder.requests[0].httpMethod == "GET")
        #expect(recorder.requests[0].timeoutInterval == 15)
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer chutes-key")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test
    func inactiveSubscriptionFetchesAndEnrichesQuotaDefinitions() async throws {
        let recorder = ChutesRequestRecorder()
        ChutesTestURLProtocol.handler = { request in
            recorder.append(request)
            let body: String = switch request.url?.path {
            case "/users/me/subscription_usage": #"{"subscription":{"active":false,"status":"free"}}"#
            case "/users/me/quotas": #"[{"chute_id":"0","is_default":true,"quota":100}]"#
            case "/users/me/quota_usage/0": #"{"quota":100,"used":10}"#
            default: throw URLError(.badURL)
            }
            return (200, Data(body.utf8))
        }
        defer { ChutesTestURLProtocol.handler = nil }
        let usage = try await ChutesUsageFetcher.fetch(
            apiKey: "key", endpointOverride: "chutes.test", session: Self.session(), environment: [:]
        )
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.1)
        #expect(usage.windows[0].detail == "10/100 credits")
        #expect(usage.plan == nil)
        #expect(recorder.requests.compactMap { $0.url?.path } == [
            "/users/me/subscription_usage", "/users/me/quotas", "/users/me/quota_usage/0",
        ])
    }

    @Test
    func partialSubscriptionUsesQuotaFallbackWithoutLosingPlan() async throws {
        let recorder = ChutesRequestRecorder()
        ChutesTestURLProtocol.handler = { request in
            recorder.append(request)
            let body: String = switch request.url?.path {
            case "/users/me/subscription_usage": #"{"subscription":{"active":true,"plan_name":"Pro"},"monthly":{"used":250,"limit":1000}}"#
            case "/users/me/quotas": #"{"rolling_window":{"requests":40,"limit":100,"window_minutes":240,"unit":"requests"}}"#
            default: throw URLError(.badURL)
            }
            return (200, Data(body.utf8))
        }
        defer { ChutesTestURLProtocol.handler = nil }
        let usage = try await ChutesUsageFetcher.fetch(
            apiKey: "key", endpointOverride: "https://chutes.test", session: Self.session(), environment: [:]
        )
        #expect(usage.windows.map(\.usedFraction) == [0.4, 0.25])
        #expect(usage.plan == "Pro")
        #expect(recorder.requests.compactMap { $0.url?.path } == [
            "/users/me/subscription_usage", "/users/me/quotas",
        ])
    }

    @Test
    func validPayloadWithoutUsageDoesNotInventWindows() throws {
        let usage = try ChutesUsageFetcher.parse(
            Data(#"{"subscription":{"active":true},"unexpected":{"nested":true}}"#.utf8)
        ).toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.plan == nil)
    }

    @Test
    func identicalUsageValuesRemainDistinctRollingAndMonthlyWindows() throws {
        let usage = try ChutesUsageFetcher.parse(Data(#"""
        {"quotas":[
          {"used":0,"limit":100,"window_minutes":240},
          {"used":0,"limit":100,"window_minutes":43200}
        ]}
        """#.utf8)).toProviderUsage()
        #expect(usage.windows.count == 2)
        #expect(usage.windows.map(\.id) == ["chutes-rolling", "chutes-monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0, 0])
    }

    @Test
    func exactOnePercentIsNotTreatedAsOneHundredPercent() throws {
        let used = try ChutesUsageFetcher.parse(
            Data(#"{"rolling_window":{"usage_percent":1}}"#.utf8)
        ).toProviderUsage()
        let remaining = try ChutesUsageFetcher.parse(
            Data(#"{"rolling_window":{"percent_remaining":1}}"#.utf8)
        ).toProviderUsage()
        #expect(used.windows[0].usedFraction == 0.01)
        #expect(remaining.windows[0].usedFraction == 0.99)
    }

    @Test(arguments: [401, 403])
    func authenticationFailuresStayDistinct(status: Int) async {
        ChutesTestURLProtocol.handler = { _ in (status, Data()) }
        defer { ChutesTestURLProtocol.handler = nil }
        await #expect(throws: ChutesUsageError.unauthorized) {
            _ = try await ChutesUsageFetcher.fetch(
                apiKey: "bad", endpointOverride: nil, session: Self.session(), environment: [:]
            )
        }
    }

    @Test
    func endpointOverrideAcceptsHTTPSAndBareHostOnly() throws {
        #expect(try ChutesUsageFetcher.resolvedAPIURL(configured: "chutes.test/api", environment: [:]).absoluteString == "https://chutes.test/api")
        #expect(try ChutesUsageFetcher.resolvedAPIURL(configured: nil, environment: ["CHUTES_API_URL": "https://env.test"]).host == "env.test")
        #expect(throws: ChutesUsageError.invalidEndpoint) {
            _ = try ChutesUsageFetcher.resolvedAPIURL(configured: "http://chutes.test", environment: [:])
        }
    }

    @Test
    func quotaFallbackFailuresPreserveVerifiedSubscriptionData() async throws {
        ChutesTestURLProtocol.handler = { request in
            if request.url?.path == "/users/me/subscription_usage" {
                return (200, Data(#"{"monthly":{"used":1,"limit":4}}"#.utf8))
            }
            return (500, Data())
        }
        defer { ChutesTestURLProtocol.handler = nil }
        let usage = try await ChutesUsageFetcher.fetch(
            apiKey: "key", endpointOverride: nil, session: Self.session(), environment: [:]
        )
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "chutes-monthly")
        #expect(usage.windows[0].usedFraction == 0.25)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChutesTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class ChutesRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private nonisolated final class ChutesTestURLProtocol: URLProtocol {
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
