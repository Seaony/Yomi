import Foundation
import LocalAuthentication
import Security

nonisolated enum KeychainAccess {
    @TaskLocal static var allowsInteraction = true
    private static let lock = NSLock()

    static func applyInteractionPolicy(to query: inout [String: Any]) {
        guard !allowsInteraction else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // Legacy macOS keychains also need an explicit UI-fail policy.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    static func perform(_ operation: () -> OSStatus) -> OSStatus {
        // The legacy interaction switch is process-wide, so calls must not overlap.
        lock.lock()
        defer { lock.unlock() }
        guard !allowsInteraction else { return operation() }

        var wasAllowed = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard readStatus == errSecSuccess else { return readStatus }
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { return status }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return operation()
    }
}
