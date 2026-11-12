import Foundation

nonisolated enum FullscreenDetectionDebounce {
    static let spaceChangeDelay: TimeInterval = 0.3
    static let confirmationDelay: TimeInterval = 0.15

    struct State: Equatable, Sendable {
        var committedValue: Bool? = nil
        var ignoreUntil: Date? = nil
        var candidate: Bool? = nil
        var candidateSince: Date? = nil
    }

    enum DiscardReason: String, Equatable, Sendable {
        case spaceTransition
        case awaitingConfirmation
        case unchanged
    }

    struct Decision: Equatable, Sendable {
        let state: State
        let committedValue: Bool?
        let nextCheckAt: Date?
        let discardReason: DiscardReason?
    }

    static func spaceChanged(previous: State, now: Date) -> State {
        State(committedValue: previous.committedValue, ignoreUntil: now.addingTimeInterval(spaceChangeDelay))
    }

    static func sample(previous: State, value: Bool, now: Date) -> Decision {
        if let deadline = previous.ignoreUntil, now < deadline {
            return Decision(state: previous, committedValue: nil, nextCheckAt: deadline, discardReason: .spaceTransition)
        }

        var state = previous
        state.ignoreUntil = nil
        if state.committedValue == value {
            state.candidate = nil
            state.candidateSince = nil
            return Decision(state: state, committedValue: nil, nextCheckAt: nil, discardReason: .unchanged)
        }

        let since: Date
        if state.candidate == value, let candidateSince = state.candidateSince {
            since = candidateSince
        } else {
            state.candidate = value
            state.candidateSince = now
            since = now
        }
        // 相同候选保留首次读取时间，快速轮询不能让确认时间不断后移。
        let confirmationAt = since.addingTimeInterval(confirmationDelay)
        guard now >= confirmationAt else {
            return Decision(state: state, committedValue: nil, nextCheckAt: confirmationAt, discardReason: .awaitingConfirmation)
        }

        state.committedValue = value
        state.candidate = nil
        state.candidateSince = nil
        return Decision(state: state, committedValue: value, nextCheckAt: nil, discardReason: nil)
    }
}
