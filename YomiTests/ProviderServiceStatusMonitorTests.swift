import Foundation
import Testing
@testable import Yomi

@MainActor
struct ProviderServiceStatusMonitorTests {
    @Test
    func initializationAndProviderChangesBeforeStartDoNotFetch() async {
        let fixture = Fixture(["claude"])
        defer { fixture.stop() }
        #expect(ProviderServiceStatusMonitor.defaultEnabled)
        #expect(fixture.defaults.object(forKey: ProviderServiceStatusMonitor.settingKey) == nil)
        fixture.monitor.providersDidChange()
        await fixture.monitor.refresh()
        #expect(await fixture.probe.totalCalls() == 0)
        #expect(fixture.monitor.statusByID.isEmpty)
    }

    @Test
    func sharedSourcesFetchOnceAndUnsupportedProvidersAreIgnored() async {
        let fixture = Fixture(["gemini", "antigravity", "gemini", "unsupported"])
        defer { fixture.stop() }
        fixture.start()
        await fixture.monitor.refresh()
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(Set(fixture.monitor.statusByID.keys) == Set(["gemini", "antigravity"].map { ProviderID(rawValue: $0) }))
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "gemini"))?.severity == .minor)
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "unsupported")) == nil)
    }

    @Test
    func newlyEnabledProviderImmediatelySharesAnExistingSourceStatus() async {
        let fixture = Fixture(["antigravity"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        let known = fixture.monitor.status(for: ProviderID(rawValue: "antigravity"))
        #expect(known?.severity == .minor)
        fixture.ids = [ProviderID(rawValue: "antigravity"), ProviderID(rawValue: "gemini")]
        fixture.monitor.providersDidChange()
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "gemini")) == known)
        await fixture.monitor.refresh(now: now.addingTimeInterval(60))
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(fixture.monitor.statusByID.count == 2)
    }

    @Test
    func switchingProvidersOfTheSameSourceKeepsStatusWithoutFetchingAgain() async {
        let fixture = Fixture(["antigravity"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        let known = fixture.monitor.status(for: ProviderID(rawValue: "antigravity"))
        #expect(known?.severity == .minor)
        fixture.ids = [ProviderID(rawValue: "gemini")]
        fixture.monitor.providersDidChange()
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "antigravity")) == nil)
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "gemini")) == known)
        await fixture.monitor.refresh(now: now.addingTimeInterval(60))
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(Set(fixture.monitor.statusByID.keys) == [ProviderID(rawValue: "gemini")])
    }

    @Test
    func aFullyDisabledSourceCannotRestoreItsPreviousStatusWhenEnabledAgain() async {
        let fixture = Fixture(["antigravity"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        #expect(fixture.monitor.statusByID.count == 1)
        fixture.ids = []
        fixture.monitor.providersDidChange()
        #expect(fixture.monitor.statusByID.isEmpty)
        fixture.ids = [ProviderID(rawValue: "gemini")]
        fixture.monitor.providersDidChange()
        await fixture.monitor.refresh(now: now.addingTimeInterval(60))
        #expect(fixture.monitor.statusByID.isEmpty)
        #expect(await fixture.probe.totalCalls() == 1)
    }

    @Test(arguments: [60.0, 900.0])
    func successfulAttemptsWaitForTheCurrentInterval(usageInterval: TimeInterval) async {
        let fixture = Fixture(["claude"], interval: usageInterval)
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        let interval = max(300, usageInterval)
        await fixture.monitor.refresh(now: now.addingTimeInterval(interval - 1))
        #expect(await fixture.probe.totalCalls() == 1)
        await fixture.monitor.refresh(now: now.addingTimeInterval(interval))
        #expect(await fixture.probe.totalCalls() == 2)
    }

    @Test
    func failedAttemptsAlsoWaitFiveMinutes() async {
        let fixture = Fixture(["claude"], mode: .failure)
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        await fixture.monitor.refresh(now: now.addingTimeInterval(299))
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(fixture.monitor.statusByID.isEmpty)
        await fixture.monitor.refresh(now: now.addingTimeInterval(300))
        #expect(await fixture.probe.totalCalls() == 2)
    }

    @Test
    func failedQueryClearsAllProvidersSharingItsPreviousIncident() async {
        let fixture = Fixture(["gemini", "antigravity"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        #expect(fixture.monitor.statusByID.count == 2)
        await fixture.probe.setMode(.failure)
        await fixture.monitor.refresh(now: now.addingTimeInterval(300))
        #expect(fixture.monitor.statusByID.isEmpty)
        #expect(await fixture.probe.totalCalls() == 2)
    }

    @Test
    func disablingTheSettingClearsIncidentsAndRejectsItsLateResponse() async {
        let fixture = Fixture(["claude"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        #expect(fixture.monitor.statusByID.count == 1)
        await fixture.probe.setMode(.held)
        let refresh = Task { await fixture.monitor.refresh(now: now.addingTimeInterval(300)) }
        await waitUntil { await fixture.probe.pendingCount() == 1 }
        fixture.defaults.set(false, forKey: ProviderServiceStatusMonitor.settingKey)
        await waitUntil { fixture.monitor.statusByID.isEmpty }
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "claude")) == nil)
        fixture.defaults.set(true, forKey: ProviderServiceStatusMonitor.settingKey)
        await fixture.monitor.refresh(now: now.addingTimeInterval(301))
        #expect(await fixture.probe.totalCalls() == 2)
        #expect(fixture.monitor.statusByID.isEmpty)
        await fixture.probe.completePending(severity: .critical)
        await refresh.value
        #expect(fixture.monitor.statusByID.isEmpty)
        #expect(await fixture.probe.cancellationsAtReturn() == 1)
        await fixture.probe.setMode(.success(.minor))
        await fixture.monitor.refresh(now: now.addingTimeInterval(600))
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "claude"))?.severity == .minor)
        #expect(await fixture.probe.totalCalls() == 3)
    }

    @Test
    func disablingAProviderClearsItAndRejectsItsLateResponse() async {
        let fixture = Fixture(["claude"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        await fixture.probe.setMode(.held)
        let refresh = Task { await fixture.monitor.refresh(now: now.addingTimeInterval(300)) }
        await waitUntil { await fixture.probe.pendingCount() == 1 }
        fixture.ids = []
        fixture.monitor.providersDidChange()
        #expect(fixture.monitor.statusByID.isEmpty)
        fixture.ids = [ProviderID(rawValue: "claude")]
        fixture.monitor.providersDidChange()
        await fixture.monitor.refresh(now: now.addingTimeInterval(301))
        #expect(await fixture.probe.totalCalls() == 2)
        #expect(fixture.monitor.statusByID.isEmpty)
        await fixture.probe.completePending(severity: .critical)
        await refresh.value
        #expect(fixture.monitor.statusByID.isEmpty)
        #expect(await fixture.probe.cancellationsAtReturn() == 1)
        await fixture.probe.setMode(.success(.minor))
        await fixture.monitor.refresh(now: now.addingTimeInterval(600))
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "claude"))?.severity == .minor)
        #expect(await fixture.probe.totalCalls() == 3)
    }

    @Test
    func disablingOneSharedProviderKeepsTheOtherResponse() async {
        let fixture = Fixture(["gemini", "antigravity"], mode: .held)
        defer { fixture.stop() }
        fixture.start()
        let refresh = Task { await fixture.monitor.refresh() }
        await waitUntil { await fixture.probe.pendingCount() == 1 }
        fixture.ids = [ProviderID(rawValue: "antigravity")]
        fixture.monitor.providersDidChange()
        await fixture.probe.completePending(severity: .major)
        await refresh.value
        #expect(Set(fixture.monitor.statusByID.keys) == [ProviderID(rawValue: "antigravity")])
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "antigravity"))?.severity == .major)
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(await fixture.probe.cancellationsAtReturn() == 0)
    }

    @Test
    func storedDisabledSettingPreventsPollingAndEnablingStartsIt() async {
        let fixture = Fixture(["claude"], initiallyEnabled: false)
        defer { fixture.stop() }
        fixture.start()
        await fixture.monitor.refresh()
        #expect(await fixture.probe.totalCalls() == 0)
        fixture.defaults.set(true, forKey: ProviderServiceStatusMonitor.settingKey)
        await waitUntil { await fixture.probe.totalCalls() == 1 }
        await waitUntil { fixture.monitor.statusByID.count == 1 }
        fixture.start()
        await fixture.monitor.refresh()
        #expect(await fixture.probe.totalCalls() == 1)
    }

    @Test
    func stoppingCancelsRequestsAndSettingChangesDoNotRestartIt() async {
        let fixture = Fixture(["claude"], mode: .held)
        defer { fixture.stop() }
        fixture.start()
        let refresh = Task { await fixture.monitor.refresh() }
        await waitUntil { await fixture.probe.pendingCount() == 1 }
        fixture.monitor.stop()
        fixture.defaults.set(false, forKey: ProviderServiceStatusMonitor.settingKey)
        fixture.defaults.set(true, forKey: ProviderServiceStatusMonitor.settingKey)
        await fixture.probe.completePending(severity: .critical)
        await refresh.value
        fixture.monitor.providersDidChange()
        await fixture.monitor.refresh()
        #expect(fixture.monitor.statusByID.isEmpty)
        #expect(await fixture.probe.totalCalls() == 1)
        #expect(await fixture.probe.cancellationsAtReturn() == 1)
    }

    @Test(arguments: [ProviderServiceSeverity.none, .unknown])
    func normalAndUnknownResponsesReplaceThePreviousIncident(severity: ProviderServiceSeverity) async {
        let fixture = Fixture(["claude"])
        defer { fixture.stop() }
        let now = Date()
        fixture.start()
        await fixture.monitor.refresh(now: now)
        await fixture.probe.setMode(.success(severity))
        await fixture.monitor.refresh(now: now.addingTimeInterval(300))
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "claude"))?.severity == severity)
        #expect(fixture.monitor.status(for: ProviderID(rawValue: "claude"))?.hasIssue == false)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("状态监控未在测试期限内完成")
    }
}

