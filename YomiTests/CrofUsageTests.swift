import Foundation
import Testing
@testable import Yomi

@Suite("Crof usage", .serialized)
struct CrofUsageTests {
    @Test
    func creditsOnlyUsesARealBalanceWithoutInventingAQuota() throws {
        let usage = try CrofUsageFetcher.parse(Data(#"{"credits":9.0441,"requests_plan":null,"usable_requests":null}"#.utf8)).toProviderUsage()
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Credits")
        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail == "$9.04")
        #expect(usage.windows[0].resetsAt == nil)

        let depleted = try CrofUsageFetcher.parse(Data(#"{"credits":0}"#.utf8)).toProviderUsage()
        #expect(depleted.windows[0].usedFraction == 1)
        #expect(depleted.windows[0].detail == "$0.00")
    }

    @Test
    func requestQuotaPrecedesCreditsAndUsesChicagoMidnight() throws {
        let now = Date(timeIntervalSince1970: 1_777_800_000)
        let usage = try CrofUsageFetcher.parse(
            Data(#"{"credits":10,"requests_plan":1000,"usable_requests":998}"#.utf8),
            now: now
        ).toProviderUsage()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let expectedReset = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))

        #expect(usage.windows.map(\.label) == ["Requests", "Credits"])
        #expect(usage.windows[0].usedFraction == 0.01)
        #expect(usage.windows[0].detail == "998 requests left")
        #expect(usage.windows[0].resetsAt == expectedReset)
        #expect(usage.windows[1].detail == "$10.00")
    }

    @Test
    func clampsRequestMathButKeepsExactDisplayedCount() throws {
        let over = try CrofUsageFetcher.parse(
            Data(#"{"credits":1,"requests_plan":100,"usable_requests":120.25}"#.utf8)
        ).toProviderUsage()
        #expect(over.windows[0].usedFraction == 0)
        #expect(over.windows[0].detail == "120.25 requests left")

        let negative = try CrofUsageFetcher.parse(
            Data(#"{"credits":1,"requests_plan":100,"usable_requests":-4}"#.utf8)
        ).toProviderUsage()
        #expect(negative.windows[0].usedFraction == 1)
        #expect(negative.windows[0].detail == "0 requests left")
    }

    @Test
    func rejectsMissingWrongTypeAndNonObjectPayloads() {
        #expect(throws: CrofUsageError.invalidField("credits")) {
            _ = try CrofUsageFetcher.parse(Data(#"{"credits":"9"}"#.utf8))
        }
        #expect(throws: CrofUsageError.invalidField("requests_plan")) {
            _ = try CrofUsageFetcher.parse(Data(#"{"credits":9,"requests_plan":"100"}"#.utf8))
        }
        #expect(throws: CrofUsageError.invalidResponse) {
            _ = try CrofUsageFetcher.parse(Data("[]".utf8))
        }
    }

    @Test
    func environmentHasPriorityAndAliasesAreSupported() {
        #expect(CrofUsageFetcher.resolvedAPIKey(
            configured: "stored",
            environment: ["CROF_API_KEY": " 'environment' "]
        ) == "environment")
        #expect(CrofUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["CROFAI_API_KEY": " alias "]
        ) == "alias")
        #expect(CrofUsageFetcher.resolvedAPIKey(configured: "  ", environment: [:]) == nil)
    }

    @Test
    func fetchUsesExactPublicEndpointAndBearerToken() async throws {
        CrofTestURLProtocol.handler = { request in
            #expect(request.url == CrofUsageFetcher.endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer crof-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(#"{"credits":9.0441}"#.utf8))
        }
        defer { CrofTestURLProtocol.handler = nil }
        let usage = try await CrofUsageFetcher.fetch(
            apiKey: "crof-test",
            session: Self.session(),
            environment: [:]
        )
        #expect(usage.windows[0].detail == "$9.04")
    }

    @Test(arguments: [401, 403])
    func authenticationFailuresStayDistinct(status: Int) async {
        CrofTestURLProtocol.handler = { _ in (status, Data()) }
        defer { CrofTestURLProtocol.handler = nil }
        await #expect(throws: CrofUsageError.unauthorized) {
            _ = try await CrofUsageFetcher.fetch(apiKey: "token", session: Self.session(), environment: [:])
        }
    }

    @Test
    func otherHTTPFailuresKeepTheirStatus() async {
        CrofTestURLProtocol.handler = { _ in (429, Data()) }
        defer { CrofTestURLProtocol.handler = nil }
        await #expect(throws: CrofUsageError.apiError(429)) {
            _ = try await CrofUsageFetcher.fetch(apiKey: "token", session: Self.session(), environment: [:])
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrofTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CrofTestURLProtocol: URLProtocol, @unchecked Sendable {
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
