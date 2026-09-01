import Foundation
import Testing
@testable import Yomi

@Suite("Moonshot usage", .serialized)
struct MoonshotUsageTests {
    @Test
    func parsesDocumentedBalanceWithoutInventingQuotaWindows() throws {
        let now = Date(timeIntervalSince1970: 1_788_192_000)
        let data = Data(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":50.0,"cash_balance":12.34},"scode":"0x0","status":true}"#.utf8)

        let summary = try MoonshotUsageFetcher.parseSummary(data, now: now)
        let usage = MoonshotUsageFetcher.providerUsage(summary: summary)

        #expect(summary.availableBalance == 49.58)
        #expect(summary.voucherBalance == 50)
        #expect(summary.cashBalance == 12.34)
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == "$49.58")
        #expect(usage.plan == nil)
        #expect(usage.details == [
            UsageDetail(id: "moonshot-balance", label: "Balance", value: "$49.58"),
        ])
        #expect(usage.updatedAt == now)
    }

    @Test
    func negativeCashBalanceSurfacesDeficitWithoutCreatingAWindow() throws {
        let data = Data(#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":50.0,"cash_balance":-0.42},"scode":"0x0","status":true}"#.utf8)

        let usage = MoonshotUsageFetcher.providerUsage(
            summary: try MoonshotUsageFetcher.parseSummary(data)
        )

        #expect(usage.windows.isEmpty)
        #expect(usage.details.first?.value == "$49.58 · $0.42 in deficit")
    }

    @Test
    func invalidRootReturnsParseError() {
        let data = Data(#"[{"available_balance":1}]"#.utf8)

        #expect(throws: MoonshotUsageError.self) {
            _ = try MoonshotUsageFetcher.parseSummary(data)
        }
        do {
            _ = try MoonshotUsageFetcher.parseSummary(data)
            Issue.record("Expected parse failure")
        } catch {
            guard case MoonshotUsageError.parseFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func unsuccessfulPayloadReturnsProviderCodeAndStatusError() {
        let data = Data(#"{"code":401,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":0},"scode":"unauthorized","status":false}"#.utf8)

        #expect(throws: MoonshotUsageError.apiError("code 401, scode unauthorized")) {
            _ = try MoonshotUsageFetcher.parseSummary(data)
        }
    }

    @Test
    func regionalEndpointsMatchOfficialHosts() {
        #expect(
            MoonshotUsageFetcher.balanceURL(region: .international).absoluteString
                == "https://api.moonshot.ai/v1/users/me/balance"
        )
        #expect(
            MoonshotUsageFetcher.balanceURL(region: .china).absoluteString
                == "https://api.moonshot.cn/v1/users/me/balance"
        )
    }

    @Test
    func regionDefaultsToInternationalAndParsesChina() {
        #expect(MoonshotUsageFetcher.resolvedRegion(configured: nil, environment: [:]) == .international)
        #expect(MoonshotUsageFetcher.resolvedRegion(
            configured: nil,
            environment: ["MOONSHOT_REGION": "china"]
        ) == .china)
        #expect(MoonshotUsageFetcher.resolvedRegion(
            configured: "moon",
            environment: ["MOONSHOT_REGION": "china"]
        ) == .international)
    }

    @Test
    func environmentKeyUsesDocumentedPriorityAndStripsQuotes() {
        let primary = [
            "MOONSHOT_API_KEY": " primary-token ",
            "MOONSHOT_KEY": "fallback-token",
        ]
        let fallback = ["MOONSHOT_KEY": "\"quoted-token\""]

        #expect(MoonshotUsageFetcher.resolvedAPIKey(
            configured: nil,
            configuredRegion: nil,
            selectedRegion: .international,
            environment: primary
        ) == "primary-token")
        #expect(MoonshotUsageFetcher.resolvedAPIKey(
            configured: nil,
            configuredRegion: nil,
            selectedRegion: .international,
            environment: fallback
        ) == "quoted-token")
    }

    @Test
    func credentialsCannotCrossRegionalHosts() {
        #expect(MoonshotUsageFetcher.resolvedAPIKey(
            configured: "international-token",
            configuredRegion: "international",
            selectedRegion: .china,
            environment: [:]
        ) == nil)
        #expect(MoonshotUsageFetcher.resolvedAPIKey(
            configured: nil,
            configuredRegion: nil,
            selectedRegion: .china,
            environment: ["MOONSHOT_API_KEY": "china-token"]
        ) == nil)
        #expect(MoonshotUsageFetcher.resolvedAPIKey(
            configured: nil,
            configuredRegion: nil,
            selectedRegion: .china,
            environment: [
                "MOONSHOT_API_KEY": "china-token",
                "MOONSHOT_REGION": "china",
            ]
        ) == "china-token")
    }

    @Test
    func legacyStoredKeyRemainsBoundToPreviouslySupportedChinaHost() {
        #expect(MoonshotUsageFetcher.storedAPIKeyRegion(nil, hasLegacyStoredKey: true) == "china")
        #expect(MoonshotUsageFetcher.storedAPIKeyRegion("international", hasLegacyStoredKey: true) == "international")
        #expect(MoonshotUsageFetcher.storedAPIKeyRegion(nil, hasLegacyStoredKey: false) == nil)
    }

    @Test
    func fetchSendsBearerTokenToSelectedRegionWithBoundedRequest() async throws {
        let recorder = MoonshotRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            let url = try #require(request.url)
            let body = #"{"code":0,"data":{"available_balance":9.87,"voucher_balance":1.23,"cash_balance":8.64},"scode":"0x0","status":true}"#
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MoonshotTestURLProtocol.handler = nil }

        let usage = try await MoonshotUsageFetcher.fetch(
            apiKey: " live-token ",
            region: "china",
            apiKeyRegion: "china",
            session: session,
            environment: [:]
        )

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.moonshot.cn/v1/users/me/balance")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(usage.balance == "$9.87")
        #expect(usage.windows.isEmpty)
    }

    @Test
    func mismatchedConfiguredKeyStopsBeforeNetwork() async {
        let recorder = MoonshotRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            throw URLError(.userAuthenticationRequired)
        }
        defer { MoonshotTestURLProtocol.handler = nil }

        await #expect(throws: MoonshotUsageError.missingCredentials) {
            _ = try await MoonshotUsageFetcher.fetch(
                apiKey: "international-token",
                region: "china",
                apiKeyRegion: "international",
                session: session,
                environment: [:]
            )
        }
        #expect(recorder.requests.isEmpty)
    }

    @Test
    func httpFailureDoesNotExposeResponseBody() async {
        let session = Self.session { request in
            let url = try #require(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":"secret provider response"}"#.utf8)
            )
        }
        defer { MoonshotTestURLProtocol.handler = nil }

        await #expect(throws: MoonshotUsageError.apiError("HTTP 401")) {
            _ = try await MoonshotUsageFetcher.fetch(
                apiKey: "live-token",
                region: "international",
                apiKeyRegion: "international",
                session: session,
                environment: [:]
            )
        }
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MoonshotTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoonshotTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MoonshotRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class MoonshotTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
