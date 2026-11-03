import Foundation
import Security
import Testing
@testable import Yomi

@Suite(.serialized)
struct MuseUsageTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("muse-\(UUID().uuidString)")

    // 测试跑在 Yomi.app 里，授权记录会写进真实偏好设置，结束后清掉。
    private func resetGrant() {
        for prefix in ["credential-keychain-granted.", "credential-keychain-denied-until."] {
            UserDefaults.standard.removeObject(forKey: prefix + MuseUsageFetcher.keychainService)
        }
    }

    @Test
    func manualRefreshReadsKeychainLoginSilentlyFirst() throws {
        resetGrant()
        defer { resetGrant() }
        var prompts: [Bool] = []
        let token = try BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
            try MuseUsageFetcher.accessToken(
                source: .account, configuredToken: nil, environment: [:], homeDirectory: home,
                readKeychain: { allowPrompt in
                    prompts.append(allowPrompt)
                    return (errSecSuccess, Data(#"{"access_token":"dca:abc"}"#.utf8))
                },
                keychainItemExists: { true }
            )
        }

        #expect(token == "dca:abc")
        #expect(prompts == [false])
    }

    @Test
    func backgroundRefreshWithoutGrantNeverTouchesTheSecret() {
        resetGrant()
        defer { resetGrant() }
        var prompts: [Bool] = []
        // 后台刷新且没有授权记录时，只查条目是否存在，不读密码也不弹窗。
        #expect(throws: MuseUsageError.keychainAccessNotGranted) {
            try MuseUsageFetcher.accessToken(
                source: .account, configuredToken: nil, environment: [:], homeDirectory: home,
                readKeychain: { allowPrompt in
                    prompts.append(allowPrompt)
                    return (errSecSuccess, Data(#"{"access_token":"dca:abc"}"#.utf8))
                },
                keychainItemExists: { true }
            )
        }
        #expect(prompts.isEmpty)
    }

    @Test
    func backgroundRefreshAfterGrantReadsSilentlyAndNeverPrompts() throws {
        resetGrant()
        defer { resetGrant() }
        _ = try BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
            try MuseUsageFetcher.accessToken(
                source: .account, configuredToken: nil, environment: [:], homeDirectory: home,
                readKeychain: { _ in (errSecSuccess, Data(#"{"access_token":"dca:abc"}"#.utf8)) },
                keychainItemExists: { true }
            )
        }
        var prompts: [Bool] = []
        #expect(throws: MuseUsageError.keychainAccessNotGranted) {
            try MuseUsageFetcher.accessToken(
                source: .account, configuredToken: nil, environment: [:], homeDirectory: home,
                readKeychain: { allowPrompt in
                    prompts.append(allowPrompt)
                    return (errSecInteractionNotAllowed, nil)
                },
                keychainItemExists: { true }
            )
        }
        #expect(prompts == [false])
    }

    @Test
    func missingKeychainItemReportsMissingLogin() {
        resetGrant()
        defer { resetGrant() }
        #expect(throws: MuseUsageError.missingCredentials) {
            try MuseUsageFetcher.accessToken(
                source: .account, configuredToken: nil, environment: [:], homeDirectory: home,
                readKeychain: { _ in (errSecItemNotFound, nil) },
                keychainItemExists: { false }
            )
        }
    }
}
