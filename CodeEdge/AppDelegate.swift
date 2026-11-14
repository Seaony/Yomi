import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 作为单元测试宿主启动时为 true；这时不建侧边栏、不刷新、不检查更新，避免测试用真实凭据联网。
    nonisolated static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static let panelVerticalPositionKey = "panel-vertical-position"
    private static let providerDetailDismissDelay: Duration = .milliseconds(110)
    private static let providerDetailPointerCheckInterval: Duration = .milliseconds(40)

    let store = UsageStore.shared
    let updates = UpdateController()
    let settingsNavigation = SettingsNavigation()
    private var showSettings: (() -> Void)?

    private var panel: FloatingPanel?
    private var railHostingView: NSHostingView<UsageRailView>?
    private var revealStripPanel: FloatingPanel?
    private var fullscreenRailController: FullscreenRailController?
    private var expandedRailFrame: NSRect?
    private var applyingRailPresentation = false
    private var railPresentationRevision = 0
    private var railPresentationTarget = false
    private var isTerminating = false
    private var providerDetailPanel: ProviderDetailPanel?
    private var providerDetailPresentation: ProviderDetailPresentation?
    private var selectedProviderID: ProviderID?
    private var selectedProviderLocalY: CGFloat?
    private var providerDetailCloseTask: Task<Void, Never>?
    private var providerDetailResizeTask: Task<Void, Never>?
    private var appearanceObserver: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var dailyBillPanel: NSPanel?
    private var verticalPosition: CGFloat = 0.5
    private var railSide = UsageRailSide.right

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !Self.isRunningTests else { return }
        UsageAnalytics.shared.start()
        // 用户反馈问题时直接发日志文件，开头要能看出版本和系统。
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        DiagnosticLog.shared.write(
            "Launched CodeEdge \(version) (\(build)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            category: .app
        )
        // 外观只在这里统一设置。preferredColorScheme 管不到自建面板，
        // 从深色切回系统时也不会复位窗口，所以直接改整个 App 的外观，系统模式时交还给 macOS。
        appearanceObserver = AppPreferences.shared.$appearance.sink { appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        restorePanelPosition()
        createPanel()
        startFullscreenRailController()
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
        isTerminating = true
        fullscreenRailController?.stop()
        revealStripPanel?.orderOut(nil)
        store.serviceStatusMonitor.stop()
        providerDetailCloseTask?.cancel()
        providerDetailResizeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func configureSettings(opener: @escaping () -> Void) {
        showSettings = opener
    }

    func registerSettingsWindow(_ window: NSWindow) {
        guard settingsWindow !== window else { return }
        if let settingsWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: settingsWindow)
        }
        settingsWindow = window
        window.titlebarSeparatorStyle = .none
        window.initialFirstResponder = nil
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window
        )
    }

    func openSettings(providerID: ProviderID? = nil) {
        closeProviderDetail()
        settingsNavigation.show(providerID: providerID)
        NSApp.setActivationPolicy(.regular)
        showSettings?()
        NSApp.activate()
    }

    func closeSettingsIfNeeded() {
        guard settingsWindow?.isVisible != true, dailyBillPanel?.isVisible != true else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let anotherWindowIsOpen = [settingsWindow, dailyBillPanel].contains { window in
            window != closing && window?.isVisible == true
        }
        if !anotherWindowIsOpen { NSApp.setActivationPolicy(.accessory) }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.fullscreenRailController?.updatePointerState()
        }
    }

    private func openDailyBill() {
        closeProviderDetail()
        if dailyBillPanel == nil {
            let visible = targetScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let height = min(720, max(420, visible.height - 80))
            let window = NSPanel(
                contentRect: NSRect(x: visible.midX - 222, y: visible.midY - height / 2, width: 444, height: height),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.minSize = NSSize(width: 444, height: 420)
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.delegate = self
            dailyBillPanel = window
        }
        dailyBillPanel?.contentViewController = NSHostingController(rootView: DailyBillWindowContent(store: store))
        dailyBillPanel?.title = AppLocalization.text("今日 AI 账单", "Today's AI bill")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        dailyBillPanel?.makeKeyAndOrderFront(nil)
        fullscreenRailController?.updatePointerState()
    }

    @objc private func screenLayoutChanged() {
        positionPanel(animated: false)
        updateProviderDetailFrame(animated: false)
        fullscreenRailController?.refreshFullscreen()
    }

    @objc private func languageChanged() {
        dailyBillPanel?.title = AppLocalization.text("今日 AI 账单", "Today's AI bill")
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
        panel.alphaValue = 1
        panel.originConstraint = { [weak self] origin, size in
            self?.constrainedPanelOrigin(origin, size: size) ?? origin
        }
        panel.onDragEnded = { [weak self] in
            self?.panelDragEnded()
        }
        self.panel = panel
        let hostingView = FirstClickHostingView(rootView: UsageRailView(
            store: store,
            openSettings: { [weak self] providerID in self?.openSettings(providerID: providerID) },
            showProviderDetail: { [weak self] descriptor, localY in
                self?.showProviderDetail(descriptor, localY: localY)
            },
            hideProviderDetail: { [weak self] providerID in
                self?.closeProviderDetail(for: providerID)
            },
            contentHeightChanged: { [weak self] height in
                guard let self else { return }
                self.resizePanel(to: height, animated: (self.panel?.alphaValue ?? 0) > 0)
            },
            hoverChanged: { [weak self] _ in
                self?.fullscreenRailController?.updatePointerState()
            }
        ))
        railHostingView = hostingView
        let clipView = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.frame = clipView.bounds
        hostingView.autoresizingMask = [.width, .height]
        clipView.addSubview(hostingView)
        panel.contentView = clipView
        panel.contentView?.layoutSubtreeIfNeeded()
        positionPanel(animated: false)

        panel.orderFrontRegardless()
    }

    private func startFullscreenRailController() {
        let stripHostingView = FirstClickHostingView(rootView: FullscreenRevealStrip(
            hoverChanged: { [weak self] hovering in
                if hovering { self?.fullscreenRailController?.pointerEnteredRevealStrip() }
                else { self?.fullscreenRailController?.updatePointerState() }
            },
            reveal: { [weak self] in self?.fullscreenRailController?.reveal() }
        ))
        let stripPanel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: FullscreenCollapsePolicy.stripWidth,
                                height: FullscreenCollapsePolicy.stripHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        stripPanel.isOpaque = false
        stripPanel.backgroundColor = .clear
        stripPanel.hasShadow = false
        stripPanel.level = .statusBar
        stripPanel.hidesOnDeactivate = false
        stripPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        stripPanel.isMovable = false
        stripPanel.isMovableByWindowBackground = false
        stripPanel.acceptsMouseMovedEvents = true
        stripPanel.isReleasedWhenClosed = false
        stripPanel.allowsDragging = false
        stripPanel.alphaValue = 0
        stripPanel.contentView = stripHostingView
        revealStripPanel = stripPanel
        positionRevealStrip()
        let controller = FullscreenRailController(context: { [weak self] in
            guard let self else {
                return .init(enabled: false, screenFrame: nil, safeAreaTopInset: 0,
                             expandedFrame: .zero, railFrame: .zero, edge: .right,
                             detailVisible: false, billVisible: false)
            }
            let screen = self.targetScreen()
            let enabled = UserDefaults.standard.object(forKey: FullscreenCollapsePolicy.settingKey) as? Bool
                ?? FullscreenCollapsePolicy.defaultEnabled
            return .init(enabled: enabled, screenFrame: screen?.frame,
                         safeAreaTopInset: screen?.safeAreaInsets.top ?? 0,
                         expandedFrame: self.expandedRailFrame ?? self.panel?.frame ?? .zero,
                         railFrame: self.panel?.isVisible == true
                            && (self.applyingRailPresentation || (self.panel?.alphaValue ?? 0) > 0)
                            ? self.panel?.frame ?? .zero : .zero,
                         edge: self.railSide == .left ? .left : .right,
                         detailVisible: self.providerDetailPanel?.isVisible == true,
                         billVisible: self.dailyBillPanel?.isVisible == true)
        }, onCollapseChanged: { [weak self] collapsed, trigger in
            self?.applyFullscreenRailPresentation(collapsed: collapsed, trigger: trigger)
        })
        fullscreenRailController = controller
        controller.start()
    }

    private func positionRevealStrip() {
        guard let revealStripPanel, let expanded = expandedRailFrame, let screen = targetScreen() else { return }
        let frame = FullscreenCollapsePolicy.collapsedFrame(
            expandedFrame: expanded, screenFrame: screen.frame, edge: railSide == .left ? .left : .right
        )
        revealStripPanel.setFrame(frame, display: true)
    }

    private func applyFullscreenRailPresentation(collapsed: Bool, trigger: RailPresentationPolicy.Trigger) {
        guard !isTerminating, let panel, let railHostingView, let revealStripPanel else { return }
        if applyingRailPresentation && railPresentationTarget != collapsed {
            DiagnosticLog.shared.write(RailDiagnostics.interrupted(collapsed: collapsed), category: .rail)
        }
        railPresentationRevision += 1
        let revision = railPresentationRevision
        railPresentationTarget = collapsed
        applyingRailPresentation = true
        let plan = RailPresentationPolicy.plan(
            collapsed: collapsed, trigger: trigger, width: panel.frame.width,
            edge: railSide == .left ? .left : .right
        )
        let duration = animationDuration(plan.duration)
        positionRevealStrip()
        panel.allowsDragging = !collapsed
        if !panel.isVisible {
            panel.alphaValue = 0
            let hiddenX = trigger == .pointer ? FullscreenCollapsePolicy.slideOffset(
                width: panel.frame.width, edge: railSide == .left ? .left : .right, revealProgress: 0
            ) : 0
            railHostingView.setFrameOrigin(NSPoint(x: hiddenX, y: 0))
            panel.orderFrontRegardless()
        }
        if !revealStripPanel.isVisible {
            revealStripPanel.alphaValue = 0
            revealStripPanel.orderFrontRegardless()
        }
        DiagnosticLog.shared.write(
            RailDiagnostics.started(collapsed: collapsed, durationMS: Int(duration * 1000), trigger: trigger),
            category: .rail
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            switch plan.curve {
            case .easeInOut: context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            // 原位改终点，让 AppKit 从当前位移和透明度接续，反向时不重置起点。
            railHostingView.animator().setFrameOrigin(NSPoint(x: plan.railOffset, y: 0))
            panel.animator().alphaValue = plan.railAlpha
            revealStripPanel.animator().alphaValue = plan.stripAlpha
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.finishRailPresentation(collapsed: collapsed, revision: revision) }
        })
    }

    private func finishRailPresentation(collapsed: Bool, revision: Int) {
        guard revision == railPresentationRevision,
              fullscreenRailController?.state.isCollapsed == collapsed,
              let panel, let revealStripPanel else { return }
        if collapsed {
            panel.orderOut(nil)
            DiagnosticLog.shared.write(RailDiagnostics.completed(collapsed: true), category: .rail)
        } else {
            revealStripPanel.orderOut(nil)
            DiagnosticLog.shared.write(RailDiagnostics.completed(collapsed: false), category: .rail)
        }
        applyingRailPresentation = false
        fullscreenRailController?.updatePointerState()
    }

    private func showProviderDetail(_ descriptor: ProviderDescriptor, localY: CGFloat) {
        providerDetailCloseTask?.cancel()
        providerDetailCloseTask = nil

        if selectedProviderID == descriptor.id, providerDetailPanel?.isVisible == true {
            return
        }

        guard let panel else { return }

        if let detailPanel = providerDetailPanel,
           let presentation = providerDetailPresentation,
           detailPanel.isVisible {
            let direction = ProviderDetailTransitionDirection(
                previousLocalY: selectedProviderLocalY,
                newLocalY: localY
            )
            presentation.update(
                descriptor: descriptor,
                direction: direction,
                animated: animationDuration(1) > 0
            )
            selectedProviderID = descriptor.id
            selectedProviderLocalY = localY
            updateProviderDetailFrame(animated: true)
            return
        }

        closeProviderDetail()
        let presentation = ProviderDetailPresentation(descriptor: descriptor)
        providerDetailPresentation = presentation
        let root = ProviderDetailPanelView(
            store: store,
            presentation: presentation,
            railSide: railSide,
            openDailyBill: { [weak self] in self?.openDailyBill() }
        )
        let detailPanel = ProviderDetailPanel(rootView: root) { [weak self] size in
            self?.scheduleProviderDetailResize(to: size, for: presentation)
        }
        let finalFrame = providerDetailFrame(
            contentSize: detailPanel.frame.size,
            localY: localY,
            panel: panel
        )
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = false
        detailPanel.level = .statusBar
        detailPanel.hidesOnDeactivate = false
        detailPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        detailPanel.isReleasedWhenClosed = false

        detailPanel.alphaValue = 0
        detailPanel.setFrame(finalFrame, display: false)

        self.providerDetailPanel = detailPanel
        selectedProviderID = descriptor.id
        selectedProviderLocalY = localY
        fullscreenRailController?.updatePointerState()
        panel.addChildWindow(detailPanel, ordered: .above)
        detailPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(0.2)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailPanel.animator().alphaValue = 1
        }
    }

    private func providerDetailFrame(
        contentSize: NSSize,
        localY: CGFloat,
        panel: FloatingPanel
    ) -> NSRect {
        let visibleFrame = targetScreen()?.visibleFrame ?? panel.frame
        let padding = ProviderDetailLayout.panelPadding
        let minimumY = visibleFrame.minY + ProviderDetailLayout.screenMargin - padding
        let maximumY = max(
            minimumY,
            visibleFrame.maxY - contentSize.height - ProviderDetailLayout.screenMargin + padding
        )
        let anchorY = panel.frame.maxY - localY
        let proposedY = anchorY - contentSize.height / 2
        let x = switch railSide {
        case .left:
            panel.frame.maxX
                + ProviderDetailLayout.railGap
                - padding
        case .right:
            panel.frame.minX
                - contentSize.width
                + padding
                - ProviderDetailLayout.railGap
        }
        return NSRect(
            x: x,
            y: min(max(proposedY, minimumY), maximumY),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func scheduleProviderDetailResize(to size: NSSize, for presentation: ProviderDetailPresentation) {
        guard !isTerminating, providerDetailPresentation === presentation else { return }
        providerDetailResizeTask?.cancel()
        // 尺寸来自 SwiftUI 的布局回调，等这一轮布局结束再调整窗口。
        providerDetailResizeTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.providerDetailResizeTask = nil
            self.updateProviderDetailFrame(contentSize: size, animated: false)
        }
    }

    private func updateProviderDetailFrame(contentSize: NSSize? = nil, animated: Bool) {
        guard let panel,
              let detailPanel = providerDetailPanel,
              detailPanel.isVisible,
              let localY = selectedProviderLocalY
        else { return }
        let frame = providerDetailFrame(
            contentSize: contentSize ?? detailPanel.frame.size,
            localY: localY,
            panel: panel
        )
        detailPanel.updateFrame(frame, duration: animated ? animationDuration(0.18) : 0)
    }

    private func closeProviderDetail() {
        providerDetailCloseTask?.cancel()
        providerDetailCloseTask = nil
        providerDetailResizeTask?.cancel()
        providerDetailResizeTask = nil
        guard let detailPanel = providerDetailPanel else { return }
        providerDetailPanel = nil
        providerDetailPresentation = nil
        selectedProviderID = nil
        selectedProviderLocalY = nil
        fullscreenRailController?.updatePointerState()

        let transitionDirection: CGFloat = railSide == .right ? 1 : -1
        let targetOrigin = NSPoint(
            x: detailPanel.frame.origin.x
                + ProviderDetailLayout.transitionOffset * transitionDirection,
            y: detailPanel.frame.origin.y
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration(0.16)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            detailPanel.animator().alphaValue = 0
            detailPanel.animator().setFrameOrigin(targetOrigin)
        }, completionHandler: { [self] in
            Task { @MainActor in
                panel?.removeChildWindow(detailPanel)
                detailPanel.orderOut(nil)
            }
        })
    }

    private func closeProviderDetail(for providerID: ProviderID) {
        guard selectedProviderID == providerID else { return }
        scheduleProviderDetailClose(for: providerID)
    }

    private func scheduleProviderDetailClose(for providerID: ProviderID) {
        providerDetailCloseTask?.cancel()
        providerDetailCloseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.providerDetailDismissDelay)
                while let self,
                      self.selectedProviderID == providerID,
                      !Task.isCancelled {
                    if !self.isPointerInsideProviderDetailRegion {
                        self.providerDetailCloseTask = nil
                        self.closeProviderDetail()
                        return
                    }
                    try await Task.sleep(for: Self.providerDetailPointerCheckInterval)
                }
            } catch {
                return
            }
        }
    }

    private var isPointerInsideProviderDetailRegion: Bool {
        guard let panel,
              let detailPanel = providerDetailPanel,
              detailPanel.isVisible
        else { return false }
        return ProviderDetailInteractionRegion.contains(
            NSEvent.mouseLocation,
            detailFrame: ProviderDetailLayout.visibleCardFrame(panelFrame: detailPanel.frame),
            railFrame: panel.frame,
            railSide: railSide
        )
    }

    private func resizePanel(to contentHeight: CGFloat, animated: Bool) {
        guard let panel else { return }
        let visibleHeight = targetScreen()?.visibleFrame.height ?? 900
        let newHeight = min(
            max(contentHeight, UsageRailLayout.minimumPanelHeight),
            visibleHeight - UsageRailLayout.screenVerticalMargin * 2
        )
        var frame = expandedRailFrame ?? panel.frame
        guard abs(frame.height - newHeight) > 0.5 else { return }
        frame.size.height = newHeight
        frame = pinnedFrame(frame)
        expandedRailFrame = frame
        panel.setFrame(
            frame,
            display: true,
            animate: animated && !applyingRailPresentation && panel.isVisible
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        positionRevealStrip()
    }

    private func constrainedPanelOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        if applyingRailPresentation || fullscreenRailController?.state.isCollapsed == true { return origin }
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
        let frame = pinnedFrame(expandedRailFrame ?? panel.frame)
        expandedRailFrame = frame
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible && !applyingRailPresentation)
        positionRevealStrip()
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
        if let screen = panel?.screen { return screen }
        if let frame = expandedRailFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
            return screen
        }
        return screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
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
        expandedRailFrame = panel.frame
        positionPanel(animated: true)
        fullscreenRailController?.refreshFullscreen()
    }

    private func pinnedX(in visible: NSRect, panelWidth: CGFloat) -> CGFloat {
        switch railSide {
        case .left:
            visible.minX - UsageRailLayout.screenEdgeOverlap
        case .right:
            visible.maxX - panelWidth + UsageRailLayout.screenEdgeOverlap
        }
    }

    private func animationDuration(_ duration: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
    }

}

