import CommonCrypto
import Foundation
import Security
import Testing
@testable import Yomi

@Suite(.serialized)
struct CursorAppTokenTests {
    // 测试跑在 Yomi.app 里，授权记录会写进真实偏好设置，结束后清掉。
    private func resetGrant() {
        for prefix in ["credential-keychain-granted.", "credential-keychain-denied-until."] {
            UserDefaults.standard.removeObject(forKey: prefix + "Cursor Safe Storage")
        }
    }

    @Test
    func plainTokenNeedsNoKeychain() {
        let token = ChromiumSafeStorage.$readOverride.withValue({ _ in
            Issue.record("明文令牌不应读取钥匙串")
            return (errSecItemNotFound, nil)
        }) {
            UsageCollector.decryptedCursorAppToken("eyJ.plain.jwt")
        }
        #expect(token == "eyJ.plain.jwt")
    }

    @Test
    func encryptedTokenIsDecryptedWithSafeStoragePassword() throws {
        resetGrant()
        defer { resetGrant() }
        let envelope = "cursor-safe-storage:v1:" + (try Self.encrypt("eyJ.secret.jwt", password: "pw")).base64EncodedString()

        let token = BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
            ChromiumSafeStorage.$readOverride.withValue({ allowPrompt in
                allowPrompt ? (errSecItemNotFound, nil) : (errSecSuccess, Data("pw".utf8))
            }) {
                UsageCollector.decryptedCursorAppToken(envelope)
            }
        }

        #expect(token == "eyJ.secret.jwt")
    }

    @Test
    func backgroundRefreshWithoutGrantDoesNotReadSafeStorage() throws {
        resetGrant()
        defer { resetGrant() }
        let envelope = "cursor-safe-storage:v1:" + (try Self.encrypt("eyJ.secret.jwt", password: "pw")).base64EncodedString()
        var prompts: [Bool] = []

        // 后台刷新且没有授权记录时不读密码，交给 Cookie 来源兜底。
        let token = ChromiumSafeStorage.$existsOverride.withValue({ true }) {
            ChromiumSafeStorage.$readOverride.withValue({ allowPrompt in
                prompts.append(allowPrompt)
                return (errSecSuccess, Data("pw".utf8))
            }) {
                UsageCollector.decryptedCursorAppToken(envelope)
            }
        }

        #expect(token == nil)
        #expect(prompts.isEmpty)
    }

    private static func encrypt(_ text: String, password: String) throws -> Data {
        let key = ChromiumSafeStorage.deriveKey(from: password)
        let input = Data(text.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = out.count
        var length = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count, outBytes.baseAddress, capacity, &length
                        )
                    }
                }
            }
        }
        try #require(status == kCCSuccess)
        out.count = length
        return Data("v10".utf8) + out
    }
}
