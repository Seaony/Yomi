import Foundation
import Testing
@testable import CodeEdge

struct ProviderBackoffTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func repeatedRateLimitsDoubleAndCapTheFallback() throws {
        var state: ProviderBackoffState?
        for expected in [60.0, 120, 240, 480, 900, 900, 900] {
            state = ProviderBackoffPolicy.updating(previous: state, httpStatus: 429, retryAfter: nil,
                                                   succeeded: false, now: now)
            #expect(try #require(state).retryAt.timeIntervalSince(now) == expected)
        }
    }

    @Test
    func respectsRetryAfterSecondsBeforeFallback() throws {
        let state = try #require(ProviderBackoffPolicy.updating(
            previous: nil, httpStatus: 429, retryAfter: " 2400 ", succeeded: false, now: now
        ))
        #expect(state.retryAt == now.addingTimeInterval(2400))
        #expect(ProviderBackoffPolicy.retryAfterDate("0", now: now) == now)
        #expect(ProviderBackoffPolicy.retryAfterDate("1.5", now: now) == now.addingTimeInterval(1.5))
    }

    @Test
    func respectsHTTPDateAndDoesNotSchedulePastDates() {
        #expect(ProviderBackoffPolicy.retryAfterDate("Fri, 15 Jan 2027 08:07:00 GMT", now: now)
            == now.addingTimeInterval(420))
        #expect(ProviderBackoffPolicy.retryAfterDate("Fri, 15 Jan 2027 07:59:00 GMT", now: now) == now)
    }

    @Test(arguments: ["", "tomorrow", "-1", "nan", "inf"])
    func malformedRetryAfterUsesFallback(value: String) throws {
        #expect(ProviderBackoffPolicy.retryAfterDate(value, now: now) == nil)
        let state = try #require(ProviderBackoffPolicy.updating(
            previous: nil, httpStatus: 429, retryAfter: value, succeeded: false, now: now
        ))
        #expect(state.retryAt == now.addingTimeInterval(60))
    }

    @Test
    func manualRefreshBypassesDeadlineAndAutomaticRefreshWaits() {
        let state = ProviderBackoffState(consecutiveRateLimits: 1, retryAt: now.addingTimeInterval(60))
        #expect(!ProviderBackoffPolicy.canRefresh(state: state, now: now, isManual: false))
        #expect(ProviderBackoffPolicy.canRefresh(state: state, now: now, isManual: true))
        #expect(ProviderBackoffPolicy.canRefresh(state: state, now: state.retryAt, isManual: false))
        #expect(ProviderBackoffPolicy.canRefresh(state: nil, now: now, isManual: false))
        #expect(ProviderBackoffPolicy.remaining(state: state, now: now) == 60)
        #expect(ProviderBackoffPolicy.remaining(state: state, now: state.retryAt.addingTimeInterval(1)) == 0)
    }

    @Test
    func deadlineAndAttemptCountSurviveRestart() throws {
        let state = ProviderBackoffState(consecutiveRateLimits: 3, retryAt: now.addingTimeInterval(240))
        let data = try JSONEncoder().encode(["codex": state])
        let restored = try JSONDecoder().decode([String: ProviderBackoffState].self, from: data)
        #expect(restored["codex"] == state)
        #expect(restored["claude"] == nil)
        #expect(!ProviderBackoffPolicy.canRefresh(state: restored["codex"], now: now, isManual: false))
        let next = try #require(ProviderBackoffPolicy.updating(
            previous: restored["codex"], httpStatus: 429, retryAfter: nil, succeeded: false, now: now
        ))
        #expect(next.retryAt == now.addingTimeInterval(480))
    }

    @Test
    func successClearsRateLimitEvenAfterFallbackAndOtherErrorsPreserveIt() {
        let state = ProviderBackoffState(consecutiveRateLimits: 2, retryAt: now.addingTimeInterval(120))
        #expect(ProviderBackoffPolicy.updating(previous: state, httpStatus: 429, retryAfter: nil,
                                              succeeded: true, now: now) == nil)
        #expect(ProviderBackoffPolicy.updating(previous: state, httpStatus: 503, retryAfter: nil,
                                              succeeded: false, now: now) == state)
        #expect(ProviderBackoffPolicy.updating(previous: nil, httpStatus: nil, retryAfter: nil,
                                              succeeded: false, now: now) == nil)
    }

    @Test
    func expiredDuringTheRemainingBatchIsImmediatelyDue() throws {
        let state = try #require(ProviderBackoffPolicy.updating(
            previous: nil, httpStatus: 429, retryAfter: "60", succeeded: false,
            now: now.addingTimeInterval(-120)
        ))
        let plan = ProviderBackoffPolicy.plan(
            stateByID: ["codex": state], enabledProviderIDs: [ProviderID(rawValue: "codex")],
            attemptedRetries: [:], now: now
        )
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "codex")])
        #expect(plan.attemptedRetries == ["codex": state.retryAt])
        #expect(plan.nextDeadline == nil)
    }

    @Test(arguments: ["0", "Fri, 15 Jan 2027 07:59:00 GMT"])
    func zeroAndPastRetryAfterAreImmediatelyDue(value: String) throws {
        let state = try #require(ProviderBackoffPolicy.updating(
            previous: nil, httpStatus: 429, retryAfter: value, succeeded: false, now: now
        ))
        let plan = ProviderBackoffPolicy.plan(
            stateByID: ["claude": state], enabledProviderIDs: [ProviderID(rawValue: "claude")],
            attemptedRetries: [:], now: now
        )
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "claude")])
        #expect(plan.attemptedRetries["claude"] == now)
    }

    @Test
    func failedRetryDoesNotRepeatTheSameDeadline() throws {
        let state = ProviderBackoffState(consecutiveRateLimits: 1, retryAt: now)
        let first = ProviderBackoffPolicy.plan(
            stateByID: ["codex": state], enabledProviderIDs: [ProviderID(rawValue: "codex")],
            attemptedRetries: [:], now: now
        )
        #expect(first.dueProviderIDs == [ProviderID(rawValue: "codex")])
        let failed = try #require(ProviderBackoffPolicy.updating(
            previous: state, httpStatus: 503, retryAfter: nil, succeeded: false,
            now: now.addingTimeInterval(10)
        ))
        let second = ProviderBackoffPolicy.plan(
            stateByID: ["codex": failed], enabledProviderIDs: [ProviderID(rawValue: "codex")],
            attemptedRetries: first.attemptedRetries, now: now.addingTimeInterval(10)
        )
        #expect(second.dueProviderIDs.isEmpty)
        #expect(second.nextDeadline == nil)
        #expect(second.attemptedRetries == first.attemptedRetries)
    }

    @Test
    func schedulesAllDueProvidersAndTheEarliestEnabledFutureDeadline() {
        let stateByID: [String: ProviderBackoffState] = [
            "codex": .init(consecutiveRateLimits: 1, retryAt: now),
            "claude": .init(consecutiveRateLimits: 2, retryAt: now.addingTimeInterval(-60)),
            "cursor": .init(consecutiveRateLimits: 1, retryAt: now.addingTimeInterval(120)),
            "kiro": .init(consecutiveRateLimits: 1, retryAt: now.addingTimeInterval(60)),
            "disabled-past": .init(consecutiveRateLimits: 1, retryAt: now.addingTimeInterval(-1)),
            "disabled-future": .init(consecutiveRateLimits: 1, retryAt: now.addingTimeInterval(1)),
        ]
        let history = ["other": now.addingTimeInterval(-300)]
        let plan = ProviderBackoffPolicy.plan(
            stateByID: stateByID,
            enabledProviderIDs: Set(["codex", "claude", "cursor", "kiro"].map { ProviderID(rawValue: $0) }),
            attemptedRetries: history, now: now
        )
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "codex"), ProviderID(rawValue: "claude")])
        #expect(plan.nextDeadline == now.addingTimeInterval(60))
        #expect(plan.attemptedRetries["codex"] == now)
        #expect(plan.attemptedRetries["claude"] == now.addingTimeInterval(-60))
        #expect(plan.attemptedRetries["other"] == history["other"])
        #expect(plan.attemptedRetries["cursor"] == nil)
        #expect(plan.attemptedRetries["disabled-past"] == nil)
    }

    @Test
    func aNewDeadlineCanBeAttemptedAgain() {
        let previousDeadline = now.addingTimeInterval(-60)
        let state = ProviderBackoffState(consecutiveRateLimits: 2, retryAt: now)
        let plan = ProviderBackoffPolicy.plan(
            stateByID: ["codex": state], enabledProviderIDs: [ProviderID(rawValue: "codex")],
            attemptedRetries: ["codex": previousDeadline], now: now
        )
        #expect(plan.dueProviderIDs == [ProviderID(rawValue: "codex")])
        #expect(plan.attemptedRetries["codex"] == state.retryAt)
    }
}
