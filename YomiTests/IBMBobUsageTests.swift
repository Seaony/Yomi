import Foundation
import Testing
@testable import Yomi

@Suite("IBM Bob usage", .serialized)
struct IBMBobUsageTests {
    @Test
    func resolvesConfiguredThenDocumentedEnvironmentKeyAndCleansQuotes() {
        #expect(IBMBobUsageFetcher.resolvedAPIKey(
            configured: " configured ",
            environment: ["BOBSHELL_API_KEY": "environment"]
        ) == "configured")
        #expect(IBMBobUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["BOBSHELL_API_KEY": "  \"bob-key\"  "]
        ) == "bob-key")
        #expect(IBMBobUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["BOBSHELL_API_KEY": "  'bob-key'  "]
        ) == "bob-key")
        #expect(IBMBobUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["IBM_BOB_API_KEY": "wrong-key"]
        ) == nil)
        #expect(IBMBobUsageFetcher.resolvedAPIKey(
            configured: "   ",
            environment: ["BOBSHELL_API_KEY": "   "]
        ) == nil)
    }

    @Test
    func fetchesProfileThenEveryRegionalTeamBudgetWithExactRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = IBMBobRequestRecorder()
        IBMBobTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/admin/v1/profile":
                return (200, Self.profileData)
            case "/admin/v1/teams/team-one/users/user-one":
                return (200, Data(#"{"usage":10}"#.utf8))
            case "/admin/v1/teams/team-two/users/user-two":
                return (200, Data(#"{"usage":25}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }
        defer { IBMBobTestURLProtocol.handler = nil }

        let snapshot = try await IBMBobUsageFetcher.fetchSnapshot(
            apiKey: "fixture-key",
            session: Self.session(),
            now: now
        )
        let usage = snapshot.toProviderUsage(language: .english)
        let requests = recorder.requests

        #expect(snapshot.usedBobcoins == 35)
        #expect(snapshot.limitBobcoins == 200)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.teams.count == 2)
        #expect(requests.count == 3)
        #expect(requests.map { $0.url?.host } == [
            "api.us-east.bob.ibm.com",
            "api.us-east.bob.ibm.com",
            "api.eu-de.bob.ibm.com",
        ])
        #expect(requests.map { $0.url?.path } == [
            "/admin/v1/profile",
            "/admin/v1/teams/team-one/users/user-one",
            "/admin/v1/teams/team-two/users/user-two",
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.timeoutInterval == 20 })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Apikey fixture-key" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "CodexBar" })
        #expect(requests[0].value(forHTTPHeaderField: "x-instance-id") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-instance-id") == "instance-one")
        #expect(requests[1].value(forHTTPHeaderField: "x-team-id") == "team-one")
        #expect(usage.windows.count == 1)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.windows[0].id == "ibmbob-monthly")
        #expect(usage.windows[0].label == "Monthly Bobcoins")
        #expect(usage.windows[0].usedFraction == 0.175)
        #expect(usage.windows[0].detail == "35 / 200 Bobcoins")
        #expect(usage.plan == "Enterprise, Pro+")
        #expect(usage.details.isEmpty)
        #expect(usage.providerCost == nil)
        #expect(usage.balance == nil)
    }

    @Test
    func decodesLiveNamesUnixResetAndTeamBudgetOverride() async throws {
        IBMBobTestURLProtocol.handler = { request in
            if request.url?.path == "/admin/v1/profile" {
                return (200, Self.liveProfileData)
            }
            return (200, Data(#"{"usage":12.5,"budget_limit":80}"#.utf8))
        }
        defer { IBMBobTestURLProtocol.handler = nil }

        let snapshot = try await IBMBobUsageFetcher.fetchSnapshot(
            apiKey: "fixture-key",
            session: Self.session()
        )

        #expect(snapshot.teams.count == 1)
        #expect(snapshot.teams[0].instanceName == "Personal")
        #expect(snapshot.teams[0].teamName == "Solo")
        #expect(snapshot.teams[0].usedBobcoins == 12.5)
        #expect(snapshot.teams[0].limitBobcoins == 80)
        #expect(snapshot.teams[0].resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func parsesFractionalAndPlainISOResetsAndUsesEarliestTeamReset() {
        let plain = IBMBobUsageFetcher.parseISO8601Date("2026-09-01T00:00:00Z")
        let fractional = IBMBobUsageFetcher.parseISO8601Date("2026-09-05T00:00:00.000Z")
        #expect(plain != nil)
        #expect(fractional != nil)
        #expect(IBMBobUsageFetcher.parseISO8601Date("not-a-date") == nil)
        #expect(IBMBobUsageFetcher.parseDate(seconds: 0) == nil)
        #expect(IBMBobUsageFetcher.parseDate(seconds: .infinity) == nil)

        let snapshot = IBMBobUsageSnapshot(
            teams: [
                .init(
                    instanceName: "One",
                    teamName: "One",
                    planName: nil,
                    usedBobcoins: 1,
                    limitBobcoins: 10,
                    resetsAt: fractional
                ),
                .init(
                    instanceName: "Two",
                    teamName: "Two",
                    planName: nil,
                    usedBobcoins: 2,
                    limitBobcoins: 10,
                    resetsAt: plain
                ),
            ],
            updatedAt: Date()
        )
        #expect(snapshot.toProviderUsage(language: .english).windows[0].resetsAt == plain)
    }

    @Test
    func usesBearerOnlyForThreePartTokenWithJSONObjectPayload() {
        let jwt = "header.eyJzdWIiOiJ1c2VyIn0.signature"
        #expect(IBMBobUsageFetcher.authorizationValue(jwt) == "Bearer \(jwt)")
        #expect(IBMBobUsageFetcher.authorizationValue("header.W10.signature") == "Apikey header.W10.signature")
        #expect(IBMBobUsageFetcher.authorizationValue("header.not-base64.signature") == "Apikey header.not-base64.signature")
        #expect(IBMBobUsageFetcher.authorizationValue("ordinary-key") == "Apikey ordinary-key")
    }

    @Test
    func fetchSendsBearerForJWTToProfileAndTeam() async throws {
        let token = "header.eyJzdWIiOiJ1c2VyIn0.signature"
        let recorder = IBMBobRequestRecorder()
        IBMBobTestURLProtocol.handler = { request in
            recorder.append(request)
            return request.url?.path == "/admin/v1/profile"
                ? (200, Self.singleTeamProfileData)
                : (200, Data(#"{"usage":4}"#.utf8))
        }
        defer { IBMBobTestURLProtocol.handler = nil }

        _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: token, session: Self.session())
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
        })
    }

    @Test(arguments: [
        "evil.example",
        "evil.example/x.bob.ibm.com",
        "bob.ibm.com.evil.example",
        "x@evil.example",
        "evil.example/path/.bob.ibm.com",
        "evil.example?next=.bob.ibm.com",
        "evil.example#.bob.ibm.com",
        "evil.example@us-east.bob.ibm.com",
        "us-east.bob.ibm.com:443",
    ])
    func rejectsUntrustedRegionalHostBeforeSendingCredentials(regionDomain: String) async {
        let recorder = IBMBobRequestRecorder()
        IBMBobTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Self.regionalProfileData(regionDomain: regionDomain))
        }
        defer { IBMBobTestURLProtocol.handler = nil }

        await #expect(throws: IBMBobUsageError.self) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(
                apiKey: "fixture-key",
                session: Self.session()
            )
        }
        #expect(recorder.requests.count == 1)
    }

    @Test(arguments: [
        ("us-east.bob.ibm.com", "api.us-east.bob.ibm.com"),
        ("api.eu-de.bob.ibm.com", "api.eu-de.bob.ibm.com"),
        ("bob.ibm.com", "api.bob.ibm.com"),
    ])
    func acceptsOnlyHTTPSBobSubdomainsAndNormalizesAPIHost(domain: String, expectedHost: String) throws {
        #expect(try IBMBobUsageFetcher.regionalBaseURL(domain).host == expectedHost)
    }

    @Test(arguments: [401, 403])
    func authenticationFailuresStayDistinct(status: Int) async {
        IBMBobTestURLProtocol.handler = { _ in (status, Data()) }
        defer { IBMBobTestURLProtocol.handler = nil }

        await #expect(throws: IBMBobUsageError.invalidCredentials) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "bad", session: Self.session())
        }
    }

    @Test(arguments: [400, 404, 429, 500])
    func nonAuthenticationHTTPFailuresPreserveStatus(status: Int) async {
        IBMBobTestURLProtocol.handler = { _ in (status, Data()) }
        defer { IBMBobTestURLProtocol.handler = nil }

        await #expect(throws: IBMBobUsageError.apiError(status)) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        }
    }

    @Test
    func malformedProfileAndTeamPayloadsFailClosed() async {
        IBMBobTestURLProtocol.handler = { _ in (200, Data(#"{"unexpected":[]}"#.utf8)) }
        await #expect(throws: IBMBobUsageError.self) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        }

        IBMBobTestURLProtocol.handler = { request in
            request.url?.path == "/admin/v1/profile"
                ? (200, Self.singleTeamProfileData)
                : (200, Data(#"{"budget_limit":40}"#.utf8))
        }
        defer { IBMBobTestURLProtocol.handler = nil }
        await #expect(throws: IBMBobUsageError.self) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        }
    }

    @Test
    func profilesWithoutUsableSubscriptionTeamsReturnNoSubscription() async {
        let profile = Data(#"{"instances":[{"instance_id":"one","teams":[]},{"instance_id":"two","user_id":"","teams":[{"id":"team"}]},{"instance_id":"three","user_id":"user","teams":[{"id":""}]}]}"#.utf8)
        IBMBobTestURLProtocol.handler = { _ in (200, profile) }
        defer { IBMBobTestURLProtocol.handler = nil }

        await #expect(throws: IBMBobUsageError.noSubscription) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        }
    }

    @Test
    func unlimitedOrIncompleteTeamBudgetsNeverInventPercentage() {
        let snapshot = IBMBobUsageSnapshot(
            teams: [
                .init(
                    instanceName: "Personal",
                    teamName: "Solo",
                    planName: "Pro+",
                    usedBobcoins: 12.5,
                    limitBobcoins: 40,
                    resetsAt: nil
                ),
                .init(
                    instanceName: "Work",
                    teamName: "Platform",
                    planName: "Enterprise",
                    usedBobcoins: 25,
                    limitBobcoins: nil,
                    resetsAt: nil
                ),
            ],
            updatedAt: Date()
        )
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(snapshot.limitBobcoins == nil)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail == "37.50 Bobcoins used")
        #expect(usage.details.isEmpty)
    }

    @Test
    func zeroBudgetNeverDividesOrInventsPercentage() {
        let snapshot = IBMBobUsageSnapshot(
            teams: [.init(
                instanceName: "Personal",
                teamName: "Personal",
                planName: nil,
                usedBobcoins: 5,
                limitBobcoins: 0,
                resetsAt: nil
            )],
            updatedAt: Date()
        )
        let usage = snapshot.toProviderUsage(language: .english)
        #expect(snapshot.limitBobcoins == 0)
        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail == "5 / 0 Bobcoins")
    }

    @Test
    func negativeAPIUsageIsClampedAndNegativeBudgetBecomesUnlimited() async throws {
        IBMBobTestURLProtocol.handler = { request in
            request.url?.path == "/admin/v1/profile"
                ? (200, Self.singleTeamProfileData)
                : (200, Data(#"{"usage":-4,"budget_limit":-1}"#.utf8))
        }
        defer { IBMBobTestURLProtocol.handler = nil }

        let snapshot = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        #expect(snapshot.teams[0].usedBobcoins == 0)
        #expect(snapshot.teams[0].limitBobcoins == nil)
        #expect(snapshot.toProviderUsage(language: .english).windows[0].usedFraction == 0)
    }

    @Test
    func networkFailureIsNotMisreportedAsParsingOrAuthentication() async {
        IBMBobTestURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { IBMBobTestURLProtocol.handler = nil }

        await #expect(throws: IBMBobUsageError.self) {
            _ = try await IBMBobUsageFetcher.fetchSnapshot(apiKey: "key", session: Self.session())
        }
    }

    @Test
    func fetchRequiresCredentialBeforeNetworking() async {
        await #expect(throws: IBMBobUsageError.missingCredentials) {
            _ = try await IBMBobUsageFetcher.fetch(
                apiKey: nil,
                session: Self.session(),
                environment: [:]
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IBMBobTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static let profileData = Data(#"""
    {
      "instances": [
        {
          "instance_id": "instance-one",
          "name": "Personal",
          "user_id": "user-one",
          "plan_name": "Pro+",
          "refresh_at": "2026-09-01T00:00:00Z",
          "region_domain": "us-east.bob.ibm.com",
          "teams": [{"id": "team-one", "name": "Solo", "budget_limit": 40}]
        },
        {
          "instance_id": "instance-two",
          "name": "Work",
          "user_id": "user-two",
          "plan_name": "Enterprise",
          "refresh_at": "2026-09-05T00:00:00.000Z",
          "region_domain": "api.eu-de.bob.ibm.com",
          "teams": [{"id": "team-two", "name": "Platform", "budget_limit": 160}]
        }
      ]
    }
    """#.utf8)

    private nonisolated static let singleTeamProfileData = Data(#"""
    {
      "instances": [{
        "instance_id": "instance-one",
        "user_id": "user-one",
        "teams": [{"id": "team-one", "budget_limit": 40}]
      }]
    }
    """#.utf8)

    private nonisolated static let liveProfileData = Data(#"""
    {
      "instances": [{
        "instance_id": "instance-one",
        "instance_name": "Personal",
        "user_id": "user-one",
        "plan_name": "Pro+",
        "refresh_at": 1788220800,
        "region_domain": "us-east.bob.ibm.com",
        "teams": [{"id": "team-one", "name": "Solo", "budget_limit": 40, "usage": 10}]
      }]
    }
    """#.utf8)

    private nonisolated static func regionalProfileData(regionDomain: String) -> Data {
        Data(#"""
        {
          "instances": [{
            "instance_id": "instance-one",
            "user_id": "user-one",
            "region_domain": "\#(regionDomain)",
            "teams": [{"id": "team-one", "budget_limit": 40}]
          }]
        }
        """#.utf8)
    }
}

private nonisolated final class IBMBobRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private nonisolated final class IBMBobTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: (@Sendable (URLRequest) throws -> (Int, Data))?

    static var handler: (@Sendable (URLRequest) throws -> (Int, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

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
