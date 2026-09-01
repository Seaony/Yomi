import Foundation
import Testing
@testable import Yomi

@Suite("Notion usage", .serialized)
struct NotionUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)
    private static let periodEndMilliseconds = 1_788_000_000_000.0
    private static let businessSpaceID = "11111111-2222-3333-4444-555555555555"
    private static let personalSpaceID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    private static let userID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test
    func parsesRateLimitAndMapsOnlyRealWindows() throws {
        let status = try NotionUsageParser.parseRateLimitStatus(Data(Self.rateLimit.utf8))
        let account = try NotionUsageParser.parseSpaces(Data(Self.spaces.utf8))
        let workspace = try #require(account.resolveWorkspace())
        let snapshot = NotionUsageSnapshot(
            rateLimit: status,
            workspace: workspace,
            account: account,
            updatedAt: Self.now
        )
        let usage = snapshot.toProviderUsage()

        #expect(status.status == "within_limit")
        #expect(status.enforcement == "preview")
        #expect(status.window?.window == "6h")
        #expect(usage.windows.map(\.id) == ["notion-rolling", "notion-monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.425, 0.18])
        #expect(usage.windows[0].resetsAt == Self.now.addingTimeInterval(12_600))
        #expect(usage.windows[1].resetsAt?.timeIntervalSince1970 == Self.periodEndMilliseconds / 1_000)
        #expect(usage.plan == "Business")
        #expect(usage.balance == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.isEmpty)
    }

    @Test
    func parsesSpacesAndChoosesAllowanceWorkspace() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spaces.utf8))

        #expect(account.userID == Self.userID)
        #expect(account.email == "person@example.com")
        #expect(account.name == "Example Person")
        #expect(account.workspaces.count == 2)
        #expect(account.resolveWorkspace()?.id == Self.businessSpaceID)
    }

    @Test
    func workspaceOverrideAcceptsDashedAndUndashedIDs() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spaces.utf8))
        let undashed = Self.personalSpaceID.replacingOccurrences(of: "-", with: "")

        #expect(account.resolveWorkspace(preferredID: Self.personalSpaceID)?.id == Self.personalSpaceID)
        #expect(account.resolveWorkspace(preferredID: undashed)?.id == Self.personalSpaceID)
        #expect(account.resolveWorkspace(preferredID: "00000000-0000-0000-0000-000000000000")?.id
            == Self.businessSpaceID)
    }

    @Test
    func fallsBackToFirstWorkspaceWhenNoPlanHasAllowance() {
        let account = NotionAccount(
            userID: Self.userID,
            email: nil,
            name: nil,
            workspaces: [NotionWorkspace(
                id: Self.personalSpaceID,
                name: "Personal",
                planType: "personal",
                subscriptionTier: "free"
            )]
        )
        #expect(account.resolveWorkspace()?.id == Self.personalSpaceID)
    }

    @Test
    func parsesSinglyWrappedRecords() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.singlyWrappedSpaces.utf8))
        #expect(account.email == "legacy@example.com")
        #expect(account.workspaces.count == 1)
        #expect(account.workspaces.first?.name == "Acme")
    }

    @Test
    func refusesAmbiguousOrNonObjectSpacesPayloads() {
        let second = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        let ambiguous = """
        {"\(Self.userID)":{"notion_user":{"\(Self.userID)":{"value":{"value":{"id":"\(Self.userID)"}}}}},
         "\(second)":{"notion_user":{"\(second)":{"value":{"value":{"id":"\(second)"}}}}}}
        """
        #expect(throws: NotionUsageError.parseFailed("getSpaces response did not identify a single user.")) {
            try NotionUsageParser.parseSpaces(Data(ambiguous.utf8))
        }
        #expect(throws: NotionUsageError.parseFailed("getSpaces response is not a JSON object.")) {
            try NotionUsageParser.parseSpaces(Data("[]".utf8))
        }
    }

    @Test
    func notApplicableAndEmptySuccessRemainDistinct() throws {
        let notApplicable = try NotionUsageParser.parseRateLimitStatus(
            Data(#"{"status":"not_applicable"}"#.utf8)
        )
        #expect(notApplicable.isNotApplicable)
        #expect(notApplicable.window == nil)
        #expect(throws: NotionUsageError.parseFailed(
            "getCreditRateLimitStatus returned no usage windows."
        )) {
            try NotionUsageParser.parseRateLimitStatus(
                Data(#"{"errorId":"abc","name":"UnauthorizedError"}"#.utf8)
            )
        }
    }

    @Test
    func strictRateLimitTypesFailParsing() {
        #expect(throws: NotionUsageError.self) {
            try NotionUsageParser.parseRateLimitStatus(Data(
                #"{"status":"within_limit","window":{"used":"42","limit":100}}"#.utf8
            ))
        }
    }

    @Test
    func usageScalesAgainstLimitAndPreservesOverage() {
        #expect(NotionUsageSnapshot.fraction(used: 25, limit: 50) == 0.5)
        #expect(NotionUsageSnapshot.fraction(used: 120, limit: 100) == 1.2)
        #expect(NotionUsageSnapshot.fraction(used: -5, limit: 100) == 0)
        #expect(NotionUsageSnapshot.fraction(used: nil, limit: 100) == nil)
        #expect(NotionUsageSnapshot.fraction(used: 42, limit: 0) == nil)
        #expect(NotionUsageSnapshot.fraction(used: 42, limit: nil) == nil)
    }

    @Test
    func missingLimitsNeverCreateZeroPercentWindows() throws {
        let status = try NotionUsageParser.parseRateLimitStatus(Data(
            #"{"status":"within_limit","window":{"window":"6h","used":42},"resetsInSeconds":60}"#.utf8
        ))
        let usage = NotionUsageSnapshot(
            rateLimit: status,
            workspace: nil,
            account: nil,
            updatedAt: Self.now
        ).toProviderUsage()
        #expect(usage.windows.isEmpty)
    }

    @Test(arguments: [
        ("6h", 360), ("30m", 30), ("7d", 10_080), ("1w", 10_080),
    ])
    func convertsWindowTokens(token: String, minutes: Int) {
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: token) == minutes)
    }

    @Test
    func dropsRollingLengthThatCollidesWithMonthlySentinel() {
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "30d") == 43_200)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "30d") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "720h") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "43200m") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "6h") == 360)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "weekly") == nil)
    }

    @Test
    func resetParsingKeepsZeroAndRejectsInvalidValues() {
        #expect(NotionUsageSnapshot.rollingReset(from: 0, now: Self.now) == Self.now)
        #expect(NotionUsageSnapshot.rollingReset(from: -1, now: Self.now) == nil)
        #expect(NotionUsageSnapshot.date(fromMilliseconds: 0) == nil)
    }

    @Test
    func manualInputAcceptsCookieHeaderAndBareToken() {
        #expect(NotionUsageFetcher.requestContext(
            from: "token_v2=abc; notion_user_id=def"
        )?.cookieHeader == "token_v2=abc; notion_user_id=def")
        #expect(NotionUsageFetcher.requestContext(from: "Cookie: token_v2=abc")?.cookieHeader == "token_v2=abc")
        #expect(NotionUsageFetcher.requestContext(from: "bare-token-value")?.cookieHeader
            == "token_v2=bare-token-value")
        #expect(NotionUsageFetcher.requestContext(from: "   ") == nil)
    }

    @Test
    func curlForwardsOnlyCodexBarAllowlistedHeaders() throws {
        let curl = """
        curl 'https://app.notion.com/api/v3/getCreditRateLimitStatus' \
          -H 'User-Agent: Captured Browser' \
          --header "notion-client-version: 23.13.0" \
          -H 'x-notion-active-user-header: \(Self.userID)' \
          -H 'x-notion-space-id: must-not-forward' \
          -H 'Authorization: Bearer must-not-forward' \
          -H 'Cookie: token_v2=abc; notion_user_id=def'
        """
        let context = try #require(NotionUsageFetcher.requestContext(from: curl))
        #expect(context.cookieHeader == "token_v2=abc; notion_user_id=def")
        #expect(context.headers["User-Agent"] == "Captured Browser")
        #expect(context.headers["notion-client-version"] == "23.13.0")
        #expect(context.headers["x-notion-active-user-header"] == Self.userID)
        #expect(context.headers["x-notion-space-id"] == nil)
        #expect(context.headers["Authorization"] == nil)
        #expect(context.headers["Cookie"] == nil)
    }

    @Test
    func curlParserSupportsAnsiAndEqualsHeaderForms() throws {
        let curl = """
        curl 'https://app.notion.com/' \
          --header=$'User-Agent: Browser\\'s Agent' \
          --header='notion-client-version: 23.13.0' \
          -H 'Cookie: token_v2=abc'
        """
        let context = try #require(NotionUsageFetcher.requestContext(from: curl))
        #expect(context.headers["User-Agent"] == "Browser's Agent")
        #expect(context.headers["notion-client-version"] == "23.13.0")
        #expect(context.cookieHeader == "token_v2=abc")
    }

    @Test
    func cookieDeduplicationPrefersCurrentAppDomain() throws {
        let cookies = try [
            Self.cookie(name: "token_v2", value: "legacy", domain: ".notion.so"),
            Self.cookie(name: "other", value: "one", domain: "notion.com"),
            Self.cookie(name: "token_v2", value: "current", domain: "app.notion.com"),
        ]
        let deduped = NotionUsageFetcher.deduplicatedByName(cookies)
        #expect(deduped.map(\.name) == ["other", "token_v2"])
        #expect(deduped.first(where: { $0.name == "token_v2" })?.value == "current")
    }

    @Test
    func fetchUsesExactSequenceBodiesAndHeaders() async throws {
        let recorder = NotionRequestRecorder()
        NotionURLProtocolStub.handler = { request in
            recorder.append(request)
            if request.url == NotionUsageFetcher.getSpacesURL {
                return (200, Data(Self.spaces.utf8))
            }
            return (200, Data(Self.rateLimit.utf8))
        }
        defer { NotionURLProtocolStub.handler = nil }
        let context = try #require(NotionUsageFetcher.requestContext(from: """
        curl https://app.notion.com -H 'User-Agent: Captured' -H 'Cookie: token_v2=abc'
        """))
        let snapshot = try await NotionUsageFetcher.fetchUsage(
            context: context,
            preferredSpaceID: nil,
            timeout: 7,
            now: Self.now,
            session: Self.session()
        )
        let requests = recorder.requests

        #expect(snapshot.workspace?.id == Self.businessSpaceID)
        #expect(requests.map(\.url) == [
            NotionUsageFetcher.getSpacesURL, NotionUsageFetcher.getCreditRateLimitStatusURL,
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.timeoutInterval == 7 })
        #expect(requests[0].httpBody == Data("{}".utf8))
        let bodyObject = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data())
        let body = try #require(bodyObject as? [String: String])
        #expect(body == ["spaceId": Self.businessSpaceID])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://app.notion.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://app.notion.com/")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Captured")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "token_v2=abc")
            #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        }
    }

    @Test(arguments: [401, 403, 500])
    func httpFailuresKeepExactCategories(status: Int) async {
        NotionURLProtocolStub.handler = { _ in (status, Data()) }
        defer { NotionURLProtocolStub.handler = nil }
        if status == 401 {
            await #expect(throws: NotionUsageError.invalidCredentials) {
                _ = try await NotionUsageFetcher.fetchUsage(
                    cookieHeader: "token_v2=abc", now: Self.now, session: Self.session()
                )
            }
        } else {
            await #expect(throws: NotionUsageError.apiError("HTTP \(status) from getSpaces")) {
                _ = try await NotionUsageFetcher.fetchUsage(
                    cookieHeader: "token_v2=abc", now: Self.now, session: Self.session()
                )
            }
        }
    }

    @Test
    func selectedIneligibleWorkspaceThrowsNamedError() async {
        NotionURLProtocolStub.handler = { request in
            request.url == NotionUsageFetcher.getSpacesURL
                ? (200, Data(Self.spaces.utf8))
                : (200, Data(#"{"status":"not_applicable"}"#.utf8))
        }
        defer { NotionURLProtocolStub.handler = nil }
        await #expect(throws: NotionUsageError.allowanceNotApplicable(workspace: "Personal")) {
            _ = try await NotionUsageFetcher.fetchUsage(
                cookieHeader: "token_v2=abc",
                preferredSpaceID: Self.personalSpaceID,
                now: Self.now,
                session: Self.session()
            )
        }
    }

    @Test
    func emptyAccountThrowsNoWorkspaceWithoutAllowanceRequest() async {
        let recorder = NotionRequestRecorder()
        NotionURLProtocolStub.handler = { request in
            recorder.append(request)
            return (200, Data("{\"only-user\":{}}".utf8))
        }
        defer { NotionURLProtocolStub.handler = nil }
        await #expect(throws: NotionUsageError.noWorkspace) {
            _ = try await NotionUsageFetcher.fetchUsage(
                cookieHeader: "token_v2=abc", now: Self.now, session: Self.session()
            )
        }
        #expect(recorder.requests.map(\.url) == [NotionUsageFetcher.getSpacesURL])
    }

    @Test
    func cancellationRemainsCancellation() async {
        NotionURLProtocolStub.handler = { _ in throw URLError(.cancelled) }
        defer { NotionURLProtocolStub.handler = nil }
        await #expect(throws: CancellationError.self) {
            _ = try await NotionUsageFetcher.fetchUsage(
                cookieHeader: "token_v2=abc", now: Self.now, session: Self.session()
            )
        }
    }

    @Test
    func invalidCachedCookieIsClearedBeforeDeferredImport() async {
        NotionURLProtocolStub.handler = { _ in (401, Data()) }
        defer { NotionURLProtocolStub.handler = nil }
        let updates = NotionCacheUpdates()
        await #expect(throws: NotionUsageError.cookieImportDeferred) {
            _ = try await NotionUsageFetcher.fetch(
                credential: "",
                source: .automatic,
                workspaceID: nil,
                session: Self.session(),
                cachedCookieHeader: "token_v2=expired",
                cacheUpdate: { value in updates.append(value) },
                allowBrowserImport: false,
                now: Self.now
            )
        }
        #expect(updates.values.count == 1)
        #expect(updates.values[0] == nil)
    }

    @Test
    func manualModeNeverFallsBackToCachedOrBrowserCookies() async {
        await #expect(throws: NotionUsageError.noSessionCookie) {
            _ = try await NotionUsageFetcher.fetch(
                credential: "",
                source: .cookie,
                workspaceID: nil,
                session: Self.session(),
                cachedCookieHeader: "token_v2=cached",
                allowBrowserImport: true
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotionURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func cookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name, .value: value, .domain: domain, .path: "/",
        ]))
    }

    private static let rateLimit = #"{"status":"within_limit","window":{"creditType":"basic_ai_credits","scope":"per_user","window":"6h","used":42.5,"limit":100},"resetsInSeconds":12600,"billingPeriodWindow":{"creditType":"basic_ai_credits","scope":"per_user","cadence":"billing_period","used":18.0,"limit":100,"periodEndMs":1788000000000},"enforcement":"preview"}"#

    private static let spaces = """
    {"\(userID)":{"notion_user":{"\(userID)":{"value":{"value":{"id":"\(userID)","email":"person@example.com","name":"Example Person"}}}},"space":{"\(personalSpaceID)":{"value":{"value":{"id":"\(personalSpaceID)","name":"Personal","plan_type":"personal","subscription_tier":"free"}}},"\(businessSpaceID)":{"value":{"value":{"id":"\(businessSpaceID)","name":"Acme","plan_type":"team","subscription_tier":"business"}}}}}}
    """

    private static let singlyWrappedSpaces = """
    {"\(userID)":{"notion_user":{"\(userID)":{"value":{"id":"\(userID)","email":"legacy@example.com","name":"Legacy Person"}}},"space":{"\(businessSpaceID)":{"value":{"id":"\(businessSpaceID)","name":"Acme","plan_type":"team","subscription_tier":"business"}}}}}
    """
}

private final class NotionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

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
        lock.lock()
        storage.append(recorded)
        lock.unlock()
    }
}

private final class NotionCacheUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class NotionURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
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
