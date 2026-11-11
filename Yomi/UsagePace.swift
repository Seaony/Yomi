import Foundation

nonisolated struct UsagePace: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    let stage: Stage
    let deltaPercent: Double
    let expectedUsedPercent: Double
    let actualUsedPercent: Double
    let predictionReady: Bool
    let etaSeconds: TimeInterval?
    let willLastToReset: Bool

    var expectedRemainingFraction: Double { 1 - expectedUsedPercent / 100 }

    static func evaluate(window: UsageWindow, now: Date = Date()) -> UsagePace? {
        guard let minutes = window.windowMinutes, minutes > 0,
              let resetsAt = window.resetsAt,
              window.usedFraction.isFinite,
              now.timeIntervalSince1970.isFinite,
              resetsAt.timeIntervalSince1970.isFinite else { return nil }

        let duration = TimeInterval(minutes) * 60
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime > 0, remainingTime <= duration else { return nil }
        let elapsed = min(max(duration - remainingTime, 0), duration)
        let expected = min(max(elapsed / duration * 100, 0), 100)
        let actual = window.clampedFraction * 100
        guard elapsed > 0 || actual == 0 else { return nil }
        let delta = actual - expected

        // 刚开始的短暂用量波动很大，先只显示时间刻度。
        let predictionReady = elapsed >= duration / 15
        var etaSeconds: TimeInterval?
        var willLastToReset = false
        if predictionReady {
            if actual >= 100 {
                etaSeconds = 0
            } else if actual > 0 {
                let rate = actual / elapsed
                let candidate = (100 - actual) / rate
                if candidate >= remainingTime {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            } else {
                willLastToReset = true
            }
        }

        return UsagePace(
            stage: stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            predictionReady: predictionReady,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset
        )
    }

    private static func stage(for delta: Double) -> Stage {
        let distance = abs(delta)
        if distance <= 2 { return .onTrack }
        if distance <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if distance <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
