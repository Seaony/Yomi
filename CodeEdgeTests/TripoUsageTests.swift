import Foundation
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct TripoUsageTests {
    private static let contract = #"{"code":0,"data":{"balance":125.75,"frozen":20.25}}"#

    @Test
    func availableCreditsDoNotSubtractReservationsOrInventQuota() throws {
        let usage = try TripoUsageFetcher.parse(Data(Self.contract.utf8))

        #expect(usage.windows.isEmpty)
        #expect(usage.providerCost == nil)
        #expect(usage.details.first { $0.id == "tripo-balance" }?.value == "125.75")
        #expect(usage.details.first { $0.id == "tripo-reserved" }?.value == "20.25")

        let zero = try TripoUsageFetcher.parse(Data(#"{"code":0,"data":{"balance":0,"frozen":0}}"#.utf8))
        #expect(zero.details.first { $0.id == "tripo-balance" }?.value == "0")
    }

    @Test(arguments: [
        "not-json", "[]", "{}", #"{"code":0,"data":[]}"#,
        #"{"code":false,"data":{"balance":100,"frozen":0}}"#,
        #"{"code":0,"data":{"frozen":0}}"#,
        #"{"code":0,"data":{"balance":null,"frozen":0}}"#,
        #"{"code":0,"data":{"balance":100,"frozen":"private-response-marker"}}"#,
        #"{"code":0,"data":{"balance":100}}"#,
        #"{"code":0,"data":{"balance":"100","frozen":0}}"#,
        #"{"code":0,"data":{"balance":true,"frozen":0}}"#,
        #"{"code":0,"data":{"balance":-1,"frozen":0}}"#,
        #"{"code":0,"data":{"balance":100,"frozen":-1}}"#,
        #"{"code":0,"data":{"balance":1e309,"frozen":0}}"#,
    ])
    func invalidBalanceResponsesFail(body: String) {
        #expect(throws: TripoUsageError.parseFailure) {
            try TripoUsageFetcher.parse(Data(body.utf8))
        }
    }

    @Test
    func apiErrorEnvelopeIsARequestFailure() {
        #expect(throws: TripoUsageError.requestRejected) {
            try TripoUsageFetcher.parse(Data(#"{"code":1,"message":"private-response-marker"}"#.utf8))
        }
    }

    @Test
    func requestUsesBearerGETOnOfficialEndpoint() async throws {
        TripoTestURLProtocol.reset(body: Self.contract)
        _ = try await TripoUsageFetcher.fetch(apiKey: "tripo_fixture", session: Self.session(), environment: [:])

        let request = try #require(TripoTestURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://openapi.tripo3d.ai/v3/account/balance")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tripo_fixture")
        #expect(TripoTestURLProtocol.requestCount == 1)
    }

    @Test
    func missingKeyFailsBeforeRequest() async {
        TripoTestURLProtocol.reset(body: Self.contract)
        await #expect(throws: TripoUsageError.missingCredentials) {
            try await TripoUsageFetcher.fetch(apiKey: nil, session: Self.session(), environment: [:])
        }
        #expect(TripoTestURLProtocol.requestCount == 0)
    }

    @Test(arguments: [
        (401, TripoUsageError.authenticationExpired),
        (403, TripoUsageError.permissionDenied),
        (429, TripoUsageError.rateLimited),
        (500, TripoUsageError.providerUnavailable(500)),
        (404, TripoUsageError.apiFailure(404)),
    ])
    func httpFailuresAreClassifiedWithoutRetrying(status: Int, expected: TripoUsageError) async {
        TripoTestURLProtocol.reset(body: "private-response-marker", status: status)
        await #expect(throws: expected) {
            try await TripoUsageFetcher.fetch(apiKey: "tripo_fixture", session: Self.session(), environment: [:])
        }
        #expect(TripoTestURLProtocol.requestCount == 1)
        #expect(expected.errorDescription?.contains("private-response-marker") == false)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TripoTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class TripoTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requestCount = 0

    static func reset(body: String, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
        lastRequest = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
