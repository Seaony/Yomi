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
}
