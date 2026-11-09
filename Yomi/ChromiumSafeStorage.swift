import CommonCrypto
import Foundation
import Security

// Chromium/Electron 在 macOS 上用钥匙串里的 Safe Storage 密码加密本地数据（OSCrypt v10）。
nonisolated enum ChromiumSafeStorage {
    /// 读取 Safe Storage 密码，授权规则见 BrowserCookieAccess.readForeignKeychainItem。
    /// grantKey 用来区分同一服务下不同账户的授权记录，默认沿用服务名。
    static func password(service: String, account: String, grantKey: String? = nil) -> String? {
        let (status, data) = BrowserCookieAccess.readForeignKeychainItem(
            service: service,
            grantKey: grantKey,
            read: { allowPrompt in
                readOverride?(account, allowPrompt) ?? readKeychain(service: service, account: account, allowPrompt: allowPrompt)
            },
            exists: existsOverride ?? { BrowserCookieAccess.foreignKeychainItemExists(service: service, account: account) }
        )
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只在条目的解密 ACL 已信任本应用时才读密码，任何情况下都不弹授权框；判断不了就当读不到。
    static func silentPassword(service: String, account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // 先只取条目引用检查 ACL，不取密码，旧式钥匙串条目取密码时可能无视不弹窗标志。
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        BrowserCookieAccess.applyNoUI(to: &query)
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let reference = attributes[kSecValueRef as String],
              decryptACLTrustsCurrentApp(unsafeDowncast(reference as AnyObject, to: SecKeychainItem.self))
        else { return nil }
        let (status, data) = readKeychain(service: service, account: account, allowPrompt: false)
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // 与 CodexBar 的钥匙串预检一致：解密 ACL 不限制调用方，或其中某个受信应用的签名要求与本应用相符，且没有提示选项。
    private static func decryptACLTrustsCurrentApp(_ item: SecKeychainItem) -> Bool {
        guard let copyAccess = securityFunction("SecKeychainItemCopyAccess", as: CopyItemAccess.self),
              let copyACLs = securityFunction("SecAccessCopyMatchingACLList", as: CopyMatchingACLList.self),
              let copyContents = securityFunction("SecACLCopyContents", as: CopyACLContents.self),
              let validate = securityFunction("SecTrustedApplicationValidateWithPath", as: ValidateWithPath.self),
              let executablePath = Bundle.main.executablePath
        else { return false }
        var access: SecAccess?
        guard copyAccess(item, &access) == errSecSuccess, let access,
              let acls = copyACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue() as? [SecACL]
        else { return false }
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyContents(acl, &applications, &description, &selector) == errSecSuccess,
                  selector.rawValue == 0 else { continue }
            guard let applications else { return true }
            let trusted = applications as? [SecTrustedApplication] ?? []
            if trusted.contains(where: { app in executablePath.withCString { validate(app, $0) } == errSecSuccess }) {
                return true
            }
        }
        return false
    }

    // SecKeychain 系列接口已弃用，运行时取符号，避免编译警告。
    private typealias CopyItemAccess = @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias CopyMatchingACLList = @convention(c) (SecAccess, CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyACLContents = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>,
        UnsafeMutablePointer<CFString?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>
    ) -> OSStatus
    private typealias ValidateWithPath = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

    private nonisolated(unsafe) static let securityHandle = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW
    )

    private static func securityFunction<T>(_ name: String, as _: T.Type) -> T? {
        guard let securityHandle, let symbol = dlsym(securityHandle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    // 测试时替换钥匙串读取。
    @TaskLocal static var readOverride: (@Sendable (_ account: String, _ allowPrompt: Bool) -> (OSStatus, Data?))?
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
