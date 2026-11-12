import Foundation
import Testing

nonisolated enum TestUserDefaultsCleanup {
    enum Failure: Error, Equatable {
        case invalidSuiteName
        case synchronizationFailed
    }

    private static let prefixes = [
        "yomi-product-shots-", "yomi-claude-plan-", "UsageParserTests.", "usage-pace-cache-",
        "backoff-store-", "adaptive-store-", "backoff-integration-", "quota-notifications-test-",
        "YomiStatusMonitorTests-", "YomiStatusObservation-", "YomiTestDefaultsCleanupTests-",
    ]

    static func accepts(_ suiteName: String) -> Bool {
        prefixes.contains { prefix in
            guard suiteName.hasPrefix(prefix) else { return false }
            let suffix = String(suiteName.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: suffix) else { return false }
            return uuid.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
        }
    }

    static func fileURL(for suiteName: String) throws -> URL {
        guard accepts(suiteName) else { throw Failure.invalidSuiteName }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences", directoryHint: .isDirectory)
            .appendingPathComponent(suiteName + ".plist")
    }

    static func remove(_ defaults: UserDefaults, suiteName: String) throws {
        // 校验完整域名后再清理，任何正式域或带路径的名字都不能进入这里。
        let file = try fileURL(for: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        guard defaults.synchronize() else { throw Failure.synchronizationFailed }
        // 清域只会移除键值，macOS 仍可能留下空 plist；这里只删自己刚创建的精确文件。
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func cleanup(_ defaults: UserDefaults, suiteName: String) {
        do {
            try remove(defaults, suiteName: suiteName)
        } catch {
            Issue.record("测试偏好清理失败：\(error)")
        }
    }
}
