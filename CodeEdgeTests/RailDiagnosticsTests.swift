import Testing
@testable import CodeEdge

struct RailDiagnosticsTests {
    @Test(arguments: [true, false], [Bool?.none, .some(false), .some(true)])
    func detectionRetainsRawConfirmationAndBothWindowCounts(raw: Bool, confirmed: Bool?) {
        let message = RailDiagnostics.detection(raw: raw, confirmed: confirmed, desktopCount: 3, regularCount: 12)
        #expect(DiagnosticsRedactor.redact(message) == message)
        let value = confirmed.map { String($0) } ?? "pending"
        #expect(message == "Fullscreen detection raw: \(raw) confirmed: \(value) desktopCount: 3 regularCount: 12")
    }

    @Test(arguments: [
        FullscreenDetectionDebounce.DiscardReason.spaceTransition,
        .awaitingConfirmation,
        .unchanged,
    ])
    func eachDiscardReasonRemainsVisible(reason: FullscreenDetectionDebounce.DiscardReason) {
        let message = RailDiagnostics.discarded(reason: reason)
        #expect(DiagnosticsRedactor.redact(message) == message)
        #expect(message == "Debounce discarded reason: \(reason.rawValue)")
    }

    @Test
    func pointerEntryKeepsItsOriginalTimestampMarker() {
        #expect(RailDiagnostics.pointerEntered == "Reveal strip pointer entered")
        #expect(DiagnosticsRedactor.redact(RailDiagnostics.pointerEntered) == RailDiagnostics.pointerEntered)
    }

    @Test(arguments: [true, false])
    func interruptedAnimationRetainsItsNewDirection(collapsed: Bool) {
        let message = RailDiagnostics.interrupted(collapsed: collapsed)
        #expect(DiagnosticsRedactor.redact(message) == message)
        #expect(message == "Rail animation interrupted reversed collapsed: \(collapsed)")
    }

    @Test(arguments: [true, false], [RailPresentationPolicy.Trigger.space, .pointer])
    func startsKeepDirectionTimingTriggerAndCurve(collapsed: Bool, trigger: RailPresentationPolicy.Trigger) {
        let duration = trigger == .space ? 250 : 220
        let message = RailDiagnostics.started(collapsed: collapsed, durationMS: duration, trigger: trigger)
        #expect(DiagnosticsRedactor.redact(message) == message)
        let phase = collapsed ? "collapse" : "expansion"
        #expect(message == "Rail \(phase) started duration_ms: \(duration) trigger: \(trigger) curve: easeInOut")
    }

    @Test(arguments: [true, false])
    func completionsKeepTheirOriginalTimestampMarkers(collapsed: Bool) {
        let message = RailDiagnostics.completed(collapsed: collapsed)
        #expect(DiagnosticsRedactor.redact(message) == message)
        #expect(message == (collapsed ? "Rail collapse completed" : "Rail expansion completed"))
    }
}
