import Darwin
import Foundation
import LocalAuthentication
import Security
import SweetCookieKit

nonisolated enum BrowserCookieAccess {
    nonisolated final class Scope: @unchecked Sendable {
        private nonisolated final class Allowance: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false

            func claim() -> Bool {
                lock.withLock {
                    guard !claimed else { return false }
                    claimed = true
                    return true
                }
            }
        }

        let allowInteraction: Bool
        private let allowance: Allowance
        private let lock = NSLock()
        private var failure: (priority: Int, message: String)?

        init(allowInteraction: Bool, sharingAllowanceFrom parent: Scope? = nil) {
            self.allowInteraction = allowInteraction && (parent?.allowInteraction ?? true)
            allowance = parent?.allowance ?? Allowance()
        }

        var failureMessage: String? {
            lock.withLock { failure?.message }
        }

        fileprivate func claimInteraction() -> Bool {
            allowInteraction && allowance.claim()
        }

        fileprivate func record(_ message: String, priority: Int) {
            lock.withLock {
                guard priority >= (failure?.priority ?? -1) else { return }
                failure = (priority, message)
            }
        }
    }

    @TaskLocal static var scope: Scope?
    private static let denialLock = NSLock()
    private static let denialKey = "browser-cookie-keychain-denied-until"

    static func records(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        client: BrowserCookieClient = BrowserCookieClient()
    ) throws -> [BrowserCookieStoreRecords] {
        do {
            return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                try client.records(matching: query, in: browser)
            }
        } catch {
            guard let cookieError = error as? BrowserCookieError,
                  case .accessDenied = cookieError,
                  browser.usesChromiumProfileStore,
                  !BrowserCookieKeychainAccessGate.isUserInteractionDisallowed,
                  !isCoolingDown,
                  scope?.claimInteraction() == true else {
                recordFailure(error, browser: browser, client: client)
                throw error
            }
            do {
                return try client.records(matching: query, in: browser)
            } catch {
                if let cookieError = error as? BrowserCookieError, case .accessDenied = cookieError {
                    denialLock.withLock {
                        UserDefaults.standard.set(Date().addingTimeInterval(6 * 60 * 60), forKey: denialKey)
                    }
                }
                recordFailure(error, browser: browser, client: client)
                throw error
            }
        }
    }

    // 读取其他应用的钥匙串条目：后台只在之前授权成功过时静默读取，
    // 需要授权时只在手动刷新时弹一次，拒绝后 6 小时内不再弹。
    static func readForeignKeychainItem(
        service: String,
        read: (_ allowPrompt: Bool) -> (OSStatus, Data?),
        exists: () -> Bool
    ) -> (OSStatus, Data?) {
        let manual = scope?.allowInteraction == true
        let granted = denialLock.withLock { UserDefaults.standard.bool(forKey: credentialGrantKey(service)) }
        // 旧式 ACL 的条目即使设置了不弹窗也可能弹，后台没授权记录时不碰密码，只查条目是否存在。
        if !manual, !granted {
            return (exists() ? errSecInteractionNotAllowed : errSecItemNotFound, nil)
        }
        var (status, data) = read(false)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            setCredentialGrant(false, service: service)
            guard claimCredentialPrompt(service: service) else { return (status, nil) }
            (status, data) = read(true)
            if [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem].contains(status) {
                denialLock.withLock {
                    UserDefaults.standard.set(Date().addingTimeInterval(6 * 60 * 60), forKey: credentialDenialKey(service))
                }
            }
        }
        if status == errSecSuccess { setCredentialGrant(true, service: service) }
        return (status, data)
    }

    // 不弹窗的钥匙串查询：同时设置 LAContext 和旧式钥匙串的 UI-fail 标志。
    static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    // 只查条目是否存在，不读取密码，不会触发授权弹窗。
    static func foreignKeychainItemExists(service: String, account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        applyNoUI(to: &query)
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    private static func claimCredentialPrompt(service: String) -> Bool {
        let coolingDown = denialLock.withLock {
            (UserDefaults.standard.object(forKey: credentialDenialKey(service)) as? Date).map { $0 > Date() } ?? false
        }
        return !coolingDown && scope?.claimInteraction() == true
    }

    private static func setCredentialGrant(_ granted: Bool, service: String) {
        denialLock.withLock { UserDefaults.standard.set(granted, forKey: credentialGrantKey(service)) }
    }

    private static func credentialDenialKey(_ service: String) -> String {
        "credential-keychain-denied-until.\(service)"
    }

    private static func credentialGrantKey(_ service: String) -> String {
        "credential-keychain-granted.\(service)"
    }

    private static var isCoolingDown: Bool {
        denialLock.withLock {
            (UserDefaults.standard.object(forKey: denialKey) as? Date).map { $0 > Date() } ?? false
        }
    }

    private static func recordFailure(_ error: Error, browser: Browser, client: BrowserCookieClient) {
        guard let error = error as? BrowserCookieError, scope != nil else { return }
        switch error {
        case .accessDenied where browser.usesChromiumProfileStore:
            scope?.record(AppLocalization.text(
                "无法读取 \(browser.displayName) 的钥匙串 Cookie。请在钥匙串访问中检查权限或解锁钥匙串，再手动刷新。",
                "Cannot read \(browser.displayName)'s Keychain cookies. Check access or unlock Keychain in Keychain Access, then refresh manually."
            ), priority: 2)
        case .accessDenied:
            recordProfileFailure(browser)
        case .notFound, .loadFailed:
            if profileAccessDenied(browser, client: client) { recordProfileFailure(browser) }
        }
    }

    private static func recordProfileFailure(_ browser: Browser) {
        scope?.record(AppLocalization.text(
            "无法读取 \(browser.displayName) 的浏览器资料。请在系统设置 → 隐私与安全性 → 文件与文件夹中检查 Yomi 的访问权限。",
            "Cannot read \(browser.displayName)'s profile. Check Yomi's access in System Settings → Privacy & Security → Files & Folders."
        ), priority: 1)
    }

    private static func profileAccessDenied(_ browser: Browser, client: BrowserCookieClient) -> Bool {
        for store in client.stores(for: browser) {
            if let file = store.databaseURL,
               FileManager.default.fileExists(atPath: file.path),
               !FileManager.default.isReadableFile(atPath: file.path) {
                return true
            }
        }
        let relative = browser.chromiumProfileRelativePath ?? browser.geckoProfilesFolder.map { "\($0)/Profiles" }
        guard let relative else { return false }
        for home in client.configuration.homeDirectories {
            let root = home.appendingPathComponent("Library/Application Support").appendingPathComponent(relative)
            do {
                _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue
                    || error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code)) {
                    return true
                }
            }
        }
        return false
    }
}
