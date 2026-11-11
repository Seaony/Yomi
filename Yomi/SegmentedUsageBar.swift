import Foundation

nonisolated enum SegmentedUsageBar {
    enum Fill: Equatable, Sendable {
        case solid
        case overspent
        case dim
    }

    struct SegmentState: Equatable, Sendable {
        let fill: Fill
        let isMarker: Bool
    }

    static let barWidth = 3.0
    static let spacing = 2.0

    static func states(
        remainingFraction: Double,
        expectedUsedFraction: Double?,
        segmentCount: Int
    ) -> [SegmentState] {
        guard segmentCount > 0 else { return [] }
        let filled = filledCount(remainingFraction: remainingFraction, segmentCount: segmentCount)
        let expected = expectedUsedFraction.flatMap { $0.isFinite ? $0 : nil }
        let expectedFilled = expected.map {
            filledCount(remainingFraction: 1 - $0, segmentCount: segmentCount)
        } ?? filled
        let marker = expected.flatMap {
            markerIndex(expectedUsedFraction: $0, segmentCount: segmentCount)
        }
        return (0..<segmentCount).map { index in
            let fill: Fill = index < filled ? .solid : index < expectedFilled ? .overspent : .dim
            // 刻度只决定高度，不覆盖这一段原本的颜色。
            return SegmentState(fill: fill, isMarker: index == marker)
        }
    }

    static func segmentCount(width: Double) -> Int {
        guard width.isFinite, width >= barWidth else { return 0 }
        return Int(((width + spacing) / (barWidth + spacing)).rounded(.down))
    }

    static func filledCount(remainingFraction: Double, segmentCount: Int) -> Int {
        guard segmentCount > 0, remainingFraction.isFinite else { return 0 }
        let fraction = min(max(remainingFraction, 0), 1)
        return min(segmentCount, Int((fraction * Double(segmentCount)).rounded()))
    }

    static func markerIndex(expectedUsedFraction: Double, segmentCount: Int) -> Int? {
        guard segmentCount > 0, expectedUsedFraction.isFinite else { return nil }
        // 条的实色部分代表剩余，时间刻度也要从已用比例镜像过来。
        let remaining = 1 - min(max(expectedUsedFraction, 0), 1)
        return min(segmentCount - 1, Int((remaining * Double(segmentCount)).rounded(.down)))
    }
}
