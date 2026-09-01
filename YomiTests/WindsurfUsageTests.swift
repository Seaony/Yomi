import Foundation
import SQLite3
import SweetCookieKit
import Testing
@testable import Yomi

@Suite(.serialized)
struct WindsurfUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_770_000_000)

    @Test
    func parsesManualJSONAndKeyValueAliases() throws {
        let json = try WindsurfUsageFetcher.parseManualSessionInput("""
        {
          "devinSessionToken": "session-json",
          "devinAuth1Token": "auth-json",
          "devinAccountId": "account-json",
          "devinPrimaryOrgId": "org-json"
        }
        """)
        #expect(json == WindsurfSessionAuth(
            sessionToken: "session-json",
            auth1Token: "auth-json",
            accountID: "account-json",
            primaryOrgID: "org-json"
        ))

        let keyValue = try WindsurfUsageFetcher.parseManualSessionInput("""
        devin_session_token=session-kv
        devin_auth1_token=auth-kv
        devin_account_id=account-kv
        devin_primary_org_id=org-kv
        """)
        #expect(keyValue.sessionToken == "session-kv")
        #expect(keyValue.auth1Token == "auth-kv")
        #expect(keyValue.accountID == "account-kv")
        #expect(keyValue.primaryOrgID == "org-kv")
    }

    @Test
    func rejectsEmptyInvalidAndIncompleteManualSessions() {
        #expect(throws: WindsurfUsageError.self) {
            try WindsurfUsageFetcher.parseManualSessionInput("  \n")
        }
        #expect(throws: WindsurfUsageError.self) {
            try WindsurfUsageFetcher.parseManualSessionInput("not a session")
        }
        #expect(throws: WindsurfUsageError.self) {
            try WindsurfUsageFetcher.parseManualSessionInput(#"{"devin_session_token":"only-one"}"#)
        }
    }

    @Test
    func localStorageOriginsAndDecodedValuesMatchReference() {
        #expect(WindsurfSessionImporter.localStorageOrigins.map(\.absoluteString) == [
            "https://app.devin.ai", "https://windsurf.com",
        ])
        #expect(WindsurfSessionImporter.preferredBrowsers == [.chrome])
        #expect(!WindsurfSessionImporter.fallbackBrowsers.contains(.chrome))
        #expect(WindsurfSessionImporter.decodedStorageValue(#""quoted-session""#) == "quoted-session")
        #expect(WindsurfSessionImporter.decodedStorageValue(" plain-session ") == "plain-session")
    }

    @Test
    func keepsStructuredOriginsSeparateAndAppendsTextFallback() throws {
        let appOrigin = try #require(URL(string: "https://app.devin.ai"))
        let legacyOrigin = try #require(URL(string: "https://windsurf.com"))
        let snapshots = WindsurfSessionImporter.localStorageSnapshots(
            from: [
                .init(origin: appOrigin, entries: [
                    Self.entry(origin: appOrigin, key: "devin_session_token", value: "partial-session"),
                    Self.entry(origin: appOrigin, key: "devin_auth1_token", value: "partial-auth"),
                ]),
                .init(origin: legacyOrigin, entries: Self.entries(
                    origin: legacyOrigin,
                    prefix: "legacy"
                )),
            ],
            textEntries: Self.textEntries(prefix: "text")
        )

        #expect(snapshots.count == 2)
        #expect(snapshots[0].sourceSuffix == "windsurf.com")
        #expect(snapshots[0].storage["devin_session_token"] == "legacy-session")
        #expect(snapshots[1].sourceSuffix == nil)
        #expect(snapshots[1].storage["devin_session_token"] == "text-session")
    }

    @Test
    func requiresCompleteStorageAndDeduplicatesBySessionToken() {
        #expect(WindsurfSessionImporter.session(
            from: ["devin_session_token": "partial"],
            sourceLabel: "partial"
        ) == nil)
        let first = Self.sessionInfo(token: "same", source: "Chrome Default")
        let repeated = WindsurfSessionImporter.SessionInfo(
            session: .init(
                sessionToken: "same",
                auth1Token: "other-auth",
                accountID: "other-account",
                primaryOrgID: "other-org"
            ),
            sourceLabel: "Chrome Profile 1"
        )
        let second = Self.sessionInfo(token: "different", source: "Chrome Profile 2")
        let sessions = WindsurfSessionImporter.deduplicateSessions([first, repeated, second])
        #expect(sessions.map(\.sourceLabel) == ["Chrome Default", "Chrome Profile 2"])
    }

    @Test
    func cachedQuotaMapsDailyWeeklyResetAndPlan() throws {
        let info = try Self.decodeCached("""
        {
          "planName":"Pro",
          "endTimestamp":1774029950000,
          "usage":{"messages":50000,"usedMessages":35650,"remainingMessages":14350},
          "quotaUsage":{
            "dailyRemainingPercent":9,
            "weeklyRemainingPercent":54,
            "dailyResetAtUnix":1774080000,
            "weeklyResetAtUnix":1774166400
          }
        }
        """)
        let usage = info.toProviderUsage(now: Self.now)
        #expect(usage.windows.map(\.label) == ["Daily", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.91, 0.46])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_774_080_000))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_774_166_400))
        #expect(usage.plan == "Pro")
        #expect(usage.details.isEmpty)
        #expect(usage.updatedAt == Self.now)
    }

    @Test
    func cachedCountersSupplyMissingQuotaWindowsAndInferUsedFromRemaining() throws {
        let info = try Self.decodeCached("""
        {
          "planName":"Pro",
          "usage":{
            "messages":100,"remainingMessages":25,
            "flowActions":150000,"usedFlowActions":0,"remainingFlowActions":150000
          }
        }
        """)
        let usage = info.toProviderUsage(now: Self.now)
        #expect(usage.windows.map(\.usedFraction) == [0.75, 0])
        #expect(usage.windows.map(\.detail) == ["75 / 100 messages", "0 / 150000 flow actions"])
    }

    @Test
    func cachedQuotaWinsPerLaneAndClampsPercentages() throws {
        let info = try Self.decodeCached("""
        {
          "usage":{
            "messages":100,"usedMessages":25,
            "flowActions":10,"usedFlowActions":5
          },
          "quotaUsage":{"dailyRemainingPercent":-20}
        }
        """)
        let usage = info.toProviderUsage(now: Self.now)
        #expect(usage.windows.map(\.usedFraction) == [1, 0.5])
        #expect(usage.windows[0].detail == nil)
        #expect(usage.windows[1].detail == "5 / 10 flow actions")
        #expect(WindsurfUsageFetcher.clampedUsedPercent(fromRemaining: 120) == 0)
    }

    @Test
    func readsUTF8AndUTF16SQLiteBlobs() throws {
        for (name, data) in [
            ("UTF-8 Pro", Data(#"{"planName":"UTF-8 Pro"}"#.utf8)),
            ("UTF-16 Pro", try #require(#"{"planName":"UTF-16 Pro"}"#.data(using: .utf16LittleEndian))),
        ] {
            let databaseURL = try Self.makeDatabase(value: data)
            defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
            let info = try WindsurfStatusProbe(databaseURL: databaseURL).fetch()
            #expect(info.planName == name)
        }
    }

    @Test
    func localProbeReportsMissingDatabaseAndMissingPlanRow() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("windsurf-missing-\(UUID().uuidString).vscdb")
        #expect(throws: WindsurfUsageError.self) {
            try WindsurfStatusProbe(databaseURL: missing).fetch()
        }

        let databaseURL = try Self.makeDatabase(value: nil)
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        #expect(throws: WindsurfUsageError.noCachedPlan) {
            try WindsurfStatusProbe(databaseURL: databaseURL).fetch()
        }
    }

    @Test
    func protobufRequestRoundTripsRequiredFields() throws {
        let data = WindsurfPlanStatusProtoCodec.encodeRequest(
            authToken: "devin-session-token$abc",
            includeTopUpStatus: true
        )
        let request = try WindsurfPlanStatusProtoCodec.decodeRequest(data)
        #expect(request.authToken == "devin-session-token$abc")
        #expect(request.includeTopUpStatus)
    }

    @Test
    func protobufResponseMapsPlanQuotaAndReset() throws {
        let response = try WindsurfPlanStatusProtoCodec.decodeResponse(Self.makePlanStatusResponse(
            planName: "Teams",
            dailyRemaining: 68,
            weeklyRemaining: 84,
            planEndUnix: 1_777_888_000,
            dailyResetUnix: 1_777_900_000,
            weeklyResetUnix: 1_778_000_000
        ))
        let usage = response.toProviderUsage(now: Self.now)
        #expect(usage.plan == "Teams")
        #expect(usage.windows.map(\.usedFraction) == [0.32, 0.16])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_777_900_000))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_778_000_000))
        #expect(usage.details.isEmpty)
    }

    @Test
    func webRequestMatchesConnectProtocolAndMapsResponse() async throws {
        let session = Self.stubSession { request in
            #expect(request.url == WindsurfUsageFetcher.getPlanStatusURL)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/proto")
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://windsurf.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://windsurf.com/profile")
            #expect(request.value(forHTTPHeaderField: "x-auth-token") == "session")
            #expect(request.value(forHTTPHeaderField: "x-devin-session-token") == "session")
            #expect(request.value(forHTTPHeaderField: "x-devin-auth1-token") == "auth")
            #expect(request.value(forHTTPHeaderField: "x-devin-account-id") == "account")
            #expect(request.value(forHTTPHeaderField: "x-devin-primary-org-id") == "org")
            let body = try WindsurfPlanStatusProtoCodec.decodeRequest(Self.requestBodyData(from: request))
            #expect(body.authToken == "session")
            #expect(body.includeTopUpStatus)
            return (200, Self.makePlanStatusResponse(
                planName: "Pro",
                dailyRemaining: 70,
                weeklyRemaining: 85,
                planEndUnix: 1_777_888_000,
                dailyResetUnix: 1_777_900_000,
                weeklyResetUnix: 1_778_000_000
            ))
        }
        defer { WindsurfTestURLProtocol.handler = nil }
        let usage = try await WindsurfUsageFetcher.fetchWeb(
            auth: .init(
                sessionToken: "session",
                auth1Token: "auth",
                accountID: "account",
                primaryOrgID: "org"
            ),
            session: session,
            now: Self.now
        )
        #expect(usage.plan == "Pro")
        #expect(usage.windows.map(\.usedFraction) == [0.3, 0.15])
    }

    @Test
    func importedSessionsRetryOnlyRecoverableAuthenticationFailures() async throws {
        WindsurfTestURLProtocol.requests = []
        let session = Self.stubSession { request in
            let token = request.value(forHTTPHeaderField: "x-devin-session-token")
            if token == "stale" { return (401, Data("unauthorized".utf8)) }
            return (200, Self.makePlanStatusResponse(
                planName: "Teams",
                dailyRemaining: 75,
                weeklyRemaining: 90,
                planEndUnix: 1_777_888_000,
                dailyResetUnix: 1_777_900_000,
                weeklyResetUnix: 1_778_000_000
            ))
        }
        defer {
            WindsurfTestURLProtocol.handler = nil
            WindsurfTestURLProtocol.requests = []
        }
        let usage = try await WindsurfUsageFetcher.fetchWeb(
            sessions: [
                Self.sessionInfo(token: "stale", source: "Chrome Default"),
                Self.sessionInfo(token: "fresh", source: "Chrome Profile 1"),
            ],
            session: session,
            now: Self.now
        )
        #expect(WindsurfTestURLProtocol.requests.count == 2)
        #expect(usage.plan == "Teams")
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.1])
    }

    @Test
    func webFailureIncludesStatusAndBodySnippet() async {
        let session = Self.stubSession { _ in (403, Data("denied".utf8)) }
        defer { WindsurfTestURLProtocol.handler = nil }
        await #expect(throws: WindsurfUsageError.requestFailed("HTTP 403: denied")) {
            try await WindsurfUsageFetcher.fetchWeb(
                auth: Self.sessionInfo(token: "bad", source: "manual").session,
                session: session
            )
        }
    }

    @Test
    func automaticSourceFallsBackToSQLiteWhenBrowserSessionIsAbsent() async throws {
        let emptyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("windsurf-empty-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let databaseURL = try Self.makeDatabase(value: Data(#"{"planName":"Local Pro","usage":{"messages":100,"usedMessages":20}}"#.utf8))
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let usage = try await WindsurfUsageFetcher.fetch(
            source: .automatic,
            manualSessionInput: nil,
            session: URLSession(configuration: .ephemeral),
            homeDirectories: [emptyHome],
            databaseURL: databaseURL,
            now: Self.now
        )
        #expect(usage.plan == "Local Pro")
        #expect(usage.windows.map(\.usedFraction) == [0.2])
    }

    @Test
    func automaticUsageWithManualSessionFallsBackToSQLite() async throws {
        let databaseURL = try Self.makeDatabase(value: Data(#"{"planName":"Fallback Local"}"#.utf8))
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let session = Self.stubSession { _ in (401, Data("expired".utf8)) }
        defer { WindsurfTestURLProtocol.handler = nil }
        let usage = try await WindsurfUsageFetcher.fetch(
            dataSource: .automatic,
            sessionSource: .manual,
            manualSessionInput: """
            devin_session_token=expired
            devin_auth1_token=expired-auth
            devin_account_id=expired-account
            devin_primary_org_id=expired-org
            """,
            session: session,
            databaseURL: databaseURL,
            now: Self.now
        )
        #expect(usage.plan == "Fallback Local")
    }

    @Test
    func explicitWebModeDoesNotFallBackToSQLite() async throws {
        let databaseURL = try Self.makeDatabase(value: Data(#"{"planName":"Must Not Be Used"}"#.utf8))
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        await #expect(throws: WindsurfUsageError.noSession) {
            try await WindsurfUsageFetcher.fetch(
                dataSource: .web,
                sessionSource: .off,
                manualSessionInput: nil,
                session: URLSession(configuration: .ephemeral),
                databaseURL: databaseURL,
                now: Self.now
            )
        }
    }

    @Test
    func cookieSourceDoesNotFallBackWhenManualBundleIsEmpty() async throws {
        let databaseURL = try Self.makeDatabase(value: Data(#"{"planName":"Local Pro"}"#.utf8))
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        await #expect(throws: WindsurfUsageError.self) {
            try await WindsurfUsageFetcher.fetch(
                source: .cookie,
                manualSessionInput: "",
                session: URLSession(configuration: .ephemeral),
                databaseURL: databaseURL
            )
        }
    }

    private static func decodeCached(_ json: String) throws -> WindsurfCachedPlanInfo {
        try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(json.utf8))
    }

    private static func sessionInfo(token: String, source: String) -> WindsurfSessionImporter.SessionInfo {
        .init(
            session: .init(
                sessionToken: token,
                auth1Token: "auth-\(token)",
                accountID: "account-\(token)",
                primaryOrgID: "org-\(token)"
            ),
            sourceLabel: source
        )
    }

    private static func entry(origin: URL, key: String, value: String) -> ChromiumLocalStorageEntry {
        ChromiumLocalStorageEntry(
            origin: origin.absoluteString,
            key: key,
            value: value,
            rawValueLength: value.utf8.count
        )
    }

    private static func entries(origin: URL, prefix: String) -> [ChromiumLocalStorageEntry] {
        [
            entry(origin: origin, key: "devin_session_token", value: "\(prefix)-session"),
            entry(origin: origin, key: "devin_auth1_token", value: "\(prefix)-auth"),
            entry(origin: origin, key: "devin_account_id", value: "\(prefix)-account"),
            entry(origin: origin, key: "devin_primary_org_id", value: "\(prefix)-org"),
        ]
    }

    private static func textEntries(prefix: String) -> [ChromiumLevelDBTextEntry] {
        [
            .init(key: "devin_session_token", value: "\(prefix)-session"),
            .init(key: "devin_auth1_token", value: "\(prefix)-auth"),
            .init(key: "devin_account_id", value: "\(prefix)-account"),
            .init(key: "devin_primary_org_id", value: "\(prefix)-org"),
        ]
    }

    private static func makeDatabase(value: Data?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("windsurf-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw SQLiteFixtureError.open }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw SQLiteFixtureError.create }
        guard let value else { return url }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO ItemTable(key, value) VALUES('windsurf.settings.cachedPlanInfo', ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw SQLiteFixtureError.prepare }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(value.count), transient)
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteFixtureError.insert
        }
        return url
    }

    private static func stubSession(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
    ) -> URLSession {
        WindsurfTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WindsurfTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func makePlanStatusResponse(
        planName: String,
        dailyRemaining: Int,
        weeklyRemaining: Int,
        planEndUnix: Int64,
        dailyResetUnix: Int64,
        weeklyResetUnix: Int64
    ) -> Data {
        let planInfo = message([stringField(2, planName)])
        let planStatus = message([
            messageField(1, planInfo),
            messageField(3, message([varintField(1, UInt64(planEndUnix))])),
            varintField(14, UInt64(dailyRemaining)),
            varintField(15, UInt64(weeklyRemaining)),
            varintField(17, UInt64(dailyResetUnix)),
            varintField(18, UInt64(weeklyResetUnix)),
        ])
        return message([messageField(1, planStatus)])
    }

    private static func message(_ fields: [Data]) -> Data {
        fields.reduce(into: Data()) { $0.append($1) }
    }

    private static func stringField(_ number: Int, _ value: String) -> Data {
        lengthDelimitedField(number, Data(value.utf8))
    }

    private static func messageField(_ number: Int, _ value: Data) -> Data {
        lengthDelimitedField(number, value)
    }

    private static func lengthDelimitedField(_ number: Int, _ value: Data) -> Data {
        message([fieldKey(number, wireType: 2), varint(UInt64(value.count)), value])
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        message([fieldKey(number, wireType: 0), varint(value)])
    }

    private static func fieldKey(_ number: Int, wireType: UInt64) -> Data {
        varint(UInt64((number << 3) | Int(wireType)))
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var data = Data()
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7f) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
        return data
    }

    private enum SQLiteFixtureError: Error {
        case open
        case create
        case prepare
        case insert
    }
}

private final class WindsurfTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/proto"]
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
