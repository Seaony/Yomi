import CoreGraphics
import Testing
@testable import Yomi

struct RailPresentationPolicyTests {
    private typealias Policy = RailPresentationPolicy

    @Test(arguments: [true, false], [FullscreenCollapsePolicy.Edge.left, .right])
    func spaceChangesOnlyFadeInBothDirections(collapsed: Bool, edge: FullscreenCollapsePolicy.Edge) {
        let plan = Policy.plan(collapsed: collapsed, trigger: .space, width: 52, edge: edge)
        #expect(plan.duration == 0.25)
        #expect(plan.curve == .easeInOut)
        #expect(plan.railOffset == 0)
        #expect(plan.railAlpha == (collapsed ? 0 : 1))
        #expect(plan.stripAlpha == (collapsed ? 1 : 0))
    }

    @Test(arguments: [true, false], [FullscreenCollapsePolicy.Edge.left, .right])
    func pointerTransitionsUseOneCurveAndDuration(collapsed: Bool, edge: FullscreenCollapsePolicy.Edge) {
        let plan = Policy.plan(collapsed: collapsed, trigger: .pointer, width: 52, edge: edge)
        #expect(plan.duration == 0.22)
        #expect(plan.curve == .easeInOut)
        #expect(plan.railOffset == (collapsed ? (edge == .left ? -52 : 52) : 0))
        #expect(plan.railAlpha == (collapsed ? 0 : 1))
        #expect(plan.stripAlpha == (collapsed ? 1 : 0))
    }

    @Test(arguments: [CGFloat(4), 52, 128])
    func pointerOffsetsUseTheActualPanelWidth(width: CGFloat) {
        let left = Policy.plan(collapsed: true, trigger: .pointer, width: width, edge: .left)
        let right = Policy.plan(collapsed: true, trigger: .pointer, width: width, edge: .right)
        #expect(left.railOffset == -width)
        #expect(right.railOffset == width)
    }
}
