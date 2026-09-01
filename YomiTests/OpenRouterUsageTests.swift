import Foundation
import Testing
@testable import Yomi

@Suite("OpenRouter usage", .serialized)
struct OpenRouterUsageTests {
    @Test
    func creditsRemainIndependentFromKeySpendingCap() throws {
        let credits = try OpenRouterUsageFetcher.parseCredits(Data(#"{"data":{"total_credits":5,"total_usage":3.1}}"#.utf8))
        let key = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"limit":30,"limit_remaining":30,"usage":27}}"#.utf8))
        let usage = OpenRouterUsageFetcher.providerUsage(
            .init(
                credits: credits,
                keyUsage: key,
                keyDiagnostic: nil,
                activity: nil,
                activityDiagnostic: "Management API key not configured",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            language: .english
        )

        #expect(credits.balance == 1.9)
        #expect(usage.balance == "$1.90")
        #expect(usage.plan == nil)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "API key limit")
        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail == "$30.00 left")
        #expect(usage.details.first { $0.label == "API key limit" }?.value == "$30.00 · Spending cap, not balance")
        #expect(usage.details.first { $0.label == "Remaining" }?.value == "$1.90")
    }

    @Test
    func serverRemainingPrecedesResetAndCumulativeUsage() throws {
        let data = Data(#"{"data":{"limit":500,"limit_remaining":454.542594979,"limit_reset":"monthly","usage":433.286754736,"usage_monthly":45.457405021}}"#.utf8)
        let key = try OpenRouterUsageFetcher.parseKeyUsage(data)

        #expect(abs((key.amountUsedForLimit ?? -1) - 45.457405021) < 1e-9)
        let usage = OpenRouterUsageFetcher.providerUsage(Self.snapshot(key: key), language: .english)
        #expect(abs(usage.windows[0].usedFraction - 0.090914810042) < 1e-12)
        #expect(usage.details.first { $0.label == "API key remaining" }?.value == "$454.54")
        #expect(usage.details.first { $0.label == "API key used" }?.value == "$433.29")
    }

    @Test(arguments: [
        (#"{"data":{"limit":30,"limit_reset":"daily","usage":27,"usage_daily":6}}"#, 6.0),
        (#"{"data":{"limit":30,"limit_reset":"weekly","usage":27,"usage_weekly":12}}"#, 12.0),
        (#"{"data":{"limit":30,"limit_reset":"monthly","usage_monthly":18}}"#, 18.0),
        (#"{"data":{"limit":30,"limit_reset":"unknown","usage":27}}"#, 27.0),
    ])
    func resetWindowFallbackMatchesDeclaredPeriod(body: String, expectedUsed: Double) throws {
        let key = try OpenRouterUsageFetcher.parseKeyUsage(Data(body.utf8))
        #expect(key.amountUsedForLimit == expectedUsed)

        let usage = OpenRouterUsageFetcher.providerUsage(Self.snapshot(key: key), language: .english)
        #expect(usage.windows.count == 1)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.first { $0.label == "Reset window" }?.value != nil)
    }

    @Test
    func dailyWeeklyMonthlySpendStayDetailsInsteadOfInventedQuotaWindows() throws {
        let key = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"usage_daily":0.12,"usage_weekly":0.74,"usage_monthly":4.56,"rate_limit":{"requests":120,"interval":"10s"}}}"#.utf8))
        let usage = OpenRouterUsageFetcher.providerUsage(Self.snapshot(key: key), language: .english)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.first { $0.label == "API key limit" }?.value == "No limit configured")
        #expect(usage.details.first { $0.label == "Today" }?.value == "$0.12")
        #expect(usage.details.first { $0.label == "This week" }?.value == "$0.74")
        #expect(usage.details.first { $0.label == "This month" }?.value == "$4.56")
        #expect(usage.details.first { $0.label == "Rate limit" }?.value == "120 requests / 10s")
    }

    @Test
    func providerOwnedDetailValuesSupportSimplifiedChinese() throws {
        let key = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"limit":30,"limit_remaining":20}}"#.utf8))
        let usage = OpenRouterUsageFetcher.providerUsage(Self.snapshot(key: key), language: .simplifiedChinese)

        #expect(usage.plan == nil)
        #expect(usage.windows.first?.detail == "剩余 $20.00")
        #expect(usage.details.first { $0.label == "API key limit" }?.value == "$30.00 · 消费上限，不是余额")
        #expect(usage.details.first { $0.label == "Last 30 days" } == nil)
    }

