import Foundation
import Testing
@testable import Yomi

@Suite("Codex usage sources", .serialized)
struct CodexUsageTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func providerSourcesMapToCodexBarStrategies() {
        #expect(CodexUsageSource.selected(by: .automatic).strategyOrder == [.api, .oauth, .cli])
        #expect(CodexUsageSource.selected(by: .cookie).strategyOrder == [.web])
        #expect(CodexUsageSource.selected(by: .command).strategyOrder == [.cli])
        #expect(CodexUsageSource.selected(by: .account).strategyOrder == [.oauth])
        #expect(CodexUsageSource.selected(by: .token).strategyOrder == [.api])
        #expect(CodexUsageSource.selected(by: .endpoint).strategyOrder == [.api, .oauth, .cli])
    }

    @Test
    func automaticFallsBackFromPATThroughOAuthToCLI() async throws {
        let recorder = CodexSourceRecorder()
        let usage = try await CodexUsageFetcher.execute(order: [.api, .oauth, .cli]) { source in
            await recorder.append(source)
            switch source {
            case .api: throw CodexUsageError.missingAPICredential
            case .oauth: throw CodexUsageError.oauthRefreshRequired
            case .cli: return Self.fixtureUsage
            case .automatic, .web: throw CodexUsageError.invalidResponse
            }
        }

        #expect(await recorder.values == [.api, .oauth, .cli])
        #expect(usage.windows.first?.label == "Weekly")
    }

    @Test
    func automaticDoesNotHideAnAuthoritativeServerFailure() async {
        let recorder = CodexSourceRecorder()
        await #expect(throws: CodexUsageError.requestFailed(503)) {
            _ = try await CodexUsageFetcher.execute(order: [.api, .oauth, .cli]) { source in
                await recorder.append(source)
                throw CodexUsageError.requestFailed(503)
            }
        }
        #expect(await recorder.values == [.api])
    }

    @Test
    func authJSONParsesPATAndOAuthClaims() throws {
        let access = try Self.jwt([
            "exp": Self.now.timeIntervalSince1970 + 3_600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-jwt"],
        ])
        let snapshot = try CodexAuthStore.parse(Data(#"""
        {
          "personal_access_token": " at-file ",
          "tokens": {
            "access_token": "\#(access)",
            "refresh_token": " refresh ",
            "id_token": "\#(access)"
          },
          "last_refresh": "2027-01-15T08:00:00Z"
        }
        """#.utf8))

        #expect(snapshot.personalAccessToken == "at-file")
        #expect(snapshot.oauthToken == access)
        #expect(snapshot.refreshToken == "refresh")
        #expect(snapshot.accountID == "acct-jwt")
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 + 3_600))
        #expect(!snapshot.oauthNeedsRefresh(now: Self.now))
    }

    @Test
    func rootAPIKeyIsAnOAuthCredentialThatDoesNotNeedRefresh() throws {
        let snapshot = try CodexAuthStore.parse(Data(#"{"OPENAI_API_KEY":"sk-local"}"#.utf8))
        #expect(snapshot.oauthToken == "sk-local")
        #expect(!snapshot.oauthNeedsRefresh(now: Self.now))
    }

    @Test
    func oauthCredentialWithinFiveMinutesRequiresNativeRefresh() throws {
        let token = try Self.jwt(["exp": Self.now.timeIntervalSince1970 + 299])
        let snapshot = try CodexAuthStore.parse(
            Data(#"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh"}}"#.utf8))
        #expect(snapshot.oauthNeedsRefresh(now: Self.now))
    }

    @Test
    func PATUsesWhoamiThenUsageWithExactHeaders() async throws {
        let recorder = CodexRequestRecorder()
        CodexTestURLProtocol.handler = { request in
            recorder.append(request)
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-explicit")
            #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/1.2.3 (") == true)
            if request.url == CodexUsageFetcher.whoamiURL {
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
                return (200, Data(#"{"chatgpt_account_id":"acct-pat","chatgpt_plan_type":"team"}"#.utf8))
            }
            #expect(request.url == CodexUsageFetcher.usageURL)
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-pat")
            return (200, Self.weeklyUsage)
        }
        defer { CodexTestURLProtocol.handler = nil }

        let usage = try await CodexUsageFetcher.fetchAPI(
            configuredCredential: "Bearer at-explicit",
            session: Self.session(),
            environment: ["CODEX_HOME": Self.missingPath(), "CODEX_CLI_VERSION": "1.2.3"],
            now: Self.now)

        #expect(recorder.requests.map(\.url) == [CodexUsageFetcher.whoamiURL, CodexUsageFetcher.usageURL])
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Weekly")
        #expect(usage.windows[0].usedFraction == 0.38)
        #expect(usage.plan == "Pro 20x")
        #expect(usage.details.isEmpty)
    }

    @Test
    func OAuthUsesAuthJSONBearerAndAccountWithoutPATHeaders() async throws {
        let directory = try Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try Self.jwt([
            "exp": Self.now.timeIntervalSince1970 + 3_600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-oauth"],
        ])
        try Data(#"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        CodexTestURLProtocol.handler = { request in
            #expect(request.url == CodexUsageFetcher.usageURL)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-oauth")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.value(forHTTPHeaderField: "originator") == nil)
            return (200, Self.weeklyUsage)
        }
        defer { CodexTestURLProtocol.handler = nil }

        let usage = try await CodexUsageFetcher.fetchOAuth(
            session: Self.session(), environment: ["CODEX_HOME": directory.path], now: Self.now)
        #expect(usage.windows.count == 1)
        #expect(usage.details.isEmpty)
    }

    @Test
    func expiredOAuthFailsBeforeHTTPAndCanFallBackToCLI() async {
        let directory = try! Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try! Self.jwt(["exp": Self.now.timeIntervalSince1970 + 60])
        try! Data(#"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        CodexTestURLProtocol.handler = { _ in
            Issue.record("Expired OAuth must not issue HTTP")
            return (500, Data())
        }
        defer { CodexTestURLProtocol.handler = nil }

        await #expect(throws: CodexUsageError.oauthRefreshRequired) {
            _ = try await CodexUsageFetcher.fetchOAuth(
                session: Self.session(), environment: ["CODEX_HOME": directory.path], now: Self.now)
        }
    }

    @Test
    func explicitOAuthUsesCLIOnlyForNativeRefresh() async throws {
        let directory = try Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try Self.jwt(["exp": Self.now.timeIntervalSince1970 + 60])
        try Data(#"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        let recorder = CodexSourceRecorder()

        let usage = try await CodexUsageFetcher.fetch(
            source: .account,
            configuredCredential: nil,
            cachedCookieHeader: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: ["CODEX_HOME": directory.path],
            now: Self.now,
            cliLoader: { _ in
                await recorder.append(.cli)
                return Self.fixtureUsage
            })

        #expect(await recorder.values == [.cli])
        #expect(usage.windows.first?.label == "Weekly")
    }

    @Test
    func webUsesOnlyNormalizedCookieAndDashboardHeaders() async throws {
        CodexTestURLProtocol.handler = { request in
            #expect(request.url == CodexUsageFetcher.usageURL)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 4)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc; theme=dark")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Self.weeklyUsage)
        }
        defer { CodexTestURLProtocol.handler = nil }

        let usage = try await CodexUsageFetcher.fetchWeb(
            manualCookie: "Cookie: session=abc; broken; theme=dark",
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            now: Self.now)
        #expect(usage.windows.count == 1)
        #expect(usage.details.isEmpty)
    }

    @Test
    func malformedAndGenericPercentagePayloadsNeverBecomeQuota() async {
        for payload in [Data(#"{"percent":62,"weekly":100}"#.utf8), Data("not-json".utf8)] {
            CodexTestURLProtocol.handler = { _ in (200, payload) }
            await #expect(throws: (any Error).self) {
                _ = try await CodexUsageFetcher.fetchWeb(
                    manualCookie: "session=abc", cachedCookie: nil, allowBrowserImport: false,
                    session: Self.session())
            }
        }
        CodexTestURLProtocol.handler = nil
    }

    @Test
    func RPCMapsDurationRolesAndIgnoresAdditionalLimits() throws {
        let data = Data(#"""
        {
          "rateLimits": {
            "primary": {"usedPercent": 38, "windowDurationMins": 10080, "resetsAt": 1800604800},
            "secondary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1800003600},
            "credits": {"hasCredits": true, "unlimited": false, "balance": "42.50"},
            "planType": "pro",
            "rateLimitsByLimitId": {
              "codex_bengalfox": {"primary":{"usedPercent":0,"windowDurationMins":300}}
            }
          }
        }
        """#.utf8)
        let usage = try CodexUsageFetcher.parseRPCResponse(data, now: Self.now)

        #expect(usage.windows.map(\.label) == ["Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.38])
        #expect(usage.windows.count == 1)
        #expect(usage.balance == "42.50")
        #expect(usage.plan == "Pro 20x")
        #expect(usage.updatedAt == Self.now)
    }

    @Test
    func CLIUsesOfficialAppServerArgumentsAndRateLimitsRPC() async throws {
        let directory = try Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-test")
        let argumentsLog = directory.appendingPathComponent("arguments.txt")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" > "$YOMI_CODEX_ARGUMENTS"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\n' '{"id":1,"result":{}}'
              ;;
            *'rateLimits'*)
              printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":38,"windowDurationMins":10080,"resetsAt":1800604800},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"planType":"plus"}}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let usage = try await CodexUsageFetcher.fetchCLI(environment: [
            "CODEX_CLI_PATH": executable.path,
            "YOMI_CODEX_ARGUMENTS": argumentsLog.path,
        ])

        #expect(try String(contentsOf: argumentsLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "-s read-only -a never app-server")
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Weekly")
        #expect(usage.windows[0].usedFraction == 0.38)
        #expect(usage.plan == "Plus")
        #expect(usage.details.isEmpty)
    }

    @Test
    func configBaseURLMatchesOfficialAndCustomRouting() throws {
        let chatGPT = try Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: chatGPT) }
        try Data(#"chatgpt_base_url = "https://chat.openai.com/""#.utf8)
            .write(to: chatGPT.appendingPathComponent("config.toml"))
        #expect(CodexUsageFetcher.resolvedUsageURL(environment: ["CODEX_HOME": chatGPT.path]).absoluteString
            == "https://chat.openai.com/backend-api/wham/usage")

        let custom = try Self.temporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: custom) }
        try Data(#"chatgpt_base_url = "https://gateway.example.test""#.utf8)
            .write(to: custom.appendingPathComponent("config.toml"))
        #expect(CodexUsageFetcher.resolvedUsageURL(environment: ["CODEX_HOME": custom.path]).absoluteString
            == "https://gateway.example.test/api/codex/usage")
    }

    private nonisolated static let fixtureUsage = ProviderUsage(
        id: ProviderID(rawValue: "codex"), state: .ready,
        windows: [UsageWindow(id: "codex-primary", label: "Weekly", usedFraction: 0.38)],
        updatedAt: now)

    private nonisolated static let weeklyUsage = Data(#"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 38,
          "reset_at": 1800604800,
          "limit_window_seconds": 604800
        },
        "secondary_window": null
      },
      "additional_rate_limits": [{"rate_limit":{"primary_window":{"used_percent":0}}}]
    }
    """#.utf8)

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func temporaryCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yomi-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func missingPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yomi-codex-missing-\(UUID().uuidString)").path
    }

    private static func jwt(_ payload: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded
        let body = try JSONSerialization.data(withJSONObject: payload).base64URLEncoded
        return "\(header).\(body).signature"
    }
}

private actor CodexSourceRecorder {
    private var storage: [CodexUsageSource] = []
    var values: [CodexUsageSource] { storage }
    func append(_ value: CodexUsageSource) { storage.append(value) }
}

private nonisolated final class CodexRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class CodexTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
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
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
