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
    private let onCollapseChanged: (Bool, RailPresentationPolicy.Trigger) -> Void
    private var isRunning = false
    private var isFullscreenOnTargetScreen = false
    private var lastFullscreenResult: Bool?
    private var lastLoggedConfirmedValue: Bool?
    private var lastDiscardReason: FullscreenDetectionDebounce.DiscardReason?
    private var detectionState = FullscreenDetectionDebounce.State()
    private var detectionTrigger = RailPresentationPolicy.Trigger.space
    private var lastEnabled: Bool?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var fullscreenPoll: Task<Void, Never>?
    private var pointerPoll: Task<Void, Never>?
    private var detectionCheck: Task<Void, Never>?
    private var scheduledDetectionCheckAt: Date?
    private var collapseTask: Task<Void, Never>?
    private var scheduledCollapseAt: Date?

    init(context: @escaping () -> Context, onCollapseChanged: @escaping (Bool, RailPresentationPolicy.Trigger) -> Void) {
        self.context = context
        self.onCollapseChanged = onCollapseChanged
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.spaceChanged() }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullscreen() }
        })
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
        detectionCheck?.cancel()
        collapseTask?.cancel()
        fullscreenPoll = nil
        pointerPoll = nil
        detectionCheck = nil
        scheduledDetectionCheckAt = nil
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
        lastLoggedConfirmedValue = nil
        lastDiscardReason = nil
        detectionState = FullscreenDetectionDebounce.State()
        detectionTrigger = .space
        let wasCollapsed = state.isCollapsed
        state = FullscreenCollapsePolicy.State()
        if wasCollapsed { onCollapseChanged(false, .pointer) }
    }

    func refreshFullscreen() {
        guard isRunning else { return }
        let current = context()
        if let lastEnabled, lastEnabled != current.enabled { detectionTrigger = .pointer }
        lastEnabled = current.enabled
        var rawValue = false
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
            rawValue = FullscreenDetection.hasFullscreenWindow(
                screenBounds: bounds,
                windows: windows,
                desktopWindows: desktopWindows,
                excludingPIDs: [ProcessInfo.processInfo.processIdentifier],
                safeAreaTopInset: current.safeAreaTopInset
            )
        }
        let decision: FullscreenDetectionDebounce.Decision
        if current.enabled {
            decision = FullscreenDetectionDebounce.sample(previous: detectionState, value: rawValue, now: Date())
        } else {
            decision = .init(state: .init(committedValue: false), committedValue: nil, nextCheckAt: nil, discardReason: nil)
        }
        detectionState = decision.state
        isFullscreenOnTargetScreen = detectionState.committedValue ?? false
        scheduleDetectionCheck(at: decision.nextCheckAt)

        let rawChanged = lastFullscreenResult != rawValue
        if rawChanged || lastLoggedConfirmedValue != detectionState.committedValue || decision.committedValue != nil {
            DiagnosticLog.shared.write(
                RailDiagnostics.detection(raw: rawValue, confirmed: detectionState.committedValue,
                                          desktopCount: desktopCount, regularCount: regularCount),
                category: .rail
            )
        }
        if let reason = decision.discardReason, rawChanged || reason != lastDiscardReason {
            DiagnosticLog.shared.write(RailDiagnostics.discarded(reason: reason), category: .rail)
        }
        lastFullscreenResult = rawValue
        lastLoggedConfirmedValue = detectionState.committedValue
        lastDiscardReason = decision.discardReason
        let trigger = decision.committedValue != nil ? detectionTrigger : .pointer
        if decision.nextCheckAt == nil { detectionTrigger = .space }
        updateState(using: current, trigger: trigger)
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

    private func spaceChanged() {
        guard isRunning else { return }
        detectionTrigger = .space
        detectionState = FullscreenDetectionDebounce.spaceChanged(previous: detectionState, now: Date())
        lastDiscardReason = nil
        scheduleDetectionCheck(at: nil)
        state.collapseAt = nil
        scheduleCollapseIfNeeded()
        refreshFullscreen()
    }

    private func scheduleDetectionCheck(at deadline: Date?) {
        guard scheduledDetectionCheckAt != deadline else { return }
        detectionCheck?.cancel()
        detectionCheck = nil
        scheduledDetectionCheckAt = deadline
        guard let deadline else { return }
        detectionCheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled, let self, self.isRunning,
                  self.scheduledDetectionCheckAt == deadline else { return }
            self.detectionCheck = nil
            self.scheduledDetectionCheckAt = nil
            self.refreshFullscreen()
        }
    }

    private func defaultsChanged() {
        guard isRunning, context().enabled != lastEnabled else { return }
        refreshFullscreen()
    }

    nonisolated static func resolveState(
        previous: FullscreenCollapsePolicy.State,
        input: FullscreenCollapsePolicy.Input,
        detectionPending: Bool
    ) -> FullscreenCollapsePolicy.State {
        guard detectionPending, input.enabled else {
            return FullscreenCollapsePolicy.reduce(previous: previous, input: input)
        }
        var held = previous
        held.collapseAt = nil
        if input.pointerInsideRail || input.pointerInsideRevealStrip || input.detailVisible
            || input.billVisible || input.revealRequested {
            held.isCollapsed = false
        }
        return held
    }

    private func updateState(
        using current: Context,
        trigger: RailPresentationPolicy.Trigger = .pointer,
        revealRequested: Bool = false,
        pointerEntry: Bool = false
    ) {
        let pointer = pointerEntry ? nil : NSEvent.mouseLocation
        let revealFrame = current.screenFrame.map {
            FullscreenCollapsePolicy.collapsedFrame(
                expandedFrame: current.expandedFrame, screenFrame: $0, edge: current.edge
            )
        }
        let previous = state
        let pointerInsideRevealFrame = pointer.map { revealFrame?.contains($0) == true } ?? false
        if previous.isCollapsed && (pointerEntry || pointerInsideRevealFrame) {
            DiagnosticLog.shared.write(RailDiagnostics.pointerEntered, category: .rail)
        }
        let now = Date()
        let input = FullscreenCollapsePolicy.Input(
            enabled: current.enabled,
            isFullscreenOnTargetScreen: isFullscreenOnTargetScreen,
            pointerInsideRail: pointer.map { current.railFrame.contains($0) } ?? false,
            pointerInsideRevealStrip: pointerEntry || pointerInsideRevealFrame,
            detailVisible: current.detailVisible,
            billVisible: current.billVisible,
            revealRequested: revealRequested,
            now: now
        )
        let detectionPending = detectionState.committedValue == nil || detectionState.candidate != nil
            || detectionState.ignoreUntil != nil
        state = Self.resolveState(previous: previous, input: input, detectionPending: detectionPending)
        scheduleCollapseIfNeeded()
        if previous.isCollapsed != state.isCollapsed {
            let revealedByInteraction = !state.isCollapsed && (!current.enabled || input.pointerInsideRail
                || input.pointerInsideRevealStrip || current.detailVisible || current.billVisible || revealRequested)
            onCollapseChanged(state.isCollapsed, revealedByInteraction ? .pointer : trigger)
        }
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
