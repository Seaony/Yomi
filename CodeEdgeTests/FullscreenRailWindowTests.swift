import AppKit
import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
struct FullscreenRailWindowTests {
    @Test
    func independentStripKeepsTheRailFrameAndHostingWindowUnchanged() {
        let expanded = CGRect(x: 1390, y: 260, width: 52, height: 400)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(contentRect: expanded, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        defer { panel.close() }
        let fullView = NSHostingView(rootView: Color.clear.frame(width: 52, height: 400))
        let clipView = NSView(frame: NSRect(origin: .zero, size: expanded.size))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        fullView.frame = clipView.bounds
        fullView.autoresizingMask = [.width, .height]
        clipView.addSubview(fullView)
        panel.contentView = clipView
        let strip = NSHostingView(rootView: FullscreenRevealStrip(hoverChanged: { _ in }, reveal: {}))
        let collapsed = FullscreenCollapsePolicy.collapsedFrame(expandedFrame: expanded, screenFrame: screen, edge: .right)
        let stripPanel = FloatingPanel(contentRect: collapsed, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        defer { stripPanel.close() }
        stripPanel.contentView = strip
        stripPanel.contentView?.layoutSubtreeIfNeeded()
        let plan = RailPresentationPolicy.plan(collapsed: true, trigger: .pointer, width: expanded.width, edge: .right)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            fullView.animator().setFrameOrigin(NSPoint(x: plan.railOffset, y: 0))
            panel.animator().alphaValue = plan.railAlpha
            stripPanel.animator().alphaValue = plan.stripAlpha
        }
        panel.orderOut(nil)
        #expect(!panel.isVisible)
        #expect(panel.alphaValue == 0)
        #expect(stripPanel.alphaValue == 1)
        #expect(panel.frame == expanded)
        #expect(panel.contentView === clipView)
        #expect(fullView.window === panel)
        #expect(fullView.frame.origin.x == expanded.width)
        #expect(clipView.layer?.masksToBounds == true)
        #expect(stripPanel.frame == collapsed)
        #expect(stripPanel.contentView?.bounds.size == CGSize(width: 4, height: 48))
        #expect(strip.window === stripPanel)
        #expect(!stripPanel.frame.contains(CGPoint(x: collapsed.minX - 1, y: collapsed.midY)))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            fullView.animator().setFrameOrigin(.zero)
            panel.animator().alphaValue = 1
            stripPanel.animator().alphaValue = 0
        }
        stripPanel.orderOut(nil)
        #expect(panel.frame == expanded)
        #expect(fullView.frame.origin == .zero)
        #expect(fullView.window === panel)
        #expect(panel.alphaValue == 1)
        #expect(stripPanel.alphaValue == 0)
        #expect(stripPanel.frame == collapsed)
    }
}
