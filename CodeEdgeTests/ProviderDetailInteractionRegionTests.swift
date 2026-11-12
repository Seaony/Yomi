import AppKit
import Testing
@testable import CodeEdge

@Suite("Provider detail interaction region")
struct ProviderDetailInteractionRegionTests {
    private let detailFrame = NSRect(x: 100, y: 200, width: 300, height: 240)
    private var panelFrame: NSRect { detailFrame.insetBy(dx: -38, dy: -38) }

    @Test
    func visibleCardFrameExcludesOnlyTheTransparentWindowPadding() {
        #expect(ProviderDetailLayout.visibleCardFrame(panelFrame: panelFrame) == detailFrame)
    }

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

    @Test(arguments: [UsageRailSide.left, .right])
    func transparentShadowMarginDoesNotKeepTheCardOpen(side: UsageRailSide) {
        let railFrame = NSRect(x: side == .right ? 406 : 42, y: 100, width: 52, height: 600)
        let outerX: CGFloat = side == .right ? 90 : 410

        #expect(!contains(NSPoint(x: outerX, y: 300), railFrame: railFrame, side: side))
        #expect(!contains(NSPoint(x: 250, y: 190), railFrame: railFrame, side: side))
        #expect(!contains(NSPoint(x: 250, y: 450), railFrame: railFrame, side: side))
        #expect(contains(NSPoint(x: 250, y: 300), railFrame: railFrame, side: side))
        #expect(contains(NSPoint(x: side == .right ? 403 : 97, y: 300), railFrame: railFrame, side: side))
    }

    @Test(arguments: [UsageRailSide.left, .right])
    func visibleCardRetainsOnlyTheOriginalEdgeTolerance(side: UsageRailSide) {
        let railFrame = NSRect(x: side == .right ? 406 : 42, y: 100, width: 52, height: 600)
        let nearX: CGFloat = side == .right ? 99 : 401
        let farX: CGFloat = side == .right ? 97 : 403

        #expect(contains(NSPoint(x: nearX, y: 300), railFrame: railFrame, side: side))
        #expect(!contains(NSPoint(x: farX, y: 300), railFrame: railFrame, side: side))
        #expect(contains(NSPoint(x: 250, y: 199), railFrame: railFrame, side: side))
        #expect(!contains(NSPoint(x: 250, y: 197), railFrame: railFrame, side: side))
    }

    private func contains(
        _ point: NSPoint,
        railFrame: NSRect,
        side: UsageRailSide
    ) -> Bool {
        ProviderDetailInteractionRegion.contains(
            point,
            detailFrame: ProviderDetailLayout.visibleCardFrame(panelFrame: panelFrame),
            railFrame: railFrame,
            railSide: side
        )
    }
}
