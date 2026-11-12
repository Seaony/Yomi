import Foundation
import Security

nonisolated struct LegacyMigrationCredential: Equatable, Sendable {
    let account: String
    let data: Data
}

nonisolated protocol LegacyMigrationKeychain {
    func accounts(service: String) throws -> [String]
    func data(service: String, account: String) throws -> Data
    func contains(service: String, account: String) throws -> Bool
    func addIfAbsent(_ credential: LegacyMigrationCredential, service: String) throws -> Bool
}

nonisolated enum LegacyMigration {
    static let legacyBundleIdentifier = "com.seaony.Yomi"
    static let bundleIdentifier = "com.seaony.CodeEdge"
    static let legacyKeychainService = "com.seaony.Yomi.providers"
    static let keychainService = "com.seaony.CodeEdge.providers"
    static let completionKey = "legacy-migration.completed.v1"

    enum Failure: Equatable, Sendable {
        case preferences
        case keychain(OSStatus)
        case applicationSupport
    }

    struct Report: Equatable, Sendable {
        var preferences = 0
        var credentials = 0
        var movedApplicationSupport = false
        var completed = false
        var alreadyComplete = false
        var failure: Failure?
        var keychainOperation: KeychainOperation?

        var logLine: String {
            let result = completed ? "completed" : "incomplete"
            let detail: String
            switch failure {
            case .preferences: detail = " stage: preferences"
            case let .keychain(status):
                detail = " stage: keychain operation: \(keychainOperation?.rawValue ?? "unknown") status: \(status)"
            case .applicationSupport: detail = " stage: application-support"
            case nil: detail = ""
            }
            return "Legacy migration \(result) preferences: \(preferences) keychain: \(credentials)\(detail)"
        }
    }

    static func shouldRun(environment: [String: String], bundleIdentifier: String?) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
            && environment["SWIFT_TESTING_ENABLED"] == nil
            && bundleIdentifier == Self.bundleIdentifier
    }

    // 必须在应用和代理实例创建前调用；测试宿主连真实偏好与钥匙串都不初始化。
    static func runOnce() {
        guard shouldRun(environment: ProcessInfo.processInfo.environment,
                        bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        let defaults = UserDefaults.standard
        let report = migrate(
            defaults: defaults,
            destinationDomain: bundleIdentifier,
            legacyValues: defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:],
            keychain: SystemKeychain(),
            applicationSupportRoot: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        )
        if !report.alreadyComplete {
            DiagnosticLog.shared.write(report.logLine, category: .migration)
        }
    }

    static func migrate(
        defaults: UserDefaults,
        destinationDomain: String,
        legacyValues: [String: Any],
        keychain: any LegacyMigrationKeychain,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report()
        let existing = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        if existing[completionKey] as? Bool == true {
            report.completed = true
            report.alreadyComplete = true
            return report
        }

        // 只看新域真正保存的键，注册默认值和全局域不能挡住旧设置。
        for (key, value) in legacyValues where acceptsPreferenceKey(key) && existing[key] == nil {
            defaults.set(value, forKey: key)
            report.preferences += 1
        }
        guard defaults.synchronize() else {
            report.failure = .preferences
            return report
        }

        do {
            for account in try keychain.accounts(service: legacyKeychainService) {
                guard try !keychain.contains(service: keychainService, account: account) else { continue }
                let credential = LegacyMigrationCredential(account: account,
                    data: try keychain.data(service: legacyKeychainService, account: account))
                if try keychain.addIfAbsent(credential, service: keychainService) { report.credentials += 1 }
            }
        } catch {
            report.failure = .keychain((error as? KeychainError)?.status ?? errSecInternalError)
            report.keychainOperation = (error as? KeychainError)?.operation
            return report
        }

        let legacyDirectory = applicationSupportRoot.appending(path: "Yomi", directoryHint: .isDirectory)
        let destinationDirectory = applicationSupportRoot.appending(path: "CodeEdge", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: legacyDirectory.path),
           !fileManager.fileExists(atPath: destinationDirectory.path) {
            do {
                try fileManager.moveItem(at: legacyDirectory, to: destinationDirectory)
                report.movedApplicationSupport = true
            } catch {
                report.failure = .applicationSupport
                return report
            }
        }

        defaults.set(true, forKey: completionKey)
        guard defaults.synchronize() else {
            defaults.removeObject(forKey: completionKey)
            _ = defaults.synchronize()
            report.failure = .preferences
            return report
        }
        report.completed = true
        return report
    }

    static func acceptsPreferenceKey(_ key: String) -> Bool {
        guard !key.hasPrefix("NS"), !key.hasPrefix("Apple") else { return false }
        return preferenceKeys.contains(key) || preferencePrefixes.contains { key.hasPrefix($0) }
    }

    private static let preferenceKeys: Set<String> = [
        "app-appearance", "app-language", "rail-background-color", "panel-side", "panel-vertical-position",
        "providers.v1", "show-provider-names", "refresh-interval", "collapse-in-fullscreen", "show-service-incidents",
        "usage-cache.v1", "usage-cache.v2", "usage-cache.v3", "provider-backoff.v1",
        "claude-weekly-amount-estimator.v1", "deepseek-balance-peaks.v1", "browser-cookie-keychain-denied-until",
        "quota-alerts.low-quota-enabled", "quota-alerts.depleted-enabled", "quota-alerts.reset-enabled",
        "quota-alerts.thresholds", "quota-alerts.muted-provider-ids", "quota-alerts.states.v1",
        "quota-alerts.authorization-requested", "quota-alerts.authorization-granted",
        "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo", "SUHasLaunchedBefore",
        "SULastCheckTime", "SUUpdateGroupIdentifier", "SULastProfileSubmissionDate", "SUSkippedVersion",
        "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion", "SUScheduledCheckInterval",
        "SUScheduledImpatientCheckInterval",
    ]
    private static let preferencePrefixes = [
        "usage-revision.", "credential-keychain-granted.", "credential-keychain-denied-until.", "yomi-",
    ]

    enum KeychainOperation: String, Sendable {
        case list, read, contains, add, unknown
    }

    struct KeychainError: Error {
        let status: OSStatus
        var operation: KeychainOperation = .unknown
    }

    struct SystemKeychain: LegacyMigrationKeychain {
        private let copyMatching: ([String: Any]) -> (OSStatus, Any?)
        private let addItem: ([String: Any]) -> OSStatus

        init(
            copyMatching: @escaping ([String: Any]) -> (OSStatus, Any?) = { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            },
            addItem: @escaping ([String: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) }
        ) {
            self.copyMatching = copyMatching
            self.addItem = addItem
        }

        func accounts(service: String) throws -> [String] {
            var query = Self.baseQuery(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            let (status, result) = copyMatching(query)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess else { throw KeychainError(status: status, operation: .list) }
            guard let rows = result as? [[String: Any]] else { throw KeychainError(status: errSecDecode, operation: .list) }
            return try rows.map { row in
                guard let account = row[kSecAttrAccount as String] as? String else {
                    throw KeychainError(status: errSecDecode, operation: .list)
                }
                return account
            }
        }

        func data(service: String, account: String) throws -> Data {
            // macOS 旧钥匙串不允许批量取密码，必须按账户逐条静默读取。
            var query = Self.baseQuery(service: service, account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            let (status, result) = copyMatching(query)
            guard status == errSecSuccess else { throw KeychainError(status: status, operation: .read) }
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode, operation: .read) }
            return data
        }

        func contains(service: String, account: String) throws -> Bool {
            var query = Self.baseQuery(service: service, account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnAttributes as String] = true
            let (status, _) = copyMatching(query)
            if status == errSecItemNotFound { return false }
            guard status == errSecSuccess else { throw KeychainError(status: status, operation: .contains) }
            return true
        }

        func addIfAbsent(_ credential: LegacyMigrationCredential, service: String) throws -> Bool {
            var query = Self.baseQuery(service: service, account: credential.account)
            query[kSecValueData as String] = credential.data
            let status = addItem(query)
            if status == errSecDuplicateItem { return false }
            guard status == errSecSuccess else { throw KeychainError(status: status, operation: .add) }
            return true
        }

        static func baseQuery(service: String, account: String? = nil) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            BrowserCookieAccess.applyNoUI(to: &query)
            return query
        }
    }
}
