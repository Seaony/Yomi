import Foundation
import Testing
@testable import CodeEdge

@MainActor
struct UsageStoreAdaptiveRefreshTests {
    @Test(arguments: [
        (0.0, false, false, 120.0),
        (2400.0, true, false, 300.0),
        (7200.0, false, false, 900.0),
        (18000.0, false, false, 1800.0),
        (0.0, true, true, 1800.0),
    ])
    func schedulesRealUsageScenarios(
        interactionAge: TimeInterval, coding: Bool, lowPower: Bool, expectedInterval: TimeInterval
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.clock.lowPower = lowPower
        fixture.store.noteInteraction(at: fixture.clock.date.addingTimeInterval(-interactionAge))
        if coding { fixture.store.noteCodingActivity(at: fixture.clock.date) }
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        #expect(fixture.store.scheduledRefreshInterval == expectedInterval)
        #expect(fixture.store.nextRefreshAt == fixture.clock.date.addingTimeInterval(expectedInterval))
    }

    @Test
    func hoverRefreshesImmediatelyWhenTheShorterDeadlineHasPassed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        #expect(fixture.store.scheduledRefreshInterval == 1800)
        fixture.clock.date.addTimeInterval(20 * 60)
        fixture.store.noteInteraction(at: fixture.clock.date)
        await waitUntil { fixture.store.lastRefreshAt == fixture.clock.date }
        #expect(await fixture.collector.calls == 2)
        #expect(fixture.store.scheduledRefreshInterval == 120)
        #expect(fixture.store.nextRefreshAt == fixture.clock.date.addingTimeInterval(120))
    }

    @Test
    func hoverUsesTheLastRefreshAndRepeatedHoverKeepsTheDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        let firstRefresh = fixture.clock.date
        fixture.clock.date.addTimeInterval(60)
        fixture.store.noteInteraction(at: fixture.clock.date)
        let deadline = firstRefresh.addingTimeInterval(120)
        #expect(fixture.store.nextRefreshAt == deadline)
        #expect(DiagnosticLog.shared.recentLogText().contains("[refresh] mode=auto reason=recent delay=60s"))
        fixture.clock.date.addTimeInterval(10)
        fixture.store.noteInteraction(at: fixture.clock.date)
        #expect(fixture.store.lastInteractionAt == fixture.clock.date)
        #expect(fixture.store.nextRefreshAt == deadline)
        #expect(await fixture.collector.calls == 1)
    }

    @Test
    func codingActivityShortensAnAlreadySleepingLongIdleSchedule() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        let firstRefresh = fixture.clock.date
        fixture.clock.date.addTimeInterval(60)
        fixture.store.noteCodingActivity(at: fixture.clock.date)
        #expect(fixture.store.lastCodingActivityAt == fixture.clock.date)
        #expect(fixture.store.scheduledRefreshInterval == 300)
        #expect(fixture.store.nextRefreshAt == firstRefresh.addingTimeInterval(300))
    }

    @Test
    func changingSettingsReschedulesImmediatelyAndFixedModeIgnoresActivity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(300, forKey: "refresh-interval")
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        let firstRefresh = fixture.clock.date
        fixture.clock.date.addTimeInterval(60)
        fixture.store.noteInteraction(at: fixture.clock.date)
        fixture.store.noteCodingActivity(at: fixture.clock.date)
        #expect(fixture.store.nextRefreshAt == firstRefresh.addingTimeInterval(300))

        fixture.defaults.set(0, forKey: "refresh-interval")
        await waitUntil { fixture.store.scheduledRefreshInterval == 120 }
        #expect(fixture.store.nextRefreshAt == firstRefresh.addingTimeInterval(120))
        #expect(fixture.store.serviceStatusRefreshInterval == 300)
        #expect(fixture.store.freshnessRefreshInterval == 1800)

        fixture.defaults.set(900, forKey: "refresh-interval")
        await waitUntil { fixture.store.scheduledRefreshInterval == 900 }
        #expect(fixture.store.nextRefreshAt == firstRefresh.addingTimeInterval(900))
        #expect(fixture.store.serviceStatusRefreshInterval == 900)
        #expect(fixture.store.freshnessRefreshInterval == 900)
        #expect(await fixture.collector.calls == 1)
    }

    @Test
    func manualCardRefreshCountsAsInteractionWithoutDuplicatingTheRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        fixture.clock.date.addTimeInterval(20 * 60)
        await fixture.store.refresh(providerID: .init(rawValue: "codex"), allowBrowserCookieImport: true)
        #expect(fixture.store.lastInteractionAt == fixture.clock.date)
        #expect(fixture.store.scheduledRefreshInterval == 120)
        #expect(fixture.store.nextRefreshAt == fixture.clock.date.addingTimeInterval(120))
        #expect(await fixture.collector.calls == 2)
    }

    @Test
    func automaticModeReevaluatesIdleTimeAfterEachRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.noteInteraction(at: fixture.clock.date)
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        #expect(fixture.store.scheduledRefreshInterval == 120)
        fixture.clock.date.addTimeInterval(10 * 60)
        await fixture.store.refresh()
        #expect(fixture.store.scheduledRefreshInterval == 300)
        fixture.clock.date.addTimeInterval(2 * 60 * 60)
        await fixture.store.refresh()
        #expect(fixture.store.scheduledRefreshInterval == 900)
        fixture.clock.date.addTimeInterval(5 * 60 * 60)
        await fixture.store.refresh()
        #expect(fixture.store.scheduledRefreshInterval == 1800)
    }

    @Test
    func powerChangesRescheduleAutomaticMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.noteInteraction(at: fixture.clock.date)
        fixture.store.start()
        await waitUntil { fixture.store.nextRefreshAt != nil }
        fixture.clock.lowPower = true
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await waitUntil { fixture.store.scheduledRefreshInterval == 1800 }
        #expect(fixture.store.nextRefreshAt == fixture.clock.date.addingTimeInterval(1800))
        fixture.clock.lowPower = false
        fixture.clock.thermal = .serious
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await Task.yield()
        #expect(fixture.store.scheduledRefreshInterval == 1800)
        fixture.clock.thermal = .nominal
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await waitUntil { fixture.store.scheduledRefreshInterval == 120 }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("刷新未在预期时间内完成排期")
    }
}

