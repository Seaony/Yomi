import Foundation
import Testing
@testable import Yomi

@Suite("LiteLLM usage", .serialized)
struct LiteLLMUsageTests {
    @Test
    func parsesUserUsageWithExactPersonalAndTeamBudgets() throws {
        let key = LiteLLMKeyInfoSnapshot(
            userID: "user-123",
            teamID: "team-456",
            keyName: "sk-...IAAw",
            spendUSD: 212.3537162499998,
            expiresAt: Date(timeIntervalSince1970: 2)
        )
        let usage = try LiteLLMUsageFetcher.parseUserInfo(
            Data(Self.userFixture.utf8),
            keyInfo: key,
            updatedAt: Date(timeIntervalSince1970: 1)
        ).providerUsage()

        #expect(usage.windows.map(\.id) == ["litellm-personal", "litellm-team"])
        #expect(abs(usage.windows[0].usedFraction - 0.7078457208333327) < 0.000001)
        #expect(usage.windows[0].detail == "$212.35 / $300.00")
        #expect(abs(usage.windows[1].usedFraction - 0.2153245658499998) < 0.000001)
        #expect(usage.windows[1].detail == "$215.32 / $1,000.00")
        #expect(usage.providerCost?.used == 212.3537162499998)
        #expect(usage.providerCost?.limit == 300)
        #expect(usage.providerCost?.period == "Personal budget")
        #expect(usage.plan == nil)
        #expect(usage.details.isEmpty)
    }

    @Test
    func keepsSpendVisibleWithoutBudget() throws {
        let key = LiteLLMKeyInfoSnapshot(
            userID: "user-123", teamID: nil, keyName: "personal-key", spendUSD: 12.5, expiresAt: nil
        )
        let payload = #"{"user_id":"user-123","user_info":{"user_id":"user-123","max_budget":null,"spend":12.5}}"#
        let usage = try LiteLLMUsageFetcher.parseUserInfo(
            Data(payload.utf8), keyInfo: key, updatedAt: Date(timeIntervalSince1970: 1)
        ).providerUsage()
        #expect(usage.windows.isEmpty)
        #expect(usage.providerCost?.used == 12.5)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.period == "Personal spend")
    }

