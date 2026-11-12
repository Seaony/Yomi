import CoreGraphics
import Foundation

nonisolated enum RailPresentationPolicy {
    enum Trigger: Equatable, Sendable {
        case space
        case pointer
    }

    enum Curve: Equatable, Sendable {
        case easeInOut
    }

    struct Plan: Equatable, Sendable {
        let duration: TimeInterval
        let curve: Curve
        let railAlpha: CGFloat
        let stripAlpha: CGFloat
        let railOffset: CGFloat
    }

    static func plan(
        collapsed: Bool,
        trigger: Trigger,
        width: CGFloat,
        edge: FullscreenCollapsePolicy.Edge
    ) -> Plan {
        Plan(
            duration: trigger == .space ? 0.25 : 0.22,
            curve: .easeInOut,
            railAlpha: collapsed ? 0 : 1,
            stripAlpha: collapsed ? 1 : 0,
            railOffset: collapsed && trigger == .pointer ? (edge == .left ? -width : width) : 0
        )
    }
}
