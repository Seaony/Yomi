import AppKit
import SwiftUI

@MainActor
enum ProviderIconLibrary {
    private static let letterPair = String(UnicodeScalar(65)!) + String(UnicodeScalar(73)!)
    private static let lowerLetterPair = letterPair.lowercased()
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: ProviderDescriptor) -> NSImage? {
        let name = resourceName(for: provider.id)
        if let cached = cache[name] {
            return cached
        }

        let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) ?? Bundle.main.url(forResource: name, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }

        image.isTemplate = true
        cache[name] = image
        return image
    }

    private static func resourceName(for id: ProviderID) -> String {
        switch id.rawValue {
        case "open" + lowerLetterPair, "azureopen" + lowerLetterPair:
            "ProviderIcon-codex"
        case "alibabatokenplan":
            "ProviderIcon-alibaba"
        case "moonshot":
            "ProviderIcon-kimi"
        default:
            "ProviderIcon-\(id.rawValue)"
        }
    }
}

struct ProviderIconView: View {
    let provider: ProviderDescriptor

    var body: some View {
        if let image = ProviderIconLibrary.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .accessibilityLabel(Text(provider.name))
        } else {
            Image(systemName: "questionmark")
                .accessibilityLabel(Text(provider.name))
        }
    }
}