    @Test
    func remainingValuesClampAtBothEnds() throws {
        let above = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"limit":30,"limit_remaining":50}}"#.utf8))
        let negative = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"limit":30,"limit_remaining":-5}}"#.utf8))
        #expect(above.amountUsedForLimit == 0)
        #expect(negative.amountUsedForLimit == 30)
    }

    @Test
    func malformedCreditsAreFatalAndMalformedKeyIsClassified() throws {
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.parseCredits(Data(#"{"data":{"total_credits":"many","total_usage":3}}"#.utf8))
        }
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"limit":"thirty"}}"#.utf8))
        }
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.parseKeyUsage(Data(#"{"data":{"rate_limit":{"requests":1.5,"interval":"10s"}}}"#.utf8))
        }
    }

    @Test
    func credentialAndEndpointResolutionAreStrict() throws {
        #expect(OpenRouterUsageFetcher.resolvedAPIKey(
            configured: "  'configured-key'  ",
            environment: ["OPENROUTER_API_KEY": "environment-key"]
        ) == "configured-key")
        #expect(OpenRouterUsageFetcher.resolvedManagementKey(
            configured: nil,
            environment: ["OPENROUTER_MANAGEMENT_API_KEY": " \"management-key\" "]
        ) == "management-key")
        #expect(try OpenRouterUsageFetcher.resolvedBaseURL(
            configured: "proxy.example/api/v1/", environment: [:]
        ).absoluteString == "https://proxy.example/api/v1")
        #expect(throws: OpenRouterUsageError.invalidEndpoint("http://proxy.example/api/v1")) {
            _ = try OpenRouterUsageFetcher.resolvedBaseURL(
                configured: "http://proxy.example/api/v1", environment: [:]
            )
        }
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.resolvedBaseURL(
                configured: "https://name:secret@proxy.example/api/v1", environment: [:]
            )
        }
    }

    @Test
    func fetchUsesExactEndpointsHeadersAndOptionalKeyDeadline() async throws {
        let recorder = OpenRouterRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            let body = request.url?.path.hasSuffix("/key") == true
                ? #"{"data":{"limit":20,"usage":5}}"#
                : #"{"data":{"total_credits":100,"total_usage":40}}"#
            return try response(request, body: body)
        }
        defer { OpenRouterTestURLProtocol.handler = nil }

        let usage = try await OpenRouterUsageFetcher.fetch(
            apiKey: " standard-key ",
            endpoint: "https://proxy.example/api/v1/",
            httpReferer: "https://client.example",
            clientTitle: "Usage client",
            session: session,
            environment: [:],
            language: .english
        )
        let requests = recorder.requests

        #expect(requests.map { $0.url?.absoluteString } == [
            "https://proxy.example/api/v1/credits",
            "https://proxy.example/api/v1/key",
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer standard-key" })
        #expect(requests[0].timeoutInterval == 15)
        #expect(requests[0].value(forHTTPHeaderField: "HTTP-Referer") == "https://client.example")
        #expect(requests[0].value(forHTTPHeaderField: "X-Title") == "Usage client")
        #expect(requests[1].timeoutInterval == 1)
        #expect(requests[1].value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.details.first { $0.label == "Last 30 days" } == nil)
    }

    @Test
    func keyFailureKeepsCreditsAndDoesNotCreateAQuota() async throws {
        let session = Self.session { request in
            if request.url?.path.hasSuffix("/key") == true {
                return try response(request, body: #"{"error":"private provider response"}"#, status: 403)
            }
            return try response(request, body: #"{"data":{"total_credits":5,"total_usage":3.1}}"#)
        }
        defer { OpenRouterTestURLProtocol.handler = nil }

        let usage = try await OpenRouterUsageFetcher.fetch(
            apiKey: "standard-key", session: session, environment: [:], language: .english
        )

        #expect(usage.state == .ready)
        #expect(usage.balance == "$1.90")
        #expect(usage.windows.isEmpty)
        #expect(usage.details.first { $0.label == "API key limit" } == nil)
    }

    @Test
    func activityUsesOfficialOriginLatestCompletedDayAndExactAggregation() async throws {
        let recorder = OpenRouterRequestRecorder()
        let history = #"{"data":[{"date":"2026-08-17","model":"vendor/model-one","endpoint_id":"one","prompt_tokens":100,"completion_tokens":50,"reasoning_tokens":10,"requests":2,"usage":12.345},{"date":"2026-07-18","model":"vendor/old","endpoint_id":"old","prompt_tokens":999,"completion_tokens":1,"reasoning_tokens":0,"requests":1,"usage":99}]}"#
        let latest = #"{"data":[{"date":"2026-08-17 00:00:00","model":"vendor/model-two","endpoint_id":"two","prompt_tokens":2,"completion_tokens":3,"reasoning_tokens":1,"requests":1,"usage":0.005,"byok_usage_inference":0.75}]}"#
        let session = Self.session { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            if path.hasSuffix("/activity") {
                return try response(request, body: request.url?.query == nil ? history : latest)
            }
            if path.hasSuffix("/key") {
                return try response(request, body: #"{"data":{"limit":20,"usage":5}}"#)
            }
            return try response(request, body: #"{"data":{"total_credits":100,"total_usage":40}}"#)
        }
        defer { OpenRouterTestURLProtocol.handler = nil }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T12:00:00Z"))

        let usage = try await OpenRouterUsageFetcher.fetch(
            apiKey: "standard-key",
            endpoint: "https://proxy.example/api/v1",
            managementAPIKey: "management-key",
            session: session,
            environment: [:],
            language: .english,
            now: now
        )
        let activityRequests = recorder.requests.filter { $0.url?.path.hasSuffix("/activity") == true }

        #expect(activityRequests.count == 2)
        #expect(activityRequests.allSatisfy { $0.url?.host == "openrouter.ai" })
        #expect(activityRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer management-key"
        })
        #expect(activityRequests.first { $0.url?.query != nil }?.url?.query == "date=2026-08-17")
        #expect(usage.last30Days?.tokens == 155)
        #expect(abs((usage.last30Days?.valueUSD ?? -1) - 13.1) < 1e-9)
        #expect(usage.details.first { $0.label == "Last 30 days requests" }?.value == "3")
        #expect(abs((usage.providerCost?.used ?? -1) - 13.1) < 1e-9)
    }

    @Test
    func duplicateActivityRowsDeduplicateAndConflictsFail() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T12:00:00Z"))
        let row = #"{"date":"2026-08-17","model":"vendor/model","endpoint_id":"same","prompt_tokens":10,"completion_tokens":5,"reasoning_tokens":2,"requests":1,"usage":1}"#
        let summary = try OpenRouterUsageFetcher.parseActivity(
            historyData: Data("{\"data\":[\(row)]}".utf8),
            latestCompletedData: Data("{\"data\":[\(row)]}".utf8),
            now: now
        )
        #expect(summary.entries.count == 1)
        #expect(summary.totalTokens == 15)

        let conflict = #"{"date":"2026-08-17","model":"vendor/model","endpoint_id":"same","prompt_tokens":11,"completion_tokens":5,"reasoning_tokens":2,"requests":1,"usage":1}"#
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.parseActivity(
                historyData: Data("{\"data\":[\(row),\(conflict)]}".utf8),
                latestCompletedData: Data(#"{"data":[]}"#.utf8),
                now: now
            )
        }
    }

    @Test(arguments: ["2026-02-31", "2026-08-18", "2026-08-17T00:00:00"])
    func invalidOrIncompleteActivityDatesNeverPublishSpend(day: String) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T12:00:00Z"))
        let body = """
        {"data":[{"date":"\(day)","prompt_tokens":1,"completion_tokens":1,"reasoning_tokens":0,"requests":1,"usage":1}]}
        """
        #expect(throws: OpenRouterUsageError.self) {
            _ = try OpenRouterUsageFetcher.parseActivity(
                historyData: Data(body.utf8),
                latestCompletedData: Data(#"{"data":[]}"#.utf8),
                now: now
            )
        }
    }

    @Test
    func activityPermissionFailurePreservesCreditsAndKeyLimit() async throws {
        let session = Self.session { request in
            if request.url?.path.hasSuffix("/activity") == true {
                return try response(request, body: #"{"error":"forbidden"}"#, status: 403)
            }
            if request.url?.path.hasSuffix("/key") == true {
                return try response(request, body: #"{"data":{"limit":20,"usage":5}}"#)
            }
            return try response(request, body: #"{"data":{"total_credits":100,"total_usage":40}}"#)
        }
        defer { OpenRouterTestURLProtocol.handler = nil }

        let usage = try await OpenRouterUsageFetcher.fetch(
            apiKey: "standard-key",
            managementAPIKey: "management-key",
            session: session,
            environment: [:],
            language: .english
        )

        #expect(usage.balance == "$60.00")
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.providerCost == nil)
        #expect(usage.details.first { $0.label == "Last 30 days" } == nil)
    }

    private static func snapshot(key: OpenRouterUsageFetcher.KeyUsage) -> OpenRouterUsageFetcher.Snapshot {
        .init(
            credits: .init(total: 100, used: 40),
            keyUsage: key,
            keyDiagnostic: nil,
            activity: nil,
            activityDiagnostic: "Management API key not configured",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        OpenRouterTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func response(
    _ request: URLRequest,
    body: String,
    status: Int = 200
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    return (
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!,
        Data(body.utf8)
    )
}

private final class OpenRouterRequestRecorder: @unchecked Sendable {
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

private final class OpenRouterTestURLProtocol: URLProtocol {
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
