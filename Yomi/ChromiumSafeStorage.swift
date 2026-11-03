import CommonCrypto
import Foundation
import Security

// Chromium/Electron 在 macOS 上用钥匙串里的 Safe Storage 密码加密本地数据（OSCrypt v10）。
nonisolated enum ChromiumSafeStorage {
    /// 读取 Safe Storage 密码，授权规则见 BrowserCookieAccess.readForeignKeychainItem。
    static func password(service: String, account: String) -> String? {
        let (status, data) = BrowserCookieAccess.readForeignKeychainItem(
            service: service,
            read: readOverride ?? { allowPrompt in
                readKeychain(service: service, account: account, allowPrompt: allowPrompt)
            },
            exists: existsOverride ?? { BrowserCookieAccess.foreignKeychainItemExists(service: service, account: account) }
        )
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // 测试时替换钥匙串读取。
    @TaskLocal static var readOverride: (@Sendable (Bool) -> (OSStatus, Data?))?
    @TaskLocal static var existsOverride: (@Sendable () -> Bool)?

    private static func readKeychain(service: String, account: String, allowPrompt: Bool) -> (OSStatus, Data?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowPrompt { BrowserCookieAccess.applyNoUI(to: &query) }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) -> Data? {
        guard encrypted.count > 3, encrypted.starts(with: Data("v10".utf8)) else { return nil }
        let payload = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outLength = 0
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress, payload.count,
                            outBytes.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        return out
    }
}
