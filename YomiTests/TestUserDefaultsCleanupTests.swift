import Foundation
import Testing

struct TestUserDefaultsCleanupTests {
    @Test(arguments: [
        "com.seaony.Yomi", "com.seaony.Yomi.12345678-1234-1234-1234-123456789ABC",
        "yomi-product-shots-", "yomi-product-shots-not-a-uuid",
        "yomi-product-shots-12345678-1234-1234-1234-123456789ABC.plist",
        "yomi-product-shots-12345678-1234-1234-1234-123456789ABC/../other",
        "/tmp/YomiStatusMonitorTests-12345678-1234-1234-1234-123456789ABC",
        "unknown-test-12345678-1234-1234-1234-123456789ABC",
    ])
    func rejectsEveryNameOutsideTheExactTestDomains(suiteName: String) {
        #expect(!TestUserDefaultsCleanup.accepts(suiteName))
        #expect(TestUserDefaults(suiteName: suiteName) == nil)
        #expect(throws: TestUserDefaultsCleanup.Failure.invalidSuiteName) {
            try TestUserDefaultsCleanup.fileURL(for: suiteName)
        }
    }

    @Test(arguments: [
        "yomi-product-shots-", "yomi-claude-plan-", "UsageParserTests.", "usage-pace-cache-",
        "backoff-store-", "adaptive-store-", "backoff-integration-", "quota-notifications-test-",
        "YomiStatusMonitorTests-", "YomiStatusObservation-", "YomiTestDefaultsCleanupTests-",
    ])
    func acceptsOnlyACompleteUUIDAfterAKnownPrefix(prefix: String) throws {
        let uuid = UUID().uuidString
        let suite = prefix + uuid
        #expect(TestUserDefaultsCleanup.accepts(suite))
        #expect(TestUserDefaultsCleanup.accepts(prefix + uuid.lowercased()))
        #expect(try TestUserDefaultsCleanup.fileURL(for: suite).lastPathComponent == suite + ".plist")
    }

    @Test
    func valuesAndCleanupNeverCreatePreferenceFiles() throws {
        let suite = "YomiTestDefaultsCleanupTests-\(UUID().uuidString)"
        let otherSuite = "YomiTestDefaultsCleanupTests-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        let otherDefaults = try #require(TestUserDefaults(suiteName: otherSuite))
        let file = try TestUserDefaultsCleanup.fileURL(for: suite)
        let otherFile = try TestUserDefaultsCleanup.fileURL(for: otherSuite)
        defer {
            TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite)
            TestUserDefaultsCleanup.cleanup(otherDefaults, suiteName: otherSuite)
        }
        defaults.set(true, forKey: "fixture")
        otherDefaults.set(true, forKey: "fixture")
        #expect(defaults.synchronize())
        #expect(otherDefaults.synchronize())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: otherFile.path))
        try TestUserDefaultsCleanup.remove(defaults, suiteName: suite)
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty == true)
        #expect(otherDefaults.bool(forKey: "fixture"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func typedValuesDefaultsAndChangeNotificationsStayAvailable() throws {
        let suite = "YomiTestDefaultsCleanupTests-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let changes = ChangeCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in changes.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        defaults.register(defaults: ["registered": 7])
        defaults.set(true, forKey: "bool")
        defaults.set(17, forKey: "integer")
        defaults.set(1.25, forKey: "double")
        defaults.set(Float(2.5), forKey: "float")
        defaults.set("yes", forKey: "string")
        defaults.set([20, 10], forKey: "array")
        defaults.set(["claude", "codex"], forKey: "strings")
        defaults.set(["fixture": 1], forKey: "dictionary")
        defaults.set(Data([1, 2]), forKey: "data")
        let url = try #require(URL(string: "https://fixture.invalid"))
        defaults.set(url, forKey: "url")
        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "integer") == 17)
        #expect(defaults.double(forKey: "double") == 1.25)
        #expect(defaults.float(forKey: "float") == 2.5)
        #expect(defaults.string(forKey: "string") == "yes")
        #expect(defaults.array(forKey: "array") as? [Int] == [20, 10])
        #expect(defaults.stringArray(forKey: "strings") == ["claude", "codex"])
        #expect(defaults.dictionary(forKey: "dictionary") as? [String: Int] == ["fixture": 1])
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.url(forKey: "url") == url)
        #expect(defaults.integer(forKey: "registered") == 7)
        #expect(defaults.integer(forKey: "missing") == 0)
        #expect(defaults.bool(forKey: "missing") == false)
        defaults.set("42", forKey: "converted")
        #expect(defaults.integer(forKey: "converted") == 42)
        defaults.removeObject(forKey: "string")
        #expect(defaults.object(forKey: "string") == nil)
        #expect(changes.value == 12)
        try TestUserDefaultsCleanup.remove(defaults, suiteName: suite)
        #expect(changes.value == 13)
        #expect(defaults.data(forKey: "data") == nil)
        #expect(defaults.integer(forKey: "registered") == 7)
    }
}

private nonisolated final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
