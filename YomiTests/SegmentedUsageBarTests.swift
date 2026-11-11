import Testing
@testable import Yomi

struct SegmentedUsageBarTests {
    @Test
    func segmentCountFitsFixedWidthsAndGaps() {
        let samples: [(Double, Int)] = [(0, 0), (2.99, 0), (3, 1), (7.99, 1), (8, 2), (100, 20), (103, 21)]
        for (width, expected) in samples {
            #expect(SegmentedUsageBar.segmentCount(width: width) == expected)
        }
    }

    @Test
    func remainingEndpointsAndRoundingAreStable() {
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0, segmentCount: 20) == 0)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 1, segmentCount: 20) == 20)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.5, segmentCount: 20) == 10)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.0249, segmentCount: 20) == 0)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.025, segmentCount: 20) == 1)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.0251, segmentCount: 20) == 1)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.9749, segmentCount: 20) == 19)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.975, segmentCount: 20) == 20)
    }

    @Test
    func clampsQuotaFractionsAndHandlesAnEmptyBar() {
        #expect(SegmentedUsageBar.filledCount(remainingFraction: -0.1, segmentCount: 20) == 0)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 1.1, segmentCount: 20) == 20)
        #expect(SegmentedUsageBar.filledCount(remainingFraction: 0.5, segmentCount: 0) == 0)
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 0.5, segmentCount: 0) == nil)
    }

    @Test
    func timeMarkerMirrorsUsedIntoRemaining() {
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 0, segmentCount: 20) == 19)
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 1, segmentCount: 20) == 0)
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 0.25, segmentCount: 20) == 15)
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 0.75, segmentCount: 20) == 5)
        #expect(SegmentedUsageBar.markerIndex(expectedUsedFraction: 0.5, segmentCount: 1) == 0)
    }

    @Test
    func aheadUsageKeepsRemainingAndOverspentSegmentsDistinct() {
        let states = SegmentedUsageBar.states(remainingFraction: 0.2, expectedUsedFraction: 0.5, segmentCount: 10)
        #expect(states.map(\.fill) == [.solid, .solid, .overspent, .overspent, .overspent,
                                     .dim, .dim, .dim, .dim, .dim])
        #expect(states.enumerated().filter { $0.element.isMarker }.map(\.offset) == [5])
    }

    @Test
    func behindUsageDoesNotCreateOverspentSegments() {
        let states = SegmentedUsageBar.states(remainingFraction: 0.8, expectedUsedFraction: 0.5, segmentCount: 10)
        #expect(states.map(\.fill) == Array(repeating: .solid, count: 8) + [.dim, .dim])
        #expect(states[5].isMarker)
        #expect(states[5].fill == .solid)
    }

    @Test
    func exactPaceDoesNotAddAnOverspentSegmentAtTheMarker() {
        let states = SegmentedUsageBar.states(remainingFraction: 0.5, expectedUsedFraction: 0.5, segmentCount: 10)
        #expect(states.map(\.fill) == Array(repeating: .solid, count: 5) + Array(repeating: .dim, count: 5))
        #expect(states[5].isMarker)
        #expect(states[5].fill == .dim)
    }

    @Test
    func remainingEndpointsKeepTheCorrectFill() {
        let empty = SegmentedUsageBar.states(remainingFraction: 0, expectedUsedFraction: 0.5, segmentCount: 10)
        #expect(empty.map(\.fill) == Array(repeating: .overspent, count: 5) + Array(repeating: .dim, count: 5))
        let full = SegmentedUsageBar.states(remainingFraction: 1, expectedUsedFraction: 0.5, segmentCount: 10)
        #expect(full.allSatisfy { $0.fill == .solid })
        #expect(full[5].isMarker)
        let fullyExpected = SegmentedUsageBar.states(remainingFraction: 0, expectedUsedFraction: 1, segmentCount: 10)
        #expect(fullyExpected.allSatisfy { $0.fill == .dim })
        #expect(fullyExpected[0].isMarker)
    }

    @Test
    func markerDoesNotReplaceAnOverspentSegmentsFill() {
        let states = SegmentedUsageBar.states(remainingFraction: 0.2, expectedUsedFraction: 0.54, segmentCount: 10)
        #expect(states[4].isMarker)
        #expect(states[4].fill == .overspent)
    }

    @Test
    func overspentBandUsesTheExistingRoundingBoundary() {
        let before = SegmentedUsageBar.states(remainingFraction: 0.2499, expectedUsedFraction: 0.75, segmentCount: 10)
        #expect(before.filter { $0.fill == .solid }.count == 2)
        #expect(before.filter { $0.fill == .overspent }.count == 1)
        let boundary = SegmentedUsageBar.states(remainingFraction: 0.25, expectedUsedFraction: 0.75, segmentCount: 10)
        #expect(boundary.filter { $0.fill == .solid }.count == 3)
        #expect(!boundary.contains { $0.fill == .overspent })
    }

    @Test
    func absentPaceKeepsTheOrdinaryBarAndEmptyBarsHaveNoState() {
        let states = SegmentedUsageBar.states(remainingFraction: 0.2, expectedUsedFraction: nil, segmentCount: 10)
        #expect(states.map(\.fill) == [.solid, .solid] + Array(repeating: .dim, count: 8))
        #expect(!states.contains { $0.isMarker })
        #expect(SegmentedUsageBar.states(remainingFraction: 0.2, expectedUsedFraction: 0.5, segmentCount: 0).isEmpty)
    }
}
