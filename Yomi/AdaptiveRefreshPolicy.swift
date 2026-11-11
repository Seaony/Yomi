import Foundation

nonisolated struct AdaptiveRefreshPolicy: Sendable {
    struct Input: Equatable, Sendable {
        var now: Date
        var lastInteractionAt: Date?
        var lastCodingActivityAt: Date? = nil
        var lowPowerModeEnabled: Bool
        var thermalState: ProcessInfo.ThermalState
    }

    enum Reason: String, Equatable, Sendable {
        case recentInteraction
        case codingActivity
        case warm
        case idle
        case longIdle
        case constrained
    }

    struct Decision: Equatable, Sendable {
        var interval: TimeInterval
        var reason: Reason

        var delay: Duration { .seconds(interval) }
    }

    static let nominalIntervalForHeuristics: TimeInterval = 300

    func nextDelay(for input: Input) -> Decision {
        if input.lowPowerModeEnabled || input.thermalState == .serious || input.thermalState == .critical {
            return Decision(interval: 1800, reason: .constrained)
        }

        let base = interactionDecision(for: input)
        if let coding = input.lastCodingActivityAt,
           input.now.timeIntervalSince(coding) < 300,
           base.interval > 300 {
            return Decision(interval: 300, reason: .codingActivity)
        }
        return base
    }

    private func interactionDecision(for input: Input) -> Decision {
        guard let interaction = input.lastInteractionAt else {
            return Decision(interval: 1800, reason: .longIdle)
        }
        let age = input.now.timeIntervalSince(interaction)
        if age <= 300 { return Decision(interval: 120, reason: .recentInteraction) }
        if age <= 3600 { return Decision(interval: 300, reason: .warm) }
        if age < 14400 { return Decision(interval: 900, reason: .idle) }
        return Decision(interval: 1800, reason: .longIdle)
    }
}
