import Darwin
import Foundation
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
