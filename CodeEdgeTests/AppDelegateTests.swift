import AppKit
import SwiftUI
import Testing
@testable import CodeEdge

struct AppDelegateTests {
    // 测试宿主就是 CodeEdge.app，必须识别出测试环境，才不会建侧边栏、用真实凭据刷新或检查更新。
    @Test
    func testHostIsDetected() {
        #expect(AppDelegate.isRunningTests)
    }

    @MainActor
    @Test
    func inactiveDetailPanelAcceptsItsFirstClick() throws {
        let panel = ProviderDetailPanel(
            rootView: Color.clear.frame(width: 120, height: 60).contentShape(Rectangle()).onTapGesture {},
            contentSizeChanged: { _ in }
        )
        defer { panel.close() }
        let hosting = try #require(panel.contentView?.subviews.first)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 60, y: 30), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        #expect(!panel.isKeyWindow)
        #expect(!panel.isVisible)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeMain)
        let hitView = try #require(hosting.hitTest(NSPoint(x: 60, y: 30)))
        #expect(hosting.acceptsFirstMouse(for: event))
        #expect(hitView.acceptsFirstMouse(for: event))
        #expect(!panel.isKeyWindow)
    }
}
