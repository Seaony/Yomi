import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodeEdge

struct LegacyMigrationTests {
    @Test
    func copiesOwnedPreferencesWithoutOverwritingNewValuesOrRegistrationDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.values = ["app-appearance": "dark", "show-provider-names": false]
        fixture.defaults.register(defaults: ["app-language": "en", "collapse-in-fullscreen": false])
        let legacy: [String: Any] = [
            "app-appearance": "light", "app-language": "zh-Hans", "show-provider-names": true,
            "collapse-in-fullscreen": true, "panel-side": "left", "panel-vertical-position": 0.37,
            "providers.v1": Data([0, 1, 2]), "refresh-interval": 123.0,
            "NSWindow Frame Test": "system-window", "AppleLanguages": ["ja"], "unrelated-project": "foreign",
        ]
        let report = fixture.migrate(legacy)

        #expect(report.completed)
        #expect(report.preferences == 6)
        #expect(fixture.defaults.values["app-appearance"] as? String == "dark")
        #expect(fixture.defaults.values["show-provider-names"] as? Bool == false)
        #expect(fixture.defaults.values["app-language"] as? String == "zh-Hans")
        #expect(fixture.defaults.values["collapse-in-fullscreen"] as? Bool == true)
        #expect(fixture.defaults.values["panel-side"] as? String == "left")
        #expect(fixture.defaults.values["panel-vertical-position"] as? Double == 0.37)
        #expect(fixture.defaults.values["providers.v1"] as? Data == Data([0, 1, 2]))
        #expect(fixture.defaults.values["refresh-interval"] as? Double == 123.0)
        #expect(fixture.defaults.values["NSWindow Frame Test"] == nil)
        #expect(fixture.defaults.values["AppleLanguages"] == nil)
        #expect(fixture.defaults.values["unrelated-project"] == nil)
        #expect(legacy["app-language"] as? String == "zh-Hans")
        #expect(fixture.defaults.values[LegacyMigration.completionKey] as? Bool == true)
    }

    @Test(arguments: [
        "SUHasLaunchedBefore", "SULastCheckTime", "SUUpdateGroupIdentifier", "SUEnableAutomaticChecks",
        "SUAutomaticallyUpdate", "SUSendProfileInfo", "SUSkippedVersion", "SUSkippedMajorVersion",
        "usage-cache.v1", "usage-cache.v2", "usage-cache.v3", "provider-backoff.v1",
        "claude-weekly-amount-estimator.v1", "deepseek-balance-peaks.v1", "rail-background-color",
        "show-service-incidents", "quota-alerts.low-quota-enabled", "quota-alerts.depleted-enabled",
        "quota-alerts.reset-enabled", "quota-alerts.thresholds", "quota-alerts.muted-provider-ids",
        "quota-alerts.states.v1", "quota-alerts.authorization-requested", "quota-alerts.authorization-granted",
        "browser-cookie-keychain-denied-until", "usage-revision.claude", "credential-keychain-granted.cursor",
        "credential-keychain-denied-until.muse", "yomi-legacy-setting",
    ])
    func preservesKnownAppAndUpdatePreferenceKeys(key: String) {
        #expect(LegacyMigration.acceptsPreferenceKey(key))
    }

    @Test(arguments: ["NSWindow Frame App", "NSToolbar Configuration", "AppleLanguages", "AppleInterfaceStyle",
                      "SUFeedURL", "SUPublicEDKey", "SomeOtherAppSetting", LegacyMigration.completionKey])
    func excludesSystemForeignAndUpdateIdentityKeys(key: String) {
        #expect(!LegacyMigration.acceptsPreferenceKey(key))
    }

    @Test
    func copiesCredentialBytesAndAccountsWithoutReplacingExistingOrDeletingLegacyEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let old = [LegacyMigrationCredential(account: "claude", data: Data([0, 255, 7])),
                   LegacyMigrationCredential(account: "cursor.session", data: Data("old-session".utf8))]
        fixture.keychain.legacy = old
        fixture.keychain.current = ["cursor.session": Data("new-session".utf8)]

        let report = fixture.migrate([:])

        #expect(report.completed)
        #expect(report.credentials == 1)
        #expect(fixture.keychain.current["claude"] == Data([0, 255, 7]))
        #expect(fixture.keychain.current["cursor.session"] == Data("new-session".utf8))
        #expect(fixture.keychain.legacy == old)
        #expect(fixture.keychain.readServices == [LegacyMigration.legacyKeychainService])
        #expect(Set(fixture.keychain.writeServices) == [LegacyMigration.keychainService])
    }

    @Test
    func repeatedMigrationDoesNotReadOrModifyLegacySourcesAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.legacy = [.init(account: "claude", data: Data("one".utf8))]
        #expect(fixture.migrate(["app-language": "en"]).completed)
        fixture.keychain.failRead = true
        fixture.defaults.values["app-language"] = "zh-Hans"

        let report = fixture.migrate(["app-language": "en", "refresh-interval": 77])

        #expect(report.completed && report.alreadyComplete)
        #expect(report.preferences == 0 && report.credentials == 0)
        #expect(fixture.keychain.readServices.count == 1)
        #expect(fixture.defaults.values["app-language"] as? String == "zh-Hans")
        #expect(fixture.defaults.values["refresh-interval"] == nil)
    }

    @Test
    func completesPreferencesBeforeCredentialReadsAndStartupObservers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var sawMigratedSettings = false
        fixture.keychain.beforeRead = {
            sawMigratedSettings = fixture.defaults.values["panel-side"] as? String == "left"
                && fixture.defaults.synchronizationCalls == 1
                && fixture.defaults.values[LegacyMigration.completionKey] == nil
        }

        let report = fixture.migrate(["panel-side": "left", "app-language": "en"])

        #expect(sawMigratedSettings)
        #expect(report.completed)
        #expect(fixture.defaults.values["panel-side"] as? String == "left")
        #expect(fixture.defaults.values["app-language"] as? String == "en")
    }

    @Test
    func credentialReadFailureLeavesMarkerUnsetAndRetries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.failRead = true
        let first = fixture.migrate(["app-language": "en"])
        #expect(first.failure == .keychain(errSecAuthFailed))
        #expect(!first.completed)
        #expect(fixture.defaults.values[LegacyMigration.completionKey] == nil)

        fixture.keychain.failRead = false
        fixture.keychain.legacy = [.init(account: "claude", data: Data("secret".utf8))]
        let second = fixture.migrate(["app-language": "zh-Hans"])
        #expect(second.completed)
        #expect(second.preferences == 0 && second.credentials == 1)
        #expect(fixture.defaults.values["app-language"] as? String == "en")
    }

    @Test
    func partialCredentialFailurePreservesCopiesAndDoesNotOverwriteThemOnRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.legacy = [.init(account: "a", data: Data([1])), .init(account: "b", data: Data([2]))]
        fixture.keychain.failAddAt = 2
        let first = fixture.migrate([:])
        #expect(first.credentials == 1)
        #expect(!first.completed)
        #expect(fixture.defaults.values[LegacyMigration.completionKey] == nil)
        #expect(fixture.keychain.current["a"] == Data([1]))

        fixture.keychain.failAddAt = nil
        fixture.keychain.current["a"] = Data([9])
        let second = fixture.migrate([:])
        #expect(second.completed && second.credentials == 1)
        #expect(fixture.keychain.current == ["a": Data([9]), "b": Data([2])])
        #expect(fixture.keychain.legacy.count == 2)
    }

    @Test
    func concurrentNewCredentialWinsTheAddRace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.legacy = [.init(account: "a", data: Data([1]))]
        fixture.keychain.racingValue = Data([9])
        let report = fixture.migrate([:])
        #expect(report.completed && report.credentials == 0)
        #expect(fixture.keychain.current["a"] == Data([9]))
    }

    @Test
    func movesApplicationSupportOnlyWhenTheNewDirectoryIsAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createLegacySupport()
        let report = fixture.migrate([:])
        #expect(report.completed && report.movedApplicationSupport)
        #expect(!FileManager.default.fileExists(atPath: fixture.oldSupport.path))
        #expect(try Data(contentsOf: fixture.newSupport.appending(path: "cache.bin")) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Logs").path))
    }

    @Test
    func existingApplicationSupportKeepsBothDirectoriesIntact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createLegacySupport()
        try FileManager.default.createDirectory(at: fixture.newSupport, withIntermediateDirectories: true)
        try Data([9]).write(to: fixture.newSupport.appending(path: "cache.bin"))
        let report = fixture.migrate([:])
        #expect(report.completed && !report.movedApplicationSupport)
        #expect(try Data(contentsOf: fixture.oldSupport.appending(path: "cache.bin")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: fixture.newSupport.appending(path: "cache.bin")) == Data([9]))
    }

    @Test
    func failedDirectoryMoveIsReportedWithoutMarkingCompletionAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createLegacySupport()
        let first = fixture.migrate([:], fileManager: RefusingFileManager())
        #expect(first.failure == .applicationSupport)
        #expect(!first.completed)
        #expect(fixture.defaults.values[LegacyMigration.completionKey] == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.oldSupport.path))
        #expect(fixture.migrate([:]).completed)
        #expect(FileManager.default.fileExists(atPath: fixture.newSupport.path))
    }

    @Test(arguments: [1, 2])
    func failedPreferencesSynchronizationDoesNotLeaveACompletionMarker(call: Int) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.failedSynchronizationCalls = [call]
        let first = fixture.migrate(["app-language": "en"])
        #expect(first.failure == .preferences)
        #expect(!first.completed)
        #expect(fixture.defaults.values[LegacyMigration.completionKey] == nil)
        if call == 1 { #expect(fixture.keychain.readServices.isEmpty) }
        fixture.defaults.failedSynchronizationCalls = []
        #expect(fixture.migrate([:]).completed)
    }

    @Test
    func logsOnlyCountsAndFixedFailureStatus() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.legacy = [.init(account: "private-account", data: Data("private-secret".utf8))]
        let report = fixture.migrate(["app-language": "private-preference"])
        #expect(report.logLine == "Legacy migration completed preferences: 1 keychain: 1")
        #expect(!report.logLine.contains("private"))
        #expect(DiagnosticsRedactor.redact(report.logLine) == report.logLine)
    }

    @Test
    func productionEntryRejectsTestHostsAndOtherBundlesBeforeAnyMigration() {
        #expect(LegacyMigration.shouldRun(environment: [:], bundleIdentifier: LegacyMigration.bundleIdentifier))
        #expect(!LegacyMigration.shouldRun(environment: ["XCTestConfigurationFilePath": "fixture"], bundleIdentifier: LegacyMigration.bundleIdentifier))
        #expect(!LegacyMigration.shouldRun(environment: ["SWIFT_TESTING_ENABLED": "1"], bundleIdentifier: LegacyMigration.bundleIdentifier))
        #expect(!LegacyMigration.shouldRun(environment: [:], bundleIdentifier: "temporary.test.bundle"))
        #expect(!LegacyMigration.shouldRun(environment: [:], bundleIdentifier: nil))
    }

    @Test
    func realKeychainQueriesKeepBothNoUIFlagsWithoutExecutingThem() throws {
        let query = LegacyMigration.SystemKeychain.baseQuery(service: "test-service", account: "test-account")
        #expect(query[kSecAttrService as String] as? String == "test-service")
        #expect(query[kSecAttrAccount as String] as? String == "test-account")
        #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
        #expect(try #require(query[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
    }
}

