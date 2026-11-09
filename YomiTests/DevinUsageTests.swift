import CommonCrypto
import Foundation
import SQLite3
import Testing
@testable import Yomi

@Suite(.serialized)
struct DevinUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func parsesNestedQuotaWindowsPlanAndOrganization() throws {
        let response: [String: Any] = [
            "plan_name": "pro",
            "quota_usage": [
                "daily_quota": [
                    "used": 3,
                    "limit": 10,
                    "reset_at": "2026-06-01T08:00:00Z",
                ],
                "weekly_quota": [
                    "remaining_percent": 0.25,
                    "next_reset_at": 1_780_560_000,
                ],
            ],
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: "org/example-org", now: Self.now)

        #expect(snapshot.daily?.usedPercent == 30)
        #expect(snapshot.weekly?.usedPercent == 75)
        #expect(snapshot.daily?.resetsAt?.timeIntervalSince1970 == 1_780_300_800)
        #expect(snapshot.weekly?.resetsAt?.timeIntervalSince1970 == 1_780_560_000)
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.organization == "example-org")
    }

    @Test
    func currentResponseUsesDistinctOnePercentBoundary() throws {
        for (input, expected) in [(0.5, 50.0), (1.0, 1.0), (1.5, 1.5)] {
            let snapshot = try DevinUsageParser.parse(
                ["daily_percentage": input, "weekly_percentage": input],
                organization: nil,
                now: Self.now
            )
            #expect(snapshot.daily?.usedPercent == expected)
            #expect(snapshot.weekly?.usedPercent == expected)
        }
    }

    @Test
    func fallbackResponseTreatsOneAsFraction() throws {
        let response: [String: Any] = [
            "quota_usage": [
                "daily_quota": ["used_percent": 1],
                "weekly_quota": ["remaining_percent": 1],
            ],
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.daily?.usedPercent == 100)
        #expect(snapshot.weekly?.usedPercent == 0)
    }

    @Test
    func hiddenDailyResponseKeepsWeeklyOnly() throws {
        let response: [String: Any] = [
            "weekly_percentage": 25,
            "weekly_reset_at": "2026-06-14T00:00:00-08:00",
            "hide_daily_quota": true,
        ]

        let usage = try DevinUsageParser.parse(response, organization: nil, now: Self.now).toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Weekly"])
        #expect(usage.windows.first?.usedFraction == 0.25)
    }

    @Test
    func parsesOverageBalanceAndMapsNativeUsage() throws {
        let snapshot = try DevinUsageParser.parse(
            [
                "daily_percentage": 12,
                "weekly_percentage": 42,
                "overage_balance": 70.87,
                "plan": "core",
            ],
            organization: "organizations/org_GQ6LhcfkW1TSinM6",
            now: Self.now
        )
        let usage = snapshot.toProviderUsage()

        #expect(usage.windows.map(\.label) == ["Daily", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.12, 0.42])
        #expect(usage.providerCost?.used == 70.87)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "Extra usage balance")
        #expect(usage.plan == "Core")
        #expect(usage.details.isEmpty)
    }

    @Test
    func parsesOverageCentsAndRejectsInvalidBalances() throws {
        let cents = try DevinUsageParser.parse(
            ["daily_percentage": 0, "overage_balance_cents": 7087],
            organization: nil
        )
        #expect(cents.overageBalance == 70.87)

        for invalid in ["-1", "Infinity", "NaN"] {
            let snapshot = try DevinUsageParser.parse(
                ["daily_percentage": 0, "overage_balance": invalid],
                organization: nil
            )
            #expect(snapshot.overageBalance == nil)
        }
    }

    @Test
    func parsesZeroPercentagesFromJSON() throws {
        let data = Data(#"{"daily_percentage":0,"weekly_percentage":0}"#.utf8)
        let snapshot = try DevinUsageParser.parse(data, organization: nil)
        #expect(snapshot.daily?.usedPercent == 0)
        #expect(snapshot.weekly?.usedPercent == 0)
    }

    @Test
    func normalizesAllSupportedOrganizationForms() {
        #expect(DevinUsageFetcher.normalizedOrganization("example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org/example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org_GQ6LhcfkW1TSinM6")
            == "organizations/org_GQ6LhcfkW1TSinM6")
        #expect(DevinUsageFetcher.normalizedOrganization("org-b31f951cd01d4c6da84991cf5b970cfb")
            == "organizations/org-b31f951cd01d4c6da84991cf5b970cfb")
        #expect(DevinUsageFetcher.normalizedOrganization(
            "https://app.devin.ai/org/example-org/settings/usage"
        ) == "org/example-org")
    }

    @Test
    func manualAuthStripsHeaderAndBearerPrefixes() throws {
        let auth = try #require(DevinUsageFetcher.manualAuth(
            from: "Authorization: Bearer secret-token",
            organization: "example-org"
        ))
        #expect(auth.bearerToken == "secret-token")
        #expect(auth.organization == "org/example-org")
        #expect(auth.sourceLabel == "manual")
    }

    @Test
    func candidatePathsMatchInternalAndExternalOrganizationFallbacks() {
        #expect(DevinUsageFetcher.candidatePaths(
            organization: "org/example-org",
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6"
        ) == [
            "org_GQ6LhcfkW1TSinM6/billing/quota/usage",
            "org/example-org/billing/quota/usage",
            "example-org/billing/quota/usage",
            "organizations/org_GQ6LhcfkW1TSinM6/billing/quota/usage",
        ])
    }

    @Test
    func fetchSendsExactEndpointAndHeaders() async throws {
        DevinURLProtocolStub.handler = { request in
            #expect(request.url?.host == "app.devin.ai")
            #expect(request.url?.path == "/api/org_GQ6LhcfkW1TSinM6/billing/quota/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == "org_GQ6LhcfkW1TSinM6")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            return (200, #"{"daily_percentage":10,"weekly_percentage":20,"plan":"free"}"#)
        }
        defer { DevinURLProtocolStub.handler = nil }
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "secret-token",
            organization: "org/example-org",
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
            sourceLabel: "test"
        )

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            session: makeSession(),
            now: Self.now
        )

        #expect(snapshot.daily?.usedPercent == 10)
        #expect(snapshot.weekly?.usedPercent == 20)
        #expect(snapshot.planName == "Free")
    }

    @Test
    func fetchUsesSupportedOrganizationEnvironmentOverride() async throws {
        DevinURLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/org/environment-org/billing/quota/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer environment-token")
            return (200, #"{"daily_percentage":0}"#)
        }
        defer { DevinURLProtocolStub.handler = nil }

        let usage = try await DevinUsageFetcher.fetch(
            credential: "Bearer secret-token",
            source: .automatic,
            organization: "configured-org",
            session: makeSession(),
            environment: [
                "DEVIN_BEARER_TOKEN": "environment-token",
                "DEVIN_ORG": "environment-org",
            ]
        )

        #expect(usage.details.isEmpty)
    }

    @Test
    func successfulMalformedResponseDoesNotTryFallbackEndpoints() async {
        DevinURLProtocolStub.requests = []
        DevinURLProtocolStub.handler = { _ in (200, "{}") }
        defer {
            DevinURLProtocolStub.handler = nil
            DevinURLProtocolStub.requests = []
        }
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "secret-token",
            organization: "org/example-org",
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
            sourceLabel: "test"
        )

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(auth: auth, session: makeSession())
            Issue.record("Expected parsing to fail")
        } catch let error as DevinUsageError {
            guard case .parseFailed = error else {
                Issue.record("Expected parse failure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(DevinURLProtocolStub.requests.count == 1)
    }

    @Test
    func sessionImporterExtractsCurrentTokenAndMatchingOrganization() throws {
        let token = "auth1_abcdefghijklmnopqrstuvwxyz0123456789"
        let storage = [
            "_https://app.devin.ai\u{0000}\u{0001}auth1_session":
                #"{"token":"\#(token)","userId":"github|123"}"#,
            "_https://app.devin.ai\u{0000}\u{0001}last-internal-org-for-external-org-v1-example-org":
                "\"org_GQ6LhcfkW1TSinM6\"",
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: "example-org",
            sourceLabel: "Chrome Default"
        ))

        #expect(session.accessToken == token)
        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func sessionImporterInfersPostAuthOrganization() throws {
        let token = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJodHRwczovL2RldmluLmFpIn0.signature"
        let storage = [
            "_https://app.devin.ai\u{0000}\u{0001}@@auth0spajs@@::client::audience::scope":
                #"{"body":{"access_token":"\#(token)"}}"#,
            "_https://app.devin.ai\u{0000}\u{0001}post-auth-v3-null-github|123-org_name-example-org": """
            {"internalOrgId":"org_GQ6LhcfkW1TSinM6","orgName":"example-org"}
            """,
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            sourceLabel: "Chrome Default"
        ))

        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func sessionsDeduplicateAndRankRichestMetadataFirst() {
        let sessions = [
            DevinSessionImporter.SessionInfo(
                accessToken: "same-token",
                organization: nil,
                internalOrganizationID: nil,
                sourceLabel: "Chrome Default"
            ),
            DevinSessionImporter.SessionInfo(
                accessToken: "same-token",
                organization: "org/example",
                internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
                sourceLabel: "Chrome Profile 1"
            ),
            DevinSessionImporter.SessionInfo(
                accessToken: "other-token",
                organization: "org/other",
                internalOrganizationID: nil,
                sourceLabel: "Chrome Profile 2"
            ),
        ]

        let result = DevinSessionImporter.rankSessions(DevinSessionImporter.deduplicateSessions(sessions))

        #expect(result.map(\.sourceLabel) == ["Chrome Profile 1", "Chrome Profile 2"])
    }

    @Test
    func automaticImporterScansChromeProfilesOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = home.appending(path: "Library/Application Support/Google/Chrome/Default/Local Storage/leveldb")
        let brave = home.appending(path: "Library/Application Support/BraveSoftware/Brave-Browser/Default/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)

        let candidates = DevinSessionImporter.chromeLocalStorageCandidates(homeDirectories: [home])

        #expect(candidates.map(\.label) == ["Chrome Default", "Brave Default"])
        #expect(candidates.map { $0.url.resolvingSymlinksInPath() } == [chrome, brave].map { $0.resolvingSymlinksInPath() })
    }

    @Test
    func appImporterReadsEncryptedDesktopSessionFromDatabaseCopy() throws {
        let home = try Self.makeDevinAppHome(rows: [
            (Self.sessionsKey, try Self.encryptedSessions([["accessToken": "app-token"], ["accessToken": "app-token"]])),
            ("devin.desktopShell.lastOrg.org-ABCDEFGH12", "{}"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appending(path: "Library/Application Support/Devin/User/globalStorage/state.vscdb")
        let original = try Data(contentsOf: database)
        let directory = database.deletingLastPathComponent()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        let sessions = DevinAppSessionImporter(home: home, password: { "pw" })
            .importSessions(organizationOverride: nil)

        #expect(sessions == [DevinSessionImporter.SessionInfo(
            accessToken: "app-token",
            organization: "organizations/org-ABCDEFGH12",
            internalOrganizationID: "org-ABCDEFGH12",
            sourceLabel: "Devin app"
        )])
        // 只读临时副本，应用自己的数据库和目录保持原样。
        #expect(try Data(contentsOf: database) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == filesBefore)
    }

    @Test
    func appImporterSkipsKeychainWithoutValidEncryptedSession() throws {
        let home = try Self.makeDevinAppHome(rows: [
            (Self.sessionsKey, #"{"type":"Buffer","data":[1,2,3]}"#),
            (#"secret://{"key":"other"}"#, try Self.encryptedSessions([["accessToken": "other-token"]])),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let sessions = DevinAppSessionImporter(home: home, password: {
            Issue.record("没有合格的加密会话时不应读取钥匙串")
            return "pw"
        }).importSessions(organizationOverride: nil)

        #expect(sessions.isEmpty)
    }

    @Test
    func appSessionPayloadAndBufferValidation() {
        #expect(DevinAppSessionImporter.accessTokens(fromSessionsPayload: #"[{"accessToken":" a "},{"accessToken":"a"},{"id":1}]"#) == ["a"])
        #expect(DevinAppSessionImporter.bufferData(fromSecretValue: #"{"type":"Buffer","data":[true,false,true]}"#) == nil)
        #expect(DevinAppSessionImporter.isSessionKey(Self.sessionsKey))
        #expect(!DevinAppSessionImporter.isSessionKey("windsurf_auth.sessions"))
    }

    @Test
    func workingBrowserSessionNeverReadsDesktopKeychain() async throws {
        DevinURLProtocolStub.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer browser-token")
            return (200, #"{"daily_percentage":10}"#)
        }
        defer { DevinURLProtocolStub.handler = nil }

        let usage = try await DevinUsageFetcher.fetch(
            credential: "",
            source: .automatic,
            organization: "org_GQ6LhcfkW1TSinM6",
            session: makeSession(),
            environment: [:],
            browserSessions: { _ in [Self.browserSession] },
            appImporter: DevinAppSessionImporter(home: URL(fileURLWithPath: "/nonexistent"), password: {
                Issue.record("浏览器会话可用时不应读取 Devin 应用的钥匙串")
                return nil
            })
        )

        #expect(usage.windows.first?.usedFraction == 0.1)
    }

    @Test
    func rejectedBrowserSessionFallsBackToDesktopSession() async throws {
        let home = try Self.makeDevinAppHome(rows: [
            (Self.sessionsKey, try Self.encryptedSessions([["accessToken": "app-token"]])),
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        DevinURLProtocolStub.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer app-token"
                ? (200, #"{"daily_percentage":20}"#)
                : (401, "{}")
        }
        defer { DevinURLProtocolStub.handler = nil }

        let usage = try await DevinUsageFetcher.fetch(
            credential: "",
            source: .automatic,
            organization: "org_GQ6LhcfkW1TSinM6",
            session: makeSession(),
            environment: [:],
            browserSessions: { _ in [Self.browserSession] },
            appImporter: DevinAppSessionImporter(home: home, password: { "pw" })
        )

        #expect(usage.windows.first?.usedFraction == 0.2)
    }

    @Test
    func browserServiceErrorDoesNotReadDesktopSession() async throws {
        DevinURLProtocolStub.handler = { _ in (500, "{}") }
        defer { DevinURLProtocolStub.handler = nil }

        await #expect(throws: DevinUsageError.apiError("HTTP 500")) {
            _ = try await DevinUsageFetcher.fetch(
                credential: "",
                source: .automatic,
                organization: "org_GQ6LhcfkW1TSinM6",
                session: makeSession(),
                environment: [:],
                browserSessions: { _ in [Self.browserSession] },
                appImporter: DevinAppSessionImporter(home: URL(fileURLWithPath: "/nonexistent"), password: {
                    Issue.record("服务端错误时不应读取 Devin 应用的钥匙串")
                    return nil
                })
            )
        }
    }

    @Test
    func unreadableBrowserStorageSurfacesWhenDesktopHasNoSession() async {
        await #expect(throws: DevinUsageError.browserStorageUnreadable) {
            _ = try await DevinUsageFetcher.fetch(
                credential: "",
                source: .automatic,
                organization: nil,
                session: makeSession(),
                environment: [:],
                browserSessions: { _ in throw DevinUsageError.browserStorageUnreadable },
                appImporter: DevinAppSessionImporter(home: URL(fileURLWithPath: "/nonexistent"), password: { nil })
            )
        }
    }

    private static let sessionsKey = #"secret://{"extensionId":"devin.devin","key":"windsurf_auth.sessions"}"#

    private static let browserSession = DevinSessionImporter.SessionInfo(
        accessToken: "browser-token",
        organization: nil,
        internalOrganizationID: nil,
        sourceLabel: "Chrome Default"
    )

    private static func makeDevinAppHome(rows: [(String, String)]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = home.appending(path: "Library/Application Support/Devin/User/globalStorage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.appending(path: "state.vscdb").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);", nil, nil, nil) == SQLITE_OK)
        for (key, value) in rows {
            let sql = "INSERT INTO ItemTable VALUES ('\(key.replacingOccurrences(of: "'", with: "''"))', '\(value.replacingOccurrences(of: "'", with: "''"))');"
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        return home
    }

    // 按 Electron Buffer 的 JSON 格式存放 v10 加密后的会话列表。
    private static func encryptedSessions(_ sessions: [[String: String]]) throws -> String {
        let plaintext = try JSONSerialization.data(withJSONObject: sessions)
        let key = ChromiumSafeStorage.deriveKey(from: "pw")
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = out.count
        var length = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            plaintext.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, plaintext.count, outBytes.baseAddress, capacity, &length
                        )
                    }
                }
            }
        }
        try #require(status == kCCSuccess)
        out.count = length
        let bytes = Array(Data("v10".utf8) + out)
        let buffer = try JSONSerialization.data(withJSONObject: ["type": "Buffer", "data": bytes.map(Int.init)])
        return String(decoding: buffer, as: UTF8.self)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class DevinURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
