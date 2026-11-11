import AppKit
import Foundation

@MainActor
final class FullscreenRailController {
    struct Context {
        let enabled: Bool
        let screenFrame: CGRect?
        let safeAreaTopInset: CGFloat
        let expandedFrame: CGRect
        let railFrame: CGRect
        let edge: FullscreenCollapsePolicy.Edge
        let detailVisible: Bool
        let billVisible: Bool
    }

    private(set) var state = FullscreenCollapsePolicy.State()

    private let context: () -> Context
    private let onCollapseChanged: (Bool) -> Void
    private var isRunning = false
    private var isFullscreenOnTargetScreen = false
    private var lastFullscreenResult: Bool?
    private var lastEnabled: Bool?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var fullscreenPoll: Task<Void, Never>?
    private var pointerPoll: Task<Void, Never>?
    private var workspaceRecheck: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var scheduledCollapseAt: Date?

    init(context: @escaping () -> Context, onCollapseChanged: @escaping (Bool) -> Void) {
        self.context = context
        self.onCollapseChanged = onCollapseChanged
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.workspaceChanged() }
            })
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.defaultsChanged() }
        }
        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            Task { @MainActor [weak self] in self?.updatePointerState() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePointerState() }
        }
        fullscreenPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.refreshFullscreen()
            }
        }
        pointerPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.updatePointerState()
            }
        }
        refreshFullscreen()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        fullscreenPoll?.cancel()
        pointerPoll?.cancel()
        workspaceRecheck?.cancel()
        collapseTask?.cancel()
        fullscreenPoll = nil
        pointerPoll = nil
        workspaceRecheck = nil
        collapseTask = nil
        scheduledCollapseAt = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        lastEnabled = nil
        isFullscreenOnTargetScreen = false
        lastFullscreenResult = nil
        let wasCollapsed = state.isCollapsed
        state = FullscreenCollapsePolicy.State()
        if wasCollapsed { onCollapseChanged(false) }
    }

    func refreshFullscreen() {
        guard isRunning else { return }
        let current = context()
        lastEnabled = current.enabled
        var desktopCount = 0
        var regularCount = 0
        if current.enabled, let screenFrame = current.screenFrame,
           let primaryScreen = NSScreen.screens.first {
            let bounds = FullscreenDetection.coreGraphicsBounds(
                appKitFrame: screenFrame, primaryScreenHeight: primaryScreen.frame.height
            )
            let windows = FullscreenDetection.onScreenWindows()
            let desktopWindows = FullscreenDetection.onScreenDesktopWindows()
            desktopCount = desktopWindows.count
            regularCount = windows.filter { $0.layer == 0 && $0.activationPolicy == .regular }.count
            isFullscreenOnTargetScreen = FullscreenDetection.hasFullscreenWindow(
                screenBounds: bounds,
                windows: windows,
                desktopWindows: desktopWindows,
                excludingPIDs: [ProcessInfo.processInfo.processIdentifier],
                safeAreaTopInset: current.safeAreaTopInset
            )
        } else {
            isFullscreenOnTargetScreen = false
        }
        if lastFullscreenResult != isFullscreenOnTargetScreen {
            lastFullscreenResult = isFullscreenOnTargetScreen
            DiagnosticLog.shared.write(
                "Fullscreen detection active=\(isFullscreenOnTargetScreen) desktopCount=\(desktopCount) regularCount=\(regularCount)",
                category: .rail
            )
        }
        updateState(using: current)
    }

    func updatePointerState() {
        guard isRunning else { return }
        updateState(using: context())
    }

    func reveal() {
        guard isRunning else { return }
        updateState(using: context(), revealRequested: true)
    }

    func pointerEnteredRevealStrip() {
        guard isRunning else { return }
        updateState(using: context(), revealRequested: true, pointerEntry: true)
    }

    private func workspaceChanged() {
        guard isRunning else { return }
        refreshFullscreen()
        workspaceRecheck?.cancel()
        workspaceRecheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.workspaceRecheck = nil
            self.refreshFullscreen()
        }
    }

    private func defaultsChanged() {
        guard isRunning, context().enabled != lastEnabled else { return }
        refreshFullscreen()
    }

    private func updateState(using current: Context, revealRequested: Bool = false, pointerEntry: Bool = false) {
        let pointer = pointerEntry ? nil : NSEvent.mouseLocation
        let revealFrame = current.screenFrame.map {
            FullscreenCollapsePolicy.collapsedFrame(
                expandedFrame: current.expandedFrame, screenFrame: $0, edge: current.edge
            )
        }
        let previous = state
        let pointerInsideRevealFrame = pointer.map { revealFrame?.contains($0) == true } ?? false
        if previous.isCollapsed && (pointerEntry || pointerInsideRevealFrame) {
            DiagnosticLog.shared.write("Reveal strip pointer entered", category: .rail)
        }
        state = FullscreenCollapsePolicy.reduce(previous: previous, input: .init(
            enabled: current.enabled,
            isFullscreenOnTargetScreen: isFullscreenOnTargetScreen,
            pointerInsideRail: pointer.map { current.railFrame.contains($0) } ?? false,
            pointerInsideRevealStrip: pointerEntry || pointerInsideRevealFrame,
            detailVisible: current.detailVisible,
            billVisible: current.billVisible,
            revealRequested: revealRequested,
            now: Date()
        ))
        scheduleCollapseIfNeeded()
        if previous.isCollapsed != state.isCollapsed { onCollapseChanged(state.isCollapsed) }
    }

    private func scheduleCollapseIfNeeded() {
        guard scheduledCollapseAt != state.collapseAt else { return }
        collapseTask?.cancel()
        collapseTask = nil
        scheduledCollapseAt = state.collapseAt
        guard let deadline = scheduledCollapseAt else { return }
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled, let self,
                  self.isRunning, self.scheduledCollapseAt == deadline else { return }
            self.collapseTask = nil
            // 到点后重新读取鼠标和窗口锁，不能按排队时的旧状态直接收起。
            self.updatePointerState()
        }
    }
}
