import CoreGraphics
import Testing
@testable import Yomi

struct FullscreenDetectionTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let pid: pid_t = 42

    @Test
    func recognizesFullHeightWindowOnTargetScreen() {
        #expect(FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen, windows: [.init(pid: pid, layer: 0, bounds: screen)]
        ))
    }

    @Test
    func fullscreenOnAnotherDisplayDoesNotCount() {
        let second = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let windows = [FullscreenDetection.Window(pid: pid, layer: 0, bounds: second)]
        #expect(!FullscreenDetection.hasFullscreenWindow(screenBounds: screen, windows: windows))
        #expect(FullscreenDetection.hasFullscreenWindow(screenBounds: second, windows: windows))
    }

    @Test
    func focusOnAnotherDisplayDoesNotHideTargetScreenEvidence() {
        let windows: [FullscreenDetection.Window] = [
            .init(pid: 99, layer: 0, bounds: .init(x: 1500, y: 50, width: 1000, height: 700)),
            .init(pid: pid, layer: 0, bounds: screen),
        ]
        #expect(FullscreenDetection.hasFullscreenWindow(screenBounds: screen, windows: windows))
    }

    @Test
    func onlyCallerExcludedProcessesAreIgnored() {
        let windows = [FullscreenDetection.Window(pid: pid, layer: 0, bounds: screen)]
        #expect(!FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen, windows: windows, excludingPIDs: [pid]
        ))
        // Finder 的真实全屏窗口也计入，调用方只排除自己的进程。
        #expect(FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen, windows: windows, excludingPIDs: [99]
        ))
    }

    @Test
    func desktopAndOverlayLayersDoNotCount() {
        #expect(!FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen,
            windows: [.init(pid: pid, layer: 25, bounds: screen), .init(pid: pid, layer: -1, bounds: screen)]
        ))
    }

    @Test
    func maximizedWindowLeavingDockSpaceDoesNotCount() {
        #expect(!FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen,
            windows: [.init(pid: pid, layer: 0, bounds: .init(x: 0, y: 25, width: 1440, height: 825))]
        ))
    }

    @Test
    func recognizesNotchedScreenContentBelowSafeArea() {
        #expect(FullscreenDetection.hasFullscreenWindow(
            screenBounds: .init(x: -1512, y: 0, width: 1512, height: 982),
            windows: [.init(pid: pid, layer: 0, bounds: .init(x: -1512, y: 37, width: 1512, height: 945))],
            safeAreaTopInset: 37
        ))
    }

    @Test
    func recognizesFullscreenWithVisibleMenuBar() {
        #expect(FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen,
            windows: [.init(pid: pid, layer: 0, bounds: .init(x: 0, y: 24, width: 1440, height: 876))]
        ))
    }

    @Test(arguments: [4.0, 4.01])
    func widthAndOriginToleranceEndsAtFourPoints(offset: Double) {
        for bounds in [
            CGRect(x: offset, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 0, width: 1440 + offset, height: 900),
        ] {
            #expect(FullscreenDetection.hasFullscreenWindow(
                screenBounds: screen, windows: [.init(pid: pid, layer: 0, bounds: bounds)]
            ) == (offset <= 4))
        }
    }

    @Test
    func windowsTooFarFromTopOrBottomDoNotCount() {
        for bounds in [
            CGRect(x: 0, y: 70, width: 1440, height: 830),
            CGRect(x: 0, y: 24, width: 1440, height: 870),
        ] {
            #expect(!FullscreenDetection.hasFullscreenWindow(
                screenBounds: screen, windows: [.init(pid: pid, layer: 0, bounds: bounds)]
            ))
        }
    }

    @Test
    func emptyScreenOrWindowListDoesNotCount() {
        #expect(!FullscreenDetection.hasFullscreenWindow(screenBounds: screen, windows: []))
        #expect(!FullscreenDetection.hasFullscreenWindow(screenBounds: .zero, windows: []))
        #expect(!FullscreenDetection.hasFullscreenWindow(
            screenBounds: screen, windows: [.init(pid: 0, layer: 0, bounds: screen)]
        ))
    }

    @Test
    func convertsScreensAboveBelowAndBesidePrimaryDisplay() {
        let samples: [(CGRect, CGRect)] = [
            (.init(x: 0, y: 0, width: 1512, height: 982), .init(x: 0, y: 0, width: 1512, height: 982)),
            (.init(x: 1512, y: 0, width: 1920, height: 1080), .init(x: 1512, y: -98, width: 1920, height: 1080)),
            (.init(x: 100, y: 982, width: 1440, height: 900), .init(x: 100, y: -900, width: 1440, height: 900)),
            (.init(x: 0, y: -1080, width: 1920, height: 1080), .init(x: 0, y: 982, width: 1920, height: 1080)),
        ]
        for (appKit, expected) in samples {
            #expect(FullscreenDetection.coreGraphicsBounds(appKitFrame: appKit, primaryScreenHeight: 982) == expected)
        }
    }
}