private struct DailyBillWindowContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DailyBillPanelView(
            data: DailyBill.calculate(usages: store.enabledProviders.compactMap { store.usageByID[$0.id] }),
            language: preferences.language,
            colorScheme: preferences.appearance.colorScheme ?? colorScheme
        )
    }
}

// 悬浮面板不主动激活应用，承载视图仍需把第一次点击交给内容。
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingPanel: NSPanel {
    var allowsDragging = true
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
        guard allowsDragging else { super.sendEvent(event); return }
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
    init(rootView: some View, contentSizeChanged: @escaping (NSSize) -> Void) {
        let content = rootView
            .fixedSize()
            .onGeometryChange(for: NSSize.self) { $0.size } action: { contentSizeChanged($0) }
            // 在这里解析尺寸动画，窗口跟随同一组中间尺寸，不再另起追赶动画。
            .geometryGroup()
        let hostingView = FirstClickHostingView(rootView: content)
        let contentRect = NSRect(origin: .zero, size: hostingView.fittingSize)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 由 AppKit 调整窗口尺寸，SwiftUI 内容只随容器铺开。
        hostingView.sizingOptions = []
        let container = NSView(frame: contentRect)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
    }

    func updateFrame(_ frame: NSRect, duration: TimeInterval) {
        // 两种更新都走同一个动画属性，新尺寸能立即替换尚未完成的位置动画。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum ProviderDetailInteractionRegion {
    private static let edgeTolerance: CGFloat = 2

    static func contains(
        _ point: NSPoint,
        detailFrame: NSRect,
        railFrame: NSRect,
        railSide: UsageRailSide
    ) -> Bool {
        if railFrame.insetBy(dx: -edgeTolerance, dy: -edgeTolerance).contains(point) {
            return true
        }
        var region = detailFrame.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
        switch railSide {
        case .left:
            let minimumX = min(region.minX, railFrame.maxX)
            region.size.width = region.maxX - minimumX
            region.origin.x = minimumX
        case .right:
            region.size.width = max(region.maxX, railFrame.minX) - region.minX
        }
        return region.contains(point)
    }
}
