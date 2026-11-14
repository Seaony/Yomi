import AppKit
import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEEDGE_TELEMETRY_PREVIEWS"] != nil))
struct TelemetrySettingsPreviewTests {
    @Test
    func renderGeneralSettings() async throws {
        let output = URL(fileURLWithPath: "/tmp/codeedge-ui-preview/telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let preferences = AppPreferences.shared
        let language = preferences.language
        let appearance = preferences.appearance
        defer {
            preferences.language = language
            preferences.appearance = appearance
        }
        preferences.language = .simplifiedChinese
        preferences.appearance = .system
        let defaults = try #require(TestUserDefaults(suiteName: "UsageParserTests.\(UUID().uuidString)"))
        for dark in [false, true] {
            let view = GeneralSettingsView()
                .frame(width: 560)
                .buttonStyle(CodeEdgeFlatButtonStyle())
                .toggleStyle(CodeEdgeFormSwitchStyle())
                .controlSize(.small)
                .tint(CodeEdgeSettingsTheme.accent)
                .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
                .defaultAppStorage(defaults)
                .environment(\.appLanguage, .simplifiedChinese)
                .environment(\.locale, AppLanguage.simplifiedChinese.locale)
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 640),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: "general-zh-\(dark ? "dark" : "light").png"))
        }
    }
}
