import CoreGraphics
import Foundation

nonisolated enum FullscreenDetection {
    struct Window: Sendable {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    static func hasFullscreenWindow(
        screenBounds: CGRect,
        windows: [Window],
        excludingPIDs: Set<pid_t> = [],
        safeAreaTopInset: CGFloat = 0
    ) -> Bool {
        guard screenBounds.width > 0, screenBounds.height > 0 else { return false }
        return windows.contains { window in
            guard window.pid > 0, window.layer == 0, !excludingPIDs.contains(window.pid) else { return false }
            let bounds = window.bounds
            guard abs(bounds.minX - screenBounds.minX) <= 4,
                  abs(bounds.width - screenBounds.width) <= 4 else { return false }

            if abs(bounds.minY - screenBounds.minY) <= 4,
               abs(bounds.height - screenBounds.height) <= 4 {
                return true
            }

            // 全屏内容可以避开刘海或菜单栏，但仍要到达目标屏幕底部。
            let maximumTopInset = max(safeAreaTopInset, 40) + 4
            return abs(bounds.maxY - screenBounds.maxY) <= 4
                && bounds.minY >= screenBounds.minY - 4
                && bounds.minY <= screenBounds.minY + maximumTopInset
                && bounds.height >= screenBounds.height - maximumTopInset - 10
        }
    }

    static func coreGraphicsBounds(appKitFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: primaryScreenHeight - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    static func onScreenWindows() -> [Window] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        // 只保留检测需要的字段，不读取窗口标题。
        return entries.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return Window(pid: pid, layer: layer, bounds: rectangle)
        }
    }
}
