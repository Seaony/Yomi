import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
struct AppPreferencesTests {
    @Test(arguments: [false, true])
    func defaultHexClearsCustomBackground(dark: Bool) throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let scheme: ColorScheme = dark ? .dark : .light
        let key = "rail-background-color.\(dark ? "dark" : "light")"
        preferences.setRailBackgroundColor(hex: "#123456", for: scheme)
        let expected = AppTheme.railBackgroundHex(for: scheme)

        let result = preferences.setRailBackgroundColor(
            hex: " \(expected.dropFirst().lowercased()) ", for: scheme
        )

        #expect(result == expected)
        #expect(preferences.railBackgroundColorHex[scheme] == nil)
        #expect(preferences.railBackgroundColor(for: scheme) == nil)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test(arguments: [false, true])
    func customHexPersistsAndRestores(dark: Bool) throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let scheme: ColorScheme = dark ? .dark : .light
        let key = "rail-background-color.\(dark ? "dark" : "light")"

        #expect(preferences.setRailBackgroundColor(hex: " 1a2b3c ", for: scheme) == "#1A2B3C")
        #expect(preferences.railBackgroundColorHex[scheme] == "#1A2B3C")
        #expect(defaults.string(forKey: key) == "#1A2B3C")
        #expect(AppPreferences(defaults: defaults).railBackgroundColorHex[scheme] == "#1A2B3C")
    }

    @Test(arguments: [false, true])
    func startupRemovesStoredDefaultHex(dark: Bool) throws {
        let defaults = try makeDefaults()
        let scheme: ColorScheme = dark ? .dark : .light
        let key = "rail-background-color.\(dark ? "dark" : "light")"
        let original = AppTheme.railBackgroundHex(for: scheme)
        defaults.set(" \(original.dropFirst().lowercased()) ", forKey: key)

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.railBackgroundColorHex[scheme] == nil)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test(arguments: [false, true])
    func colorPickerReturningToDefaultClearsCustomBackground(dark: Bool) throws {
        let defaults = try makeDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let scheme: ColorScheme = dark ? .dark : .light
        let key = "rail-background-color.\(dark ? "dark" : "light")"
        preferences.setRailBackgroundColor(hex: "#123456", for: scheme)

        preferences.setRailBackgroundColor(AppTheme.railBackground(for: scheme), for: scheme)

        #expect(preferences.railBackgroundColorHex[scheme] == nil)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func legacySingleColorIsOnlyClearedForMatchingAppearance() throws {
        let defaults = try makeDefaults()
        let legacy = AppTheme.railBackgroundHex(for: .light)
        defaults.set(legacy, forKey: "rail-background-color")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.railBackgroundColorHex[.light] == nil)
        #expect(defaults.object(forKey: "rail-background-color.light") == nil)
        #expect(preferences.railBackgroundColorHex[.dark] == legacy)
        #expect(defaults.string(forKey: "rail-background-color.dark") == legacy)
        #expect(defaults.object(forKey: "rail-background-color") == nil)
    }

    private func makeDefaults() throws -> TestUserDefaults {
        try #require(TestUserDefaults(suiteName: "UsageParserTests.\(UUID().uuidString)"))
    }
}
