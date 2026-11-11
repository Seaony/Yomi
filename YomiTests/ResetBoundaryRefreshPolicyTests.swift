import Foundation
import Testing
@testable import Yomi

struct ResetBoundaryRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func schedulesEveryDueProviderAndTheEarliestFutureWindow() {
        let usages = [
            usage("claude", windows: [window("session", reset: now), window("weekly", reset: now.addingTimeInterval(60))]),
            usage("codex", windows: [window("weekly", reset: now.addingTimeInterval(-1))]),
            usage("gemini", windows: [], additional: [window("daily", reset: now.addingTimeInterval(30))]),
        ]
        let plan = ResetBoundaryRefreshPolicy.plan(usages: usages, attemptedBoundaries: [], now: now)
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "claude"), ProviderID(rawValue: "codex")])
        #expect(plan.nextDeadline == now.addingTimeInterval(30))
        #expect(plan.attemptedBoundaries.count == 2)
    }

    @Test
    func duplicateWindowsAndProviderSnapshotsOnlyCountOnce() {
        let repeated = window("weekly", reset: now)
        let snapshot = usage("codex", windows: [repeated, repeated], additional: [repeated])
        let plan = ResetBoundaryRefreshPolicy.plan(usages: [snapshot, snapshot], attemptedBoundaries: [], now: now)
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "codex")])
        #expect(plan.attemptedBoundaries == [
            .init(providerID: snapshot.id, resetsAt: now),
        ])
        #expect(plan.nextDeadline == nil)
    }

    @Test
    func failedRefreshDoesNotRetryTheSameExpiredCachedBoundary() {
        var cached = usage("claude", windows: [window("session", reset: now.addingTimeInterval(-3600))],
                           state: .unavailable)
        cached.updatedAt = now.addingTimeInterval(-7200)
        let first = ResetBoundaryRefreshPolicy.plan(usages: [cached], attemptedBoundaries: [], now: now)
        #expect(first.dueProviderIDs == [cached.id])
        let second = ResetBoundaryRefreshPolicy.plan(
            usages: [cached], attemptedBoundaries: first.attemptedBoundaries, now: now.addingTimeInterval(60)
        )
        #expect(second.dueProviderIDs.isEmpty)
        #expect(second.nextDeadline == nil)
        #expect(second.attemptedBoundaries == first.attemptedBoundaries)
    }

    @Test
    func newCycleOfTheSameWindowCanTriggerAgain() {
        let original = usage("codex", windows: [window("weekly", reset: now)])
        let first = ResetBoundaryRefreshPolicy.plan(usages: [original], attemptedBoundaries: [], now: now)
        let newReset = now.addingTimeInterval(300)
        let nextCycle = usage("codex", windows: [window("weekly", reset: newReset)])
        let waiting = ResetBoundaryRefreshPolicy.plan(
            usages: [nextCycle], attemptedBoundaries: first.attemptedBoundaries, now: now
        )
        #expect(waiting.dueProviderIDs.isEmpty)
        #expect(waiting.nextDeadline == newReset)
        #expect(waiting.attemptedBoundaries == first.attemptedBoundaries)
        let due = ResetBoundaryRefreshPolicy.plan(
            usages: [nextCycle], attemptedBoundaries: waiting.attemptedBoundaries, now: newReset
        )
        #expect(due.dueProviderIDs == [nextCycle.id])
        #expect(due.attemptedBoundaries.count == 2)
        #expect(due.nextDeadline == nil)
    }

    @Test
    func providersRemainIndependentWhileWindowsShareAResetBoundary() {
        let usages = [
            usage("claude", windows: [window("shared", reset: now), window("different", reset: now)]),
            usage("codex", windows: [window("shared", reset: now)]),
        ]
        let plan = ResetBoundaryRefreshPolicy.plan(usages: usages, attemptedBoundaries: [], now: now)
        #expect(plan.dueProviderIDs.count == 2)
        #expect(plan.attemptedBoundaries.count == 2)
    }

    @Test
    func windowsWithoutAResetAreIgnoredAndHistoryIsPreserved() {
        let previous = ResetBoundaryRefreshPolicy.Boundary(
            providerID: ProviderID(rawValue: "claude"), resetsAt: now.addingTimeInterval(-60)
        )
        let plan = ResetBoundaryRefreshPolicy.plan(
            usages: [usage("claude", windows: [window("unknown", reset: nil)])],
            attemptedBoundaries: [previous], now: now
        )
        #expect(plan.dueProviderIDs.isEmpty)
        #expect(plan.nextDeadline == nil)
        #expect(plan.attemptedBoundaries == [previous])
    }

    @Test
    func fullAmpReplenishingBalanceDoesNotTriggerARefreshLoop() throws {
        let text = "Amp Free: $10/$10 remaining (replenishes +$0.5/hour)"
        var attempted: Set<ResetBoundaryRefreshPolicy.Boundary> = []
        for offset in [0.0, 1.0] {
            let reportedAt = now.addingTimeInterval(offset)
            let snapshot = try AmpUsageFetcher.parseDisplayText(text, now: reportedAt)
            let usage = AmpUsageFetcher.providerUsage(snapshot, now: reportedAt)
            #expect(usage.windows.first?.resetsAt == reportedAt)
            let plan = ResetBoundaryRefreshPolicy.plan(
                usages: [usage], attemptedBoundaries: attempted, now: reportedAt
            )
            #expect(plan.dueProviderIDs.isEmpty)
            #expect(plan.nextDeadline == nil)
            #expect(plan.attemptedBoundaries == attempted)
            attempted = plan.attemptedBoundaries
        }
    }

    @Test(arguments: [-60.0, 0.0])
    func resetAlreadyExpiredWhenReportedIsIgnored(resetOffset: TimeInterval) {
        let usage = ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: .ready,
            windows: [window("weekly", reset: now.addingTimeInterval(resetOffset))], updatedAt: now
        )
        let plan = ResetBoundaryRefreshPolicy.plan(
            usages: [usage], attemptedBoundaries: [], now: now.addingTimeInterval(60)
        )
        #expect(plan.dueProviderIDs.isEmpty)
        #expect(plan.nextDeadline == nil)
        #expect(plan.attemptedBoundaries.isEmpty)
    }

    @Test
    func missingObservationTimeCannotScheduleAReset() {
        let usage = ProviderUsage(
            id: ProviderID(rawValue: "claude"), state: .unavailable,
            windows: [window("session", reset: now.addingTimeInterval(60))], updatedAt: nil
        )
        let future = ResetBoundaryRefreshPolicy.plan(usages: [usage], attemptedBoundaries: [], now: now)
        #expect(future.dueProviderIDs.isEmpty)
        #expect(future.nextDeadline == nil)
        let expired = ResetBoundaryRefreshPolicy.plan(
            usages: [usage], attemptedBoundaries: future.attemptedBoundaries, now: now.addingTimeInterval(120)
        )
        #expect(expired.dueProviderIDs.isEmpty)
        #expect(expired.nextDeadline == nil)
        #expect(expired.attemptedBoundaries.isEmpty)
    }

    @Test
    func resetObservedInTheFutureRemainsDueWhenItsCachedDataAges() {
        let reset = now.addingTimeInterval(60)
        var usage = ProviderUsage(
            id: ProviderID(rawValue: "claude"), state: .ready,
            windows: [window("session", reset: reset)], updatedAt: now
        )
        let future = ResetBoundaryRefreshPolicy.plan(usages: [usage], attemptedBoundaries: [], now: now)
        #expect(future.dueProviderIDs.isEmpty)
        #expect(future.nextDeadline == reset)
        #expect(future.attemptedBoundaries.isEmpty)
        usage.state = .unavailable
        let due = ResetBoundaryRefreshPolicy.plan(
            usages: [usage], attemptedBoundaries: future.attemptedBoundaries, now: reset
        )
        #expect(due.dueProviderIDs == [usage.id])
        #expect(due.nextDeadline == nil)
        #expect(due.attemptedBoundaries == [.init(providerID: usage.id, resetsAt: reset)])
    }

    @Test
    func renamingAWindowAtTheSameResetDoesNotTriggerAgain() {
        let first = ResetBoundaryRefreshPolicy.plan(
            usages: [usage("claude", windows: [window("weekly", reset: now)])],
            attemptedBoundaries: [], now: now
        )
        let renamed = usage("claude", windows: [window("renamed-weekly", reset: now)])
        let second = ResetBoundaryRefreshPolicy.plan(
            usages: [renamed], attemptedBoundaries: first.attemptedBoundaries,
            lastTriggeredAtByProvider: first.lastTriggeredAtByProvider, now: now.addingTimeInterval(60)
        )
        #expect(first.dueProviderIDs == [renamed.id])
        #expect(second.dueProviderIDs.isEmpty)
        #expect(second.nextDeadline == nil)
        #expect(second.attemptedBoundaries == first.attemptedBoundaries)
    }

    @Test
    func anotherResetWaitsUntilSixtySecondsAfterThePreviousTrigger() {
        let original = usage("claude", windows: [window("session", reset: now)])
        let first = ResetBoundaryRefreshPolicy.plan(usages: [original], attemptedBoundaries: [], now: now)
        let next = usage("claude", windows: [window("weekly", reset: now.addingTimeInterval(30))])
        let waiting = ResetBoundaryRefreshPolicy.plan(
            usages: [next], attemptedBoundaries: first.attemptedBoundaries,
            lastTriggeredAtByProvider: first.lastTriggeredAtByProvider, now: now.addingTimeInterval(59)
        )
        #expect(waiting.dueProviderIDs.isEmpty)
        #expect(waiting.nextDeadline == now.addingTimeInterval(60))
        #expect(waiting.attemptedBoundaries == first.attemptedBoundaries)
        #expect(waiting.lastTriggeredAtByProvider[next.id] == now)
        let due = ResetBoundaryRefreshPolicy.plan(
            usages: [next], attemptedBoundaries: waiting.attemptedBoundaries,
            lastTriggeredAtByProvider: waiting.lastTriggeredAtByProvider, now: now.addingTimeInterval(60)
        )
        #expect(due.dueProviderIDs == [next.id])
        #expect(due.attemptedBoundaries.count == 2)
        #expect(due.lastTriggeredAtByProvider[next.id] == now.addingTimeInterval(60))
        #expect(due.nextDeadline == nil)
    }

    @Test
    func aProviderCoolingDownDoesNotDelayAnotherProvider() {
        let first = ResetBoundaryRefreshPolicy.plan(
            usages: [usage("claude", windows: [window("session", reset: now)])],
            attemptedBoundaries: [], now: now
        )
        let nextReset = now.addingTimeInterval(1)
        let usages = [
            usage("claude", windows: [window("weekly", reset: nextReset)]),
            usage("codex", windows: [window("weekly", reset: nextReset)]),
        ]
        let second = ResetBoundaryRefreshPolicy.plan(
            usages: usages, attemptedBoundaries: first.attemptedBoundaries,
            lastTriggeredAtByProvider: first.lastTriggeredAtByProvider, now: now.addingTimeInterval(2)
        )
        #expect(second.dueProviderIDs == [ProviderID(rawValue: "codex")])
        #expect(second.nextDeadline == now.addingTimeInterval(60))
        #expect(second.lastTriggeredAtByProvider[ProviderID(rawValue: "claude")] == now)
        #expect(second.lastTriggeredAtByProvider[ProviderID(rawValue: "codex")] == now.addingTimeInterval(2))
    }

    @Test
    func allDueResetsOfOneProviderShareOneTrigger() {
        let snapshot = usage(
            "claude", windows: [window("session", reset: now.addingTimeInterval(-10)), window("weekly", reset: now)],
            additional: [window("model-weekly", reset: now), window("another", reset: now.addingTimeInterval(-5))]
        )
        let first = ResetBoundaryRefreshPolicy.plan(usages: [snapshot], attemptedBoundaries: [], now: now)
        #expect(first.dueProviderIDs == [snapshot.id])
        #expect(first.attemptedBoundaries.count == 3)
        #expect(first.lastTriggeredAtByProvider[snapshot.id] == now)
        let repeated = ResetBoundaryRefreshPolicy.plan(
            usages: [snapshot], attemptedBoundaries: first.attemptedBoundaries,
            lastTriggeredAtByProvider: first.lastTriggeredAtByProvider, now: now.addingTimeInterval(1)
        )
        #expect(repeated.dueProviderIDs.isEmpty)
        #expect(repeated.nextDeadline == nil)
    }

    @Test
    func aFutureObservedResetIsScheduledAndRecordsItsTriggerTime() {
        let reset = now.addingTimeInterval(120)
        let snapshot = ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: .ready,
            windows: [window("weekly", reset: reset)], updatedAt: now
        )
        let future = ResetBoundaryRefreshPolicy.plan(usages: [snapshot], attemptedBoundaries: [], now: now)
        #expect(future.dueProviderIDs.isEmpty)
        #expect(future.nextDeadline == reset)
        #expect(future.lastTriggeredAtByProvider.isEmpty)
        let due = ResetBoundaryRefreshPolicy.plan(
            usages: [snapshot], attemptedBoundaries: future.attemptedBoundaries,
            lastTriggeredAtByProvider: future.lastTriggeredAtByProvider, now: reset
        )
        #expect(due.dueProviderIDs == [snapshot.id])
        #expect(due.lastTriggeredAtByProvider[snapshot.id] == reset)
    }

    private func usage(
        _ provider: String,
        windows: [UsageWindow],
        additional: [UsageWindow] = [],
        state: ProviderUsage.State = .ready
    ) -> ProviderUsage {
        ProviderUsage(id: ProviderID(rawValue: provider), state: state, windows: windows,
                      additionalWindows: additional, updatedAt: now.addingTimeInterval(-3600))
    }

    private func window(_ id: String, reset: Date?) -> UsageWindow {
        UsageWindow(id: id, label: id, usedFraction: 0.5, resetsAt: reset)
    }
}
