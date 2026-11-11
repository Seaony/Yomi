import CoreGraphics
import Foundation

nonisolated enum FullscreenCollapsePolicy {
    static let settingKey = "collapse-in-fullscreen"
    static let defaultEnabled = true
    static let collapseDelay: TimeInterval = 0.45
    static let stripWidth: CGFloat = 4
    static let stripHeight: CGFloat = 48
    static let slideDuration: TimeInterval = 0.2

    enum Edge: Equatable, Sendable {
        case left
        case right
    }

    struct State: Equatable, Sendable {
        var isCollapsed = false
        var collapseAt: Date? = nil
        var wasFullscreenEligible = false
    }

    struct Input: Sendable {
        var enabled: Bool
        var isFullscreenOnTargetScreen: Bool
        var pointerInsideRail = false
        var pointerInsideRevealStrip = false
        var detailVisible = false
        var billVisible = false
        var revealRequested = false
        var now: Date
    }

    static func reduce(previous: State, input: Input) -> State {
        guard input.enabled, input.isFullscreenOnTargetScreen else { return State() }
        if input.pointerInsideRail || input.pointerInsideRevealStrip || input.detailVisible || input.billVisible
            || input.revealRequested {
            return State(wasFullscreenEligible: true)
        }
        guard previous.wasFullscreenEligible, !previous.isCollapsed else {
            return State(isCollapsed: true, wasFullscreenEligible: true)
        }

        // 鼠标移开后只记一次截止时间，轮询不能不断推迟收起。
        let deadline = previous.collapseAt ?? input.now.addingTimeInterval(collapseDelay)
        if input.now >= deadline { return State(isCollapsed: true, wasFullscreenEligible: true) }
        return State(collapseAt: deadline, wasFullscreenEligible: true)
    }

    static func collapsedFrame(expandedFrame: CGRect, screenFrame: CGRect, edge: Edge) -> CGRect {
        CGRect(
            x: edge == .left ? screenFrame.minX : screenFrame.maxX - stripWidth,
            y: expandedFrame.midY - stripHeight / 2,
            width: stripWidth,
            height: stripHeight
        )
    }

    static func slideOffset(width: CGFloat, edge: Edge, revealProgress: CGFloat) -> CGFloat {
        (edge == .left ? -width : width) * (1 - revealProgress)
    }
}
