import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let panelVerticalPositionKey = "panel-vertical-position"

    let store = UsageStore.shared

    private var panel: FloatingPanel?
    private var providerDetailPanel: ProviderDetailPanel?
    private var selectedProviderID: ProviderID?
    private var globalClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var verticalPosition: CGFloat = 0.5
    private var railSide = UsageRailSide.right

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        restorePanelPosition()
        createPanel()
        store.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged),
            name: .appLanguageDidChange,
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
            window.title = settingsWindowTitle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
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

    @objc private func languageChanged() {
        settingsWindow?.title = settingsWindowTitle
    }

    private var settingsWindowTitle: String {
        AppLocalization.text("Yomi 设置", "Yomi Settings")
    }

    private func createPanel() {
        let visibleHeight = (screenUnderPointer() ?? NSScreen.main)?.visibleFrame.height ?? 900
        let measurementHeight = max(
            UsageRailLayout.minimumPanelHeight,
            visibleHeight - UsageRailLayout.screenVerticalMargin * 2
        )
        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: UsageRailLayout.panelWidth,
                height: measurementHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.originConstraint = { [weak self] origin, size in
            self?.constrainedPanelOrigin(origin, size: size) ?? origin
        }
        panel.onDragEnded = { [weak self] in
            self?.panelDragEnded()
        }
        self.panel = panel
        panel.contentView = NSHostingView(rootView: UsageRailView(
            store: store,
            openSettings: { [weak self] providerID in self?.openSettings(providerID: providerID) },
            toggleProviderDetail: { [weak self] descriptor, localY in
                self?.toggleProviderDetail(descriptor, localY: localY)
            },
            contentHeightChanged: { [weak self] height in
                guard let self else { return }
                self.resizePanel(to: height, animated: (self.panel?.alphaValue ?? 0) > 0)
            }
        ))
        panel.contentView?.layoutSubtreeIfNeeded()
        positionPanel(animated: false)

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
            railSide: railSide
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
        let finalX = switch railSide {
        case .left:
            panel.frame.maxX
                + ProviderDetailLayout.railGap
                - ProviderDetailLayout.outerPadding
        case .right:
            panel.frame.minX
                - fittingSize.width
                + ProviderDetailLayout.outerPadding
                - ProviderDetailLayout.railGap
        }
        let transitionDirection: CGFloat = railSide == .right ? 1 : -1
        let finalOrigin = NSPoint(
            x: finalX,
            y: min(max(proposedY, minimumY), maximumY)
        )
        detailPanel.alphaValue = 0
        detailPanel.setFrameOrigin(NSPoint(
            x: finalOrigin.x + ProviderDetailLayout.transitionOffset * transitionDirection,
            y: finalOrigin.y
        ))

        self.providerDetailPanel = detailPanel
        selectedProviderID = descriptor.id
        panel.addChildWindow(detailPanel, ordered: .above)
        detailPanel.orderFrontRegardless()
        installDetailClickMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailPanel.animator().alphaValue = 1
            detailPanel.animator().setFrameOrigin(finalOrigin)
        }
    }

    private func closeProviderDetail() {
        guard let detailPanel = providerDetailPanel else { return }
        providerDetailPanel = nil
        selectedProviderID = nil
        removeDetailClickMonitor()

        let transitionDirection: CGFloat = railSide == .right ? 1 : -1
        let targetOrigin = NSPoint(
            x: detailPanel.frame.origin.x
                + ProviderDetailLayout.transitionOffset * transitionDirection,
            y: detailPanel.frame.origin.y
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            detailPanel.animator().alphaValue = 0
            detailPanel.animator().setFrameOrigin(targetOrigin)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.16))
            self?.panel?.removeChildWindow(detailPanel)
            detailPanel.orderOut(nil)
        }
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
            visibleHeight - UsageRailLayout.screenVerticalMargin * 2
        )
        guard abs(panel.frame.height - newHeight) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = newHeight
        frame = pinnedFrame(frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func constrainedPanelOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard let visible = targetScreen()?.visibleFrame else { return origin }
        let minimumX = visible.minX - UsageRailLayout.screenEdgeOverlap
        let maximumX = visible.maxX - size.width + UsageRailLayout.screenEdgeOverlap
        let minimumY = visible.minY + UsageRailLayout.screenVerticalMargin
        let maximumY = max(
            minimumY,
            visible.maxY - size.height - UsageRailLayout.screenVerticalMargin
        )
        let constrainedY = min(max(origin.y, minimumY), maximumY)
        let travel = maximumY - minimumY
        verticalPosition = travel > 0 ? (constrainedY - minimumY) / travel : 0.5
        return NSPoint(
            x: min(max(origin.x, minimumX), maximumX),
            y: constrainedY
        )
    }

    private func positionPanel(animated: Bool) {
        guard let panel else { return }
        let frame = pinnedFrame(panel.frame)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func pinnedFrame(_ frame: NSRect) -> NSRect {
        let screen = targetScreen()
        guard let visible = screen?.visibleFrame else { return frame }
        let height = min(
            frame.height,
            visible.height - UsageRailLayout.screenVerticalMargin * 2
        )
        let minimumY = visible.minY + UsageRailLayout.screenVerticalMargin
        let maximumY = max(
            minimumY,
            visible.maxY - height - UsageRailLayout.screenVerticalMargin
        )
        return NSRect(
            x: pinnedX(in: visible, panelWidth: frame.width),
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

    private func restorePanelPosition() {
        if let savedSide = UserDefaults.standard.string(forKey: UsageRailSide.storageKey),
           let side = UsageRailSide(rawValue: savedSide) {
            railSide = side
        }
        guard let saved = UserDefaults.standard.object(
            forKey: Self.panelVerticalPositionKey
        ) as? NSNumber else { return }
        verticalPosition = min(max(CGFloat(saved.doubleValue), 0), 1)
    }

    private func persistPanelPosition() {
        UserDefaults.standard.set(railSide.rawValue, forKey: UsageRailSide.storageKey)
        UserDefaults.standard.set(
            Double(verticalPosition),
            forKey: Self.panelVerticalPositionKey
        )
    }

    private func panelDragEnded() {
        guard let panel,
              let visible = targetScreen()?.visibleFrame else { return }
        closeProviderDetail()
        railSide = panel.frame.midX < visible.midX ? .left : .right
        persistPanelPosition()
        positionPanel(animated: true)
    }

    private func pinnedX(in visible: NSRect, panelWidth: CGFloat) -> CGFloat {
        switch railSide {
        case .left:
            visible.minX - UsageRailLayout.screenEdgeOverlap
        case .right:
            visible.maxX - panelWidth + UsageRailLayout.screenEdgeOverlap
        }
    }

}

final class FloatingPanel: NSPanel {
    var originConstraint: ((NSPoint, NSSize) -> NSPoint)?
    var onDragEnded: (() -> Void)?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false

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
            isDragging = false
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

            if !isDragging {
                guard hypot(horizontalDistance, verticalDistance) > 6 else {
                    super.sendEvent(event)
                    return
                }
                super.sendEvent(event)
                isDragging = true
            }

            setFrameOrigin(NSPoint(
                x: startOrigin.x + horizontalDistance,
                y: startOrigin.y + verticalDistance
            ))

        case .leftMouseUp:
            let finishedDragging = isDragging
            dragStartMouseLocation = nil
            dragStartOrigin = nil
            isDragging = false
            super.sendEvent(event)
            if finishedDragging {
                onDragEnded?()
            }

        default:
            super.sendEvent(event)
        }
    }
}

final class ProviderDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
