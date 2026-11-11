import Foundation

nonisolated enum SegmentedUsageBar {
    static let barWidth = 3.0
    static let spacing = 2.0

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
