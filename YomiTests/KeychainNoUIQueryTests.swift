import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Yomi

struct KeychainNoUIQueryTests {
    @Test
    func noUIQueryKeepsBothSilentFlags() throws {
        var query: [String: Any] = [:]
        BrowserCookieAccess.applyNoUI(to: &query)

        // 运行时读到的值必须就是系统常量，否则旧式钥匙串仍会弹授权框。
        #expect(BrowserCookieAccess.authenticationUIFailPolicy == "u_AuthUIF")
        #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
    }
}
