import Testing
@testable import Yomi

struct SegmentedUsageBarTests {
    @Test
    func fixedSegmentsRepresentTheRequestedPercentages() {
        let samples: [(Double, Int)] = [(1, 50), (0.78, 39), (0.58, 29), (0.2, 10), (0.03, 2), (0, 0)]
        for (remaining, filled) in samples {
            let states = SegmentedUsageBar.states(remainingFraction: remaining)
            #expect(states.count == 50)
            #expect(SegmentedUsageBar.filledCount(remainingFraction: remaining) == filled)
            #expect(states == Array(repeating: .solid, count: filled) + Array(repeating: .dim, count: 50 - filled))
        }
        #expect(SegmentedUsageBar.segmentCount == 50)
        #expect(SegmentedUsageBar.spacing == 2)
    }

    @Test
    func halfSegmentRoundsUpAtBothEndsAndInTheMiddle() {
        let samples: [(Double, Int)] = [
            (0.009999, 0), (0.01, 1), (0.010001, 1),
            (0.029999, 1), (0.03, 2), (0.030001, 2),
            (0.489999, 24), (0.49, 25), (0.490001, 25),
            (0.989999, 49), (0.99, 50), (0.990001, 50),
        ]
        for (remaining, filled) in samples {
            #expect(SegmentedUsageBar.filledCount(remainingFraction: remaining) == filled)
            #expect(SegmentedUsageBar.states(remainingFraction: remaining).filter { $0 == .solid }.count == filled)
        }
    }

    @Test
    func fractionsOutsideTheQuotaRangeStayWithinFiftySegments() {
        #expect(SegmentedUsageBar.states(remainingFraction: -0.1) == Array(repeating: .dim, count: 50))
        #expect(SegmentedUsageBar.states(remainingFraction: 1.1) == Array(repeating: .solid, count: 50))
        #expect(SegmentedUsageBar.states(remainingFraction: .nan) == Array(repeating: .dim, count: 50))
    }
}
