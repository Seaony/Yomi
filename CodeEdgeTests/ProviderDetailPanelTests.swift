import AppKit
import Combine
import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
struct ProviderDetailPanelTests {
    @Test
    func changingCardHeightLeavesWindowSizingToAppKit() async throws {
        let content = CardContent()
        var reportedSize: NSSize?
        let panel = ProviderDetailPanel(rootView: Card(content: content)) { reportedSize = $0 }
        showOffscreen(panel)
        defer { panel.close() }

        let initialSize = NSSize(width: 384, height: 180)
        let container = try #require(panel.contentView)
        #expect(type(of: container) == NSView.self)
        #expect(panel.frame.size == initialSize)
        #expect(panel.contentMinSize == .zero)

        for height: CGFloat in [450, 449, 180] {
            let oldFrame = panel.frame
            let expectedSize = NSSize(width: 384, height: height)
            withAnimation(.easeInOut(duration: 0.02)) { content.height = height }
            for _ in 0..<50 {
                if reportedSize == expectedSize { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(reportedSize == expectedSize)
            #expect(panel.frame == oldFrame)
            #expect(panel.contentMinSize == .zero)

            panel.updateFrame(NSRect(origin: oldFrame.origin, size: expectedSize), duration: 0)
            #expect(panel.frame.size == expectedSize)
            #expect(container.subviews.first?.frame == container.bounds)
        }
    }

    @Test
    func switchingProvidersAndRefreshingResizeTheDetailCard() async throws {
        let codex = try #require(ProviderCatalog.byID[ProviderID(rawValue: "codex")])
        let claude = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        let defaults = try #require(UserDefaults(suiteName: "CodeEdgeDetailPanelTests.\(UUID())"))
        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)
        let presentation = ProviderDetailPresentation(descriptor: codex)
        let root = ProviderDetailPanelView(store: store, presentation: presentation, railSide: .right)
        let quota = UsageWindow(id: "session", label: "Session", usedFraction: 0.4)
        store.showPreviewUsage([ProviderUsage(id: claude.id, state: .ready, windows: [quota])])

        var reportedSize: NSSize?
        let panel = ProviderDetailPanel(rootView: root) { reportedSize = $0 }
        showOffscreen(panel)
        defer { panel.close() }

        let initialFrame = panel.frame
        presentation.update(descriptor: claude, direction: .down, animated: true)
        panel.updateFrame(initialFrame.offsetBy(dx: 0, dy: 32), duration: 0.14)
        let switchedSize = try await sizeChange(from: initialFrame.size) { reportedSize }
        #expect(switchedSize.height > initialFrame.height)
        #expect(switchedSize.width == initialFrame.width)
        let switchedFrame = NSRect(origin: initialFrame.origin, size: switchedSize)
        panel.updateFrame(switchedFrame, duration: 0)
        try await Task.sleep(for: .milliseconds(180))
        #expect(panel.frame == switchedFrame)

        let previousSize = try #require(reportedSize)
        reportedSize = nil
        let weekly = UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.2)
        store.showPreviewUsage([ProviderUsage(id: claude.id, state: .ready, windows: [quota, weekly])])
        let refreshedSize = try await sizeChange(from: previousSize) { reportedSize }
        #expect(refreshedSize.height > previousSize.height)
        panel.updateFrame(NSRect(origin: panel.frame.origin, size: refreshedSize), duration: 0)
        #expect(panel.frame.size == refreshedSize)

        let refreshedFrame = panel.frame
        panel.updateFrame(refreshedFrame.offsetBy(dx: 0, dy: 32), duration: 0.14)
        panel.updateFrame(refreshedFrame, duration: 0.14)
        try await Task.sleep(for: .milliseconds(180))
        #expect(panel.frame == refreshedFrame)
    }

    private func showOffscreen(_ panel: ProviderDetailPanel) {
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderBack(nil)
    }

    private func sizeChange(from size: NSSize, reportedSize: () -> NSSize?) async throws -> NSSize {
        for _ in 0..<100 {
            if let newSize = reportedSize(), newSize != size { return newSize }
            try await Task.sleep(for: .milliseconds(10))
        }
        let newSize = try #require(reportedSize())
        try #require(newSize != size)
        return newSize
    }

    private final class CardContent: ObservableObject {
        @Published var height: CGFloat = 180
    }

    private struct Card: View {
        @ObservedObject var content: CardContent

        var body: some View {
            Color.clear.frame(width: 384, height: content.height)
        }
    }
}
