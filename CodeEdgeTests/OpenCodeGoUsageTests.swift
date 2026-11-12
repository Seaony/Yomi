import Foundation
import SQLite3
import Testing
@testable import CodeEdge

struct OpenCodeGoUsageTests {
    // 记录请求走的是接口（/zen/go/v1/usage）还是网页会话（/_server 等），返回 500 让抓取直接结束。
    private static func requestedPaths(
        credential: String, source: ProviderSource, localKey: String?, browserCookie: String?, webStatus: Int = 500
    ) async -> [String] {
        // 上一次调用里没跑完的请求可能晚到，用标记只统计这次调用的请求。
        let call = UUID().uuidString
        OpenCodeGoRecordingURLProtocol.setWebStatus(webStatus)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeGoRecordingURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Call": call]
        _ = try? await OpenCodeGoUsageFetcher.fetch(
            credential: credential, source: source, workspaceID: "wrk_1",
            session: URLSession(configuration: configuration),
            localAPIKey: { localKey }, browserCookie: { browserCookie }
        )
        return OpenCodeGoRecordingURLProtocol.paths(for: call)
    }

    @Test
    func configuredSourceDecidesTheRequestPath() async {
        let api = "/zen/go/v1/usage"
        // 选 API Key：即使浏览器有会话也只走接口。
        #expect(await Self.requestedPaths(credential: "", source: .token, localKey: "cli-key", browserCookie: "auth=x") == [api])
        // 选 Cookie：即使有 CLI 登录也只走网页会话。
        let cookiePaths = await Self.requestedPaths(credential: "", source: .cookie, localKey: "cli-key", browserCookie: "auth=x")
        #expect(!cookiePaths.isEmpty && !cookiePaths.contains(api))
        // 自动：浏览器会话排在 CLI 登录前面；都没有时才用 CLI 登录。
        let auto = await Self.requestedPaths(credential: "", source: .automatic, localKey: "cli-key", browserCookie: "auth=x")
        #expect(!auto.isEmpty && !auto.contains(api))
        #expect(await Self.requestedPaths(credential: "", source: .automatic, localKey: "cli-key", browserCookie: nil) == [api])
        // 自动且手动填了 Key：直接用它。
        #expect(await Self.requestedPaths(credential: "sk-manual", source: .automatic, localKey: nil, browserCookie: "auth=x") == [api])
        // 浏览器会话已失效（401）时，接着用 CLI 登录。
        let expired = await Self.requestedPaths(
            credential: "", source: .automatic, localKey: "cli-key", browserCookie: "auth=x", webStatus: 401
        )
        #expect(expired.last == api)
    }

    @Test
    func parsesAuthoritativeAPIWindowsAsPercentUnits() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"{"usage":{"rolling":{"usagePercent":0.25,"resetInSec":600},"weekly":{"usagePercent":75,"resetInSec":7200},"monthly":{"usagePercent":90,"resetInSec":86400}}}"#.utf8)

