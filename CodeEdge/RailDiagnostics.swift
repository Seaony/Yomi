import Foundation

nonisolated enum RailDiagnostics {
    static func detection(raw: Bool, confirmed: Bool?, desktopCount: Int, regularCount: Int) -> String {
        let confirmed = confirmed.map { String($0) } ?? "pending"
        return "Fullscreen detection raw: \(raw) confirmed: \(confirmed) desktopCount: \(desktopCount) regularCount: \(regularCount)"
    }

    static func discarded(reason: FullscreenDetectionDebounce.DiscardReason) -> String {
        "Debounce discarded reason: \(reason.rawValue)"
    }

    static let pointerEntered = "Reveal strip pointer entered"

    static func interrupted(collapsed: Bool) -> String {
        "Rail animation interrupted reversed collapsed: \(collapsed)"
    }

    static func started(collapsed: Bool, durationMS: Int, trigger: RailPresentationPolicy.Trigger) -> String {
        let phase = collapsed ? "collapse" : "expansion"
        return "Rail \(phase) started duration_ms: \(durationMS) trigger: \(trigger) curve: easeInOut"
    }

    static func completed(collapsed: Bool) -> String {
        collapsed ? "Rail collapse completed" : "Rail expansion completed"
    }
}