@MainActor
private final class Fixture {
    let suite = "YomiStatusMonitorTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let probe: StatusFetchProbe
    let monitor: ProviderServiceStatusMonitor
    var ids: [ProviderID]
    var interval: TimeInterval

    init(
        _ providers: [String],
        interval: TimeInterval = 300,
        initiallyEnabled: Bool? = nil,
        mode: StatusFetchProbe.Mode = .success(.minor)
    ) {
        defaults = TestUserDefaults(suiteName: suite)!
        if let initiallyEnabled { defaults.set(initiallyEnabled, forKey: ProviderServiceStatusMonitor.settingKey) }
        let probe = StatusFetchProbe(mode: mode)
        self.probe = probe
        monitor = ProviderServiceStatusMonitor(defaults: defaults, fetcher: { try await probe.fetch($0) })
        ids = providers.map { ProviderID(rawValue: $0) }
        self.interval = interval
    }

    func start() {
        monitor.start(providerIDs: { [weak self] in self?.ids ?? [] }, usageInterval: { [weak self] in self?.interval ?? 300 })
    }

    func stop() {
        monitor.stop()
        TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite)
    }
}

private actor StatusFetchProbe {
    enum Mode: Sendable {
        case success(ProviderServiceSeverity)
        case failure
        case held
    }

    enum Failure: Error { case unavailable }

    private var mode: Mode
    private var calls = 0
    private var cancellations = 0
    private var pending: [ProviderServiceStatusSource: [CheckedContinuation<ProviderServiceStatus, Never>]] = [:]

    init(mode: Mode) { self.mode = mode }

    func setMode(_ mode: Mode) { self.mode = mode }
    func totalCalls() -> Int { calls }
    func pendingCount() -> Int { pending.values.reduce(0) { $0 + $1.count } }
    func cancellationsAtReturn() -> Int { cancellations }

    func fetch(_ source: ProviderServiceStatusSource) async throws -> ProviderServiceStatus {
        calls += 1
        switch mode {
        case let .success(severity): return Self.status(source: source, severity: severity)
        case .failure: throw Failure.unavailable
        case .held:
            let result = await withCheckedContinuation { pending[source, default: []].append($0) }
            if Task.isCancelled { cancellations += 1 }
            return result
        }
    }

    func completePending(severity: ProviderServiceSeverity) {
        let responses = pending
        pending.removeAll()
        for (source, continuations) in responses {
            for continuation in continuations { continuation.resume(returning: Self.status(source: source, severity: severity)) }
        }
    }

    private nonisolated static func status(
        source: ProviderServiceStatusSource, severity: ProviderServiceSeverity
    ) -> ProviderServiceStatus {
        ProviderServiceStatus(severity: severity, title: "Public incident", components: [], updatedAt: nil, pageURL: source.pageURL)
    }
}
