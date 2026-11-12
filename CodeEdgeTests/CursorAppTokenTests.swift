import CommonCrypto
import Foundation
import Security
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct CursorAppTokenTests {
    // 测试跑在 CodeEdge.app 里，授权记录会写进真实偏好设置，结束后清掉。
    private func resetGrant() {
        for prefix in ["credential-keychain-granted.", "credential-keychain-denied-until."] {
            UserDefaults.standard.removeObject(forKey: prefix + "Cursor Safe Storage")
            UserDefaults.standard.removeObject(forKey: prefix + "Cursor Safe Storage (Cursor Key)")
        }
    }

    @Test
    func plainTokenNeedsNoKeychain() {
        let token = ChromiumSafeStorage.$readOverride.withValue({ _, _ in
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
            ChromiumSafeStorage.$readOverride.withValue({ account, allowPrompt in
                // Electron 的密钥在 Cursor Key 账户下。
                guard account == "Cursor Key" else { return (errSecItemNotFound, nil) }
                return allowPrompt ? (errSecItemNotFound, nil) : (errSecSuccess, Data("pw".utf8))
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
            ChromiumSafeStorage.$readOverride.withValue({ _, allowPrompt in
                prompts.append(allowPrompt)
                return (errSecSuccess, Data("pw".utf8))
            }) {
                UsageCollector.decryptedCursorAppToken(envelope)
            }
        }

        #expect(token == nil)
        #expect(prompts.isEmpty)
    }

    @Test
    func encryptedTokenFallsBackToLegacyCursorAccount() throws {
        resetGrant()
        defer { resetGrant() }
        let envelope = "cursor-safe-storage:v1:" + (try Self.encrypt("eyJ.secret.jwt", password: "pw")).base64EncodedString()

        let token = BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
            ChromiumSafeStorage.$readOverride.withValue({ account, _ in
                account == "Cursor" ? (errSecSuccess, Data("pw".utf8)) : (errSecItemNotFound, nil)
            }) {
                UsageCollector.decryptedCursorAppToken(envelope)
            }
        }

        #expect(token == "eyJ.secret.jwt")
    }

    @Test
    func failedInteractiveDecryptionDoesNotPromptForLegacyAccount() throws {
        resetGrant()
        defer { resetGrant() }
        let envelope = "cursor-safe-storage:v1:" + (try Self.encrypt("eyJ.secret.jwt", password: "pw")).base64EncodedString()
        var reads: [(String, Bool)] = []

        // 第一个账户弹框后密码不对，旧账户不能再弹第二次。
        let token = BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
            ChromiumSafeStorage.$readOverride.withValue({ account, allowPrompt in
                reads.append((account, allowPrompt))
                return allowPrompt ? (errSecSuccess, Data("wrong".utf8)) : (errSecInteractionNotAllowed, nil)
            }) {
                UsageCollector.decryptedCursorAppToken(envelope)
            }
        }

        #expect(token == nil)
        #expect(reads.filter(\.1).count == 1)
        #expect(reads.first?.0 == "Cursor Key")
    }

    @Test
    func deniedNewAccountDoesNotPromptLegacyAccountOnNextRefresh() throws {
        resetGrant()
        defer { resetGrant() }
        let envelope = "cursor-safe-storage:v1:" + (try Self.encrypt("eyJ.secret.jwt", password: "pw")).base64EncodedString()
        var prompts: [String] = []
        let read: @Sendable (String, Bool) -> (OSStatus, Data?) = { _, allowPrompt in
            allowPrompt ? (errSecUserCanceled, nil) : (errSecInteractionNotAllowed, nil)
        }

        // 第一次手动刷新拒绝了 Cursor Key，冷却期内的下一次手动刷新不能再为旧账户 Cursor 弹框。
        for _ in 0..<2 {
            _ = BrowserCookieAccess.$scope.withValue(.init(allowInteraction: true)) {
                ChromiumSafeStorage.$readOverride.withValue({ account, allowPrompt in
                    if allowPrompt { prompts.append(account) }
                    return read(account, allowPrompt)
                }) {
                    UsageCollector.decryptedCursorAppToken(envelope)
                }
            }
        }

        #expect(prompts == ["Cursor Key"])
    }

    @Test
    func emptyManualCookieDoesNotFallBackToAppSession() async throws {
        let descriptor = try #require(ProviderCatalog.all.first { $0.id.rawValue == "cursor" })
        var configuration = ProviderConfiguration(descriptor: descriptor)
        configuration.source = .cookie

        // 手动 Cookie 留空时不能改用 Cursor 应用里登录的账号。
        await ChromiumSafeStorage.$readOverride.withValue({ _, _ in
            Issue.record("手动 Cookie 模式不应读取 Cursor 应用令牌")
            return (errSecItemNotFound, nil)
        }) {
            do {
                _ = try await UsageCollector().collect(descriptor: descriptor, configuration: configuration, secret: "  ")
                Issue.record("留空的手动 Cookie 应报缺凭据")
            } catch UsageCollectionError.missingCredential {
            } catch {
                Issue.record("意外错误：\(error)")
            }
        }
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
