import Foundation
import Testing
@testable import Yomi

@Suite("Abacus usage", .serialized)
struct AbacusUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func parsesCreditsBillingDateAndPlanWithoutUnitConversion() throws {
        let snapshot = try AbacusUsageFetcher.parseResults(
            computePoints: ["totalComputePoints": 1_000, "computePointsLeft": 750.0],
            billingInfo: [
                "nextBillingDate": "2026-09-30T12:34:56.789Z",
                "currentTier": "Pro",
            ],
            now: Self.now
        )
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.creditsUsed == 250)
        #expect(snapshot.creditsTotal == 1_000)
        #expect(snapshot.resetsAt == Self.date("2026-09-30T12:34:56.789Z"))
        #expect(usage.id == ProviderID(rawValue: "abacus"))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].detail == "250 / 1,000 credits")
        #expect(usage.plan == "Pro")
        #expect(usage.updatedAt == Self.now)
    }

    @Test
    func creditFormattingAndFractionsMatchReference() {
        #expect(AbacusUsageSnapshot.formatCredits(12_345) == "12,345")
        #expect(AbacusUsageSnapshot.formatCredits(42.5) == "42.5")

        let zero = AbacusUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 500,
            resetsAt: nil,
            planName: "Basic",
            updatedAt: Self.now
        ).toProviderUsage()
        let full = AbacusUsageSnapshot(
            creditsUsed: 1_200,
            creditsTotal: 1_000,
            resetsAt: nil,
            planName: nil,
            updatedAt: Self.now
        ).toProviderUsage()
        let missing = AbacusUsageSnapshot(
            creditsUsed: nil,
            creditsTotal: nil,
            resetsAt: nil,
            planName: nil,
            updatedAt: Self.now
        ).toProviderUsage()

        #expect(zero.windows[0].usedFraction == 0)
        #expect(zero.windows[0].detail == "0 / 500 credits")
        #expect(full.windows[0].usedFraction == 1)
        #expect(missing.windows[0].usedFraction == 0)
        #expect(missing.windows[0].detail == nil)
    }

    @Test
    func missingCreditFieldsFailClosedAndListAvailableKeys() {
        #expect(throws: AbacusUsageError.parseFailed(
            "Missing credit fields in compute points response. Keys: [computePointsLeft]"
        )) {
            _ = try AbacusUsageFetcher.parseResults(
                computePoints: ["computePointsLeft": 10],
                billingInfo: [:]
            )
        }
    }

    @Test
    func cookieNormalizerAcceptsHeadersAndCurlCaptures() {
        #expect(AbacusUsageFetcher.normalizedCookie("Cookie: sessionid=abc; theme=dark") == "sessionid=abc; theme=dark")
        #expect(AbacusUsageFetcher.normalizedCookie("curl https://apps.abacus.ai -H 'Cookie: sessionid=abc'") == "sessionid=abc")
        #expect(AbacusUsageFetcher.normalizedCookie("curl https://apps.abacus.ai --cookie \"sessionid=abc\"") == "sessionid=abc")
        #expect(AbacusUsageFetcher.normalizedCookie(nil) == nil)
    }

    @Test
    func browserCookieValidationRejectsAnonymousAndCSRFSets() {
        #expect(AbacusUsageFetcher.containsSessionCookie(["sessionid"]))
        #expect(AbacusUsageFetcher.containsSessionCookie(["custom_auth_cookie"]))
        #expect(AbacusUsageFetcher.containsSessionCookie(["my_jwt_value"]))
        #expect(!AbacusUsageFetcher.containsSessionCookie(["csrftoken", "_ga", "analytics_session"]))
        #expect(!AbacusUsageFetcher.containsSessionCookie(["theme", "marketing_id"]))
    }

    @Test
    func exactConcurrentRequestsMapRequiredAndOptionalResponses() async throws {
        let recorder = AbacusRequestRecorder()
        AbacusTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url {
            case AbacusUsageFetcher.computePointsURL:
                return (200, Self.envelope([
                    "totalComputePoints": 2_000,
                    "computePointsLeft": 1_500,
                ]))
            case AbacusUsageFetcher.billingInfoURL:
                return (200, Self.envelope([
                    "nextBillingDate": "2026-10-01T00:00:00Z",
                    "currentTier": "Team",
                ]))
            default:
                return (404, Data())
            }
        }
        defer { AbacusTestURLProtocol.handler = nil }

        let snapshot = try await AbacusUsageFetcher.fetchWithCookieHeader(
            "sessionid=abc",
            session: Self.session(),
            now: Self.now
        )
        let requests = recorder.requests

        #expect(requests.count == 2)
        let compute = try #require(requests.first { $0.url == AbacusUsageFetcher.computePointsURL })
        let billing = try #require(requests.first { $0.url == AbacusUsageFetcher.billingInfoURL })
        #expect(compute.httpMethod == "GET")
        #expect(compute.httpBody == nil)
        #expect(billing.httpMethod == "POST")
        #expect(billing.httpBody == Data("{}".utf8))
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "sessionid=abc" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        #expect(snapshot.creditsUsed == 500)
        #expect(snapshot.planName == "Team")
    }

    @Test
    func optionalBillingFailureStillReturnsReliableCredits() async throws {
        AbacusTestURLProtocol.handler = { request in
            request.url == AbacusUsageFetcher.computePointsURL
                ? (200, Self.envelope(["totalComputePoints": 100, "computePointsLeft": 25]))
                : (500, Data("private billing body".utf8))
        }
        defer { AbacusTestURLProtocol.handler = nil }

        let snapshot = try await AbacusUsageFetcher.fetchWithCookieHeader(
            "sessionid=abc",
            session: Self.session(),
            now: Self.now
        )
        #expect(snapshot.creditsUsed == 75)
        #expect(snapshot.resetsAt == nil)
        #expect(snapshot.planName == nil)
    }

    @Test(arguments: [401, 403])
    func authenticationStatusesAreUnauthorized(status: Int) async {
        AbacusTestURLProtocol.handler = { request in
            request.url == AbacusUsageFetcher.computePointsURL
                ? (status, Data())
                : (500, Data())
        }
        defer { AbacusTestURLProtocol.handler = nil }

        await #expect(throws: AbacusUsageError.unauthorized) {
            _ = try await AbacusUsageFetcher.fetchWithCookieHeader(
                "sessionid=bad",
                session: Self.session()
            )
        }
    }

    @Test
    func applicationAuthenticationErrorsAreUnauthorized() async {
        AbacusTestURLProtocol.handler = { request in
            request.url == AbacusUsageFetcher.computePointsURL
                ? (200, Data(#"{"success":false,"error":"Session expired"}"#.utf8))
                : (500, Data())
        }
        defer { AbacusTestURLProtocol.handler = nil }

        await #expect(throws: AbacusUsageError.unauthorized) {
            _ = try await AbacusUsageFetcher.fetchWithCookieHeader(
                "sessionid=bad",
                session: Self.session()
            )
        }
    }

    @Test
    func malformedAndNonDictionaryJSONNeverInventCredits() async {
        for data in [Data("not-json".utf8), Data("[]".utf8)] {
            AbacusTestURLProtocol.handler = { request in
                request.url == AbacusUsageFetcher.computePointsURL ? (200, data) : (500, Data())
            }
            await #expect(throws: AbacusUsageError.self) {
                _ = try await AbacusUsageFetcher.fetchWithCookieHeader(
                    "sessionid=abc",
                    session: Self.session()
                )
            }
        }
        AbacusTestURLProtocol.handler = nil
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AbacusTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func envelope(_ result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["success": true, "result": result])
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private final class AbacusRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            recorded.httpBody = data
        }
        lock.withLock { storage.append(recorded) }
    }
}

private final class AbacusTestURLProtocol: URLProtocol, @unchecked Sendable {
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