        let usage = try OpenCodeGoUsageFetcher.parseAPI(data: data, now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.0025, 0.75, 0.9])
    }

    @Test
    func parsesWebFractionsAndOptionalMonthlyWindow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "usage": [
                "rollingUsage": ["usagePercent": 0.25, "resetInSec": 600],
                "weeklyUsage": ["window": ["usagePercent": 0.75, "resetInSec": 7200]],
            ],
        ])

        let usage = try OpenCodeGoUsageFetcher.parseWeb(text: String(decoding: data, as: UTF8.self), now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.75])
    }

    @Test
    func parsesHydrationPayloadWithAllThreeWindows() throws {
        let text = "$R[24]($R[18],$R[27]={rollingUsage:$R[28]={resetInSec:17591,usagePercent:17},"
            + "weeklyUsage:$R[29]={resetInSec:444552,usagePercent:75},"
            + "monthlyUsage:$R[30]={resetInSec:2591424,usagePercent:91}});"

        let usage = try OpenCodeGoUsageFetcher.parseWeb(text: text, now: .distantPast)

        #expect(usage.windows.map(\.usedFraction) == [0.17, 0.75, 0.91])
    }

    @Test
    func parsesExplicitAndScaledZenBalances() {
        #expect(OpenCodeGoUsageFetcher.parseZenBalance(text: "現在の残高 $1,234.56") == 1234.56)
        let billing = #"$R[0]={customerID:"cus_test",balance:$R[2]=2375000000,reload:!1}"#
        #expect(OpenCodeGoUsageFetcher.parseBillingBalance(text: billing) == 23.75)
        #expect(OpenCodeGoUsageFetcher.parseBillingBalance(text: #"{"balance":100}"#) == nil)
    }

    @Test
    func normalizesDocumentedAPIKeyEnvironmentFormat() {
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("  go_test  ") == "go_test")
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("'go_quoted'") == "go_quoted")
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("  ").isEmpty)
        #expect(ProviderCatalog.byID[ProviderID(rawValue: "opencodego")]?.environmentKeys == ["OPENCODE_API_KEY"])
    }

    @Test
    func renewalIsAdditionalMetadataNotQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let renewal = "2030-01-02T03:04:05.000Z"
        let data = Data(#"{"renewAt":"\#(renewal)","usage":{"rolling":{"usagePercent":10,"resetInSec":600}}}"#.utf8)

        let usage = try OpenCodeGoUsageFetcher.parseAPI(data: data, now: now)

        #expect(usage.windows.count == 1)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func localDatabaseRowsOnlyAddVerifiableCostAndRequestCounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = ProviderUsage(
            id: ProviderID(rawValue: "opencodego"), state: .ready,
            windows: [UsageWindow(
                id: "opencodego-rolling", label: "5-hour", usedFraction: 0.2,
                resetsAt: nil, detail: nil
            )],
            updatedAt: now
        )
        let rows = OpenCodeGoLocalUsageReader.parseRows(
            "1799996400000\t1.25\t2\n1797580800000\t3.50\t1\ninvalid\trow\t0\n"
        )

        let enriched = OpenCodeGoLocalUsageReader.enrich(original, rows: rows, now: now)

        #expect(enriched.windows == original.windows)
        #expect(enriched.today == nil)
        #expect(enriched.last30Days == nil)
        let combined = UsageStore.combinedLast30DaysUsage([enriched])
        #expect(combined?.tokens == 0)
        #expect(combined?.valueUSD == 4.75)
        let daily = UsageStore.overviewDailyUsage(usages: [enriched], now: now)
        #expect(daily.last?.usage.tokens == 0)
        #expect(daily.last?.usage.valueUSD == 1.25)
        #expect(enriched.todayDate == now)
        #expect(enriched.todayRequests?.requests == 2)
        #expect(enriched.todayRequests?.valueUSD == 1.25)
        #expect(enriched.last30DaysRequests?.requests == 3)
        #expect(enriched.last30DaysRequests?.valueUSD == 4.75)
    }

    @Test(arguments: [false, true])
    func localDatabaseReadsV2SessionMessagesOnce(withLegacyTables: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yomi-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "opencode.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        func execute(_ sql: String) {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        let created = 1_800_000_000_000
        func v2(_ id: String, type: String, provider: String, cost: Double) -> String {
            """
            INSERT INTO session_message VALUES ('\(id)', '\(type)', \(created), '{"time":{"created":\(created)},\
            "cost":\(cost),"model":{"providerID":"\(provider)","id":"glm"},"tokens":{"input":10,"output":5,\
            "reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        }
        execute("CREATE TABLE session_message (id TEXT, type TEXT, time_created INTEGER, data TEXT)")
        execute(v2("m1", type: "assistant", provider: "opencode-go", cost: 1))
        execute(v2("m2", type: "compaction", provider: "opencode-go", cost: 0.5))
        execute(v2("m3", type: "assistant", provider: "other", cost: 9))
        execute(v2("m4", type: "user", provider: "opencode-go", cost: 9))
        if withLegacyTables {
            execute("CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT)")
            execute("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
            execute("""
            INSERT INTO message VALUES ('m1', \(created), '{"providerID":"opencode-go","role":"assistant",\
            "cost":2,"tokens":{"input":20,"output":10,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """)
            // 旧表金额溢出成无穷大时不能挡住 v2 的有效记录。
            execute("""
            INSERT INTO message VALUES ('m2', \(created), '{"providerID":"opencode-go","role":"assistant",\
            "cost":1e999}');
            """)
        }
        sqlite3_close(handle)

        let rows = try #require(OpenCodeGoLocalUsageReader.readRows(
            since: Date(timeIntervalSince1970: 1_799_000_000), database: database
        ))
        #expect(rows.count == 2)
        #expect(rows.map(\.cost).reduce(0, +) == (withLegacyTables ? 2.5 : 1.5))
        #expect(rows.compactMap(\.tokens).reduce(0, +) == (withLegacyTables ? 45 : 30))
    }

    @Test
    func cliCredentialPrefersActiveDatabaseLoginOverLegacyAuthFile() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "yomi-opencode-\(UUID().uuidString)")
        let directory = home.appending(path: ".local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"opencode-go":{"type":"api","key":"legacy-key"}}"#.utf8)
            .write(to: directory.appending(path: "auth.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OpenCodeGoLocalUsageReader.cliCredential(environment: [:], homeDirectory: home, now: now) == "legacy-key")

        var handle: OpaquePointer?
        #expect(sqlite3_open(directory.appending(path: "opencode.db").path, &handle) == SQLITE_OK)
        func execute(_ sql: String) {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("CREATE TABLE credential (integration_id TEXT, active INTEGER, value TEXT)")
        execute(#"INSERT INTO credential VALUES ('opencode', 1, '{"type":"key","key":"shared-key"}')"#)
        execute(#"INSERT INTO credential VALUES ('opencode-go', 0, '{"type":"key","key":"inactive"}')"#)
        #expect(OpenCodeGoLocalUsageReader.cliCredential(environment: [:], homeDirectory: home, now: now) == "shared-key")

        execute("""
        INSERT INTO credential VALUES ('opencode-go', 1, '{"type":"oauth","access":"go-access","expires":1800000060000}')
        """)
        #expect(OpenCodeGoLocalUsageReader.cliCredential(environment: [:], homeDirectory: home, now: now) == "go-access")
        // 登录过期后不回退到其他凭据，交给用户重新登录。
        #expect(OpenCodeGoLocalUsageReader.cliCredential(
            environment: [:], homeDirectory: home, now: now.addingTimeInterval(120)
        ) == nil)

        execute(#"DELETE FROM credential"#)
        sqlite3_close(handle)
        #expect(OpenCodeGoLocalUsageReader.cliCredential(environment: [:], homeDirectory: home, now: now) == nil)
    }
}


private nonisolated final class OpenCodeGoRecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(call: String, path: String)] = []
    nonisolated(unsafe) private static var webStatus = 500
    static func paths(for call: String) -> [String] { lock.withLock { recorded.filter { $0.call == call }.map(\.path) } }
    static func setWebStatus(_ status: Int) { lock.withLock { webStatus = status } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let status = Self.lock.withLock {
            Self.recorded.append((request.value(forHTTPHeaderField: "X-Test-Call") ?? "", path))
            return path == "/zen/go/v1/usage" ? 500 : Self.webStatus
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
