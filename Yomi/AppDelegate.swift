import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = UsageStore.shared

    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var preferencesObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        store.start()

        preferencesObserver = store.preferences.$configurations
            .receive(on: RunLoop.main)
            .sink { [weak self] configurations in
                self?.resizePanel(enabledCount: configurations.filter(\.isEnabled).count, animated: true)
            }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    func openSettings(providerID: ProviderID? = nil) {
        if settingsWindow == nil {
            let root = SettingsView(store: store, initialProviderID: providerID)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Yomi 设置"
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.minSize = NSSize(width: 920, height: 600)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSettingsIfNeeded() {
        guard settingsWindow?.isVisible != true else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func screenLayoutChanged() {
        positionPanel(animated: false)
    }

    private func createPanel() {
        let height = panelHeight(enabledCount: store.enabledProviders.count)
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 126, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: UsageRailView(
            store: store,
            openSettings: { [weak self] providerID in self?.openSettings(providerID: providerID) }
        ))
        self.panel = panel
        positionPanel(animated: false)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func resizePanel(enabledCount: Int, animated: Bool) {
        guard let panel else { return }
        let newHeight = panelHeight(enabledCount: enabledCount)
        guard abs(panel.frame.height - newHeight) > 0.5 else { return }
        var frame = panel.frame
        let midpoint = frame.midY
        frame.size.height = newHeight
        frame.origin.y = midpoint - newHeight / 2
        frame = pinnedFrame(frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func positionPanel(animated: Bool) {
        guard let panel else { return }
        let frame = pinnedFrame(panel.frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func pinnedFrame(_ frame: NSRect) -> NSRect {
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        return NSRect(
            x: visible.maxX - frame.width + 1,
            y: visible.midY - frame.height / 2,
            width: frame.width,
            height: min(frame.height, visible.height - 24)
        )
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func panelHeight(enabledCount: Int) -> CGFloat {
        let visibleHeight = (screenUnderPointer() ?? NSScreen.main)?.visibleFrame.height ?? 900
        let rowsHeight = CGFloat(max(enabledCount, 1)) * 112
        return min(max(rowsHeight + 126, 420), visibleHeight - 24)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
