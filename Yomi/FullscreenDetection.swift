import AppKit
import CoreGraphics
import Foundation

nonisolated enum FullscreenDetection {
    enum ActivationPolicy: Equatable, Sendable {
        case regular
        case accessory
        case prohibited
        case unknown
    }

    struct Window: Sendable {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        let activationPolicy: ActivationPolicy

        init(pid: pid_t, layer: Int, bounds: CGRect, activationPolicy: ActivationPolicy = .regular) {
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
            self.activationPolicy = activationPolicy
        }
    }

    static func hasFullscreenWindow(
        screenBounds: CGRect,
        windows: [Window],
        desktopWindows: [Window] = [],
        excludingPIDs: Set<pid_t> = [],
        safeAreaTopInset: CGFloat = 0
    ) -> Bool {
        guard screenBounds.width > 0, screenBounds.height > 0 else { return false }
        let hasRegularCandidate = windows.contains { window in
            guard window.pid > 0, window.layer == 0, window.activationPolicy == .regular,
                  !excludingPIDs.contains(window.pid) else { return false }
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
        guard hasRegularCandidate else { return false }

        let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let visibleDesktops = desktopWindows.filter { $0.layer == desktopIconLayer }
        // 所有屏幕都没有桌面图标层时，保留只按普通应用窗口几何判断的降级。
        return !visibleDesktops.contains { desktop in
            desktop.bounds.insetBy(dx: -4, dy: -4).contains(screenBounds)
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

    @MainActor
    static func onScreenWindows() -> [Window] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var policies: [pid_t: ActivationPolicy] = [:]
        // 只保留检测需要的字段，不读取窗口标题。
        return entries.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let policy: ActivationPolicy
            if let cached = policies[pid] {
                policy = cached
            } else {
                switch NSRunningApplication(processIdentifier: pid)?.activationPolicy {
                case .regular?: policy = .regular
                case .accessory?: policy = .accessory
                case .prohibited?: policy = .prohibited
                case nil: policy = .unknown
                @unknown default: policy = .unknown
                }
                policies[pid] = policy
            }
            return Window(pid: pid, layer: layer, bounds: rectangle, activationPolicy: policy)
        }
    }

    static func onScreenDesktopWindows() -> [Window] {
        guard let entries = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        return entries.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == desktopIconLayer,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return Window(pid: pid, layer: layer, bounds: rectangle, activationPolicy: .unknown)
        }
    }
}
