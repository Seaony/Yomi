import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
private final class UpdateWindowLevelCoordinator: NSObject, SPUStandardUserDriverDelegate {
    private weak var obscuringWindow: NSWindow?
    private var originalLevel: NSWindow.Level?

    func standardUserDriverWillShowModalAlert() {
        guard let window = NSApp.keyWindow,
              window.level > .modalPanel
        else {
            return
        }

        obscuringWindow = window
        originalLevel = window.level
        window.level = .normal
    }

    func standardUserDriverDidShowModalAlert() {
        if let obscuringWindow, let originalLevel {
            obscuringWindow.level = originalLevel
        }
        obscuringWindow = nil
        originalLevel = nil
    }
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let configurationError: String?

    private let userDriverDelegate = UpdateWindowLevelCoordinator()
    private let updaterController: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        guard let feed, URL(string: feed) != nil else {
            configurationError = "The update feed is not configured for this build."
            updaterController = nil
            return
        }
        guard let publicKey,
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32
        else {
            configurationError = "The Sparkle public key is not configured for this build."
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
        let updater = controller.updater
        configurationError = nil
        updaterController = controller
        canCheckForUpdates = updater.canCheckForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
