import Foundation
import SweetCookieKit
import Testing
@testable import Yomi

@Suite("Command Code usage", .serialized)
struct CommandCodeUsageTests {
    @Test
    func subscriptionFailureMarkersStabilizeADepletedPaidMonthlyWindow() throws {
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let previous = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 6,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: nil,
            weeklyWindow: nil,
            plan: plan,
            billingPeriodEnd: Date(timeIntervalSince1970: 1_800_000_000),
            subscriptionStatus: "active",
            subscriptionEnrichmentUnavailable: false,
            updatedAt: Date()
        ).toProviderUsage()
        let current = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 0,
            purchasedCredits: 5,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: nil,
            weeklyWindow: nil,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil,
            subscriptionEnrichmentUnavailable: true,
            updatedAt: Date()
        ).toProviderUsage()
        #expect(current.windows.first { $0.id == "commandcode-monthly" } == nil)
        let resolved = UsageStore.commandCodeUsageResolvingDepletionOnEnrichmentFailure(
            current: current,
            previous: previous
        )
        #expect(resolved.windows.first { $0.id == "commandcode-monthly" }?.usedFraction == 1)
        #expect(resolved.commandCodeSubscriptionEnrichmentUnavailable)
        #expect(resolved.commandCodeMonthlyGrantDepleted)

        let free = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 0,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: nil,
            weeklyWindow: nil,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil,
            subscriptionEnrichmentUnavailable: false,
            updatedAt: Date()
        ).toProviderUsage()
        #expect(UsageStore.commandCodeUsageResolvingDepletionOnEnrichmentFailure(
            current: free,
            previous: previous
        ).windows.first { $0.id == "commandcode-monthly" } == nil)
    }
    @Test
    func planCatalogMatchesReference() {
        #expect(CommandCodePlanCatalog.plan(forID: "INDIVIDUAL-GO")?.monthlyCreditsUSD == 10)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-goat")?.monthlyCreditsUSD == 70)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-pro")?.monthlyCreditsUSD == 30)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-pro-v1")?.monthlyCreditsUSD == 80)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-max")?.monthlyCreditsUSD == 150)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-ultra")?.monthlyCreditsUSD == 300)
        #expect(CommandCodePlanCatalog.plan(forID: "unknown") == nil)
    }

    @Test
    func cookieOverrideUsesExactPriorityAndBareTokenDefault() {
        let cookie = CommandCodeCookieHeader.override(from:
            "better-auth.session_token=legacy; __Secure-commandcode_prod_.session_token=current")
        #expect(cookie?.name == "__Secure-commandcode_prod_.session_token")
        #expect(cookie?.token == "current")
        #expect(CommandCodeCookieHeader.override(from: "bare")?.headerValue
            == "__Secure-better-auth.session_token=bare")
        #expect(CommandCodeCookieHeader.override(from: "BETTER-AUTH.SESSION_TOKEN=value")?.name
            == "BETTER-AUTH.SESSION_TOKEN")
        #expect(CommandCodeCookieHeader.override(from: " ") == nil)
    }

    @Test
    func creditsParserReadsRootRollingWindows() throws {
        let payload = try CommandCodeUsageFetcher.parseCredits(data: Data(#"""
        {
          "credits":{"monthlyCredits":8.5,"purchasedCredits":2},
          "windowLimits":{
            "fiveHour":{"cap":4,"used":1,"resetAt":1780000000000},
            "weekly":{"cap":"20","used":"4","resetAt":"1780100000"}
          }
        }
        """#.utf8))
        #expect(payload.monthlyCredits == 8.5)
        #expect(payload.purchasedCredits == 2)
        #expect(payload.premiumMonthlyCredits == 0)
        #expect(payload.opensourceMonthlyCredits == 0)
        #expect(payload.fiveHourWindow?.usedFraction == 0.25)
        #expect(payload.fiveHourWindow?.windowMinutes == 300)
        #expect(payload.fiveHourWindow?.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(payload.weeklyWindow?.usedFraction == 0.2)
        #expect(payload.weeklyWindow?.windowMinutes == 10_080)
        #expect(payload.weeklyWindow?.resetsAt == Date(timeIntervalSince1970: 1_780_100_000))
    }

    @Test
    func creditsParserReadsNestedWindowsAndRootWins() throws {
        let payload = try CommandCodeUsageFetcher.parseCredits(data: Data(#"""
        {
          "credits":{"monthlyCredits":"7.25","windowLimits":{"fiveHour":{"cap":4,"used":1}}},
          "windowLimits":{"weekly":{"cap":10,"used":3}}
        }
        """#.utf8))
        #expect(payload.monthlyCredits == 7.25)
        #expect(payload.fiveHourWindow == nil)
        #expect(payload.weeklyWindow?.usedFraction == 0.3)
    }

    @Test
    func malformedCreditsNeverInventQuota() {
        #expect(throws: CommandCodeUsageError.self) {
            _ = try CommandCodeUsageFetcher.parseCredits(data: Data("not-json".utf8))
        }
        #expect(throws: CommandCodeUsageError.self) {
            _ = try CommandCodeUsageFetcher.parseCredits(data: Data(#"{"credits":{}}"#.utf8))
        }
        #expect(throws: CommandCodeUsageError.self) {
            _ = try CommandCodeUsageFetcher.parseCredits(data: Data(#"{"monthlyCredits":10}"#.utf8))
        }
    }

    @Test
    func subscriptionParserDistinguishesFreeFailureAndMissingData() throws {
        let active = try CommandCodeUsageFetcher.parseSubscription(data: Data(#"""
        {
          "success":true,"data":{"planId":"individual-go","status":"active",
          "currentPeriodEnd":"2026-06-06T07:28:50.000Z"}
        }
        """#.utf8))
        #expect(active?.planID == "individual-go")
        #expect(active?.status == "active")
        #expect(active?.currentPeriodEnd != nil)
        #expect(try CommandCodeUsageFetcher.parseSubscription(
            data: Data(#"{"success":true,"data":null}"#.utf8)) == nil)
        #expect(throws: CommandCodeUsageError.self) {
            _ = try CommandCodeUsageFetcher.parseSubscription(
                data: Data(#"{"success":false,"error":"unavailable"}"#.utf8))
        }
        #expect(throws: CommandCodeUsageError.self) {
            _ = try CommandCodeUsageFetcher.parseSubscription(data: Data(#"{"success":true}"#.utf8))
        }
    }

    @Test
    func snapshotMapsExactlyThreeReferenceWindows() {
        let snapshot = Self.snapshot(
            remaining: 8,
            purchased: 2,
            fiveHour: .init(usedFraction: 0.25, windowMinutes: 300, resetsAt: nil),
            weekly: .init(usedFraction: 0.1, windowMinutes: 10_080, resetsAt: nil),
            plan: CommandCodePlanCatalog.plan(forID: "individual-go")
        )
        let usage = snapshot.toProviderUsage()
        #expect(usage.windows.map(\.id) == [
            "commandcode-five-hour", "commandcode-weekly", "commandcode-monthly",
        ])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.1, 0.2])
        #expect(usage.plan == "Go")
        #expect(usage.balance == nil)
    }

    @Test
    func freeAndUnknownMonthlyPresentationMatchesReference() {
        #expect(Self.snapshot(remaining: 0).toProviderUsage().windows.isEmpty)
        let remaining = Self.snapshot(remaining: 5).toProviderUsage()
        #expect(remaining.windows.isEmpty)
        #expect(remaining.plan == nil)
        let purchased = Self.snapshot(remaining: 0, purchased: 3).toProviderUsage()
        #expect(purchased.windows.isEmpty)
        #expect(purchased.plan == nil)
    }

    @Test
    func requestsRequiredCreditsAndOptionalSubscriptionWithExactHeaders() async throws {
        let recorder = CommandCodeRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            if request.url?.path == CommandCodeUsageFetcher.creditsPath {
                return Self.response(request, status: 200, body: Self.creditsJSON)
            }
            return Self.response(request, status: 200, body: Self.subscriptionJSON)
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        let snapshot = try await CommandCodeUsageFetcher.fetchSnapshot(
            cookieHeader: "session=valid",
            session: session,
            now: Date(timeIntervalSince1970: 123)
        )
        #expect(Set(recorder.requests.compactMap(\.url?.path)) == Set([
            CommandCodeUsageFetcher.creditsPath, CommandCodeUsageFetcher.subscriptionsPath,
        ]))
        #expect(recorder.requests.allSatisfy { request in
            request.httpMethod == "GET"
                && request.timeoutInterval == 15
                && request.value(forHTTPHeaderField: "Cookie") == "session=valid"
                && request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*"
                && request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9"
                && request.value(forHTTPHeaderField: "Origin") == "https://commandcode.ai"
                && request.value(forHTTPHeaderField: "Referer") == "https://commandcode.ai/"
                && request.value(forHTTPHeaderField: "User-Agent") == CommandCodeUsageFetcher.userAgent
        })
        #expect(snapshot.plan?.id == "individual-go")
        #expect(snapshot.subscriptionEnrichmentUnavailable == false)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 123))
    }

    @Test
    func requiredCreditsFailureIsNotHiddenBySubscription() async {
        let session = Self.session { request in
            let status = request.url?.path == CommandCodeUsageFetcher.creditsPath ? 503 : 200
            return Self.response(request, status: status, body: Self.subscriptionJSON)
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        await #expect(throws: CommandCodeUsageError.apiError(503)) {
            _ = try await CommandCodeUsageFetcher.fetchSnapshot(
                cookieHeader: "session=valid", session: session)
        }
    }

    @Test(arguments: [401, 403])
    func authenticationStatusesAreExact(status: Int) async {
        let session = Self.session { request in Self.response(request, status: status, body: "{}") }
        defer { CommandCodeTestURLProtocol.handler = nil }
        await #expect(throws: CommandCodeUsageError.invalidCredentials) {
            _ = try await CommandCodeUsageFetcher.fetchSnapshot(
                cookieHeader: "session=invalid", session: session)
        }
    }

    @Test
    func optionalSubscriptionFailurePreservesRequiredCredits() async throws {
        let session = Self.session { request in
            if request.url?.path == CommandCodeUsageFetcher.creditsPath {
                return Self.response(request, status: 200, body: Self.creditsJSON)
            }
            return Self.response(request, status: 503, body: "{}")
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        let snapshot = try await CommandCodeUsageFetcher.fetchSnapshot(
            cookieHeader: "session=valid", session: session)
        #expect(snapshot.monthlyCreditsRemaining == 8)
        #expect(snapshot.plan == nil)
        #expect(snapshot.subscriptionEnrichmentUnavailable)
    }

    @Test
    func unknownActivePlanFailsExplicitly() async {
        let session = Self.session { request in
            let body = request.url?.path == CommandCodeUsageFetcher.creditsPath
                ? Self.creditsJSON
                : #"{"success":true,"data":{"planId":"individual-future","status":"active"}}"#
            return Self.response(request, status: 200, body: body)
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        await #expect(throws: CommandCodeUsageError.unknownPlan("individual-future")) {
            _ = try await CommandCodeUsageFetcher.fetchSnapshot(
                cookieHeader: "session=valid", session: session)
        }
    }

    @Test
    func invalidSessionRotatesButNonAuthFailureStops() async throws {
        let recorder = CommandCodeRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == "session=stale" {
                return Self.response(request, status: 401, body: "{}")
            }
            return Self.response(
                request,
                status: 200,
                body: request.url?.path == CommandCodeUsageFetcher.creditsPath
                    ? Self.creditsJSON : Self.subscriptionJSON
            )
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        _ = try await CommandCodeUsageFetcher.fetchFromSessions([
            .init(cookieHeader: "session=stale", sourceLabel: "Chrome"),
            .init(cookieHeader: "session=fresh", sourceLabel: "Vivaldi"),
        ], session: session)
        #expect(recorder.requests.contains { $0.value(forHTTPHeaderField: "Cookie") == "session=fresh" })

        recorder.removeAll()
        let failing = Self.session { request in
            recorder.append(request)
            return Self.response(request, status: 503, body: "{}")
        }
        await #expect(throws: CommandCodeUsageError.apiError(503)) {
            _ = try await CommandCodeUsageFetcher.fetchFromSessions([
                .init(cookieHeader: "session=first", sourceLabel: "Chrome"),
                .init(cookieHeader: "session=second", sourceLabel: "Vivaldi"),
            ], session: failing)
        }
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "session=first"
        })
    }

    @Test
    func cachedSessionIsClearedThenSuccessfulImportIsPersisted() async throws {
        let updates = CommandCodeCacheRecorder()
        let session = Self.session { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == "session=cached" {
                return Self.response(request, status: 403, body: "{}")
            }
            return Self.response(
                request,
                status: 200,
                body: request.url?.path == CommandCodeUsageFetcher.creditsPath
                    ? Self.creditsJSON : Self.subscriptionJSON
            )
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        _ = try await CommandCodeUsageFetcher.fetchFromSessions([
            .init(cookieHeader: "session=cached", sourceLabel: "Cache"),
            .init(cookieHeader: "session=imported", sourceLabel: "Chrome Default"),
        ], session: session, cacheUpdate: { await updates.append($0) })
        #expect(await updates.values == [nil, "session=imported"])
    }

    @Test
    func importSessionCacheUsesFiveSecondTTL() {
        let cache = CommandCodeImportSessionCache(ttl: 5)
        var loads = 0
        let first = cache.sessions(now: Date(timeIntervalSince1970: 0)) {
            loads += 1
            return [.init(cookieHeader: "a=1", sourceLabel: "A")]
        }
        let cached = cache.sessions(now: Date(timeIntervalSince1970: 4.9)) {
            loads += 1
            return [.init(cookieHeader: "b=2", sourceLabel: "B")]
        }
        let expired = cache.sessions(now: Date(timeIntervalSince1970: 5)) {
            loads += 1
            return [.init(cookieHeader: "b=2", sourceLabel: "B")]
        }
        #expect(first == cached)
        #expect(expired.first?.cookieHeader == "b=2")
        #expect(loads == 2)
    }

    @Test
    func emptyBrowserImportIsNotCached() {
        let cache = CommandCodeImportSessionCache(ttl: 5)
        var loads = 0
        _ = cache.sessions(now: Date(timeIntervalSince1970: 0)) {
            loads += 1
            return []
        }
        _ = cache.sessions(now: Date(timeIntervalSince1970: 1)) {
            loads += 1
            return []
        }
        #expect(loads == 2)
    }

    @Test
    func networkAndPrimaryStoresMergeByNewestExpiry() {
        let profile = BrowserProfile(id: "profile", name: "Default")
        let network = BrowserCookieStore(
            browser: .chrome, profile: profile, kind: .network,
            label: "Chrome Default (Network)", databaseURL: nil)
        let primary = BrowserCookieStore(
            browser: .chrome, profile: profile, kind: .primary,
            label: "Chrome Default", databaseURL: nil)
        let older = Self.cookie(value: "old", expires: Date(timeIntervalSince1970: 10))
        let newer = Self.cookie(value: "new", expires: Date(timeIntervalSince1970: 20))
        let merged = CommandCodeUsageFetcher.mergedRecords([
            .init(store: primary, records: [newer]),
            .init(store: network, records: [older]),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.value == "new")
    }

    @Test
    func optionalJoinHonorsGraceWithoutWaitingForIgnoredCancellation() async throws {
        let source = Task<Int, Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(returning: 42)
                }
            }
        }
        let started = ContinuousClock.now
        let outcome = await CommandCodeBoundedTaskJoin(sourceTask: source)
            .value(joinGrace: .milliseconds(20))
        let elapsed = started.duration(to: .now)
        guard case .timedOut = outcome else {
            Issue.record("Expected timeout")
            return
        }
        #expect(elapsed < .milliseconds(300))
        try await Task.sleep(for: .milliseconds(550))
    }

    @Test
    func parentCancellationWinsWhileWaitingForOptionalSubscription() async throws {
        let source = Task<Int, Error> {
            try await Task.sleep(for: .seconds(10))
            return 42
        }
        let join = CommandCodeBoundedTaskJoin(sourceTask: source)
        let task = Task {
            await join.value(joinGrace: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let outcome = await task.value
        guard case let .failure(error) = outcome else {
            Issue.record("Expected cancellation failure")
            return
        }
        #expect(error is CancellationError)
        #expect(source.isCancelled)
    }

    @Test
    func unsupportedSourcesAndEmptyManualCredentialFailBeforeNetworking() async {
        let recorder = CommandCodeRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            return Self.response(request, status: 200, body: "{}")
        }
        defer { CommandCodeTestURLProtocol.handler = nil }
        await #expect(throws: CommandCodeUsageError.missingCredentials) {
            _ = try await CommandCodeUsageFetcher.fetch(
                credential: "", source: .cookie, session: session)
        }
        await #expect(throws: CommandCodeUsageError.missingCredentials) {
            _ = try await CommandCodeUsageFetcher.fetch(
                credential: "session=value", source: .command, session: session)
        }
        await #expect(throws: CommandCodeUsageError.missingCredentials) {
            _ = try await CommandCodeUsageFetcher.fetch(
                credential: "session=value", source: .token, session: session)
        }
        #expect(recorder.requests.isEmpty)
    }

    private static let creditsJSON = #"""
    {
      "credits":{"monthlyCredits":8,"purchasedCredits":0,
      "premiumMonthlyCredits":0,"opensourceMonthlyCredits":8}
    }
    """#

    private static let subscriptionJSON = #"""
    {
      "success":true,"data":{"planId":"individual-go","status":"active",
      "currentPeriodEnd":"2026-06-06T07:28:50.000Z"}
    }
    """#

    private static func snapshot(
        remaining: Double,
        purchased: Double = 0,
        fiveHour: CommandCodeUsageFetcher.RollingWindow? = nil,
        weekly: CommandCodeUsageFetcher.RollingWindow? = nil,
        plan: CommandCodePlanCatalog.Plan? = nil
    ) -> CommandCodeUsageSnapshot {
        CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: remaining,
            purchasedCredits: purchased,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: fiveHour,
            weeklyWindow: weekly,
            plan: plan,
            billingPeriodEnd: nil,
            subscriptionStatus: plan == nil ? nil : "active",
            subscriptionEnrichmentUnavailable: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        CommandCodeTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandCodeTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func cookie(value: String, expires: Date?) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: "commandcode.ai",
            name: "__Secure-better-auth.session_token",
            path: "/",
            value: value,
            expires: expires,
            isSecure: true,
            isHTTPOnly: true
        )
    }
}

private final class CommandCodeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

private actor CommandCodeCacheRecorder {
    private(set) var values: [String?] = []
    func append(_ value: String?) { values.append(value) }
}

private final class CommandCodeTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
