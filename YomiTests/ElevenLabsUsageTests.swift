import Foundation
import Testing
@testable import Yomi

@Suite("ElevenLabs usage", .serialized)
struct ElevenLabsUsageTests {
    @Test
    func parsesSubscriptionIntoCreditsAndVoiceWindows() throws {
        let now = Date(timeIntervalSince1970: 1)
        let data = Data(#"""
        {
          "tier": "creator",
          "character_count": 25000,
          "character_limit": 100000,
          "voice_slots_used": 2,
          "voice_limit": 10,
          "professional_voice_slots_used": 1,
          "professional_voice_limit": 2,
          "current_overage": {"amount": "0", "currency": "usd"},
          "status": "active",
          "next_character_count_reset_unix": 1738356858
        }
        """#.utf8)

        let snapshot = try ElevenLabsUsageFetcher.parseSnapshot(data, updatedAt: now)
        let usage = snapshot.providerUsage()

        #expect(snapshot.characterCount == 25_000)
        #expect(snapshot.characterLimit == 100_000)
        #expect(snapshot.usedFraction == 0.25)
        #expect(snapshot.remainingCharacters == 75_000)
        #expect(snapshot.currentOverage == ElevenLabsOverage(amount: "0", currency: "usd"))
        #expect(usage.windows == [UsageWindow(
            id: "credits",
            label: "Credits",
            usedFraction: 0.25,
            resetsAt: Date(timeIntervalSince1970: 1_738_356_858),
            detail: "25,000 / 100,000 credits"
        )])
        #expect(usage.additionalWindows == [
            UsageWindow(
                id: "voice-slots",
                label: "Voice slots",
                usedFraction: 0.2,
                resetsAt: nil,
                detail: "2 / 10"
            ),
            UsageWindow(
                id: "professional-voices",
                label: "Professional voices",
                usedFraction: 0.5,
                resetsAt: nil,
                detail: "1 / 2"
            ),
        ])
        #expect(usage.plan == "Creator")
        #expect(usage.updatedAt == now)
        #expect(usage.balance == nil)
        #expect(usage.details.isEmpty)
    }

    @Test
    func overagePercentagesClampAndRemainingNeverBecomesNegative() {
        let snapshot = makeSnapshot(
            characterCount: 150_000,
            characterLimit: 100_000,
            voiceSlotsUsed: 12,
            voiceLimit: 10
        )
        let usage = snapshot.providerUsage()

        #expect(snapshot.usedFraction == 1)
        #expect(snapshot.remainingCharacters == 0)
        #expect(usage.windows.first?.usedFraction == 1)
        #expect(usage.additionalWindows.first?.usedFraction == 1)
    }

    @Test
    func zeroCharacterLimitAndInvalidVoiceLimitsDoNotInventUsage() {
        let snapshot = makeSnapshot(
            characterCount: 50,
            characterLimit: 0,
            voiceSlotsUsed: 1,
            voiceLimit: 0
        )
        let usage = snapshot.providerUsage()

        #expect(snapshot.usedFraction == 0)
        #expect(usage.windows.first?.usedFraction == 0)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func planOnlyShowsTheRealSubscriptionTier() {
        #expect(makeSnapshot(tier: "growing_business", status: "active").providerUsage().plan == "Growing Business")
        #expect(makeSnapshot(tier: "creator", status: "past_due").providerUsage().plan == "Creator")
        #expect(makeSnapshot(tier: "  ", status: "trialing").providerUsage().plan == nil)
        #expect(makeSnapshot(tier: nil, status: nil).providerUsage().plan == nil)
    }

    @Test
    func missingRequiredSubscriptionFieldsReturnsParseFailure() {
        let data = Data(#"{"tier":"creator","character_count":10}"#.utf8)

        #expect(throws: ElevenLabsUsageError.self) {
            _ = try ElevenLabsUsageFetcher.parseSnapshot(data, updatedAt: Date())
        }
        do {
            _ = try ElevenLabsUsageFetcher.parseSnapshot(data, updatedAt: Date())
            Issue.record("Expected parse failure")
        } catch {
            guard case ElevenLabsUsageError.parseFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func APIKeyResolutionUsesDocumentedPriorityAndCleansWrappingQuotes() {
        #expect(ElevenLabsUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: [
                "ELEVENLABS_API_KEY": " primary ",
                "XI_API_KEY": "secondary",
            ]
        ) == "primary")
        #expect(ElevenLabsUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["XI_API_KEY": " 'fallback' "]
        ) == "fallback")
        #expect(ElevenLabsUsageFetcher.resolvedAPIKey(
            configured: " \"configured\" ",
            environment: ["ELEVENLABS_API_KEY": "environment"]
        ) == "configured")
        #expect(ElevenLabsUsageFetcher.resolvedAPIKey(configured: "  ", environment: [:]) == nil)
    }

    @Test
    func endpointOverrideAcceptsHTTPSBareHostsPortsAndIPv6() throws {
        #expect(try ElevenLabsUsageFetcher.resolvedAPIURL(
            environment: ["ELEVENLABS_API_URL": "https://eleven.test/v1"]
        ).absoluteString == "https://eleven.test/v1")
        #expect(try ElevenLabsUsageFetcher.resolvedAPIURL(
            environment: ["ELEVENLABS_API_URL": "eleven.test"]
        ).absoluteString == "https://eleven.test")
        #expect(try ElevenLabsUsageFetcher.resolvedAPIURL(
            environment: ["ELEVENLABS_API_URL": "localhost:8080"]
        ).absoluteString == "https://localhost:8080")
        #expect(try ElevenLabsUsageFetcher.resolvedAPIURL(
            environment: ["ELEVENLABS_API_URL": "https://[::1]:8443/v1"]
        ).absoluteString == "https://[::1]:8443/v1")
    }

    @Test(arguments: [
        "http://attacker.test",
        "https://user:pass@proxy.test/v1",
        "https://proxy.test%2f.attacker.test/v1",
        "https://bad host/v1",
        "https://bad%20host/v1",
        "https://bad%09host/v1",
    ])
    func endpointOverrideRejectsInsecureOrMalformedValues(_ endpoint: String) {
        #expect(throws: ElevenLabsUsageError.invalidEndpointOverride("ELEVENLABS_API_URL")) {
            _ = try ElevenLabsUsageFetcher.resolvedAPIURL(
                environment: ["ELEVENLABS_API_URL": endpoint]
            )
        }
    }

    @Test
    func subscriptionURLPreservesVersionedBaseBehavior() {
        #expect(ElevenLabsUsageFetcher.subscriptionURL(
            baseURL: URL(string: "https://api.elevenlabs.io")!
        ).absoluteString == "https://api.elevenlabs.io/v1/user/subscription")
        #expect(ElevenLabsUsageFetcher.subscriptionURL(
            baseURL: URL(string: "https://eleven.test/v1/")!
        ).absoluteString == "https://eleven.test/v1/user/subscription")
        #expect(ElevenLabsUsageFetcher.subscriptionURL(
            baseURL: URL(string: "https://eleven.test/proxy")!
        ).absoluteString == "https://eleven.test/proxy/v1/user/subscription")
    }

    @Test
    func fetchSendsExactRequestAndMapsResponse() async throws {
        let recorder = ElevenLabsRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            let url = try #require(request.url)
            let body = #"{"tier":"starter","character_count":1000,"character_limit":10000,"status":"active"}"#
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
        defer { ElevenLabsTestURLProtocol.handler = nil }

        let now = Date(timeIntervalSince1970: 123)
        let usage = try await ElevenLabsUsageFetcher.fetch(
            apiKey: " xi-test ",
            session: session,
            environment: ["ELEVENLABS_API_URL": "https://elevenlabs.test/v1/"],
            now: now
        )

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.url?.absoluteString == "https://elevenlabs.test/v1/user/subscription")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(usage.windows.first?.usedFraction == 0.1)
        #expect(usage.plan == "Starter")
        #expect(usage.updatedAt == now)
    }

    @Test(arguments: [401, 403])
    func unauthorizedResponsesMapToMissingCredentials(_ status: Int) async {
        let session = Self.session { request in
            let url = try #require(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":"secret response"}"#.utf8)
            )
        }
        defer { ElevenLabsTestURLProtocol.handler = nil }

        await #expect(throws: ElevenLabsUsageError.missingCredentials) {
            _ = try await ElevenLabsUsageFetcher.fetch(
                apiKey: "xi-test",
                session: session,
                environment: [:]
            )
        }
    }

    @Test
    func nonSuccessResponseDoesNotExposeResponseBody() async {
        let session = Self.session { request in
            let url = try #require(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":"secret response"}"#.utf8)
            )
        }
        defer { ElevenLabsTestURLProtocol.handler = nil }

        await #expect(throws: ElevenLabsUsageError.apiError("HTTP 500")) {
            _ = try await ElevenLabsUsageFetcher.fetch(
                apiKey: "xi-test",
                session: session,
                environment: [:]
            )
        }
    }

    @Test
    func missingCredentialAndInvalidOverrideStopBeforeNetwork() async {
        let recorder = ElevenLabsRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            throw URLError(.userAuthenticationRequired)
        }
        defer { ElevenLabsTestURLProtocol.handler = nil }

        await #expect(throws: ElevenLabsUsageError.missingCredentials) {
            _ = try await ElevenLabsUsageFetcher.fetch(
                apiKey: nil,
                session: session,
                environment: [:]
            )
        }
        await #expect(throws: ElevenLabsUsageError.invalidEndpointOverride("ELEVENLABS_API_URL")) {
            _ = try await ElevenLabsUsageFetcher.fetch(
                apiKey: "xi-test",
                session: session,
                environment: ["ELEVENLABS_API_URL": "http://attacker.test"]
            )
        }
        #expect(recorder.requests.isEmpty)
    }

    private func makeSnapshot(
        tier: String? = "creator",
        status: String? = "active",
        characterCount: Int = 25_000,
        characterLimit: Int = 100_000,
        voiceSlotsUsed: Int? = nil,
        voiceLimit: Int? = nil
    ) -> ElevenLabsUsageSnapshot {
        ElevenLabsUsageSnapshot(
            tier: tier,
            characterCount: characterCount,
            characterLimit: characterLimit,
            voiceSlotsUsed: voiceSlotsUsed,
            professionalVoiceSlotsUsed: nil,
            voiceLimit: voiceLimit,
            professionalVoiceLimit: nil,
            currentOverage: nil,
            status: status,
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        ElevenLabsTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevenLabsTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ElevenLabsRequestRecorder: @unchecked Sendable {
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

private final class ElevenLabsTestURLProtocol: URLProtocol, @unchecked Sendable {
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
