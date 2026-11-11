import CoreGraphics
import Foundation
import Testing
@testable import Yomi

struct FullscreenCollapsePolicyTests {
    private typealias Policy = FullscreenCollapsePolicy
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var fullscreenInput: Policy.Input {
        Policy.Input(enabled: true, isFullscreenOnTargetScreen: true, now: now)
    }

    @Test
    func normalDesktopKeepsTheRailExpanded() {
        let input = Policy.Input(enabled: true, isFullscreenOnTargetScreen: false, now: now)
        #expect(Policy.reduce(previous: Policy.State(), input: input) == Policy.State())
    }

    @Test
    func enteringFullscreenAwayFromTheEdgeCollapsesImmediately() {
        let state = Policy.reduce(previous: Policy.State(), input: fullscreenInput)
        #expect(state.isCollapsed)
        #expect(state.collapseAt == nil)
        #expect(state.wasFullscreenEligible)
    }

    @Test(arguments: [true, false])
    func touchingRailOrRevealStripExpandsImmediately(touchesStrip: Bool) {
        var input = fullscreenInput
        input.pointerInsideRevealStrip = touchesStrip
        input.pointerInsideRail = !touchesStrip
        let state = Policy.reduce(previous: Policy.State(isCollapsed: true, wasFullscreenEligible: true), input: input)
        #expect(!state.isCollapsed)
        #expect(state.collapseAt == nil)
    }

    @Test
    func explicitRevealWorksWithoutPointerAndThenUsesNormalGrace() {
        var input = fullscreenInput
        input.revealRequested = true
        let revealed = Policy.reduce(
            previous: Policy.State(isCollapsed: true, wasFullscreenEligible: true), input: input
        )
        #expect(!revealed.isCollapsed)
        #expect(revealed.collapseAt == nil)

        input.revealRequested = false
        input.now = now.addingTimeInterval(0.1)
        let pending = Policy.reduce(previous: revealed, input: input)
        #expect(!pending.isCollapsed)
        #expect(pending.collapseAt == input.now.addingTimeInterval(0.45))
        input.now = input.now.addingTimeInterval(0.45)
        #expect(Policy.reduce(previous: pending, input: input).isCollapsed)
    }

    @Test
    func leavingWaitsExactlyPointFourFiveSecondsWithoutPollsExtendingIt() {
        let expanded = Policy.State(wasFullscreenEligible: true)
        let pending = Policy.reduce(previous: expanded, input: fullscreenInput)
        let deadline = now.addingTimeInterval(0.45)
        #expect(!pending.isCollapsed)
        #expect(pending.collapseAt == deadline)

        var input = fullscreenInput
        input.now = now.addingTimeInterval(0.3)
        let polled = Policy.reduce(previous: pending, input: input)
        #expect(!polled.isCollapsed)
        #expect(polled.collapseAt == deadline)
        input.now = now.addingTimeInterval(0.449)
        #expect(!Policy.reduce(previous: polled, input: input).isCollapsed)
        input.now = deadline
        let collapsed = Policy.reduce(previous: polled, input: input)
        #expect(collapsed.isCollapsed)
        #expect(collapsed.collapseAt == nil)
    }

    @Test(arguments: [true, false])
    func detailOrBillKeepsTheRailOpenEvenWhenOldTimerExpires(showsBill: Bool) {
        var input = fullscreenInput
        input.now = now.addingTimeInterval(1)
        input.billVisible = showsBill
        input.detailVisible = !showsBill
        let pending = Policy.State(collapseAt: now.addingTimeInterval(0.45), wasFullscreenEligible: true)
        let state = Policy.reduce(previous: pending, input: input)
        #expect(!state.isCollapsed)
        #expect(state.collapseAt == nil)
        #expect(state.wasFullscreenEligible)
    }

    @Test
    func fullscreenOnAnotherScreenDoesNotChangeTheRail() {
        let target = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let input = Policy.Input(
            enabled: true,
            isFullscreenOnTargetScreen: FullscreenDetection.hasFullscreenWindow(
                screenBounds: target, windows: [.init(pid: 42, layer: 0, bounds: other)]
            ),
            now: now
        )
        #expect(Policy.reduce(previous: Policy.State(), input: input) == Policy.State())
    }

    @Test
    func turningTheSettingOffRestoresTheRailAndClearsTimers() {
        var input = fullscreenInput
        input.enabled = false
        for state in [
            Policy.State(isCollapsed: true, wasFullscreenEligible: true),
            Policy.State(collapseAt: now.addingTimeInterval(0.45), wasFullscreenEligible: true),
        ] {
            #expect(Policy.reduce(previous: state, input: input) == Policy.State())
        }
        #expect(Policy.defaultEnabled)
        #expect(Policy.settingKey == "collapse-in-fullscreen")
    }

    @Test
    func leavingFullscreenRestoresTheRailAndClearsTimers() {
        var input = fullscreenInput
        input.isFullscreenOnTargetScreen = false
        #expect(Policy.reduce(
            previous: Policy.State(isCollapsed: true, wasFullscreenEligible: true), input: input
        ) == Policy.State())
    }

    @Test
    func returningBeforeTheDeadlineCancelsThePendingCollapse() {
        let pending = Policy.reduce(previous: Policy.State(wasFullscreenEligible: true), input: fullscreenInput)
        var input = fullscreenInput
        input.now = now.addingTimeInterval(0.4)
        input.pointerInsideRail = true
        let returned = Policy.reduce(previous: pending, input: input)
        #expect(returned.collapseAt == nil)
        input.now = now.addingTimeInterval(0.5)
        #expect(!Policy.reduce(previous: returned, input: input).isCollapsed)

        input.pointerInsideRail = false
        let nextDeparture = Policy.reduce(previous: returned, input: input)
        #expect(nextDeparture.collapseAt == input.now.addingTimeInterval(0.45))
    }

    @Test
    func closingTheLastVisibleCardStartsANewGracePeriod() {
        var input = fullscreenInput
        input.detailVisible = true
        let held = Policy.reduce(previous: Policy.State(), input: input)
        input.detailVisible = false
        input.now = now.addingTimeInterval(10)
        let released = Policy.reduce(previous: held, input: input)
        #expect(!released.isCollapsed)
        #expect(released.collapseAt == input.now.addingTimeInterval(0.45))
    }

    @Test
    func alreadyCollapsedRailDoesNotScheduleRepeatedTimers() {
        let collapsed = Policy.reduce(previous: Policy.State(), input: fullscreenInput)
        var input = fullscreenInput
        input.now = now.addingTimeInterval(60)
        #expect(Policy.reduce(previous: collapsed, input: input) == collapsed)
    }

    @Test
    func stripUsesExactlyFourByFortyEightPointsAtThePhysicalScreenEdge() {
        let screen = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let expanded = CGRect(x: -50, y: 50, width: 52, height: 600)
        for edge in [Policy.Edge.left, .right] {
            let strip = Policy.collapsedFrame(expandedFrame: expanded, screenFrame: screen, edge: edge)
            #expect(strip.size == CGSize(width: 4, height: 48))
            #expect(strip.midY == expanded.midY)
            #expect(screen.contains(strip))
            if edge == .left { #expect(strip.minX == screen.minX) }
            else { #expect(strip.maxX == screen.maxX) }
        }
    }
}
