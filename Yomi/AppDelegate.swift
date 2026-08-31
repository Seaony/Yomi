import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = UsageStore.shared

    private var panel: FloatingPanel?
    private var providerDetailPanel: ProviderDetailPanel?
    private var selectedProviderID: ProviderID?
    private var globalClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var verticalPosition: CGFloat = 0.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        store.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeDetailClickMonitor()
        NotificationCenter.default.removeObserver(self)
    }

    func openSettings(providerID: ProviderID? = nil) {
        closeProviderDetail()
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
        let height = initialPanelHeight()
        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: UsageRailLayout.panelWidth,
                height: height
            ),
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
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.originConstraint = { [weak self] origin, size in
            self?.constrainedPanelOrigin(origin, size: size) ?? origin
        }
        panel.contentView = NSHostingView(rootView: UsageRailView(
            store: store,
            openSettings: { [weak self] providerID in self?.openSettings(providerID: providerID) },
            toggleProviderDetail: { [weak self] descriptor, localY in
                self?.toggleProviderDetail(descriptor, localY: localY)
            },
            contentHeightChanged: { [weak self] height in
                self?.resizePanel(to: height, animated: true)
            }
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

    private func toggleProviderDetail(_ descriptor: ProviderDescriptor, localY: CGFloat) {
        if selectedProviderID == descriptor.id, providerDetailPanel?.isVisible == true {
            closeProviderDetail()
            return
        }

        closeProviderDetail()
        guard let panel else { return }

        let root = ProviderDetailPanelView(
            store: store,
            descriptor: descriptor,
            settings: { [weak self] in self?.openSettings(providerID: descriptor.id) }
        )
        let hostingView = NSHostingView(rootView: root)
        let fittingSize = hostingView.fittingSize
        let detailPanel = ProviderDetailPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        detailPanel.contentView = hostingView
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = false
        detailPanel.level = .statusBar
        detailPanel.hidesOnDeactivate = false
        detailPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        detailPanel.isReleasedWhenClosed = false

        let visibleFrame = targetScreen()?.visibleFrame ?? panel.frame
        let minimumY = visibleFrame.minY + 8
        let maximumY = max(minimumY, visibleFrame.maxY - fittingSize.height - 8)
        let anchorY = panel.frame.maxY - localY
        let proposedY = anchorY - fittingSize.height / 2
        let origin = NSPoint(
            x: panel.frame.minX - fittingSize.width + 26,
            y: min(max(proposedY, minimumY), maximumY)
        )
        detailPanel.setFrameOrigin(origin)

        self.providerDetailPanel = detailPanel
        selectedProviderID = descriptor.id
        panel.addChildWindow(detailPanel, ordered: .above)
        detailPanel.orderFrontRegardless()
        installDetailClickMonitor()
    }

    private func closeProviderDetail() {
        guard let detailPanel = providerDetailPanel else { return }
        panel?.removeChildWindow(detailPanel)
        detailPanel.orderOut(nil)
        providerDetailPanel = nil
        selectedProviderID = nil
        removeDetailClickMonitor()
    }

    private func installDetailClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closeProviderDetail() }
        }
    }

    private func removeDetailClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func resizePanel(to contentHeight: CGFloat, animated: Bool) {
        guard let panel else { return }
        let visibleHeight = targetScreen()?.visibleFrame.height ?? 900
        let newHeight = min(
            max(contentHeight, UsageRailLayout.minimumPanelHeight),
            visibleHeight - 24
        )
        guard abs(panel.frame.height - newHeight) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = newHeight
        frame = pinnedFrame(frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func constrainedPanelOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard let visible = targetScreen()?.visibleFrame else { return origin }
        let minimumY = visible.minY + 12
        let maximumY = max(minimumY, visible.maxY - size.height - 12)
        let constrainedY = min(max(origin.y, minimumY), maximumY)
        let travel = maximumY - minimumY
        verticalPosition = travel > 0 ? (constrainedY - minimumY) / travel : 0.5
        return NSPoint(x: visible.maxX - size.width + 1, y: constrainedY)
    }

    private func positionPanel(animated: Bool) {
        guard let panel else { return }
        let frame = pinnedFrame(panel.frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func pinnedFrame(_ frame: NSRect) -> NSRect {
        let screen = targetScreen()
        guard let visible = screen?.visibleFrame else { return frame }
        let height = min(frame.height, visible.height - 24)
        let minimumY = visible.minY + 12
        let maximumY = max(minimumY, visible.maxY - height - 12)
        return NSRect(
            x: visible.maxX - frame.width + 1,
            y: minimumY + (maximumY - minimumY) * verticalPosition,
            width: frame.width,
            height: height
        )
    }

    private func targetScreen() -> NSScreen? {
        panel?.screen ?? screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func initialPanelHeight() -> CGFloat {
        let visibleHeight = (screenUnderPointer() ?? NSScreen.main)?.visibleFrame.height ?? 900
        let storedShowNames = UserDefaults.standard.object(forKey: "show-provider-names") as? Bool
        let rowHeight = UsageRailLayout.scaled((storedShowNames ?? true) ? 101 : 84)
        let transitionSpace = UsageRailLayout.transitionHeight * 2
        let contentHeight = CGFloat(max(store.enabledProviders.count, 1)) * rowHeight
            + UsageRailLayout.scaled(84)
            + transitionSpace
        return min(max(contentHeight, UsageRailLayout.minimumPanelHeight), visibleHeight - 24)
    }
}

final class FloatingPanel: NSPanel {
    var originConstraint: ((NSPoint, NSSize) -> NSPoint)?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingVertically = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(originConstraint?(point, frame.size) ?? point)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseLocation = NSPoint(
                x: frame.minX + event.locationInWindow.x,
                y: frame.minY + event.locationInWindow.y
            )
            dragStartOrigin = frame.origin
            isDraggingVertically = false
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let startMouse = dragStartMouseLocation,
                  let startOrigin = dragStartOrigin
            else {
                super.sendEvent(event)
                return
            }

            let currentMouse = NSPoint(
                x: frame.minX + event.locationInWindow.x,
                y: frame.minY + event.locationInWindow.y
            )
            let horizontalDistance = currentMouse.x - startMouse.x
            let verticalDistance = currentMouse.y - startMouse.y

            if !isDraggingVertically {
                guard abs(verticalDistance) > 6,
                      abs(verticalDistance) > abs(horizontalDistance)
                else {
                    super.sendEvent(event)
                    return
                }
                super.sendEvent(event)
                isDraggingVertically = true
            }

            setFrameOrigin(NSPoint(x: startOrigin.x, y: startOrigin.y + verticalDistance))

        case .leftMouseUp:
            dragStartMouseLocation = nil
            dragStartOrigin = nil
            isDraggingVertically = false
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }
}

final class ProviderDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
