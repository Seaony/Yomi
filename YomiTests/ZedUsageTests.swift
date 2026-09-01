import Foundation
import Testing
@testable import Yomi

@Suite("Zed usage", .serialized)
struct ZedUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_768_435_200)

    @Test
    func decodesLimitedAndUnlimitedUsageShapes() throws {
        let limited = try ZedUsageFetcher.parse(Self.fixture(plan: "zed_free", used: 12, limit: "50"))
        let unlimited = try ZedUsageFetcher.parse(Self.fixture(plan: "zed_pro", used: 0, limit: #""unlimited""#))

        #expect(limited.plan.usage.editPredictions.limit == .limited(50))
        #expect(limited.plan.usage.editPredictions.used == 12)
        #expect(unlimited.plan.usage.editPredictions.limit == .unlimited)
    }

    @Test
    func limitedPlanMapsOnlyEditPredictions() throws {
        let response = try ZedUsageFetcher.parse(Self.fixture(plan: "zed_free", used: 10, limit: "20"))
        let usage = ZedUsageFetcher.providerUsage(response, now: Self.now)

        #expect(usage.plan == "Zed Free")
        #expect(usage.windows.map(\.label) == ["Edit predictions"])
        #expect(usage.windows[0].usedFraction == 0.5)
        #expect(usage.windows[0].detail == "10 / 20 predictions")
        #expect(usage.details.isEmpty)
    }

    @Test
    func unlimitedPlanDoesNotInventConsumption() throws {
        let response = try ZedUsageFetcher.parse(Self.fixture(plan: "zed_pro", used: 999, limit: #""unlimited""#))
        let usage = ZedUsageFetcher.providerUsage(response, now: Self.now)

        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail == "Unlimited")
    }

    @Test
    func limitedUsageClampsAndZeroLimitIsOmitted() throws {
        let over = ZedUsageFetcher.providerUsage(
            try ZedUsageFetcher.parse(Self.fixture(plan: "zed_student", used: 30, limit: "25")),
            now: Self.now
        )
        let zero = ZedUsageFetcher.providerUsage(
            try ZedUsageFetcher.parse(Self.fixture(plan: "zed_free", used: 0, limit: "0")),
            now: Self.now
        )

        #expect(over.windows[0].usedFraction == 1)
        #expect(over.windows[0].detail == "25 / 25 predictions")
        #expect(zero.windows.isEmpty)
    }

    @Test
    func overdueInvoiceDoesNotCreateWarningOrFabricatedQuota() throws {
        let response = try ZedUsageFetcher.parse(Self.fixture(
            plan: "zed_business",
            used: 0,
            limit: #""unlimited""#,
            overdue: true
        ))
        let usage = ZedUsageFetcher.providerUsage(response, now: Self.now)

        #expect(usage.details.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func displayPlanNamesMatchZedEnums() {
        #expect(ZedUsageFetcher.displayPlanName("zed_pro") == "Zed Pro")
        #expect(ZedUsageFetcher.displayPlanName("zed_pro_trial") == "Zed Pro Trial")
        #expect(ZedUsageFetcher.displayPlanName("zed_student") == "Zed Student")
        #expect(ZedUsageFetcher.displayPlanName("custom_enterprise") == "Custom Enterprise")
    }

    @Test
    func settingsUseDocumentedPathAndRouting() throws {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zed/settings.json")
        #expect(ZedUsageFetcher.defaultSettingsURL == expected)

        let production = ZedClientSettings(credentialsURL: "zed-preview-key", serverURL: "https://zed.dev")
        let staging = ZedClientSettings(credentialsURL: nil, serverURL: "https://staging.zed.dev")
        let custom = ZedClientSettings(
            credentialsURL: "https://zed.example.com",
            serverURL: "https://zed.example.com"
        )
        let crossOrigin = ZedClientSettings(credentialsURL: "https://zed.dev", serverURL: "https://evil.example")

        #expect(production.keychainServiceURL == "zed-preview-key")
        #expect(production.cloudAPIURL?.absoluteString == "https://cloud.zed.dev/client/users/me")
        #expect(staging.cloudAPIURL?.absoluteString == "https://cloud.zed.dev/client/users/me")
        #expect(custom.cloudAPIURL?.absoluteString == "https://zed.example.com/client/users/me")
        #expect(crossOrigin.cloudAPIURL == nil)
    }

    @Test
    func settingsLoaderReadsCredentialAndServerKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-Zed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"credentials_url":"zed-preview-key","server_url":"https://staging.zed.dev"}"#.utf8)
            .write(to: url)

        let settings = try #require(ZedClientSettings.load(from: url))
        #expect(settings.credentialsURL == "zed-preview-key")
        #expect(settings.serverURL == "https://staging.zed.dev")
    }

    @Test
    func fetchUsesExactAuthorizationAndEndpoint() async throws {
        let recorder = ZedRequestRecorder()
        ZedTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Self.fixture(plan: "zed_pro", used: 0, limit: #""unlimited""#))
        }
        defer { ZedTestURLProtocol.handler = nil }

        let usage = try await ZedUsageFetcher.fetch(
            session: Self.session(),
            now: Self.now,
            settingsLoader: { nil },
            credentialsLoader: { _ in ZedCredentials(userID: "4242", accessToken: "test-token") }
        )

        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://cloud.zed.dev/client/users/me")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "4242 test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 18)
        #expect(usage.plan == "Zed Pro")
    }

    @Test
    func invalidAndCrossOriginServersStopBeforeCredentialRead() async {
        let recorder = ZedCredentialReadRecorder()
        await #expect(throws: ZedUsageError.invalidServerURL("file:///tmp/zed")) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: { ZedClientSettings(credentialsURL: nil, serverURL: "file:///tmp/zed") },
                credentialsLoader: { service in recorder.append(service); return nil }
            )
        }
        await #expect(throws: ZedUsageError.untrustedServerConfiguration) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: {
                    ZedClientSettings(credentialsURL: "https://zed.dev", serverURL: "https://evil.example")
                },
                credentialsLoader: { service in recorder.append(service); return nil }
            )
        }
        #expect(recorder.values.isEmpty)
    }

    @Test
    func missingCredentialsStopsBeforeNetwork() async {
        await #expect(throws: ZedUsageError.notSignedIn) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: { nil },
                credentialsLoader: { _ in nil }
            )
        }
    }

    @Test(arguments: [401, 403])
    func unauthorizedResponsesAreRejected(status: Int) async {
        ZedTestURLProtocol.handler = { _ in (status, Data()) }
        defer { ZedTestURLProtocol.handler = nil }
        await #expect(throws: ZedUsageError.unauthorized) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: { nil },
                credentialsLoader: { _ in ZedCredentials(userID: "1", accessToken: "bad") }
            )
        }
    }

    @Test
    func malformedResponseAndOtherHTTPStatusFailClosed() async {
        ZedTestURLProtocol.handler = { _ in (200, Data(#"{"status":"ok"}"#.utf8)) }
        await #expect(throws: ZedUsageError.self) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: { nil },
                credentialsLoader: { _ in ZedCredentials(userID: "1", accessToken: "token") }
            )
        }
        ZedTestURLProtocol.handler = { _ in (429, Data()) }
        await #expect(throws: ZedUsageError.httpError(429)) {
            _ = try await ZedUsageFetcher.fetch(
                session: Self.session(),
                settingsLoader: { nil },
                credentialsLoader: { _ in ZedCredentials(userID: "1", accessToken: "token") }
            )
        }
        ZedTestURLProtocol.handler = nil
    }

    private nonisolated static func fixture(
        plan: String,
        used: Int,
        limit: String,
        overdue: Bool = false
    ) -> Data {
        Data("""
        {
          "user": {"id":4242,"github_login":"octocat","name":"The Octocat"},
          "plan": {
            "plan_v3":"\(plan)",
            "subscription_period": {
              "started_at":"2026-01-01T00:00:00.000Z",
              "ended_at":"2026-02-01T00:00:00.000Z"
            },
            "usage":{"edit_predictions":{"used":\(used),"limit":\(limit)}},
            "has_overdue_invoices":\(overdue)
          }
        }
        """.utf8)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZedTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class ZedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private nonisolated final class ZedCredentialReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

private nonisolated final class ZedTestURLProtocol: URLProtocol {
    static let lock = NSLock()
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
                httpVersion: "HTTP/1.1",
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
