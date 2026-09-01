import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct AntigravityUsageTests {
    private static let otherAbbreviation = String(UnicodeScalar(71)!)
        + String(UnicodeScalar(80)!) + String(UnicodeScalar(84)!)

    @Test
    func parsesQuotaSummaryIntoFamilyRepresentativesAndFourCadenceRows() throws {
        let data = Data("""
        {
          "response": {
            "groups": [
              {
                "displayName": "Claude and \(Self.otherAbbreviation) models",
                "buckets": [
                  {"bucketId":"3p-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.64}},
                  {"bucketId":"3p-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.73}}
                ]
              },
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId":"gemini-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.82}},
                  {"bucketId":"gemini-5h","displayName":"Five Hour Limit","remaining":{"remainingFraction":0.91}}
                ]
              }
            ]
          }
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseQuotaSummary(data: data)

        #expect(usage.windows.map(\.id) == ["antigravity-gemini", "antigravity-other"])
        #expect(zip(usage.windows.map(\.usedFraction), [0.18, 0.36]).allSatisfy {
            abs($0 - $1) < 0.000_000_001
        })
        #expect(usage.additionalWindows.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(usage.additionalWindows.map(\.label) == [
            "Gemini 5-hour", "Gemini weekly",
            "Claude/\(Self.otherAbbreviation) 5-hour", "Claude/\(Self.otherAbbreviation) weekly",
        ])
    }

    @Test
    func parsesOneOfRemainingAndKeepsUnknownCadenceName() throws {
        let data = Data("""
        {
          "groups": [{
            "displayName":"Gemini Models",
            "buckets":[
              {"bucketId":"gemini_session","displayName":"Session","remaining":{"case":"remainingFraction","value":0.75}},
              {"bucketId":"gemini-session-history","displayName":"Session History","remainingFraction":0.5}
            ]
          }]
        }
        """.utf8)

        let rows = try AntigravityUsageFetcher.parseQuotaSummary(data: data).additionalWindows

        #expect(rows[0].id == "antigravity-quota-summary-gemini_session")
        #expect(rows[0].label == "Gemini 5-hour")
        #expect(rows[0].usedFraction == 0.25)
        #expect(rows[1].label == "Gemini Session History")
    }

    @Test
    func disabledAndMissingFractionsAreNotPublishedAsExhaustedUsage() throws {
        let data = Data("""
        {
          "groups": [{
            "displayName":"Gemini Models",
            "buckets":[
              {"bucketId":"gemini-5h","displayName":"Five Hour Limit","disabled":true,"remainingFraction":0.2},
              {"bucketId":"gemini-weekly","displayName":"Weekly Limit"}
            ]
          }]
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseQuotaSummary(data: data)

        #expect(usage.windows.first?.usedFraction == 0)
        #expect(usage.additionalWindows.allSatisfy { $0.usedFraction == 0 })
        #expect(usage.additionalWindows.allSatisfy { $0.detail != nil })
    }

    @Test
    func localModelRowsCollapseIntoTwoPoolsAndExcludeFilteredVariants() throws {
        let otherModel = Self.otherAbbreviation.lowercased() + "-oss-120b-medium"
        let data = Data("""
        {
          "code":0,
          "userStatus":{
            "email":"person@example.com",
            "userTier":{"name":"Ultra"},
            "cascadeModelConfigData":{"clientModelConfigs":[
              {"label":"Gemini 3 Pro","modelOrAlias":{"model":"gemini-3-pro"},"quotaInfo":{"remainingFraction":0.8}},
              {"label":"Gemini 3 Flash","modelOrAlias":{"model":"gemini-3-flash"},"quotaInfo":{"remainingFraction":0.3}},
              {"label":"Gemini Flash Lite","modelOrAlias":{"model":"gemini-3-flash-lite"},"quotaInfo":{"remainingFraction":0.1}},
              {"label":"Claude Sonnet","modelOrAlias":{"model":"claude-sonnet-4"},"quotaInfo":{"remainingFraction":0.7}},
              {"label":"Other OSS","modelOrAlias":{"model":"\(otherModel)"},"quotaInfo":{"remainingFraction":0.4}},
              {"label":"Gemini Image","modelOrAlias":{"model":"gemini-3-pro-image"},"quotaInfo":{"remainingFraction":0.5}}
            ]}
          }
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.map(\.usedFraction) == [0.7, 0.6])
        #expect(usage.additionalWindows.map(\.id) == ["gemini-3-flash-lite", "gemini-3-pro-image"])
        #expect(usage.plan == "Ultra")
        #expect(usage.details.isEmpty)
    }

    @Test
    func resetOnlyFamilyIsPreservedAsUnavailableGroupedContext() throws {
        let data = Data("""
        {
          "clientModelConfigs":[
            {
              "label":"Gemini 3 Pro",
              "modelOrAlias":{"model":"gemini-3-pro"},
              "quotaInfo":{"resetTime":"2030-01-01T00:00:00Z"}
            }
          ]
        }
        """.utf8)

        let usage = try AntigravityUsageFetcher.parseModelResponse(data: data)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.map(\.id) == ["antigravity-gemini"])
        #expect(usage.additionalWindows.first?.label == "Gemini Models")
        #expect(usage.additionalWindows.first?.usedFraction == 0)
        #expect(usage.additionalWindows.first?.resetsAt == ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
    }

    @Test
    func identityPrefersUserTierOverGenericPlanInfo() throws {
        let data = Data("""
        {"userStatus":{
          "email":"person@example.com",
          "userTier":{"name":"Ultra"},
          "planStatus":{"planInfo":{"planName":"Pro"}}
        }}
        """.utf8)

        let identity = try AntigravityUsageFetcher.parseIdentity(data: data)

        #expect(identity.email == "person@example.com")
        #expect(identity.plan == "Ultra")
    }

    @Test
    func fullAvailableModelFractionsRequireQuotaVerification() {
        let full = [
            AntigravityUsageFetcher.ModelQuota(
                label: "Gemini Pro", modelID: "gemini-pro", remainingFraction: 1,
                resetsAt: nil, resetDescription: nil
            ),
        ]
        let partial = [
            AntigravityUsageFetcher.ModelQuota(
                label: "Gemini Pro", modelID: "gemini-pro", remainingFraction: 0.9,
                resetsAt: nil, resetDescription: nil
            ),
        ]

        #expect(AntigravityUsageFetcher.shouldVerifyAvailableModels(full))
        #expect(!AntigravityUsageFetcher.shouldVerifyAvailableModels(partial))
    }

    @Test
    func verifiedBucketsReplaceAvailabilityFractionsAndDropUnverifiedRows() {
        let models = [
            AntigravityUsageFetcher.ModelQuota(
                label: "Gemini Pro", modelID: "gemini-pro", remainingFraction: 1,
                resetsAt: nil, resetDescription: nil
            ),
            AntigravityUsageFetcher.ModelQuota(
                label: "Gemini Flash", modelID: "gemini-flash", remainingFraction: 1,
                resetsAt: nil, resetDescription: nil
            ),
        ]
        let verified = [
            AntigravityUsageFetcher.ModelQuota(
                label: "gemini-pro", modelID: "gemini-pro", remainingFraction: 0.25,
                resetsAt: Date(timeIntervalSince1970: 123), resetDescription: nil
            ),
        ]

        let merged = AntigravityUsageFetcher.merge(models: models, verified: verified)

        #expect(merged.count == 1)
        #expect(merged.first?.label == "Gemini Pro")
        #expect(merged.first?.remainingFraction == 0.25)
        #expect(merged.first?.resetsAt == Date(timeIntervalSince1970: 123))
    }

    @Test
    func credentialsAcceptSnakeAndCamelShapesAndClaimsPreferSignedEmail() throws {
        let expiry = 1_800_000_000_000.0
        let snake = try JSONDecoder().decode(
            AntigravityOAuthCredentials.self,
            from: Data("""
            {"access_token":"a","refresh_token":"r","expiry_date":\(expiry),"project_id":"p"}
            """.utf8)
        )
        let camel = try JSONDecoder().decode(
            AntigravityOAuthCredentials.self,
            from: Data("""
            {"accessToken":"a","refreshToken":"r","expiresAt":1800000000000,"projectId":"p"}
            """.utf8)
        )
        let payload = try JSONSerialization.data(withJSONObject: ["email": "signed@example.com", "hd": "example.com"])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let claims = AntigravityUsageFetcher.tokenClaims("header.\(payload).signature")

        #expect(snake.accessToken == camel.accessToken)
        #expect(snake.expiryMilliseconds == camel.expiryMilliseconds)
        #expect(snake.projectID == camel.projectID)
        #expect(claims.email == "signed@example.com")
        #expect(claims.hostedDomain == "example.com")
    }

    @Test
    func remoteFetchUsesExactEndpointsHeadersAndProject() async throws {
        let protocolStub = AntigravityTestURLProtocol.self
        protocolStub.requests = []
        protocolStub.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1internal:loadCodeAssist" {
                return response(url, """
                {"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"project-123"}
                """)
            }
            if url.path == "/v1internal:fetchAvailableModels" {
                return response(url, """
                {"models":{"gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.4}}}}
                """)
            }
            return response(url, "{}", status: 404)
        }
        defer { protocolStub.handler = nil; protocolStub.requests = [] }

        let credentials = AntigravityOAuthCredentials(
            accessToken: "token", refreshToken: nil, expiryDate: Date().addingTimeInterval(3600),
            idToken: try idToken(email: "person@example.com")
        )
        let credentialData = try JSONEncoder().encode(credentials)
        let credential = try #require(String(data: credentialData, encoding: .utf8))
        let session = stubSession(protocolStub)

        let usage = try await AntigravityUsageFetcher.fetchRemote(
            credential: credential,
            session: session,
            environment: [:],
            homeDirectory: FileManager.default.temporaryDirectory
        )

        #expect(usage.windows.first?.usedFraction == 0.6)
        #expect(usage.plan == "Paid")
        #expect(usage.details.isEmpty)
        #expect(protocolStub.requests.map { $0.url?.path } == [
            "/v1internal:loadCodeAssist", "/v1internal:fetchAvailableModels",
        ])
        #expect(protocolStub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer token"
                && $0.value(forHTTPHeaderField: "User-Agent") == "antigravity"
        })
        let request = try AntigravityUsageFetcher.remoteRequest(
            path: "/v1internal:fetchAvailableModels",
            accessToken: "token",
            body: ["project": "project-123"]
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["project"] as? String == "project-123")
    }

    @Test
    func remoteFullFractionsAreReplacedByVerifiedQuotaBuckets() async throws {
        let protocolStub = AntigravityTestURLProtocol.self
        protocolStub.requests = []
        protocolStub.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return response(url, "{\"cloudaicompanionProject\":\"project-123\"}")
            case "/v1internal:fetchAvailableModels":
                return response(url, """
                {"models":{"gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":1}}}}
                """)
            case "/v1internal:retrieveUserQuota":
                return response(url, """
                {"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.2}]}
                """)
            default:
                return response(url, "{}", status: 404)
            }
        }
        defer { protocolStub.handler = nil; protocolStub.requests = [] }

        let credentials = AntigravityOAuthCredentials(
            accessToken: "token", refreshToken: nil, expiryDate: Date().addingTimeInterval(3600)
        )
        let data = try JSONEncoder().encode(credentials)
        let credential = try #require(String(data: data, encoding: .utf8))

        let usage = try await AntigravityUsageFetcher.fetchRemote(
            credential: credential,
            session: stubSession(protocolStub),
            environment: [:],
            homeDirectory: FileManager.default.temporaryDirectory
        )

        #expect(usage.windows.first?.usedFraction == 0.8)
        let paths = protocolStub.requests.compactMap { $0.url?.path }
        #expect(paths.contains("/v1internal:retrieveUserQuota"))
    }

    private func stubSession(_ protocolClass: AnyClass) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    private func response(_ url: URL, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private func idToken(email: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
}

private final class AntigravityTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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
