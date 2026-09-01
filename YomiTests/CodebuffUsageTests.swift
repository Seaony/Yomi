import Foundation
import Testing
@testable import Yomi

@Suite("Codebuff usage", .serialized)
struct CodebuffUsageTests {
    @Test
    func credentialPriorityMatchesEnvironmentSettingsAndCLIFile() throws {
        let file = try Self.credentialsFile(#"{"authToken":"file-token"}"#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(CodebuffUsageFetcher.resolvedCredential(
            configured: "settings-token",
            environment: ["CODEBUFF_API_KEY": "environment-token"],
            authFileURL: file
        ) == .init(token: "environment-token", source: .environment))
        #expect(CodebuffUsageFetcher.resolvedCredential(
            configured: "settings-token",
            environment: [:],
            authFileURL: file
        ) == .init(token: "settings-token", source: .configured))
        #expect(CodebuffUsageFetcher.resolvedCredential(
            configured: nil,
            environment: [:],
            authFileURL: file
        ) == .init(token: "file-token", source: .authFile))
    }

    @Test(arguments: [
        (#"{"default":{"authToken":"default-token"},"authToken":"top-token"}"#, "default-token"),
        (#"{"authToken":"  'top-token'  "}"#, "top-token"),
        (#"{"default":{"authToken":"   "},"authToken":"top-token"}"#, "top-token"),
        ("{not-json}", nil),
    ])
    func credentialsFileParsingMatchesOfficialShape(body: String, expected: String?) {
        #expect(CodebuffUsageFetcher.parseAuthToken(Data(body.utf8)) == expected)
    }

    @Test
    func defaultCredentialsPathMatchesCodebuffCLI() {
        let home = URL(fileURLWithPath: "/tmp/codebuff-home", isDirectory: true)
        #expect(CodebuffUsageFetcher.defaultAuthFileURL(homeDirectory: home).path
            == "/tmp/codebuff-home/.config/manicode/credentials.json")
    }

    @Test(arguments: [
        ([:], "https://www.codebuff.com"),
        (["CODEBUFF_API_URL": "codebuff.test"], "https://codebuff.test"),
        (["CODEBUFF_API_URL": "localhost:8080"], "https://localhost:8080"),
        (["CODEBUFF_API_URL": "https://[::1]:8443/v1"], "https://[::1]:8443/v1"),
    ])
    func endpointResolutionAcceptsOnlyDocumentedForms(environment: [String: String], expected: String) throws {
        #expect(try CodebuffUsageFetcher.resolvedBaseURL(environment: environment).absoluteString == expected)
    }

    @Test(arguments: [
        "http://attacker.test",
        "https://user:pass@proxy.test/v1",
        "https://proxy.test%2f.attacker.test/v1",
        "https://bad host/v1",
        "https://bad%20host/v1",
        "https://bad%09host/v1",
    ])
    func endpointResolutionRejectsUnsafeOverrides(value: String) {
        #expect(throws: CodebuffUsageError.invalidEndpointOverride) {
            _ = try CodebuffUsageFetcher.resolvedBaseURL(environment: ["CODEBUFF_API_URL": value])
        }
    }

    @Test
    func usagePayloadUsesExactFieldsAliasesAndDates() throws {
        let primary = try CodebuffUsageFetcher.parseUsage(Data(#"{"usage":1250,"quota":5000,"remainingBalance":3750,"autoTopupEnabled":true,"next_quota_reset":"2026-05-01T00:00:00.123Z"}"#.utf8))
        #expect(primary.used == 1250)
        #expect(primary.total == 5000)
        #expect(primary.remaining == 3750)
        #expect(primary.autoTopUpEnabled == true)
        #expect(primary.nextQuotaReset != nil)

        let aliases = try CodebuffUsageFetcher.parseUsage(Data(#"{"used":"12","limit":"100","remaining":"88","auto_topup_enabled":false,"next_quota_reset":"1777593600000"}"#.utf8))
        #expect(aliases.used == 12)
        #expect(aliases.total == 100)
        #expect(aliases.remaining == 88)
        #expect(aliases.autoTopUpEnabled == false)
        #expect(aliases.nextQuotaReset == Date(timeIntervalSince1970: 1_777_593_600))
    }

    @Test
    func subscriptionPayloadUsesExactPrecedenceAndAliases() throws {
        let data = Data(#"{"displayName":"Root","subscription":{"displayName":"Pro","status":"active","tier":"ignored","billingPeriodEnd":"2026-05-15T00:00:00Z"},"rateLimit":{"weeklyUsed":"2100","weeklyLimit":7000,"weeklyResetsAt":1778198400},"user":{"email":"user@example.com"}}"#.utf8)
        let payload = try CodebuffUsageFetcher.parseSubscription(data)
        #expect(payload.tier == "Pro")
        #expect(payload.status == "active")
        #expect(payload.weeklyUsed == 2100)
        #expect(payload.weeklyLimit == 7000)
        #expect(payload.weeklyResetsAt == Date(timeIntervalSince1970: 1_778_198_400))
        #expect(payload.email == "user@example.com")
        #expect(payload.billingPeriodEnd != nil)
    }

    @Test(arguments: [
        (#"{"subscription":{"scheduledTier":3}}"#, "3"),
        (#"{"subscription":{"scheduledTier":9223372036854775808}}"#, "9223372036854775808"),
        (#"{"subscription":{"status":"trialing","tier":"free"}}"#, "free"),
    ])
    func subscriptionTierAcceptsCurrentServerRepresentations(body: String, expected: String) throws {
        #expect(try CodebuffUsageFetcher.parseSubscription(Data(body.utf8)).tier == expected)
    }

    @Test
    func malformedPayloadsFailWithoutInventingQuota() {
        #expect(throws: CodebuffUsageError.self) { _ = try CodebuffUsageFetcher.parseUsage(Data("not-json".utf8)) }
        #expect(throws: CodebuffUsageError.self) {
            _ = try CodebuffUsageFetcher.parseSubscription(Data("not-json".utf8))
        }
    }

    @Test
    func snapshotMapsOnlyCreditsAndWeeklyWindows() {
        let reset = Date(timeIntervalSince1970: 1_777_680_000)
        let usage = CodebuffUsageFetcher.providerUsage(Self.snapshot(
            creditsUsed: 250,
            creditsTotal: 1000,
            creditsRemaining: 750,
            weeklyUsed: 100,
            weeklyLimit: 500,
            weeklyResetsAt: reset,
            tier: "pro",
            autoTopUpEnabled: true,
            accountEmail: "user@example.com"
        ))
        #expect(usage.windows.map(\.id) == ["codebuff-credits", "codebuff-weekly"])
        #expect(usage.windows.map(\.label) == ["Credits", "Weekly"])
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].detail == nil)
        #expect(usage.windows[1].usedFraction == 0.2)
        #expect(usage.windows[1].resetsAt == reset)
        #expect(usage.balance == "750")
        #expect(usage.plan == "Pro")
        #expect(usage.details.isEmpty)
    }

    @Test
    func creditsWindowRequiresARealTotal() {
        let inferred = CodebuffUsageFetcher.providerUsage(Self.snapshot(
            creditsUsed: 40, creditsRemaining: 60
        ))
        #expect(inferred.windows.first?.usedFraction == 0.4)

        let usedOnly = CodebuffUsageFetcher.providerUsage(Self.snapshot(creditsUsed: 42))
        #expect(usedOnly.windows.isEmpty)

        let remainingOnly = CodebuffUsageFetcher.providerUsage(Self.snapshot(creditsRemaining: 17))
        #expect(remainingOnly.windows.isEmpty)
        #expect(remainingOnly.balance == "17")

        let empty = CodebuffUsageFetcher.providerUsage(Self.snapshot())
        #expect(empty.windows.isEmpty)
    }

    @Test
    func apiKeySourcesRequestUsageOnly() async throws {
        let recorder = CodebuffRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            return Self.response(request, status: 200, body: #"{"usage":25,"quota":100,"remainingBalance":75}"#)
        }
        defer { CodebuffTestURLProtocol.handler = nil }

        let usage = try await CodebuffUsageFetcher.fetch(
            credential: "settings-token",
            source: .automatic,
            session: session,
            environment: ["CODEBUFF_API_KEY": "environment-token"]
        )
        #expect(recorder.requests.map { $0.url?.path } == ["/api/v1/usage"])
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer environment-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(Self.requestBody(request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(payload == ["fingerprintId": "codexbar-usage"])
        #expect(usage.windows.map(\.id) == ["codebuff-credits"])
    }

    @Test
    func cliCredentialRequestsUsageAndOptionalSubscriptionConcurrently() async throws {
        let file = try Self.credentialsFile(#"{"default":{"authToken":"file-token"}}"#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let recorder = CodebuffRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            if request.url?.path == "/api/user/subscription" {
                return Self.response(request, status: 200, body: #"{"subscription":{"displayName":"Pro"},"rateLimit":{"weeklyUsed":20,"weeklyLimit":80}}"#)
            }
            return Self.response(request, status: 200, body: #"{"usage":25,"quota":100,"remainingBalance":75}"#)
        }
        defer { CodebuffTestURLProtocol.handler = nil }

        let usage = try await CodebuffUsageFetcher.fetch(
            credential: nil,
            source: .automatic,
            session: session,
            environment: [:],
            authFileURL: file
        )
        #expect(Set(recorder.requests.compactMap { $0.url?.path })
            == Set(["/api/v1/usage", "/api/user/subscription"]))
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer file-token"
        })
        #expect(usage.windows.map(\.id) == ["codebuff-credits", "codebuff-weekly"])
    }

    @Test(arguments: [401, 403, 404, 429, 503])
    func requiredUsageStatusMappingIsExact(status: Int) async {
        let session = Self.session { request in Self.response(request, status: status, body: "{}") }
        defer { CodebuffTestURLProtocol.handler = nil }

        do {
            _ = try await CodebuffUsageFetcher.fetchSnapshot(
                token: "token",
                baseURL: CodebuffUsageFetcher.defaultBaseURL,
                includeSubscription: false,
                session: session
            )
            Issue.record("Expected a status error")
        } catch let error as CodebuffUsageError {
            switch status {
            case 401, 403: #expect(error == .unauthorized)
            case 404: #expect(error == .endpointNotFound)
            case 500...599: #expect(error == .serviceUnavailable(status))
            default: #expect(error == .apiError(status))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func optionalSubscriptionFailureKeepsRequiredCredits() async throws {
        let session = Self.session { request in
            if request.url?.path == "/api/user/subscription" {
                return Self.response(request, status: 503, body: "{}")
            }
            return Self.response(request, status: 200, body: #"{"usage":25,"quota":100}"#)
        }
        defer { CodebuffTestURLProtocol.handler = nil }

        let snapshot = try await CodebuffUsageFetcher.fetchSnapshot(
            token: "token",
            baseURL: CodebuffUsageFetcher.defaultBaseURL,
            includeSubscription: true,
            session: session
        )
        #expect(snapshot.creditsUsed == 25)
        #expect(snapshot.weeklyLimit == nil)
    }

    @Test
    func optionalSubscriptionDeadlineDoesNotDelayRequiredCredits() async throws {
        let source = Task<Int, Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(returning: 42)
                }
            }
        }
        let startedAt = ContinuousClock.now
        let outcome = await CodebuffBoundedTaskJoin(sourceTask: source).value(joinGrace: .milliseconds(20))
        let elapsed = startedAt.duration(to: .now)
        guard case .timedOut = outcome else {
            Issue.record("Expected the optional subscription join to time out")
            return
        }
        #expect(elapsed < .milliseconds(300))
        try await Task.sleep(for: .milliseconds(550))
    }

    @Test
    func unsupportedSourceAndMissingCredentialsFailBeforeNetworking() async {
        let recorder = CodebuffRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            return Self.response(request, status: 200, body: "{}")
        }
        defer { CodebuffTestURLProtocol.handler = nil }

        await #expect(throws: CodebuffUsageError.missingCredentials) {
            try await CodebuffUsageFetcher.fetch(
                credential: nil, source: .account, session: session, environment: [:],
                authFileURL: URL(fileURLWithPath: "/tmp/codebuff-missing-credentials")
            )
        }
        await #expect(throws: CodebuffUsageError.missingCredentials) {
            try await CodebuffUsageFetcher.fetch(
                credential: " ", source: .token, session: session, environment: [:],
                authFileURL: URL(fileURLWithPath: "/tmp/codebuff-missing-credentials")
            )
        }
        #expect(recorder.requests.isEmpty)
    }

    private static func snapshot(
        creditsUsed: Double? = nil,
        creditsTotal: Double? = nil,
        creditsRemaining: Double? = nil,
        weeklyUsed: Double? = nil,
        weeklyLimit: Double? = nil,
        weeklyResetsAt: Date? = nil,
        tier: String? = nil,
        autoTopUpEnabled: Bool? = nil,
        accountEmail: String? = nil
    ) -> CodebuffUsageFetcher.Snapshot {
        .init(
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsRemaining: creditsRemaining,
            weeklyUsed: weeklyUsed,
            weeklyLimit: weeklyLimit,
            weeklyResetsAt: weeklyResetsAt,
            billingPeriodEnd: nil,
            nextQuotaReset: nil,
            tier: tier,
            subscriptionStatus: nil,
            autoTopUpEnabled: autoTopUpEnabled,
            accountEmail: accountEmail,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func credentialsFile(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("credentials.json")
        try Data(body.utf8).write(to: file)
        return file
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        CodebuffTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodebuffTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class CodebuffRequestRecorder: @unchecked Sendable {
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

private final class CodebuffTestURLProtocol: URLProtocol {
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
