import Foundation
import Testing
@testable import CodeEdge

@MainActor
struct UsageStoreBackoffTests {
    @Test
    func restoresProviderDeadlineAndReportsItsRemainingTime() throws {
        let name = "backoff-store-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: name))
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: name) }
        let now = Date()
        let state = ProviderBackoffState(consecutiveRateLimits: 2, retryAt: now.addingTimeInterval(120))
        defaults.set(try JSONEncoder().encode(["codex": state]), forKey: "provider-backoff.v1")
        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)
        #expect(store.backoffByID["codex"] == state)
        #expect(store.backoffDescription(for: .init(rawValue: "codex"), now: now, language: .english)
                == "Rate limited. Retry in 2 min")
        #expect(store.backoffDescription(for: .init(rawValue: "codex"), now: state.retryAt, language: .english) == nil)
    }

    @Test
    func preservesExistingFixedIntervalsAndDefaultsToAutomatic() throws {
        let name = "adaptive-store-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: name))
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: name) }
        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)
        #expect(store.currentRefreshInterval == 0)
        #expect(store.freshnessRefreshInterval == 1800)
        #expect(store.serviceStatusRefreshInterval == 300)
        defaults.set(0, forKey: "refresh-interval")
        #expect(store.currentRefreshInterval == 0)
        for interval in [60.0, 300, 900, 1800] {
            defaults.set(interval, forKey: "refresh-interval")
            #expect(store.currentRefreshInterval == interval)
        }
    }

    @Test
    func capturesRetryAfterWithoutLettingAnOptionalRequestHideRateLimiting() throws {
        let url = try #require(URL(string: "https://fixture.invalid/usage"))
        let trace = FetchDiagnostics()
        trace.record(request: URLRequest(url: url), response: HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]
        ))
        trace.record(request: URLRequest(url: url), response: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        #expect(trace.httpStatus == 200)
        #expect(trace.rateLimit?.retryAfter == "120")
        #expect(ProviderBackoffPolicy.updating(previous: nil, httpStatus: 429,
                                              retryAfter: trace.rateLimit?.retryAfter,
                                              succeeded: true, now: Date()) == nil)
    }

    @Test
    func retriesAnExpiredBackoffAfterTheOtherProvidersFinish() async throws {
        let fixture = try fixture(enabled: ["codex", "claude"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let collector = BackoffFixtureCollector(replies: [
            "codex": [.init(status: 429, retryAfter: "0"), .init()],
            "claude": [.init(delay: .milliseconds(80))],
        ])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        await store.refresh()
        await waitForCalls(collector, provider: "codex", count: 2)
        await waitForRefreshCompletion(store)
        #expect(await collector.calls(for: "codex") == 2)
        #expect(await collector.calls(for: "claude") == 1)
        #expect(store.backoffByID["codex"] == nil)
    }

    @Test
    func repeatedImmediateRateLimitsReturnToExponentialBackoff() async throws {
        let fixture = try fixture(enabled: ["codex"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let collector = BackoffFixtureCollector(replies: [
            "codex": [.init(status: 429, retryAfter: "0"), .init(status: 429, retryAfter: "0")],
        ])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        await store.refresh()
        await waitForCalls(collector, provider: "codex", count: 2)
        await waitForRefreshCompletion(store)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await collector.calls(for: "codex") == 2)
        let state = try #require(store.backoffByID["codex"])
        #expect(state.consecutiveRateLimits == 2)
        #expect(state.retryAt.timeIntervalSinceNow > 110)
    }

    @Test
    func automaticRefreshKeepsCacheAndManualRefreshBypassesBackoff() async throws {
        let fixture = try fixture(enabled: ["codex"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let state = ProviderBackoffState(consecutiveRateLimits: 1, retryAt: Date().addingTimeInterval(600))
        fixture.defaults.set(try JSONEncoder().encode(["codex": state]), forKey: "provider-backoff.v1")
        let collector = BackoffFixtureCollector(replies: [:])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        let cachedWindow = UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.4)
        store.showPreviewUsage([ProviderUsage(id: .init(rawValue: "codex"), state: .ready,
                                             windows: [cachedWindow], updatedAt: Date())])
        await store.refresh()
        #expect(await collector.calls(for: "codex") == 0)
        #expect(store.usage(for: .init(rawValue: "codex")).windows == [cachedWindow])
        #expect(store.usage(for: .init(rawValue: "codex")).state == .unavailable)
        await store.refresh(providerID: .init(rawValue: "codex"), isManual: true)
        #expect(await collector.calls(for: "codex") == 1)
        #expect(store.backoffByID["codex"] == nil)
        #expect(try JSONDecoder().decode([String: ProviderBackoffState].self,
                                      from: #require(fixture.defaults.data(forKey: "provider-backoff.v1"))).isEmpty)
    }

    @Test
    func resetBoundaryRefreshesTheProviderWithoutWaitingForTheFixedLoop() async throws {
        let fixture = try fixture(enabled: ["codex"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let collector = BackoffFixtureCollector(replies: [
            "codex": [.init(resetAt: Date().addingTimeInterval(-1), updatedAt: Date().addingTimeInterval(-2)), .init()],
        ])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        await store.refresh()
        await waitForCalls(collector, provider: "codex", count: 2)
        await waitForRefreshCompletion(store)
        #expect(await collector.calls(for: "codex") == 2)
    }

    @Test
    func queuedManualRefreshKeepsItsBypassWithoutRequestingBrowserAccess() async throws {
        let fixture = try fixture(enabled: ["codex", "claude"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let state = ProviderBackoffState(consecutiveRateLimits: 1, retryAt: Date().addingTimeInterval(600))
        fixture.defaults.set(try JSONEncoder().encode(["codex": state]), forKey: "provider-backoff.v1")
        let collector = BackoffFixtureCollector(replies: ["claude": [.init(delay: .milliseconds(80))]])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        let running = Task { await store.refresh(providerID: .init(rawValue: "claude")) }
        await waitForCalls(collector, provider: "claude", count: 1)
        await store.refresh(providerID: .init(rawValue: "codex"), isManual: true)
        await store.refresh(providerID: .init(rawValue: "codex"))
        await running.value
        #expect(await collector.calls(for: "codex") == 1)
        #expect(await collector.browserImportPermissions() == [false, false])
    }

    @Test
    func distinctResetDatesCannotRefreshTheSameProviderAgainDuringCooldown() async throws {
        let fixture = try fixture(enabled: ["codex"])
        defer { TestUserDefaultsCleanup.cleanup(fixture.defaults, suiteName: fixture.name) }
        let now = Date()
        let collector = BackoffFixtureCollector(replies: [
            "codex": [
                .init(resetAt: now.addingTimeInterval(-1), updatedAt: now.addingTimeInterval(-2)),
                .init(resetAt: now.addingTimeInterval(-0.5), updatedAt: now.addingTimeInterval(-1)),
            ],
        ])
        let store = UsageStore(preferences: fixture.preferences, collector: collector, defaults: fixture.defaults)
        await store.refresh()
        await waitForCalls(collector, provider: "codex", count: 2)
        await waitForRefreshCompletion(store)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await collector.calls(for: "codex") == 2)
    }

    private func fixture(enabled: Set<String>) throws -> (name: String, defaults: UserDefaults, preferences: ProviderPreferences) {
        let name = "backoff-integration-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: name))
        let configurations = ProviderCatalog.all.map { descriptor in
            var configuration = ProviderConfiguration(descriptor: descriptor)
            configuration.isEnabled = enabled.contains(descriptor.id.rawValue)
            return configuration
        }
        defaults.set(try JSONEncoder().encode(configurations), forKey: "providers.v1")
        return (name, defaults, ProviderPreferences(defaults: defaults))
    }

    private func waitForRefreshCompletion(_ store: UsageStore) async {
        for _ in 0..<300 {
            if !store.isRefreshing { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("自动刷新未在清理测试偏好前完成")
    }

    private func waitForCalls(_ collector: BackoffFixtureCollector, provider: String, count: Int) async {
        for _ in 0..<120 {
            if await collector.calls(for: provider) >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor BackoffFixtureCollector: UsageCollecting {
    struct Reply: Sendable {
        var status = 200
        var retryAfter: String?
        var delay: Duration = .zero
        var resetAt: Date?
        var updatedAt: Date?
    }

    private var replies: [String: [Reply]]
    private var counts: [String: Int] = [:]
    private var importPermissions: [Bool] = []

    init(replies: [String: [Reply]]) { self.replies = replies }

    func calls(for id: String) -> Int { counts[id, default: 0] }
    func browserImportPermissions() -> [Bool] { importPermissions }

    func collect(descriptor: ProviderDescriptor, configuration: ProviderConfiguration, secret: String,
                 allowVertexClaudeFallback: Bool, allowBrowserCookieImport: Bool, usageRevision: Int?) async throws -> ProviderUsage {
        let id = descriptor.id.rawValue
        counts[id, default: 0] += 1
        importPermissions.append(allowBrowserCookieImport)
        var queue = replies[id] ?? []
        let reply = queue.isEmpty ? Reply() : queue.removeFirst()
        replies[id] = queue
        try await Task.sleep(for: reply.delay)
        FetchDiagnostics.current?.beginStrategy("API")
        if reply.status == 429 {
            let url = URL(string: "https://fixture.invalid/quota")!
            FetchDiagnostics.current?.record(request: URLRequest(url: url), response: HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: reply.retryAfter.map { ["Retry-After": $0] }
            ))
            throw UsageCollectionError.requestFailed(429)
        }
        let windows = reply.resetAt.map { [UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.4, resetsAt: $0)] } ?? []
        return ProviderUsage(id: descriptor.id, state: .ready, windows: windows,
                             updatedAt: reply.updatedAt ?? Date(), diagnosticSource: "API")
    }

    func enrichLocalMetadata(to usage: ProviderUsage, descriptor: ProviderDescriptor,
                             allowVertexClaudeFallback: Bool) async -> ProviderUsage { usage }
}
