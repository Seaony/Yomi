import Foundation
import Testing
@testable import CodeEdge

struct FullscreenDetectionDebounceTests {
    private typealias Debounce = FullscreenDetectionDebounce
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func startupWaitsForTwoSamplesAtLeastOneHundredFiftyMillisecondsApart() {
        let first = Debounce.sample(previous: .init(), value: true, now: now)
        let deadline = now.addingTimeInterval(0.15)
        #expect(first.committedValue == nil)
        #expect(first.state.committedValue == nil)
        #expect(first.state.candidate == true)
        #expect(first.nextCheckAt == deadline)

        let early = Debounce.sample(previous: first.state, value: true, now: deadline.addingTimeInterval(-0.001))
        #expect(early.committedValue == nil)
        #expect(early.nextCheckAt == deadline)
        let confirmed = Debounce.sample(previous: early.state, value: true, now: deadline)
        #expect(confirmed.committedValue == true)
        #expect(confirmed.state.committedValue == true)
        #expect(confirmed.state.candidate == nil)
        #expect(confirmed.state.candidateSince == nil)
        #expect(confirmed.nextCheckAt == nil)
    }

    @Test
    func spaceChangePreservesCommittedValueAndClearsTheCandidate() {
        let state = Debounce.spaceChanged(
            previous: .init(committedValue: false, candidate: true, candidateSince: now.addingTimeInterval(-1)),
            now: now
        )
        #expect(state.committedValue == false)
        #expect(state.ignoreUntil == now.addingTimeInterval(0.3))
        #expect(state.candidate == nil)
        #expect(state.candidateSince == nil)
    }

    @Test(arguments: [0.0, 0.15, 0.299])
    func samplesInsideThreeHundredMillisecondShieldCannotCommit(elapsed: TimeInterval) {
        let shielded = Debounce.spaceChanged(previous: .init(committedValue: false), now: now)
        let decision = Debounce.sample(previous: shielded, value: true, now: now.addingTimeInterval(elapsed))
        #expect(decision.committedValue == nil)
        #expect(decision.state == shielded)
        #expect(decision.nextCheckAt == now.addingTimeInterval(0.3))
        #expect(decision.discardReason == .spaceTransition)
    }

    @Test
    func exactShieldBoundaryStartsACandidateRatherThanCommittingIt() {
        let shielded = Debounce.spaceChanged(previous: .init(), now: now)
        let boundary = now.addingTimeInterval(0.3)
        let decision = Debounce.sample(previous: shielded, value: true, now: boundary)
        #expect(decision.committedValue == nil)
        #expect(decision.state.ignoreUntil == nil)
        #expect(decision.state.candidate == true)
        #expect(decision.state.candidateSince == boundary)
        #expect(decision.nextCheckAt == boundary.addingTimeInterval(0.15))
        #expect(decision.discardReason == .awaitingConfirmation)
    }

    @Test
    func measuredSpaceSwitchNeverCommitsTheTransientTrueReading() {
        // 17:15:00.322 切换 Space，17:15:00.685 才读到目标桌面的 false。
        let second = now.addingTimeInterval(17 * 3600 + 15 * 60)
        let spaceAt = second.addingTimeInterval(0.322)
        var state = Debounce.spaceChanged(previous: .init(), now: spaceAt)
        var commits: [Bool] = []
        let transient = Debounce.sample(previous: state, value: true, now: spaceAt)
        if let value = transient.committedValue { commits.append(value) }
        #expect(transient.committedValue == nil)
        state = transient.state

        let falseAt = second.addingTimeInterval(0.685)
        let candidate = Debounce.sample(previous: state, value: false, now: falseAt)
        if let value = candidate.committedValue { commits.append(value) }
        #expect(candidate.committedValue == nil)
        #expect(candidate.state.candidate == false)
        let deadline = falseAt.addingTimeInterval(0.15)
        let confirmed = Debounce.sample(previous: candidate.state, value: false, now: deadline)
        if let value = confirmed.committedValue { commits.append(value) }
        #expect(commits == [false])
        #expect(confirmed.state.committedValue == false)
    }

