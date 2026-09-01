import AppKit
import Testing
@testable import Yomi

@Suite("Provider detail interaction region")
struct ProviderDetailInteractionRegionTests {
    private let detailFrame = NSRect(x: 100, y: 200, width: 300, height: 240)

    @Test
    func rightRailIncludesCardAndHorizontalBridge() {
        let railFrame = NSRect(x: 406, y: 100, width: 52, height: 600)

        #expect(contains(NSPoint(x: 250, y: 300), railFrame: railFrame, side: .right))
        #expect(contains(NSPoint(x: 403, y: 300), railFrame: railFrame, side: .right))
        #expect(contains(NSPoint(x: 430, y: 500), railFrame: railFrame, side: .right))
        #expect(!contains(NSPoint(x: 403, y: 500), railFrame: railFrame, side: .right))
        #expect(!contains(NSPoint(x: 97, y: 300), railFrame: railFrame, side: .right))
    }

    @Test
    func leftRailIncludesCardAndHorizontalBridge() {
        let railFrame = NSRect(x: 42, y: 100, width: 52, height: 600)

        #expect(contains(NSPoint(x: 250, y: 300), railFrame: railFrame, side: .left))
        #expect(contains(NSPoint(x: 97, y: 300), railFrame: railFrame, side: .left))
        #expect(contains(NSPoint(x: 60, y: 500), railFrame: railFrame, side: .left))
        #expect(!contains(NSPoint(x: 97, y: 500), railFrame: railFrame, side: .left))
        #expect(!contains(NSPoint(x: 403, y: 300), railFrame: railFrame, side: .left))
    }

    private func contains(
        _ point: NSPoint,
        railFrame: NSRect,
        side: UsageRailSide
    ) -> Bool {
        ProviderDetailInteractionRegion.contains(
            point,
            detailFrame: detailFrame,
            railFrame: railFrame,
            railSide: side
        )
    }
}
