import Combine
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: appearanceKey) }
    }

    private let defaults: UserDefaults
    private let appearanceKey = "app-appearance"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: appearanceKey) ?? ""
        ) ?? .system
    }
}

enum AppTheme {
    static func railBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : Color(white: 0.97)
    }

    static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static func detailBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.075, blue: 0.085)
            : Color(red: 0.965, green: 0.965, blue: 0.975)
    }
}
