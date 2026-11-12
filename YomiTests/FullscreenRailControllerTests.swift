import Foundation
import Testing
@testable import Yomi

struct FullscreenRailControllerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func pendingDetectionCancelsAnExpiredCollapseDeadline() {
        let previous = FullscreenCollapsePolicy.State(
            collapseAt: now.addingTimeInterval(-1), wasFullscreenEligible: true
        )
        let state = FullscreenRailController.resolveState(previous: previous, input: input(), detectionPending: true)
        #expect(!state.isCollapsed)
        #expect(state.collapseAt == nil)
        #expect(state.wasFullscreenEligible)
    }

    @Test
    func pendingDetectionDoesNotRevealAnAlreadyCollapsedRail() {
        let previous = FullscreenCollapsePolicy.State(isCollapsed: true, wasFullscreenEligible: true)
        let state = FullscreenRailController.resolveState(previous: previous, input: input(), detectionPending: true)
        #expect(state.isCollapsed)
        #expect(state.collapseAt == nil)
    }

    @Test
    func pointerAndWindowLocksCanRevealWhileDetectionIsPending() {
        let previous = FullscreenCollapsePolicy.State(isCollapsed: true, wasFullscreenEligible: true)
        for flag in 0..<5 {
            var current = input()
            switch flag {
            case 0: current.pointerInsideRail = true
            case 1: current.pointerInsideRevealStrip = true
            case 2: current.detailVisible = true
            case 3: current.billVisible = true
            default: current.revealRequested = true
            }
            let state = FullscreenRailController.resolveState(previous: previous, input: current, detectionPending: true)
            #expect(!state.isCollapsed)
            #expect(state.collapseAt == nil)
        }
    }

    @Test
    func disablingRevealsImmediatelyWhileDetectionIsPending() {
        let previous = FullscreenCollapsePolicy.State(isCollapsed: true, wasFullscreenEligible: true)
        var current = input()
        current.enabled = false
        let state = FullscreenRailController.resolveState(previous: previous, input: current, detectionPending: true)
        #expect(state == FullscreenCollapsePolicy.State())
    }

    @Test
    func resumedDetectionStartsAFullNewCollapseDelay() throws {
        let previous = FullscreenCollapsePolicy.State(
            collapseAt: now.addingTimeInterval(-1), wasFullscreenEligible: true
        )
        let held = FullscreenRailController.resolveState(previous: previous, input: input(), detectionPending: true)
        let resumedAt = now.addingTimeInterval(0.45)
        let resumed = FullscreenRailController.resolveState(
            previous: held, input: input(now: resumedAt), detectionPending: false
        )
        #expect(!resumed.isCollapsed)
        let deadline = try #require(resumed.collapseAt)
        #expect(deadline == resumedAt.addingTimeInterval(0.45))
        #expect(!FullscreenRailController.resolveState(
            previous: resumed, input: input(now: deadline.addingTimeInterval(-0.001)), detectionPending: false
        ).isCollapsed)
        #expect(FullscreenRailController.resolveState(
            previous: resumed, input: input(now: deadline), detectionPending: false
        ).isCollapsed)
    }

    @Test
    func pointerPollingCannotStartACountdownBeforeConfirmation() {
        var state = FullscreenCollapsePolicy.State(wasFullscreenEligible: true)
        for elapsed in [0.0, 0.25, 0.5, 1.0] {
            state = FullscreenRailController.resolveState(
                previous: state, input: input(now: now.addingTimeInterval(elapsed)), detectionPending: true
            )
            #expect(!state.isCollapsed)
            #expect(state.collapseAt == nil)
        }
    }

    private func input(now: Date? = nil) -> FullscreenCollapsePolicy.Input {
        .init(enabled: true, isFullscreenOnTargetScreen: true, now: now ?? self.now)
    }
}