    @Test
    func parsesKeyIdentityAndRequiresUserOrTeam() throws {
        let payload = #"{"info":{"key_name":"team-service-key","spend":25,"team_id":"team-456"}}"#
        let key = try LiteLLMUsageFetcher.parseKeyInfo(Data(payload.utf8))
        #expect(key.userID == nil)
        #expect(key.teamID == "team-456")
        #expect(key.keyName == "team-service-key")
        #expect(throws: LiteLLMUsageError.missingUserID) {
            _ = try LiteLLMUsageFetcher.parseKeyInfo(Data(#"{"info":{"spend":1}}"#.utf8))
        }
    }

    @Test
    func managementURLsStripOnlyTrailingV1() {
        let root = URL(string: "https://litellm.example.com")!
        let versioned = URL(string: "https://litellm.example.com/v1")!
        let nested = URL(string: "https://gateway.example.com/litellm/v1/")!
        #expect(LiteLLMUsageFetcher.keyInfoURL(root).absoluteString == "https://litellm.example.com/key/info")
        #expect(LiteLLMUsageFetcher.keyInfoURL(versioned).absoluteString == "https://litellm.example.com/key/info")
        #expect(LiteLLMUsageFetcher.userInfoURL(nested, userID: "user-123").absoluteString == "https://gateway.example.com/litellm/user/info?user_id=user-123")
        #expect(LiteLLMUsageFetcher.teamInfoURL(nested, teamID: "team-456").absoluteString == "https://gateway.example.com/litellm/team/info?team_id=team-456")
    }

    @Test
    func rejectsMismatchedReturnedIdentity() {
        let userKey = LiteLLMKeyInfoSnapshot(
            userID: "expected", teamID: nil, keyName: nil, spendUSD: 0, expiresAt: nil
        )
        #expect(throws: LiteLLMUsageError.self) {
            _ = try LiteLLMUsageFetcher.parseUserInfo(
                Data(#"{"user_id":"wrong","user_info":{"user_id":"wrong"}}"#.utf8),
                keyInfo: userKey,
                updatedAt: Date()
            )
        }
        let teamKey = LiteLLMKeyInfoSnapshot(
            userID: nil, teamID: "expected", keyName: nil, spendUSD: 0, expiresAt: nil
        )
        #expect(throws: LiteLLMUsageError.self) {
            _ = try LiteLLMUsageFetcher.parseTeamInfo(
                Data(#"{"team_id":"wrong","team_info":{"team_id":"wrong"}}"#.utf8),
                keyInfo: teamKey,
                updatedAt: Date()
            )
        }
    }

    @Test
    func exactFetchUsesBearerAndTeamOnlyPath() async throws {
        LiteLLMTestURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-team")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            if request.url?.path == "/key/info" {
                #expect(request.url?.query == nil)
                return (200, Data(#"{"info":{"key_name":"team-service-key","team_id":"team-456","spend":25}}"#.utf8))
            }
            #expect(request.url?.path == "/team/info")
            #expect(request.url?.query == "team_id=team-456")
            return (200, Data(#"{"team_id":"team-456","team_info":{"team_id":"team-456","team_alias":"platform","max_budget":100,"spend":25}}"#.utf8))
        }
        defer { LiteLLMTestURLProtocol.handler = nil }
        let usage = try await LiteLLMUsageFetcher.fetch(
            apiKey: " sk-team\n ",
            endpointOverride: "https://litellm.example.com/v1",
            session: Self.session(),
            environment: [:],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(usage.windows.map(\.id) == ["litellm-team"])
        #expect(usage.providerCost?.period == "Team budget")
    }

    @Test
    func quotedEnvironmentAndEndpointSecurityMatchContract() async throws {
        LiteLLMTestURLProtocol.handler = { request in
            if request.url?.path == "/key/info" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-env")
                return (200, Data(#"{"info":{"user_id":"user-123"}}"#.utf8))
            }
            return (200, Data(#"{"user_id":"user-123","user_info":{"user_id":"user-123"}}"#.utf8))
        }
        defer { LiteLLMTestURLProtocol.handler = nil }
        _ = try await LiteLLMUsageFetcher.fetch(
            apiKey: nil,
            endpointOverride: nil,
            session: Self.session(),
            environment: [
                "LITELLM_API_KEY": " 'sk-env' ",
                "LITELLM_BASE_URL": #" "https://litellm.example.com/v1" "#,
            ]
        )
        await #expect(throws: LiteLLMUsageError.invalidEndpointOverride("LITELLM_BASE_URL")) {
            _ = try await LiteLLMUsageFetcher.fetch(
                apiKey: "key", endpointOverride: "http://public.example.com", session: Self.session(), environment: [:]
            )
        }
    }

    @Test
    func rejectedVirtualKeySurfacesAPIError() async {
        LiteLLMTestURLProtocol.handler = { _ in (401, Data(#"{"detail":"Unauthorized"}"#.utf8)) }
        defer { LiteLLMTestURLProtocol.handler = nil }
        await #expect(throws: LiteLLMUsageError.self) {
            _ = try await LiteLLMUsageFetcher.fetch(
                apiKey: "sk-target", endpointOverride: "https://litellm.example.com", session: Self.session(), environment: [:]
            )
        }
    }

    private static let userFixture = #"{"user_id":"user-123","user_info":{"user_id":"user-123","user_alias":"litellm-user@example.com","max_budget":300,"spend":212.3537162499998,"user_email":"litellm-user@example.com","metadata":{"preferred_username":"litellm-user@example.com"}},"teams":[{"team_alias":"unrelated","team_id":"team-other","max_budget":5,"spend":4},{"team_alias":"ai","team_id":"team-456","max_budget":1000,"spend":215.3245658499998,"budget_duration":"7d","budget_reset_at":"2026-06-15T00:00:00Z"}]}"#

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiteLLMTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LiteLLMTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
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