    @Test
    func ignoredSamplesDoNotStartTheConfirmationClock() {
        let shielded = Debounce.spaceChanged(previous: .init(), now: now)
        let ignored = Debounce.sample(previous: shielded, value: true, now: now.addingTimeInterval(0.2))
        let candidateAt = now.addingTimeInterval(0.3)
        let candidate = Debounce.sample(previous: ignored.state, value: true, now: candidateAt)
        let early = Debounce.sample(previous: candidate.state, value: true, now: now.addingTimeInterval(0.4))
        #expect(ignored.committedValue == nil)
        #expect(candidate.committedValue == nil)
        #expect(early.committedValue == nil)
        #expect(early.nextCheckAt == candidateAt.addingTimeInterval(0.15))
    }

    @Test
    func flippedCandidateMustStartANewConfirmationInterval() {
        let first = Debounce.sample(previous: .init(), value: true, now: now)
        let falseAt = now.addingTimeInterval(0.1)
        let flipped = Debounce.sample(previous: first.state, value: false, now: falseAt)
        #expect(flipped.committedValue == nil)
        #expect(flipped.state.candidate == false)
        #expect(flipped.state.candidateSince == falseAt)
        let trueAt = now.addingTimeInterval(0.2)
        let flippedAgain = Debounce.sample(previous: flipped.state, value: true, now: trueAt)
        let deadline = trueAt.addingTimeInterval(0.15)
        #expect(flippedAgain.committedValue == nil)
        #expect(flippedAgain.nextCheckAt == deadline)
        let early = Debounce.sample(previous: flippedAgain.state, value: true, now: deadline.addingTimeInterval(-0.001))
        #expect(early.committedValue == nil)
        #expect(Debounce.sample(previous: early.state, value: true, now: deadline).committedValue == true)
    }

    @Test
    func pollingDoesNotPushTheConfirmationDeadlineBack() {
        let first = Debounce.sample(previous: .init(), value: false, now: now)
        let second = Debounce.sample(previous: first.state, value: false, now: now.addingTimeInterval(0.1))
        #expect(second.committedValue == nil)
        #expect(second.state.candidateSince == now)
        #expect(second.nextCheckAt == now.addingTimeInterval(0.15))
    }

    @Test
    func repeatedSpaceChangeRestartsShieldAndDropsUnconfirmedSamples() {
        let candidate = Debounce.sample(previous: .init(committedValue: true), value: false, now: now)
        let repeatedAt = now.addingTimeInterval(0.1)
        let restarted = Debounce.spaceChanged(previous: candidate.state, now: repeatedAt)
        #expect(restarted.committedValue == true)
        #expect(restarted.candidate == nil)
        #expect(restarted.ignoreUntil == repeatedAt.addingTimeInterval(0.3))
        let ignored = Debounce.sample(previous: restarted, value: false, now: now.addingTimeInterval(0.3))
        #expect(ignored.committedValue == nil)
        #expect(ignored.discardReason == .spaceTransition)
        #expect(ignored.nextCheckAt == repeatedAt.addingTimeInterval(0.3))
    }

    @Test
    func alreadyCommittedValueIsNotCommittedAgain() {
        let previous = Debounce.State(committedValue: false)
        let decision = Debounce.sample(previous: previous, value: false, now: now)
        #expect(decision.state == previous)
        #expect(decision.committedValue == nil)
        #expect(decision.nextCheckAt == nil)
        #expect(decision.discardReason == .unchanged)
    }

    @Test
    func returningToCommittedValueClearsTheOppositeCandidate() {
        let candidate = Debounce.State(committedValue: true, candidate: false, candidateSince: now)
        let returned = Debounce.sample(previous: candidate, value: true, now: now.addingTimeInterval(0.14))
        #expect(returned.committedValue == nil)
        #expect(returned.state.candidate == nil)
        #expect(returned.state.candidateSince == nil)
        let nextAt = now.addingTimeInterval(0.2)
        let next = Debounce.sample(previous: returned.state, value: false, now: nextAt)
        #expect(next.committedValue == nil)
        #expect(next.nextCheckAt == nextAt.addingTimeInterval(0.15))
    }
}
