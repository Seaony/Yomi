import Foundation
import Testing
@testable import Yomi

@Suite("Grok usage", .serialized)
struct GrokUsageTests {
    @Test
    func routesOnlySupportedOAuthAndGrokSessionCredentials() {
        #expect(GrokCredentialRoute.resolve(" Bearer token-123 ") == .oauth("token-123"))
        #expect(GrokCredentialRoute.resolve("sso=session; other=value") == .cookie("sso=session; other=value"))
        #expect(GrokCredentialRoute.resolve("Cookie: other=value; sso-rw=write") == .cookie("other=value; sso-rw=write"))
        #expect(GrokCredentialRoute.resolve("xai-management-key") == .none)
        #expect(GrokCredentialRoute.resolve("other=value") == .cookie("other=value"))
        #expect(GrokCredentialRoute.resolve("   ") == .none)
    }

    @Test
    func authJSONPrefersUsableOIDCThenFallsBackToLegacy() throws {
        let preferred = try GrokCredentialsStore.parse(Data(#"""
        {
          "https://accounts.x.ai/sign-in":{"key":"legacy","auth_mode":"session"},
          "https://auth.x.ai::client":{"key":"oidc","auth_mode":"oidc","email":"a@example.com","team_id":"team","principal_type":" team ","expires_at":"2099-01-01T00:00:00Z"}
        }
        """#.utf8))
        #expect(preferred.accessToken == "oidc")
        #expect(preferred.email == "a@example.com")
        #expect(preferred.teamID == "team")
        #expect(preferred.isTeam)
        #expect(preferred.fallbackPlan == "SuperGrok")
        #expect(!preferred.isExpired)

        let fallback = try GrokCredentialsStore.parse(Data(#"""
        {
          "https://auth.x.ai::client":{"auth_mode":"oidc"},
          "https://accounts.x.ai/sign-in":{"key":"legacy","auth_mode":"session"}
        }
        """#.utf8))
        #expect(fallback.accessToken == "legacy")
        #expect(fallback.fallbackPlan == "session")
    }

    @Test
    func resolvesGrokHomeAndReadsOnlyItsAuthFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-Grok-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"https://auth.x.ai::client":{"key":"file-token"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        #expect(GrokCredentialsStore.authURL(environment: ["GROK_HOME": root.path])
            == root.appendingPathComponent("auth.json"))
        #expect(GrokCredentialsStore.load(environment: ["GROK_HOME": root.path])?.accessToken == "file-token")
    }

    @Test
    func decodesCLIBillingAndComputesOnlyDocumentedMonthlyPercent() throws {
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(#"""
        {
          "billingCycle":{"billingPeriodStart":"2026-05-01T00:00:00Z","billingPeriodEnd":"2026-06-01T00:00:00Z"},
          "monthlyLimit":{"val":1000},"usage":{"totalUsed":{"val":1250}}
        }
        """#.utf8))
        #expect(response.usedPercent == 100)
        #expect(response.windowMinutes == 31 * 24 * 60)
        #expect(response.resetsAt != nil)
        let missing = try JSONDecoder().decode(
            GrokBillingResponse.self,
            from: Data(#"{"usage":{"totalUsed":{"val":100}}}"#.utf8))
        #expect(missing.usedPercent == nil)
    }

    @Test
    func parsesCreditsProxyPercentRatioPlanResetAndUnknownUsage() throws {
        let direct = try GrokUsageFetcher.parseProxy(Data(#"""
        {
          "config":{"creditUsagePercent":62.5,"currentPeriod":{"end":"2099-01-01T00:00:00Z"},"subscriptionTier":"SUPERGROK_HEAVY"}
        }
        """#.utf8))
        #expect(direct.usedPercent == 62.5)
        #expect(direct.plan == "SuperGrok Heavy")
        #expect(direct.resetsAt != nil)

        let ratio = try GrokUsageFetcher.parseProxy(Data(#"""
        {
          "subscriptionTier":"SuperGrok","config":{"onDemandCap":{"val":80},"onDemandUsed":{"val":20},"billingPeriodEnd":"2099-01-01T00:00:00Z"}
        }
        """#.utf8))
        #expect(ratio.usedPercent == 25)
        #expect(ratio.plan == "SuperGrok")

        let unknown = try GrokUsageFetcher.parseProxy(Data(#"""
        {
          "config":{"currentPeriod":{"end":"2099-01-01T00:00:00Z"}}
        }
        """#.utf8))
        #expect(unknown.usedPercent == nil)
        #expect(throws: GrokUsageError.parseFailed) {
            _ = try GrokUsageFetcher.parseProxy(Data(#"{"config":{}}"#.utf8))
        }
    }

    @Test
    func parsesFramedAndRawGRPCPercentAndRejectsAuthenticationTrailer() throws {
        let raw = Self.percentPayload(33)
        #expect(try GrokUsageFetcher.parseGRPC(raw).usedPercent == 33)
        #expect(try GrokUsageFetcher.parseGRPC(Self.frame(raw)).usedPercent == 33)
        let trailers = Self.frame(Data("grpc-status:16\r\ngrpc-message:expired%20token\r\n".utf8), flags: 0x80)
        #expect(throws: GrokUsageError.invalidCredentials) {
            _ = try GrokUsageFetcher.parseGRPC(trailers)
        }
    }

    @Test
    func inferredNoUsageZeroIsMarkedUnpublished() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Self.noUsagePayload(reset: 1_900_000_000)
        let snapshot = try GrokUsageFetcher.parseGRPC(Self.frame(payload), now: now)
        #expect(snapshot.usedPercent == 0)
        #expect(!snapshot.percentWasPublished)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test
    func mapsAtMostOneCreditsWindowAndNeverCreatesOnDemandOrFakeUnknownWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let known = GrokUsageFetcher.providerUsage(
            snapshot: .init(usedPercent: 40, resetsAt: now.addingTimeInterval(6 * 86400), plan: "SUPERGROK_HEAVY"),
            credentials: nil,
            windowMinutes: nil,
            local: (today: 10, last30: 20),
            now: now,
            language: .english)
        #expect(known.windows.count == 1)
        #expect(known.windows[0].id == "grok-credits")
        #expect(known.windows[0].label == "Weekly")
        #expect(known.windows[0].usedFraction == 0.4)
        #expect(known.additionalWindows.isEmpty)
        #expect(known.plan == "SuperGrok Heavy")
        #expect(known.today?.tokens == 10)
        #expect(known.today?.valueUSD == nil)
        #expect(known.providerCost == nil)
        #expect(known.balance == nil)

        let unknown = GrokUsageFetcher.providerUsage(
            snapshot: .init(usedPercent: nil, resetsAt: now.addingTimeInterval(6 * 86400)),
            credentials: nil,
            windowMinutes: nil,
            local: (nil, nil),
            now: now,
            language: .english)
        #expect(unknown.windows.isEmpty)
        #expect(unknown.additionalWindows.isEmpty)
        #expect(unknown.message == "Grok billing did not report a usage percentage")
    }

    @Test
    func accountSourceUsesInjectedCLIAndDoesNotReachHTTPWithoutAuth() async throws {
        let recorder = GrokRequestRecorder()
        GrokTestURLProtocol.handler = { request in
            recorder.append(request)
            throw URLError(.badURL)
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .account,
            credential: nil,
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: [:],
            cliLoader: { _ in
                try JSONDecoder().decode(GrokBillingResponse.self, from: Data(#"""
                {
                  "billingCycle":{"billingPeriodStart":"2026-05-01T00:00:00Z","billingPeriodEnd":"2026-06-01T00:00:00Z"},
                  "monthlyLimit":{"val":100},"usage":{"totalUsed":{"val":50}}
                }
                """#.utf8))
            })
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Monthly")
        #expect(usage.windows[0].usedFraction == 0.5)
        #expect(recorder.requests.isEmpty)
    }

    @Test
    func realCLITransportWaitsForInitializeThenSendsUnescapedBillingMethod() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-Grok-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("grok-fixture")
        let script = #"""
        #!/bin/sh
        IFS= read -r initialize
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 10 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r billing
        case "$billing" in *'"method":"x.ai/billing"'*) ;; *) exit 11 ;; esac
        case "$billing" in *'\\/'*) exit 12 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"monthlyLimit":{"val":100},"usage":{"totalUsed":{"val":25}}}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let usage = try await GrokUsageFetcher.fetch(
            source: .account,
            credential: nil,
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: ["GROK_CLI_PATH": executable.path])
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.25)
    }

    @Test
    func OAuthKnownProxyUsesExactRequestsAndSkipsGRPC() async throws {
        let recorder = GrokRequestRecorder()
        GrokTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/v1/billing":
                return (200, Data(#"{"config":{"creditUsagePercent":12,"currentPeriod":{"end":"2099-01-01T00:00:00Z"}}}"#.utf8), [:])
            case "/v1/settings":
                return (200, Data(#"{"subscription_tier_display":"SUPERGROK_HEAVY"}"#.utf8), [:])
            default:
                throw URLError(.badURL)
            }
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .token,
            credential: "Bearer oauth-token",
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: [:])
        let requests = recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].timeoutInterval == 15)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
        #expect(requests[0].value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
        #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "CodexBar")
        #expect(requests[1].url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/settings")
        #expect(requests[1].timeoutInterval == 2)
        #expect(usage.windows[0].usedFraction == 0.12)
        #expect(usage.plan == "SuperGrok Heavy")
    }

    @Test
    func OAuthProxyFailureFallsBackToExactGRPCBearerRequest() async throws {
        let recorder = GrokRequestRecorder()
        GrokTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.host {
            case "cli-chat-proxy.grok.com":
                return request.url?.path == "/v1/settings"
                    ? (500, Data(), [:])
                    : (500, Data("down".utf8), [:])
            case "grok.com":
                return (200, Self.frame(Self.percentPayload(42)), [:])
            default:
                throw URLError(.badURL)
            }
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .token,
            credential: "oauth-token",
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: [:])
        let grpc = try #require(recorder.requests.first { $0.url?.host == "grok.com" })
        #expect(grpc.url?.path == "/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")
        #expect(grpc.httpMethod == "POST")
        #expect(grpc.httpBody == Data([0, 0, 0, 0, 0]))
        #expect(grpc.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
        #expect(grpc.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(grpc.value(forHTTPHeaderField: "Origin") == "https://grok.com")
        #expect(grpc.value(forHTTPHeaderField: "Referer") == "https://grok.com/?_s=usage")
        #expect(grpc.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
        #expect(grpc.value(forHTTPHeaderField: "x-grpc-web") == "1")
        #expect(grpc.value(forHTTPHeaderField: "x-user-agent") == "connect-es/2.1.1")
        #expect(usage.windows[0].usedFraction == 0.42)
    }

    @Test
    func inferredGRPCZeroNeverFillsUnknownProxyPercent() async throws {
        GrokTestURLProtocol.handler = { request in
            switch request.url?.host {
            case "cli-chat-proxy.grok.com":
                if request.url?.path == "/v1/settings" { return (200, Data(#"{}"#.utf8), [:]) }
                return (200, Data(#"{"config":{"currentPeriod":{"end":"2099-01-01T00:00:00Z"}}}"#.utf8), [:])
            case "grok.com":
                return (200, Self.frame(Self.noUsagePayload(reset: 1_900_000_000)), [:])
            default:
                throw URLError(.badURL)
            }
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .token,
            credential: "oauth-token",
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: [:],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.windows.isEmpty)
        #expect(usage.message != nil)
    }

    @Test
    func cookieSourceSendsOnlyNormalizedGrokCookieAndExactGRPCHeaders() async throws {
        let recorder = GrokRequestRecorder()
        GrokTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Self.frame(Self.percentPayload(7)), [:])
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .cookie,
            credential: "Cookie: other=x; sso=session",
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: [:])
        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "other=x; sso=session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(usage.windows[0].usedFraction == 0.07)
        #expect(usage.details.isEmpty)
    }

    @Test
    func cachedCookieIsClearedOnlyForAuthenticationFailure() async {
        let cleared = GrokStringBox()
        GrokTestURLProtocol.handler = { _ in (401, Data(), [:]) }
        await #expect(throws: GrokUsageError.missingCredentials) {
            _ = try await GrokUsageFetcher.fetch(
                source: .cookie,
                credential: nil,
                cachedCookie: "sso=stale",
                allowBrowserImport: false,
                session: Self.session(),
                environment: [:],
                cacheUpdate: { cleared.set($0) })
        }
        #expect(cleared.wasSet)
        GrokTestURLProtocol.handler = { _ in (500, Data(), [:]) }
        cleared.reset()
        await #expect(throws: GrokUsageError.self) {
            _ = try await GrokUsageFetcher.fetch(
                source: .cookie,
                credential: nil,
                cachedCookie: "sso=stale",
                allowBrowserImport: false,
                session: Self.session(),
                environment: [:],
                cacheUpdate: { cleared.set($0) })
        }
        #expect(!cleared.wasSet)
        GrokTestURLProtocol.handler = nil
    }

    @Test
    func automaticTriesCLIThenOAuthWithoutInventingAnotherWindow() async throws {
        let cliCalls = GrokIntBox()
        GrokTestURLProtocol.handler = { request in
            if request.url?.path == "/v1/settings" { return (200, Data(#"{}"#.utf8), [:]) }
            return (200, Data(#"{"config":{"creditUsagePercent":19}}"#.utf8), [:])
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .automatic,
            credential: nil,
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: ["GROK_OAUTH_TOKEN": "environment-token"],
            cliLoader: { _ in
                cliCalls.increment()
                throw GrokUsageError.cliUnavailable
            })
        #expect(cliCalls.value == 1)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.19)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func teamPrincipalDegradesToIdentityOnlyForExactNoPersonalTeamRPC() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-Grok-team-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"https://auth.x.ai::client":{"key":"team-token","email":"team@example.com","team_id":"team-123","principal_type":"Team"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        GrokTestURLProtocol.handler = { request in
            if request.url?.path == "/v1/settings" {
                return (200, Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8), [:])
            }
            if request.url?.host == "cli-chat-proxy.grok.com" {
                return (500, Data(), [:])
            }
            let trailer = Self.frame(Data("grpc-status:9\r\ngrpc-message:no%20personal%20team\r\n".utf8), flags: 0x80)
            return (200, trailer, [:])
        }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .token,
            credential: nil,
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: ["GROK_HOME": root.path])
        #expect(usage.windows.isEmpty)
        #expect(usage.plan == "SuperGrok")
        #expect(usage.details.isEmpty)
        #expect(usage.message == GrokUsageError.teamUsageUnsupported.errorDescription)
    }

    @Test
    func teamCLIUnsupportedMethodAlsoKeepsIdentityWithoutFakeQuota() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-Grok-team-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"https://auth.x.ai::client":{"key":"team-token","email":"team@example.com","principal_type":"Team"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        GrokTestURLProtocol.handler = { _ in (200, Data(#"{}"#.utf8), [:]) }
        defer { GrokTestURLProtocol.handler = nil }
        let usage = try await GrokUsageFetcher.fetch(
            source: .account,
            credential: nil,
            cachedCookie: nil,
            allowBrowserImport: false,
            session: Self.session(),
            environment: ["GROK_HOME": root.path],
            cliLoader: { _ in throw GrokUsageError.cliFailure("Method not found: x.ai/billing") })
        #expect(usage.windows.isEmpty)
        #expect(usage.details.isEmpty)
        #expect(usage.message == GrokUsageError.teamUsageUnsupported.errorDescription)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func percentPayload(_ percent: Float) -> Data {
        var data = Data([0x0D])
        var bits = percent.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        return data
    }

    private nonisolated static func noUsagePayload(reset: UInt64) -> Data {
        let resetMessage = Data([0x08]) + Self.varint(reset)
        let periodMessage = Data([0x08, 0x01])
        var inner = Data([0x2A]) + Self.varint(UInt64(resetMessage.count)) + resetMessage
        inner += Data([0x32]) + Self.varint(UInt64(periodMessage.count)) + periodMessage
        return Data([0x0A]) + Self.varint(UInt64(inner.count)) + inner
    }

    private nonisolated static func frame(_ payload: Data, flags: UInt8 = 0) -> Data {
        let count = UInt32(payload.count).bigEndian
        var data = Data([flags])
        withUnsafeBytes(of: count) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private nonisolated static func varint(_ input: UInt64) -> Data {
        var value = input
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}

private nonisolated final class GrokRequestRecorder: @unchecked Sendable {
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

private nonisolated final class GrokStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storageWasSet = false
    var wasSet: Bool { lock.withLock { storageWasSet } }
    func set(_: String?) { lock.withLock { storageWasSet = true } }
    func reset() { lock.withLock { storageWasSet = false } }
}

private nonisolated final class GrokIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class GrokTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
