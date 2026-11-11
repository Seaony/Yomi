import Foundation
import Testing
@testable import Yomi

struct QuotaNotificationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let provider = ProviderID(rawValue: "claude")
    private let settings = QuotaNotificationPolicy.Settings(
        lowQuotaEnabled: true, depletedEnabled: true, resetEnabled: true
    )

    @Test
    func firstRefreshOnlyRecordsEvenWhenDepleted() throws {
        let result = evaluate(used: 1, first: true)
        #expect(result.events.isEmpty)
        let tracked = try #require(result.state?.windows["session"])
        #expect(tracked.firedThresholds == [50, 20])
        #expect(tracked.depletedFired)
        #expect(evaluate(used: 1, previous: result.state).events.isEmpty)
    }

    @Test
    func firstProviderSampleAndNewWindowsOnlyRecord() {
        let initial = evaluate(used: 0.9)
        #expect(initial.events.isEmpty)
        let anotherWindow = ProviderUsage(id: provider, state: .ready, windows: [
            UsageWindow(id: "new-window", label: "Ignored label", usedFraction: 1),
        ])
        let result = QuotaNotificationPolicy.reduce(
            usage: anotherWindow, previous: initial.state, isFirstRefresh: false, settings: settings, now: now
        )
        #expect(result.events.isEmpty)
        #expect(result.state?.windows["new-window"]?.depletedFired == true)
    }

    @Test
    func thresholdsFireOncePerCycleEvenWhenUsageFallsAndRises() throws {
        let baseline = evaluate(used: 0.1, first: true)
        let warning = evaluate(used: 0.55, previous: baseline.state)
        #expect(warning.events.map(\.kind) == [.lowQuota])
        #expect(warning.events.first?.threshold == 50)
        let lower = evaluate(used: 0.1, previous: warning.state)
        #expect(evaluate(used: 0.7, previous: lower.state).events.isEmpty)
        let urgent = evaluate(used: 0.85, previous: warning.state)
        #expect(urgent.events.first?.threshold == 20)
        #expect(evaluate(used: 0.9, previous: urgent.state).events.isEmpty)
        let tracked = try #require(urgent.state?.windows["session"])
        #expect(tracked.firedThresholds == [50, 20])
    }

    @Test
    func jumpAcrossSeveralThresholdsUsesMostUrgentAndDepletionTakesPriority() {
        let baseline = evaluate(used: 0.1, first: true)
        let warning = evaluate(used: 0.9, previous: baseline.state)
        #expect(warning.events.count == 1)
        #expect(warning.events.first?.threshold == 20)
        #expect(warning.state?.windows["session"]?.firedThresholds == [50, 20])
        let exhausted = evaluate(used: 1, previous: baseline.state)
        #expect(exhausted.events.map(\.kind) == [.depleted])
        #expect(evaluate(used: 1, previous: exhausted.state).events.isEmpty)
    }

    @Test
    func elapsedResetStartsNewThresholdCycle() {
        let oldReset = now.addingTimeInterval(-1)
        let newReset = now.addingTimeInterval(18_000)
        let baseline = evaluate(used: 0.1, first: true, reset: oldReset)
        let warning = evaluate(used: 0.9, previous: baseline.state, reset: oldReset)
        let restored = evaluate(used: 0.1, previous: warning.state, reset: newReset)
        #expect(restored.events.map(\.kind) == [.reset])
        #expect(restored.state?.windows["session"]?.firedThresholds.isEmpty == true)
        let nextWarning = evaluate(used: 0.55, previous: restored.state, reset: newReset)
        #expect(nextWarning.events.first?.threshold == 50)
        #expect(evaluate(used: 0.55, previous: nextWarning.state, reset: newReset).events.isEmpty)
    }

    @Test(arguments: [0.1, 0.15])
    func smallUsageResetDoesNotNotifyButStillStartsNewCycle(used: Double) {
        let baseline = evaluate(used: used, first: true, reset: now.addingTimeInterval(-1))
        let restored = evaluate(used: 0, previous: baseline.state, reset: now.addingTimeInterval(18_000))
        #expect(restored.events.isEmpty)
        #expect(restored.state?.windows["session"]?.peakUsedFraction == 0)
        #expect(evaluate(used: 0.6, previous: restored.state, reset: now.addingTimeInterval(18_000))
            .events.first?.threshold == 50)
    }

    @Test
    func futureDeadlineDriftAndPercentageDropDoNotCountAsReset() {
        let baseline = evaluate(used: 0.9, first: true, reset: now.addingTimeInterval(60))
        let correction = evaluate(used: 0.05, previous: baseline.state, reset: now.addingTimeInterval(120))
        #expect(correction.events.isEmpty)
        #expect(correction.state?.windows["session"]?.firedThresholds == [50, 20])
        #expect(evaluate(used: 0.9, previous: correction.state, reset: now.addingTimeInterval(120))
            .events.isEmpty)
        let noDeadline = evaluate(used: 0.9, first: true)
        #expect(evaluate(used: 0, previous: noDeadline.state).events.isEmpty)
    }

    @Test(arguments: [ProviderUsage.State.failed, .unavailable, .loading])
    func failedAndCachedSamplesDoNotNotifyOrChangeBaseline(state: ProviderUsage.State) {
        let baseline = evaluate(used: 0.1, first: true)
        let result = evaluate(used: 1, previous: baseline.state, state: state)
        #expect(result.events.isEmpty)
        #expect(result.state == baseline.state)
        let firstFailure = evaluate(used: 1, state: state, first: true)
        #expect(firstFailure.state == nil)
    }

    @Test
    func restartPreservesFiredThresholdsAndConsumesFirstFreshSample() throws {
        let baseline = evaluate(used: 0.1, first: true)
        let warning = evaluate(used: 0.9, previous: baseline.state)
        let data = try JSONEncoder().encode(try #require(warning.state))
        let restored = try JSONDecoder().decode(QuotaNotificationPolicy.State.self, from: data)
        let first = evaluate(used: 1, previous: restored, first: true)
        #expect(first.events.isEmpty)
        #expect(evaluate(used: 1, previous: first.state).events.isEmpty)
        let correction = evaluate(used: 0.1, previous: first.state)
        #expect(evaluate(used: 0.9, previous: correction.state).events.isEmpty)
    }

    @Test
    func startupAfterResetRecordsNewCycleWithoutNotifying() {
        let previous = evaluate(used: 0.9, first: true, reset: now.addingTimeInterval(-1))
        let first = evaluate(used: 0.1, previous: previous.state, first: true,
                             reset: now.addingTimeInterval(18_000))
        #expect(first.events.isEmpty)
        #expect(first.state?.windows["session"]?.firedThresholds.isEmpty == true)
        #expect(evaluate(used: 0.55, previous: first.state, reset: now.addingTimeInterval(18_000))
            .events.first?.threshold == 50)
    }

    @Test
    func disabledAlertsStillConsumeCrossingsAndRevisionChangeRebuildsBaseline() {
        let baseline = evaluate(used: 0.1, first: true)
        let muted = evaluate(used: 0.9, previous: baseline.state, settings: .init())
        #expect(muted.events.isEmpty)
        #expect(evaluate(used: 0.95, previous: muted.state).events.isEmpty)
        let switched = evaluate(used: 1, previous: muted.state, revision: 1)
        #expect(switched.events.isEmpty)
        #expect(switched.state?.revision == 1)
    }

    @Test
    func windowsTrackIndependentlyAndDuplicateIdentifiersDoNotDoubleNotify() {
        let baseline = ProviderUsage(id: provider, state: .ready, windows: [
            UsageWindow(id: "session", label: "Session", usedFraction: 0.1),
            UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.1),
        ])
        let first = QuotaNotificationPolicy.reduce(
            usage: baseline, previous: nil, isFirstRefresh: true, settings: settings, now: now
        )
        let current = ProviderUsage(id: provider, state: .ready, windows: [
            UsageWindow(id: "session", label: "private.person@example.com", usedFraction: 0.9),
            UsageWindow(id: "weekly", label: "Bearer private-secret", usedFraction: 0.6),
        ], additionalWindows: [
            UsageWindow(id: "session", label: "Ignored duplicate", usedFraction: 1),
        ])
        let next = QuotaNotificationPolicy.reduce(
            usage: current, previous: first.state, isFirstRefresh: false, settings: settings, now: now
        )
        #expect(next.events.map(\.windowID) == ["session", "weekly"])
        #expect(next.events.map(\.threshold) == [20, 50])
        #expect(!String(describing: next.events).contains("private"))
    }

    @Test
    func filtersInactiveThresholdsAndIgnoresUnusableFractions() {
        let custom = QuotaNotificationPolicy.Settings(thresholds: [50, 20, 20, 0, -1, 100])
        #expect(custom.activeThresholds == [50, 20])
        let baseline = evaluate(used: 0.1, first: true)
        #expect(evaluate(used: .nan, previous: baseline.state).state == baseline.state)
        #expect(evaluate(used: .infinity, previous: baseline.state).state == baseline.state)
    }

    private func evaluate(
        used: Double,
        previous: QuotaNotificationPolicy.State? = nil,
        state: ProviderUsage.State = .ready,
        first: Bool = false,
        reset: Date? = nil,
        revision: Int = 0,
        settings: QuotaNotificationPolicy.Settings? = nil
    ) -> QuotaNotificationPolicy.Reduction {
        QuotaNotificationPolicy.reduce(
            usage: ProviderUsage(id: provider, state: state, windows: [
                UsageWindow(id: "session", label: "Session", usedFraction: used, resetsAt: reset),
            ]),
            previous: previous, revision: revision, isFirstRefresh: first,
            settings: settings ?? self.settings, now: now
        )
    }
}
