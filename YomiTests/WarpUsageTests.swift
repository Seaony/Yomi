import Foundation
import Testing
@testable import Yomi

@Suite("Warp usage", .serialized)
struct WarpUsageTests {
    @Test
    func resolvesConfiguredAndDocumentedEnvironmentKeysInOrder() {
        #expect(WarpUsageFetcher.resolvedAPIKey(
            configured: " \"configured\" ",
            environment: ["WARP_API_KEY": "environment"]
        ) == "configured")
        #expect(WarpUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: [
                "WARP_API_KEY": " primary ",
                "WARP_TOKEN": "secondary",
            ]
        ) == "primary")
        #expect(WarpUsageFetcher.resolvedAPIKey(
            configured: " ",
            environment: ["WARP_TOKEN": " 'fallback' "]
        ) == "fallback")
        #expect(WarpUsageFetcher.resolvedAPIKey(configured: nil, environment: [:]) == nil)
    }

    @Test
    func parsesLimitsAndAggregatesUserAndWorkspaceBonusGrants() throws {
        let now = Date(timeIntervalSince1970: 123)
        let data = Data(#"""
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": false,
                  "nextRefreshTime": "2026-02-28T19:16:33.462988Z",
                  "requestLimit": 1500,
                  "requestsUsedSinceLastRefresh": 5
                },
                "bonusGrants": [
                  {
                    "requestCreditsGranted": 20,
                    "requestCreditsRemaining": 10,
                    "expiration": "2026-03-01T10:00:00.100Z"
                  },
                  {
                    "requestCreditsGranted": 4,
                    "requestCreditsRemaining": 2,
                    "expiration": "2026-03-01T10:00:00.800Z"
                  }
                ],
                "workspaces": [
                  {
                    "bonusGrantsInfo": {
                      "grants": [
                        {
                          "requestCreditsGranted": "15",
                          "requestCreditsRemaining": "5",
                          "expiration": "2026-03-15T10:00:00Z"
                        }
                      ]
                    }
                  }
                ]
              }
            }
          }
        }
        """#.utf8)

        let snapshot = try WarpUsageFetcher.parse(data, updatedAt: now)

        #expect(snapshot.requestLimit == 1_500)
        #expect(snapshot.requestsUsed == 5)
        #expect(snapshot.isUnlimited == false)
        #expect(snapshot.nextRefreshTime == Self.date("2026-02-28T19:16:33.462988Z"))
        #expect(snapshot.bonusCreditsTotal == 39)
        #expect(snapshot.bonusCreditsRemaining == 17)
        #expect(snapshot.bonusNextExpiration == Self.date("2026-03-01T10:00:00.100Z"))
        #expect(snapshot.bonusNextExpirationRemaining == 12)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func stringNumbersAndBooleanAliasesMatchCodexBarParsing() throws {
        let data = Data(#"""
        {
          "data": {"user": {"__typename": "UserOutput", "user": {
            "requestLimitInfo": {
              "isUnlimited": "YES",
              "nextRefreshTime": "2026-02-28T19:16:33Z",
              "requestLimit": "1500",
              "requestsUsedSinceLastRefresh": "5"
            }
          }}}
        }
        """#.utf8)

        let snapshot = try WarpUsageFetcher.parse(data)

        #expect(snapshot.isUnlimited)
        #expect(snapshot.requestLimit == 1_500)
        #expect(snapshot.requestsUsed == 5)
        #expect(snapshot.nextRefreshTime == Self.date("2026-02-28T19:16:33Z"))
    }

    @Test
    func limitedSnapshotMapsCreditsAndAddOnCreditsExactly() throws {
        let now = Date(timeIntervalSince1970: 456)
        let reset = try #require(Self.date("2026-03-30T00:00:00Z"))
        let expiration = try #require(Self.date("2026-03-10T00:00:00Z"))
        let snapshot = WarpUsageSnapshot(
            requestLimit: 1_000,
            requestsUsed: 250,
            nextRefreshTime: reset,
            isUnlimited: false,
            updatedAt: now,
            bonusCreditsRemaining: 15,
            bonusCreditsTotal: 50,
            bonusNextExpiration: expiration,
            bonusNextExpirationRemaining: 10
        )

        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.id == ProviderID(rawValue: "warp"))
        #expect(usage.windows == [UsageWindow(
            id: "credits",
            label: "Credits",
            usedFraction: 0.25,
            resetsAt: reset,
            detail: "250/1000 credits"
        )])
        #expect(usage.additionalWindows.count == 1)
        #expect(usage.additionalWindows[0].id == "add-on-credits")
        #expect(usage.additionalWindows[0].label == "Add-on credits")
        #expect(usage.additionalWindows[0].usedFraction == 0.7)
        #expect(usage.additionalWindows[0].resetsAt == nil)
        #expect(usage.additionalWindows[0].detail == nil)
        #expect(usage.balance == nil)
        #expect(usage.plan == nil)
        #expect(usage.updatedAt == now)
    }

    @Test
    func unlimitedPrimaryIsFullRemainingAndNeverShowsResetDate() {
        let snapshot = WarpUsageSnapshot(
            requestLimit: 0,
            requestsUsed: 999,
            nextRefreshTime: Date(timeIntervalSince1970: 999),
            isUnlimited: true,
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.windows.first?.usedFraction == 0)
        #expect(usage.windows.first?.resetsAt == nil)
        #expect(usage.windows.first?.detail == "Unlimited")
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func exhaustedBonusStaysVisibleAndMissingBonusIsOmitted() {
        let exhausted = WarpUsageSnapshot(
            requestLimit: 100,
            requestsUsed: 10,
            nextRefreshTime: nil,
            isUnlimited: false,
            updatedAt: Date(),
            bonusCreditsRemaining: 0,
            bonusCreditsTotal: 20
        ).toProviderUsage(language: .english)
        let missing = WarpUsageSnapshot(
            requestLimit: 100,
            requestsUsed: 10,
            nextRefreshTime: nil,
            isUnlimited: false,
            updatedAt: Date()
        ).toProviderUsage(language: .english)

        #expect(exhausted.additionalWindows.first?.usedFraction == 1)
        #expect(exhausted.additionalWindows.first?.detail == nil)
        #expect(missing.additionalWindows.isEmpty)
    }

    @Test
    func graphQLErrorsBecomeAPIErrorAndOnlyIncludeThreeMessages() {
        let data = Data(#"""
        {"errors":[
          {"message":"first"},
          "second",
          {"message":"third"},
          {"message":"fourth"}
        ]}
        """#.utf8)

        #expect(throws: WarpUsageError.apiError(200, "first | second | third")) {
            _ = try WarpUsageFetcher.parse(data)
        }
    }

    @Test
    func malformedShapesDoNotInventUsage() {
        #expect(throws: WarpUsageError.parseFailed("Root JSON is not an object.")) {
            _ = try WarpUsageFetcher.parse(Data("[]".utf8))
        }
        #expect(throws: WarpUsageError.parseFailed("Missing data.user in response.")) {
            _ = try WarpUsageFetcher.parse(Data(#"{"data":{}}"#.utf8))
        }
        #expect(throws: WarpUsageError.parseFailed("Unexpected user type 'AuthError'.")) {
            _ = try WarpUsageFetcher.parse(Data(
                #"{"data":{"user":{"__typename":"AuthError"}}}"#.utf8
            ))
        }
        #expect(throws: WarpUsageError.parseFailed(
            "Unable to extract requestLimitInfo from response."
        )) {
            _ = try WarpUsageFetcher.parse(Data(
                #"{"data":{"user":{"__typename":"UserOutput","user":{}}}}"#.utf8
            ))
        }
    }

    @Test
    func APIErrorSummaryHandlesPlainTextJSONAndLongBodies() {
        #expect(WarpUsageFetcher.apiErrorSummary(
            statusCode: 429,
            data: Data("Rate exceeded.".utf8)
        ) == "Rate exceeded.")
        #expect(WarpUsageFetcher.apiErrorSummary(
            statusCode: 401,
            data: Data(#"{"errors":[{"message":"Unauthorized"}]}"#.utf8)
        ) == "Unauthorized")
        #expect(WarpUsageFetcher.apiErrorSummary(
            statusCode: 500,
            data: Data(#"{"message":"Unavailable"}"#.utf8)
        ) == "Unavailable")
        let long = String(repeating: "x", count: 240)
        #expect(WarpUsageFetcher.apiErrorSummary(
            statusCode: 500,
            data: Data(long.utf8)
        ).count == 203)
    }

    @Test
    func requestBodyContainsExactOperationQueryAndOSContext() throws {
        let data = try WarpUsageFetcher.requestBody(osVersionString: "26.5.0")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(root["variables"] as? [String: Any])
        let requestContext = try #require(variables["requestContext"] as? [String: Any])
        let osContext = try #require(requestContext["osContext"] as? [String: Any])

        #expect(root["operationName"] as? String == "GetRequestLimitInfo")
        #expect((root["query"] as? String)?.contains("bonusGrantsInfo") == true)
        #expect((requestContext["clientContext"] as? [String: Any])?.isEmpty == true)
        #expect(osContext["category"] as? String == "macOS")
        #expect(osContext["name"] as? String == "macOS")
        #expect(osContext["version"] as? String == "26.5.0")
    }

    @Test
    func fetchSendsExactGraphQLRequestAndMapsResponse() async throws {
        let recorder = WarpRequestRecorder()
        WarpTestURLProtocol.handler = { request in
            recorder.append(request)
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":false,"requestLimit":100,"requestsUsedSinceLastRefresh":20}}}}}"#
            return (response, Data(body.utf8))
        }
        defer { WarpTestURLProtocol.handler = nil }
        let now = Date(timeIntervalSince1970: 789)

        let usage = try await WarpUsageFetcher.fetch(
            apiKey: " wk-test ",
            session: Self.session(),
            environment: [:],
            now: now
        )

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.url?.absoluteString == "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 15)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-warp-client-id") == "warp-app")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-category") == "macOS")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-name") == "macOS")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-version")?.isEmpty == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wk-test")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Warp/1.0")
        #expect(request.httpBody?.isEmpty == false || request.httpBodyStream != nil)
        #expect(usage.windows.first?.usedFraction == 0.2)
        #expect(usage.updatedAt == now)
    }

    @Test
    func HTTPFailuresKeepStatusAndSafeSummary() async {
        WarpTestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("Rate exceeded.".utf8))
        }
        defer { WarpTestURLProtocol.handler = nil }

        await #expect(throws: WarpUsageError.apiError(429, "Rate exceeded.")) {
            _ = try await WarpUsageFetcher.fetch(
                apiKey: "wk-test",
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func missingCredentialsStopsBeforeNetwork() async {
        await #expect(throws: WarpUsageError.missingCredentials) {
            _ = try await WarpUsageFetcher.fetch(
                apiKey: nil,
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func transportFailuresBecomeNetworkErrors() async {
        WarpTestURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { WarpTestURLProtocol.handler = nil }

        do {
            _ = try await WarpUsageFetcher.fetch(
                apiKey: "wk-test",
                session: Self.session(),
                environment: [:]
            )
            Issue.record("Expected network failure")
        } catch {
            guard case WarpUsageError.networkError = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: text) { return value }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WarpTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class WarpRequestRecorder: @unchecked Sendable {
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

private final class WarpTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
