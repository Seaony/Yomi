import Foundation

nonisolated enum QuotaNotificationPolicy {
    enum Kind: String, Codable, Hashable, Sendable {
        case lowQuota
        case depleted
        case reset
    }

    struct Settings: Equatable, Sendable {
        var lowQuotaEnabled = false
        var depletedEnabled = false
        var resetEnabled = false
        var thresholds = [50, 20]

        var activeThresholds: [Int] {
            Array(Set(thresholds.filter { (1...99).contains($0) })).sorted(by: >)
        }
    }

    struct WindowState: Codable, Equatable, Sendable {
        var lastUsedFraction: Double
        var peakUsedFraction: Double
        var resetsAt: Date?
        var firedThresholds: Set<Int> = []
        var depletedFired = false
    }

    struct State: Codable, Equatable, Sendable {
        var revision: Int
        var windows: [String: WindowState] = [:]
    }

    struct Event: Equatable, Sendable {
        let providerID: ProviderID
        let windowID: String
        let kind: Kind
        let remainingPercent: Double
        let resetsAt: Date?
        var threshold: Int? = nil
    }

    struct Reduction: Equatable, Sendable {
        let state: State?
        let events: [Event]
    }

    // 与 CodexBar 的百分比单位保持一致。
    static let depletedRemainingPercent = 0.0001

    static func reduce(
        usage: ProviderUsage,
        previous: State?,
        revision: Int = 0,
        isFirstRefresh: Bool,
        settings: Settings,
        now: Date = Date()
    ) -> Reduction {
        // 失败和缓存不能成为下次提醒的基线。
        guard usage.state == .ready else { return Reduction(state: previous, events: []) }
        let sameOwner = previous?.revision == revision
        var state = sameOwner ? previous! : State(revision: revision)
        let suppress = isFirstRefresh || !sameOwner
        let thresholds = settings.activeThresholds
        var events: [Event] = []
        var visited: Set<String> = []

        for window in usage.windows + usage.additionalWindows {
            guard window.usedFraction.isFinite, visited.insert(window.id).inserted else { continue }
            let used = window.clampedFraction
            let remaining = (1 - used) * 100
            let currentlyCrossed = Set(thresholds.filter { remaining <= Double($0) })
            let depleted = remaining <= depletedRemainingPercent
            guard var tracked = state.windows[window.id] else {
                state.windows[window.id] = WindowState(
                    lastUsedFraction: used, peakUsedFraction: used, resetsAt: window.resetsAt,
                    firedThresholds: currentlyCrossed, depletedFired: depleted
                )
                continue
            }

            let rolled = tracked.resetsAt.map { old in
                old <= now && window.resetsAt.map { $0 > old && $0 > now } == true
            } ?? false
            let priorPeak = tracked.peakUsedFraction
            let previousRemaining = rolled ? 100 : (1 - tracked.lastUsedFraction) * 100
            if rolled {
                // 即便旧窗口用得少而不发重置提醒，新周期也要独立计数。
                tracked.firedThresholds = []
                tracked.depletedFired = false
                tracked.peakUsedFraction = used
            }

            let crossed = thresholds.filter {
                remaining <= Double($0) && previousRemaining > Double($0)
                    && !tracked.firedThresholds.contains($0)
            }.min()
            let newlyDepleted = depleted && previousRemaining > depletedRemainingPercent
                && !tracked.depletedFired

            if !suppress {
                if rolled, priorPeak > 0.15, settings.resetEnabled {
                    events.append(Event(providerID: usage.id, windowID: window.id, kind: .reset,
                                        remainingPercent: remaining, resetsAt: window.resetsAt))
                }
                if newlyDepleted, settings.depletedEnabled {
                    events.append(Event(providerID: usage.id, windowID: window.id, kind: .depleted,
                                        remainingPercent: remaining, resetsAt: window.resetsAt))
                } else if let crossed, settings.lowQuotaEnabled {
                    events.append(Event(providerID: usage.id, windowID: window.id, kind: .lowQuota,
                                        remainingPercent: remaining, resetsAt: window.resetsAt,
                                        threshold: crossed))
                }
            }

            // 静音和启动首轮也记住已跨过的档位，后来启用时不补发旧提醒。
            if let crossed {
                tracked.firedThresholds.formUnion(thresholds.filter { $0 >= crossed })
            }
            if suppress { tracked.firedThresholds.formUnion(currentlyCrossed) }
            tracked.depletedFired = tracked.depletedFired || depleted
            tracked.lastUsedFraction = used
            tracked.peakUsedFraction = max(tracked.peakUsedFraction, used)
            tracked.resetsAt = window.resetsAt
            state.windows[window.id] = tracked
        }
        return Reduction(state: state, events: events)
    }
}
