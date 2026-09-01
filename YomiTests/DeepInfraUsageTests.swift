import Foundation
import Testing
@testable import Yomi

@Suite("DeepInfra usage", .serialized)
struct DeepInfraUsageTests {
    @Test
    func convertsCentsAndDeductsRecentSpendFromPrepaidBalance() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try DeepInfraUsageFetcher.parse(
            checklistData: Self.checklist(stripeBalance: -99.75, recent: 3.94, limit: 20),
            usageData: Self.usage(totalCostCents: 394),
            now: now
        )
        let usage = snapshot.toProviderUsage()

        #expect(abs(snapshot.availableBalanceUSD - 95.81) < 0.000_001)
        #expect(snapshot.amountOwedUSD == 0)
        #expect(snapshot.currentMonthCostUSD == 3.94)
        #expect(snapshot.recentCostUSD == 3.94)
        #expect(snapshot.spendingLimitUSD == 20)
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$95.81 available")
        #expect(usage.details.map(\.value) == ["$95.81 available", "$3.94"])
        #expect(usage.providerCost == ProviderCostSummary(
            used: 3.94,
            limit: 20,
            currencyCode: "USD",
            period: "Billing cycle",
            balance: 95.81
        ))
        #expect(usage.updatedAt == now)
    }

    @Test
    func positiveStripeBalanceIsAmountOwedAndNoLimitIsInvented() throws {
        let usage = try DeepInfraUsageFetcher.parse(
            checklistData: Self.checklist(stripeBalance: 2.75, recent: 7, limit: -1),
            usageData: Self.usage(totalCostCents: 650)
        ).toProviderUsage()

        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$9.75 owed")
        #expect(usage.details.map(\.value) == ["$9.75 owed", "$6.50"])
        #expect(usage.providerCost == nil)
    }

    @Test
    func suspendedAccountDoesNotCreateADiagnosticQuotaWindow() throws {
        let usage = try DeepInfraUsageFetcher.parse(
            checklistData: Self.checklist(
                stripeBalance: -5,
                recent: 1,
                limit: nil,
                suspended: true,
                suspendReason: "Payment review"
            ),
            usageData: Self.usage(totalCostCents: 100)
        ).toProviderUsage()

        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$4.00 available")
    }

    @Test
    func environmentResolutionUsesDocumentedPriorityAndCleansQuotes() {
        #expect(DeepInfraUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["DEEPINFRA_API_KEY": " 'primary' ", "DEEPINFRA_TOKEN": "fallback"]
        ) == "primary")
        #expect(DeepInfraUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["DEEPINFRA_TOKEN": " fallback "]
        ) == "fallback")
        #expect(DeepInfraUsageFetcher.resolvedAPIKey(configured: nil, environment: [:]) == nil)
    }

    @Test
    func fetchesExactEndpointsInOrderWithBearerToken() async throws {
        let recorder = DeepInfraRequestRecorder()
        DeepInfraTestURLProtocol.handler = { request in
            recorder.append(request)
            return request.url == DeepInfraUsageFetcher.checklistURL
                ? (200, Self.checklist(stripeBalance: -9, recent: 2, limit: 10))
                : (200, Self.usage(totalCostCents: 150))
        }
        defer { DeepInfraTestURLProtocol.handler = nil }

        let usage = try await DeepInfraUsageFetcher.fetch(
            apiKey: " fixture-token ",
            session: Self.session()
        )
        let requests = recorder.requests

        #expect(usage.balance == "$7.00 available")
        #expect(requests.map(\.url) == [DeepInfraUsageFetcher.checklistURL, DeepInfraUsageFetcher.usageURL])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(requests.allSatisfy { $0.timeoutInterval == 30 })
    }

    @Test(arguments: [
        (401, "API key rejected (HTTP 401)."),
        (403, "API key cannot access billing data (HTTP 403)."),
        (429, "HTTP 429"),
    ])
    func HTTPFailuresStayDistinct(status: Int, message: String) async {
        DeepInfraTestURLProtocol.handler = { _ in (status, Data("private response".utf8)) }
        defer { DeepInfraTestURLProtocol.handler = nil }
        await #expect(throws: DeepInfraUsageError.apiError(message)) {
            _ = try await DeepInfraUsageFetcher.fetch(apiKey: "token", session: Self.session())
        }
    }

    @Test
    func malformedResponsesDoNotCreateBalance() {
        #expect(throws: DeepInfraUsageError.self) {
            _ = try DeepInfraUsageFetcher.parse(
                checklistData: Data("{}".utf8),
                usageData: Self.usage(totalCostCents: 100)
            )
        }
        #expect(throws: DeepInfraUsageError.self) {
            _ = try DeepInfraUsageFetcher.parse(
                checklistData: Self.checklist(stripeBalance: -1, recent: 0, limit: nil),
                usageData: Data("{}".utf8)
            )
        }
    }

    private nonisolated static func checklist(
        stripeBalance: Double,
        recent: Double,
        limit: Double?,
        suspended: Bool = false,
        suspendReason: String? = nil
    ) -> Data {
        let limitValue = limit.map { String($0) } ?? "null"
        let reason = suspendReason.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "stripe_balance": \(stripeBalance),
          "recent": \(recent),
          "limit": \(limitValue),
          "suspended": \(suspended),
          "suspend_reason": \(reason)
        }
        """.utf8)
    }

    private nonisolated static func usage(totalCostCents: Double) -> Data {
        Data("""
        {
          "months": [{"period":"2026.07","items":[],"total_cost":\(totalCostCents)}],
          "initial_month":"2026.07"
        }
        """.utf8)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepInfraTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class DeepInfraRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private nonisolated final class DeepInfraTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
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
