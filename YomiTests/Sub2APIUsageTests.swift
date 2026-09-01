import Foundation
import Testing
@testable import Yomi

@Suite("sub2api usage", .serialized)
struct Sub2APIUsageTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_720_440_000)

    @Test
    func quotaLimitedPayloadMapsOnlyVerifiedQuotaAndRateWindows() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(Self.quotaPayload.utf8), now: Self.now)
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(snapshot.mode == "quota_limited")
        #expect(snapshot.quota == Sub2APIQuota(limit: 100, used: 25, remaining: 75, unit: "USD"))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "sub2api-quota")
        #expect(usage.windows[0].label == "Quota")
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].detail == "$25.00 / $100.00")
        #expect(usage.additionalWindows.map(\.id) == ["5h", "7d"])
        #expect(usage.additionalWindows.map(\.label) == ["5 hour limit", "7 day limit"])
        #expect(usage.additionalWindows.map(\.usedFraction) == [0.25, 0.2])
        #expect(usage.additionalWindows[0].resetsAt != nil)
        #expect(usage.details.first { $0.id == "sub2api-today-requests" }?.value == "4")
        #expect(usage.details.first { $0.id == "sub2api-today-tokens" }?.value == "1,200 · $1.25")
        #expect(usage.details.first { $0.id == "sub2api-all-time-requests" }?.value == "40")
        #expect(usage.details.first { $0.id == "sub2api-all-time-tokens" }?.value == "12,000 · $25.00")
        #expect(usage.today == DailyTokenUsage(tokens: 1_200, valueUSD: 1.25))
        #expect(usage.providerCost == nil)
    }

    @Test
    func subscriptionCountersRemainAuthoritativeDailyWeeklyMonthlyWindows() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(Self.subscriptionPayload.utf8), now: Self.now)
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.windows.map(\.id) == ["sub2api-daily", "sub2api-weekly", "sub2api-monthly"])
        #expect(usage.windows.map(\.label) == ["Daily quota", "Weekly quota", "Monthly quota"])
        let expectedFractions: [Double] = [1, 229.20 / 700, 1296.23 / 2800]
        #expect(usage.windows.map(\.usedFraction) == expectedFractions)
        #expect(usage.windows.map(\.detail) == [
            "$120.23 / $120.00", "$229.20 / $700.00", "$1,296.23 / $2,800.00",
        ])
        #expect(usage.plan == "Claude Team")
        #expect(!usage.details.contains { $0.id == "sub2api-expires-at" })
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func walletPayloadShowsBalanceWithoutInventingQuota() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(#"""
        {
          "mode":"unrestricted","isValid":true,"planName":"Wallet plan",
          "remaining":42.5,"unit":"USD","balance":42.5
        }
        """#.utf8), now: Self.now)
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == "$42.50")
        #expect(usage.plan == "Wallet plan")
        #expect(usage.details.first == UsageDetail(id: "sub2api-balance", label: "Balance", value: "$42.50"))
    }

    @Test
    func nonUSDCurrencyMatchesCodexBarFormatting() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(#"""
        {
          "unit":"EUR","balance":12.5,
          "quota":{"limit":100,"used":25,"remaining":75,"unit":"EUR"}
        }
        """#.utf8))
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.balance == "12.50 EUR")
        #expect(usage.windows[0].detail == "25.00 EUR / 100.00 EUR")
    }

    @Test
    func missingSubscriptionLimitsDoNotCreateProgressBars() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(#"""
        {
          "subscription":{"daily_usage_usd":5,"weekly_usage_usd":10,"monthly_usage_usd":20}
        }
        """#.utf8))
        #expect(snapshot.toProviderUsage().windows.isEmpty)
    }

    @Test
    func zeroRateLimitUsesCodexBarExhaustedSemantics() throws {
        let snapshot = try Sub2APIUsageFetcher.parse(Data(#"""
        {
          "rate_limits":[{"window":"1d","limit":0,"used":0,"remaining":0}]
        }
        """#.utf8))
        #expect(snapshot.toProviderUsage(language: .english).additionalWindows[0].usedFraction == 1)
    }

    @Test(arguments: [
        ("https://api.example.com", "https://api.example.com/v1/usage?days=30&timezone=Etc/UTC"),
        ("https://api.example.com/v1", "https://api.example.com/v1/usage?days=30&timezone=Etc/UTC"),
        ("https://api.example.com/v1/usage", "https://api.example.com/v1/usage?days=30&timezone=Etc/UTC"),
        ("https://api.example.com/custom", "https://api.example.com/custom/v1/usage?days=30&timezone=Etc/UTC"),
    ])
    func rootVersionedCompleteAndCustomBasePathsNormalizeExactly(raw: String, expected: String) throws {
        let base = try Sub2APIUsageFetcher.resolvedBaseURL(configured: raw, environment: [:])
        let timezone = try #require(TimeZone(identifier: "Etc/UTC"))
        #expect(try Sub2APIUsageFetcher.usageURL(baseURL: base, timeZone: timezone).absoluteString == expected)
    }

    @Test(arguments: [
        "https://api.example.com",
        "https://api.example.com/v1",
        "http://localhost:8080",
        "http://127.0.0.2:8080",
        "http://[::1]:8080",
    ])
    func acceptsHTTPSAndLoopbackHTTP(raw: String) throws {
        #expect(try Sub2APIUsageFetcher.resolvedBaseURL(configured: raw, environment: [:]).host != nil)
    }

    @Test(arguments: [
        "http://api.example.com",
        "ftp://api.example.com",
        "api.example.com",
        "https://user:pass@api.example.com",
        "https://%61pi.example.com",
        "https://api.example.com?token=secret",
        "https://api.example.com#fragment",
    ])
    func rejectsUnsafeOrImplicitBaseURLs(raw: String) {
        #expect(throws: Sub2APIUsageError.invalidBaseURL) {
            _ = try Sub2APIUsageFetcher.resolvedBaseURL(configured: raw, environment: [:])
        }
    }

    @Test
    func configuredCredentialsWinAndQuotedEnvironmentValuesAreCleaned() throws {
        #expect(Sub2APIUsageFetcher.resolvedAPIKey(
            configured: " configured ",
            environment: ["SUB2API_API_KEY": "environment"]
        ) == "configured")
        #expect(Sub2APIUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["SUB2API_API_KEY": " 'environment' "]
        ) == "environment")
        #expect(try Sub2APIUsageFetcher.resolvedBaseURL(
            configured: nil,
            environment: ["SUB2API_BASE_URL": " 'https://api.example.com' "]
        ).host == "api.example.com")
    }

    @Test
    func missingCredentialsRemainDistinct() async {
        await #expect(throws: Sub2APIUsageError.missingAPIKey) {
            _ = try await Sub2APIUsageFetcher.fetch(
                apiKey: nil,
                endpointOverride: nil,
                session: Self.session(),
                environment: [:]
            )
        }
        await #expect(throws: Sub2APIUsageError.missingBaseURL) {
            _ = try await Sub2APIUsageFetcher.fetch(
                apiKey: "key",
                endpointOverride: nil,
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func fetchUsesExactReadOnlyEndpointBearerHeaderAndDeadline() async throws {
        Sub2APITestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/usage")
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "days", value: "30")))
            #expect(query.contains(URLQueryItem(name: "timezone", value: "Etc/UTC")))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return (200, Data(#"{"mode":"unrestricted","isValid":true,"balance":5}"#.utf8))
        }
        defer { Sub2APITestURLProtocol.handler = nil }

        let usage = try await Sub2APIUsageFetcher.fetch(
            apiKey: "fixture-key",
            endpointOverride: "https://api.example.com",
            session: Self.session(),
            environment: [:],
            timeZone: try #require(TimeZone(identifier: "Etc/UTC")),
            now: Self.now
        )
        #expect(usage.balance == "$5.00")
        #expect(usage.updatedAt == Self.now)
    }

    @Test(arguments: [401, 403, 429, 500, 503, 400])
    func HTTPFailuresPreserveClassifiedMeaning(status: Int) async {
        Sub2APITestURLProtocol.handler = { _ in (status, Data("not-json".utf8)) }
        defer { Sub2APITestURLProtocol.handler = nil }
        do {
            _ = try await Sub2APIUsageFetcher.fetch(
                apiKey: "key",
                endpointOverride: "https://api.example.com",
                session: Self.session(),
                environment: [:]
            )
            Issue.record("Expected failure")
        } catch let error as Sub2APIUsageError {
            switch status {
            case 401, 403: #expect(error == .unauthorized)
            case 429: #expect(error == .rateLimited)
            case 500...: #expect(error == .providerUnavailable(status))
            default: #expect(error == .apiFailure(status))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func successfulInvalidKeyResponseIsAuthenticationFailure() {
        #expect(throws: Sub2APIUsageError.unauthorized) {
            _ = try Sub2APIUsageFetcher.parse(Data(#"{"isValid":false}"#.utf8))
        }
    }

    @Test(arguments: [
        "not-json",
        "[]",
        #"{"quota":"not-an-object"}"#,
        #"{"quota":{"limit":"many","used":1,"remaining":1}}"#,
        #"{"quota":{"limit":10,"used":1}}"#,
        #"{"subscription":{"daily_limit_usd":"ten"}}"#,
        #"{"rate_limits":{}}"#,
        #"{"rate_limits":[{"window":"","limit":1,"used":0,"remaining":1}]}"#,
        #"{"rate_limits":[{"window":"5h","limit":1,"used":0}]}"#,
        #"{"usage":{"today":{"requests":1.5}}}"#,
        #"{"expires_at":"tomorrow"}"#,
    ])
    func malformedOrUnverifiedAccountingFieldsFailClosed(body: String) {
        #expect(throws: Sub2APIUsageError.self) {
            _ = try Sub2APIUsageFetcher.parse(Data(body.utf8))
        }
    }

    @Test
    func arbitraryPercentageFieldsNeverBecomeQuota() throws {
        let usage = try Sub2APIUsageFetcher.parse(Data(#"""
        {
          "percentage":62,"weekly":100,"message":"62% remaining"
        }
        """#.utf8)).toProviderUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func networkFailuresStayDistinctFromHTTPFailures() async {
        Sub2APITestURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { Sub2APITestURLProtocol.handler = nil }
        do {
            _ = try await Sub2APIUsageFetcher.fetch(
                apiKey: "key",
                endpointOverride: "https://api.example.com",
                session: Self.session(),
                environment: [:]
            )
            Issue.record("Expected failure")
        } catch let error as Sub2APIUsageError {
            guard case .networkFailure = error else {
                Issue.record("Expected networkFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Sub2APITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let quotaPayload = #"""
    {
      "mode":"quota_limited","isValid":true,"status":"active","remaining":75,"unit":"USD",
      "quota":{"limit":100,"used":25,"remaining":75,"unit":"USD"},
      "rate_limits":[
        {"window":"5h","limit":20,"used":5,"remaining":15,"reset_at":"2026-07-11T12:30:00Z"},
        {"window":"7d","limit":200,"used":40,"remaining":160}
      ],
      "expires_at":"2026-08-01T00:00:00Z",
      "usage":{
        "today":{"requests":4,"total_tokens":1200,"actual_cost":1.25},
        "total":{"requests":40,"total_tokens":12000,"actual_cost":25}
      }
    }
    """#

    private static let subscriptionPayload = #"""
    {
      "mode":"unrestricted","planName":"Claude Team",
      "subscription":{
        "daily_usage_usd":120.23,"weekly_usage_usd":229.20,"monthly_usage_usd":1296.23,
        "daily_limit_usd":120,"weekly_limit_usd":700,"monthly_limit_usd":2800,
        "expires_at":"2026-08-15T00:00:00.123Z"
      },
      "daily_usage":[{"date":"2026-07-05","actual_cost":229.20}]
    }
    """#
}

private final class Sub2APITestURLProtocol: URLProtocol, @unchecked Sendable {
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
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
