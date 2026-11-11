import AppKit
import SwiftUI
import Testing
@testable import Yomi

@MainActor
struct FullscreenRailWindowTests {
    @Test
    func collapsedWindowHasOnlyTheStripBoundsAndCanRestoreTheFullView() {
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
        panel.contentView = strip
        panel.setFrame(collapsed, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!panel.isVisible)
        #expect(panel.frame == collapsed)
        #expect(panel.frame.size == CGSize(width: 4, height: 48))
        #expect(panel.contentView?.bounds.size == CGSize(width: 4, height: 48))
        #expect(fullView.window == nil)
        #expect(!panel.frame.contains(CGPoint(x: collapsed.minX - 1, y: collapsed.midY)))
        panel.setFrame(expanded, display: false)
        panel.contentView = clipView
        #expect(panel.frame == expanded)
        #expect(panel.contentView === clipView)
        #expect(fullView.window === panel)
    }
}
