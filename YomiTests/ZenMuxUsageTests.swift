import Foundation
import Testing
@testable import Yomi

@Suite("ZenMux usage", .serialized)
struct ZenMuxUsageTests {
    @Test
    func subscriptionAndBalanceMapExactly() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ZenMuxTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            switch request.url?.path {
            case "/api/v1/management/subscription/detail": return (200, Data(Self.subscription.utf8))
            case "/api/v1/management/payg/balance": return (200, Data(#"{"success":true,"data":{"currency":"usd","total_credits":482.74}}"#.utf8))
            default: return (404, Data())
            }
        }
        defer { ZenMuxTestURLProtocol.handler = nil }
        let usage = try await ZenMuxUsageFetcher.fetch(
            managementKey: "management-key", session: Self.session(), environment: [:], now: now
        )
        #expect(usage.windows.count == 2)
        #expect(abs(usage.windows[0].usedFraction - 0.0715) < 0.000001)
        #expect(usage.windows[0].detail == "57.20 / 800 flows")
        #expect(abs(usage.windows[1].usedFraction - 0.0673) < 0.000001)
        #expect(usage.windows[1].detail == "416.11 / 6182 flows")
        #expect(usage.plan == "Ultra plan")
        #expect(usage.providerCost?.used == 482.74)
        #expect(usage.providerCost?.period == "ZenMux PAYG balance")
    }

    @Test
    func optionalBalanceFailurePreservesQuotaButAuthDoesNot() async throws {
        ZenMuxTestURLProtocol.handler = { request in
            request.url?.path.hasSuffix("subscription/detail") == true
                ? (200, Data(Self.subscription.utf8))
                : (500, Data())
        }
        defer { ZenMuxTestURLProtocol.handler = nil }
        let usage = try await ZenMuxUsageFetcher.fetch(managementKey: "key", session: Self.session(), environment: [:])
        #expect(usage.windows.count == 2)
        #expect(usage.providerCost == nil)

        ZenMuxTestURLProtocol.handler = { request in
            request.url?.path.hasSuffix("subscription/detail") == true
                ? (200, Data(Self.subscription.utf8))
                : (401, Data())
        }
        await #expect(throws: ZenMuxUsageError.unauthorized) {
            _ = try await ZenMuxUsageFetcher.fetch(managementKey: "key", session: Self.session(), environment: [:])
        }
    }

    @Test
    func nonUSDBalanceIsIgnoredAndAccountStatusIsNotPresentedAsPlan() async throws {
        let subscription = Self.subscription.replacingOccurrences(of: "healthy", with: "monitored")
        ZenMuxTestURLProtocol.handler = { request in
            request.url?.path.hasSuffix("subscription/detail") == true
                ? (200, Data(subscription.utf8))
                : (200, Data(#"{"success":true,"data":{"currency":"eur","total_credits":5}}"#.utf8))
        }
        defer { ZenMuxTestURLProtocol.handler = nil }
        let usage = try await ZenMuxUsageFetcher.fetch(managementKey: "key", session: Self.session(), environment: [:])
        #expect(usage.plan == "Ultra plan")
        #expect(usage.providerCost == nil)
    }

    @Test(arguments: [401, 403])
    func authenticationStatusIsFatal(status: Int) async {
        ZenMuxTestURLProtocol.handler = { _ in (status, Data()) }
        defer { ZenMuxTestURLProtocol.handler = nil }
        await #expect(throws: ZenMuxUsageError.unauthorized) {
            _ = try await ZenMuxUsageFetcher.fetch(managementKey: "key", session: Self.session(), environment: [:])
        }
    }

    @Test
    func missingCredentialAndMalformedSubscriptionFailClosed() async {
        await #expect(throws: ZenMuxUsageError.missingCredentials) {
            _ = try await ZenMuxUsageFetcher.fetch(managementKey: "  ", session: Self.session(), environment: [:])
        }
        ZenMuxTestURLProtocol.handler = { _ in (200, Data(#"{"success":true,"data":{"plan":{}}}"#.utf8)) }
        defer { ZenMuxTestURLProtocol.handler = nil }
        await #expect(throws: ZenMuxUsageError.self) {
            _ = try await ZenMuxUsageFetcher.fetch(managementKey: "key", session: Self.session(), environment: [:])
        }
    }

    private nonisolated static let subscription = #"{"success":true,"data":{"plan":{"tier":"ultra","expires_at":"2026-04-12T08:26:56.000Z"},"account_status":"healthy","quota_5_hour":{"usage_percentage":0.0715,"resets_at":"2026-03-24T08:35:09.000Z","max_flows":800,"used_flows":57.2,"remaining_flows":742.8},"quota_7_day":{"usage_percentage":0.0673,"resets_at":"2026-03-26T02:15:05.000Z","max_flows":6182,"used_flows":416.11,"remaining_flows":5765.89}}}"#

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZenMuxTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ZenMuxTestURLProtocol: URLProtocol {
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