@MainActor
private struct Fixture {
    let name: String
    let defaults: UserDefaults
    let clock = RefreshClock()
    let collector = AdaptiveFixtureCollector()
    let store: UsageStore

    init() throws {
        name = "adaptive-store-\(UUID().uuidString)"
        defaults = try #require(TestUserDefaults(suiteName: name))
        let configurations = ProviderCatalog.all.map { descriptor in
            var configuration = ProviderConfiguration(descriptor: descriptor)
            configuration.isEnabled = descriptor.id.rawValue == "codex"
            return configuration
        }
        defaults.set(try JSONEncoder().encode(configurations), forKey: "providers.v1")
        defaults.set(false, forKey: ProviderServiceStatusMonitor.settingKey)
        let clock = clock
        store = UsageStore(
            preferences: ProviderPreferences(defaults: defaults), collector: collector, defaults: defaults,
            now: { clock.date }, powerState: { (clock.lowPower, clock.thermal) }
        )
    }

    func cleanup() {
        TestUserDefaultsCleanup.cleanup(defaults, suiteName: name)
    }
}

@MainActor
private final class RefreshClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var lowPower = false
    var thermal = ProcessInfo.ThermalState.nominal
}

private actor AdaptiveFixtureCollector: UsageCollecting {
    private(set) var calls = 0

    func collect(descriptor: ProviderDescriptor, configuration: ProviderConfiguration, secret: String,
                 allowVertexClaudeFallback: Bool, allowBrowserCookieImport: Bool, usageRevision: Int?) async throws -> ProviderUsage {
        calls += 1
        return ProviderUsage(id: descriptor.id, state: .ready, windows: [], updatedAt: Date())
    }

    func enrichLocalMetadata(to usage: ProviderUsage, descriptor: ProviderDescriptor,
                             allowVertexClaudeFallback: Bool) async -> ProviderUsage { usage }
}
