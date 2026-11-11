import Foundation

nonisolated enum SegmentedUsageBar {
    enum Fill: Equatable, Sendable {
        case solid
        case dim
    }

    static let segmentCount = 50
    static let spacing = 2.0

    static func filledCount(remainingFraction: Double) -> Int {
        guard remainingFraction.isFinite else { return 0 }
        let fraction = min(max(remainingFraction, 0), 1)
        return Int((fraction * Double(segmentCount)).rounded())
    }

    static func states(remainingFraction: Double) -> [Fill] {
        let filled = filledCount(remainingFraction: remainingFraction)
        return (0..<segmentCount).map { $0 < filled ? .solid : .dim }
    }
}
