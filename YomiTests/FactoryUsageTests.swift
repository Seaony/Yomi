import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct FactoryUsageTests {
    @Test
    func parsesRateLimitWindowsCoreWindowsAndBalance() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let billing = Data("""
        {
          "usesTokenRateLimitsBilling": true,
          "limits": {
            "standard": {
              "fiveHour": {"usedPercent": 12, "secondsRemaining": 3600},
              "weekly": {"usedPercent": 34, "secondsRemaining": 86400},
              "monthly": {"usedPercent": 56, "secondsRemaining": 604800}
            },
            "core": {
              "fiveHour": {"usedPercent": 7, "secondsRemaining": 1800},
              "weekly": {"usedPercent": 8, "secondsRemaining": 7200},
              "monthly": {"usedPercent": 9, "secondsRemaining": 14400}
            }
          },
          "extraUsageBalanceCents": 1234,
          "overagePreference": "standard"
        }
        """.utf8)
        let auth = Data("""
        {
          "organization": {
            "name": "Acme",
            "subscription": {
              "factoryTier": "team",
              "orbSubscription": {"plan": {"name": "Pro"}}
            }
          },
          "userProfile": {"email": "person@example.com"}
        }
        """.utf8)

        let usage = try FactoryUsageFetcher.parseBillingLimits(data: billing, authData: auth, now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.12, 0.34, 0.56])
        #expect(usage.windows[0].resetsAt == now.addingTimeInterval(3600))
        #expect(usage.additionalWindows.map(\.label) == ["Core 5h", "Core 7-day", "Core Monthly"])
        #expect(usage.additionalWindows.map(\.usedFraction) == [0.07, 0.08, 0.09])
        #expect(usage.balance == "$12.34")
        #expect(usage.providerCost?.used == 12.34)
        #expect(usage.providerCost?.period == "Extra usage balance")
        #expect(usage.plan == "Factory Team - Pro")
        #expect(usage.details.isEmpty)
    }

    @Test
    func clearsExpiredFactoryWindowUsage() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let billing = Data("""
        {
          "usesTokenRateLimitsBilling": true,
          "limits": {
            "standard": {
              "fiveHour": {"usedPercent": 81, "windowEnd": 1699999000},
              "weekly": {"usedPercent": 22, "windowEnd": "2030-01-01T00:00:00Z"},
              "monthly": {"usedPercent": 33, "secondsRemaining": 10}
            },
            "core": {
              "fiveHour": {"usedPercent": 0},
              "weekly": {"usedPercent": 0},
              "monthly": {"usedPercent": 0}
            }
          }
        }
        """.utf8)

        let usage = try FactoryUsageFetcher.parseBillingLimits(
            data: billing,
            authData: Data("{}".utf8),
            now: now
        )

        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].resetsAt == nil)
        #expect(usage.windows[1].usedFraction == 0.22)
        #expect(usage.windows[2].resetsAt == now.addingTimeInterval(10))
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func parsesLegacyStandardAndPremiumRatioSemantics() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usageData = Data("""
        {
          "usage": {
            "endDate": 1700003600000,
            "standard": {"userTokens": 100, "totalAllowance": 1000, "usedRatio": 0},
            "premium": {"userTokens": 0, "totalAllowance": 0, "usedRatio": 75}
          }
        }
        """.utf8)
        let auth = Data("""
        {"organization":{"subscription":{"factoryTier":"enterprise"}}}
        """.utf8)

        let usage = try FactoryUsageFetcher.parseLegacyUsage(
            data: usageData,
            authData: auth,
            now: now
        )

        #expect(usage.windows.map(\.label) == ["Standard", "Premium"])
        #expect(usage.windows.map(\.usedFraction) == [0.1, 0.75])
        #expect(usage.windows.map(\.resetsAt) == [
            Date(timeIntervalSince1970: 1_700_003_600),
            Date(timeIntervalSince1970: 1_700_003_600),
        ])
        #expect(usage.plan == "Factory Enterprise")
    }

    @Test
    func treatsVeryLargeLegacyAllowanceAsUnlimitedReference() throws {
        let data = Data("""
        {"usage":{"standard":{"userTokens":25000000,"totalAllowance":1000000000001}}}
        """.utf8)
        let usage = try FactoryUsageFetcher.parseLegacyUsage(data: data, authData: Data("{}".utf8))
        #expect(usage.windows[0].usedFraction == 0.25)
    }

    @Test
    func parsesManualCookieAuthorizationAndBareBearer() throws {
        let combined = try #require(FactoryUsageFetcher.manualCredentials(
            "Cookie: session=stale; access-token=cookie-token\nAuthorization: Bearer bearer-token"
        ))
        #expect(combined.cookieHeader == "session=stale; access-token=cookie-token")
        #expect(combined.bearerToken == "bearer-token")

        let bare = try #require(FactoryUsageFetcher.manualCredentials(
            "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        ))
        #expect(bare.cookieHeader == nil)
        #expect(bare.bearerToken == "abcdefghijklmnopqrstuvwxyz0123456789ABCD")
        #expect(FactoryUsageFetcher.manualCredentials("definitely not credentials") == nil)
    }

    @Test
    func resolvesEnvironmentBeforeFactoryDotEnv() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factoryDirectory = directory.appending(path: ".factory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: factoryDirectory, withIntermediateDirectories: true)
        try Data("export FACTORY_API_KEY='fk-dotenv'\n".utf8)
            .write(to: factoryDirectory.appending(path: ".env"))

        #expect(FactoryUsageFetcher.resolvedAPIKey(environment: [:], homeDirectory: directory) == "fk-dotenv")
        #expect(FactoryUsageFetcher.resolvedAPIKey(
            environment: ["FACTORY_API_KEY": "  \"fk-environment\"  "],
            homeDirectory: directory
        ) == "fk-environment")
    }

    @Test
    func apiKeyFetchUsesFactoryHeadersBillingPathAndBearerSubject() async throws {
        let protocolStub = FactoryURLProtocolStub.self
        protocolStub.requests = []
        protocolStub.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                return response(url, "{\"organization\":{\"name\":\"Acme\"}}")
            }
            if url.path == "/api/billing/limits" {
                return response(url, """
                {
                  "usesTokenRateLimitsBilling": true,
                  "limits": {"standard": {
                    "fiveHour": {"usedPercent": 12},
                    "weekly": {"usedPercent": 34},
                    "monthly": {"usedPercent": 56}
                  }}
                }
                """)
            }
            return response(url, "{}", status: 404)
        }
        defer {
            protocolStub.handler = nil
            protocolStub.requests = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolStub]
        let session = URLSession(configuration: configuration)

        let usage = try await FactoryUsageFetcher.fetch(
            apiKey: jwt(["sub": "user-1"]),
            session: session,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(usage.windows.map(\.usedFraction) == [0.12, 0.34, 0.56])
        #expect(protocolStub.requests.map { $0.url?.path } == [
            "/api/app/auth/me", "/api/billing/limits",
        ])
        #expect(protocolStub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
                && $0.value(forHTTPHeaderField: "Origin") == "https://app.factory.ai"
                && $0.value(forHTTPHeaderField: "x-factory-client") == "web-app"
        })
    }

    @Test
    func billingFailureFallsBackToLegacyUsageWithUserIDQuery() async throws {
        let protocolStub = FactoryURLProtocolStub.self
        protocolStub.requests = []
        protocolStub.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" { return response(url, "{}") }
            if url.path == "/api/billing/limits" { return response(url, "{}", status: 403) }
            if url.path == "/api/organization/subscription/usage" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
                    URLQueryItem(name: "useCache", value: "true"),
                    URLQueryItem(name: "userId", value: "user-jwt"),
                ])
                return response(url, """
                {"usage":{"standard":{"userTokens":10,"totalAllowance":100}}}
                """)
            }
            return response(url, "{}", status: 404)
        }
        defer {
            protocolStub.handler = nil
            protocolStub.requests = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolStub]
        let session = URLSession(configuration: configuration)

        let usage = try await FactoryUsageFetcher.fetch(
            apiKey: jwt(["sub": "user-jwt"]),
            session: session
        )

        #expect(usage.windows[0].usedFraction == 0.1)
        #expect(protocolStub.requests.map { $0.url?.path } == [
            "/api/app/auth/me", "/api/billing/limits", "/api/organization/subscription/usage",
        ])
    }

    private func response(
        _ url: URL,
        _ body: String,
        status: Int = 200
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    private func jwt(_ payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        let payload = (try? JSONSerialization.data(withJSONObject: payload).base64EncodedString()) ?? ""
        return "\(header).\(payload).signature"
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class FactoryURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.requests.append(request)
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