private struct Fixture {
    let defaults = MigrationDefaults(suiteName: "CodeEdgeMigrationTests.\(UUID().uuidString)")!
    let keychain = FakeKeychain()
    let root = FileManager.default.temporaryDirectory.appending(path: "CodeEdgeMigration-\(UUID().uuidString)")
    var oldSupport: URL { root.appending(path: "Yomi", directoryHint: .isDirectory) }
    var newSupport: URL { root.appending(path: "CodeEdge", directoryHint: .isDirectory) }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func createLegacySupport() throws {
        try FileManager.default.createDirectory(at: oldSupport, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: oldSupport.appending(path: "cache.bin"))
    }
    func migrate(_ values: [String: Any], fileManager: FileManager = .default) -> LegacyMigration.Report {
        LegacyMigration.migrate(defaults: defaults, destinationDomain: defaults.domain,
            legacyValues: values, keychain: keychain, applicationSupportRoot: root, fileManager: fileManager)
    }
}

nonisolated private final class MigrationDefaults: UserDefaults, @unchecked Sendable {
    let domain: String
    var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    var synchronizationCalls = 0
    var failedSynchronizationCalls: Set<Int> = []

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        domain = suiteName
        super.init(suiteName: suiteName)
    }
    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        domainName == domain ? values : nil
    }
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults registrationDictionary: [String: Any]) { registered = registrationDictionary }
    override func synchronize() -> Bool {
        synchronizationCalls += 1
        return !failedSynchronizationCalls.contains(synchronizationCalls)
    }
}

nonisolated private final class FakeKeychain: LegacyMigrationKeychain {
    var legacy: [LegacyMigrationCredential] = []
    var current: [String: Data] = [:]
    var readServices: [String] = []
    var writeServices: [String] = []
    var failRead = false
    var failAddAt: Int?
    var racingValue: Data?
    var beforeRead: (() -> Void)?
    private var addCalls = 0

    func entries(service: String) throws -> [LegacyMigrationCredential] {
        readServices.append(service)
        beforeRead?()
        if failRead { throw LegacyMigration.KeychainError(status: errSecAuthFailed) }
        return legacy
    }
    func contains(service: String, account: String) throws -> Bool { current[account] != nil }
    func addIfAbsent(_ credential: LegacyMigrationCredential, service: String) throws -> Bool {
        addCalls += 1
        if failAddAt == addCalls { throw LegacyMigration.KeychainError(status: errSecInteractionNotAllowed) }
        if let racingValue { current[credential.account] = racingValue }
        guard current[credential.account] == nil else { return false }
        current[credential.account] = credential.data
        writeServices.append(service)
        return true
    }
}

nonisolated private final class RefusingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
