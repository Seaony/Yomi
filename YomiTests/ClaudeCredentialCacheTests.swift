import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Yomi

struct ClaudeCredentialCacheTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private nonisolated final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [(OSStatus, Data?)]
        private var count = 0

        init(_ results: [(OSStatus, Data?)]) {
            self.results = results
        }

        var calls: Int { lock.withLock { count } }

        func read(_ query: [String: Any]) -> (OSStatus, Data?) {
            lock.withLock {
                count += 1
                let context = query[kSecUseAuthenticationContext as String] as? LAContext
                let policy = query[kSecUseAuthenticationUI as String] as? String
                if context?.interactionNotAllowed == true || policy == kSecUseAuthenticationUIFail as String {
                    return (errSecInteractionNotAllowed, nil)
                }
                return results.isEmpty ? (errSecItemNotFound, nil) : results.removeFirst()
            }
        }
    }

    @Test
    func backgroundReadCanRequestAuthorization() async throws {
        let data = try Self.credential(token: "authorized", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecSuccess, data)])
        let collector = UsageCollector()

        let result = await Task.detached {
            await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read)
        }.value

        #expect(result == data)
        #expect(reader.calls == 1)
    }

    @Test
    func repeatedRefreshesReuseUnexpiredCredentials() async throws {
        let data = try Self.credential(token: "first", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecSuccess, data)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == data)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(60), read: reader.read
        ) == data)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(120), read: reader.read
        ) == data)
        #expect(reader.calls == 1)
    }

    @Test
    func expirationReloadsCredentialsWithoutManualRefresh() async throws {
        let first = try Self.credential(token: "first", expiresAt: Self.now.addingTimeInterval(60))
        let renewed = try Self.credential(token: "renewed", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecSuccess, first), (errSecSuccess, renewed)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == first)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(60), read: reader.read
        ) == renewed)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(120), read: reader.read
        ) == renewed)
        #expect(reader.calls == 2)
    }

    @Test
    func rejectedTokenReloadsAndReusesNewCredentials() async throws {
        let first = try Self.credential(token: "rejected", expiresAt: Self.now.addingTimeInterval(3600))
        let renewed = try Self.credential(token: "renewed", expiresAt: Self.now.addingTimeInterval(7200))
        let reader = Reader([(errSecSuccess, first), (errSecSuccess, renewed)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == first)
        #expect(await collector.invalidateClaudeKeychainCredential(rejectedToken: "rejected"))
        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == renewed)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(60), read: reader.read
        ) == renewed)
        #expect(reader.calls == 2)
    }

    @Test
    func unrelatedRejectedTokenDoesNotEvictCachedCredentials() async throws {
        let data = try Self.credential(token: "local", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecSuccess, data)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == data)
        #expect(await collector.invalidateClaudeKeychainCredential(rejectedToken: "configured") == false)
        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == data)
        #expect(reader.calls == 1)
    }

    @Test
    func cancelledAuthorizationDoesNotDisableFutureRefreshes() async throws {
        let data = try Self.credential(token: "authorized", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecUserCanceled, nil), (errSecSuccess, data)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == nil)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(60), read: reader.read
        ) == data)
        #expect(reader.calls == 2)
    }

    @Test
    func expiredCredentialsAreNotRetained() async throws {
        let expired = try Self.credential(token: "expired", expiresAt: Self.now.addingTimeInterval(-1))
        let renewed = try Self.credential(token: "renewed", expiresAt: Self.now.addingTimeInterval(3600))
        let reader = Reader([(errSecSuccess, expired), (errSecSuccess, renewed)])
        let collector = UsageCollector()

        #expect(await collector.claudeKeychainCredentialData(now: Self.now, read: reader.read) == expired)
        #expect(await collector.claudeKeychainCredentialData(
            now: Self.now.addingTimeInterval(60), read: reader.read
        ) == renewed)
        #expect(reader.calls == 2)
    }

    private nonisolated static func credential(token: String, expiresAt: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": expiresAt.timeIntervalSince1970 * 1000,
            ],
        ])
    }
}
