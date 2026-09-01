import Foundation
import Testing
@testable import Yomi

@Suite("Kimi Code usage")
struct KimiUsageTests {
    @Test func parsesCodeAPIWeeklyAndFiveHourWindows() throws {
        let data = Data(#"""
        {
          "usage":{"limit":100,"used":"25","remaining":75,"reset_at":"2026-09-08T00:00:00Z"},
          "limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"20","used":5,"remaining":"15","resetTime":"2026-09-01T05:00:00Z"}}]
        }
        """#.utf8)
        let usage = KimiUsageFetcher.providerUsage(snapshot: try KimiUsageFetcher.parseCode(data))
        #expect(usage.windows.map(\.id) == ["kimi-weekly", "kimi-session"])
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[1].usedFraction == 0.25)
        #expect(usage.windows[1].label == "5-hour usage")
    }

    @Test func webUsesOnlyFeatureCodingScope() throws {
        let data = Data(#"""
        {"usages":[
          {"scope":"FEATURE_OMNI","detail":{"limit":"10","used":"9"}},
          {"scope":"FEATURE_CODING","detail":{"limit":"100","used":"40"},"limits":[]}
        ]}
        """#.utf8)
        let usage = KimiUsageFetcher.providerUsage(snapshot: try KimiUsageFetcher.parseWeb(data))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.4)
    }

    @Test func subscriptionUsesSharedTotalRatioAndDistinctCodeWeekly() throws {
        let usageData = Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"40","resetTime":"2026-09-08T00:00:00Z"}}]}"#.utf8)
        let subscription = Data(#"""
        {
          "subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.7,"kimiCodeUsedRatio":0.2,"expireTime":"2026-10-01T00:00:00Z"},
          "ratelimitCode7d":{"ratio":0.5,"enabled":true,"resetTime":"2026-09-09T00:00:00Z"}
        }
        """#.utf8)
        let result = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(usageData, subscriptionData: subscription)
        )
        #expect(result.additionalWindows.map(\.id) == ["kimi-monthly", "kimi-code-7d"])
        #expect(result.additionalWindows[0].usedFraction == 0.7)
    }

    @Test func duplicateSubscriptionWeeklyIsSuppressed() throws {
        let reset = "2026-09-08T00:00:00Z"
        let usageData = Data("""
        {"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"40","resetTime":"\(reset)"}}]}
        """.utf8)
        let subscription = Data("""
        {"ratelimitCode7d":{"ratio":0.4,"enabled":true,"resetTime":"\(reset)"}}
        """.utf8)
        let result = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(usageData, subscriptionData: subscription)
        )
        #expect(result.additionalWindows.isEmpty)
    }

    @Test func invalidCountersDoNotCreateQuotaWindows() throws {
        let data = Data(#"{"usage":{"limit":"invalid","used":"5"}}"#.utf8)
        let usage = KimiUsageFetcher.providerUsage(snapshot: try KimiUsageFetcher.parseCode(data))
        #expect(usage.state == .failed)
        #expect(usage.windows.isEmpty)
    }

    @Test func extractsOnlyJWTOrKimiAuthCookie() {
        #expect(KimiUsageFetcher.webToken(from: "kimi-auth=eyJabc.def.ghi; foo=bar") == "eyJabc.def.ghi")
        #expect(KimiUsageFetcher.webToken(from: "eyJabc.def.ghi") == "eyJabc.def.ghi")
        #expect(KimiUsageFetcher.webToken(from: "ordinary-api-key") == nil)
    }

    @Test func buildsCodeEndpointWithoutDuplicatingPath() throws {
        #expect(try KimiUsageFetcher.codeUsageEndpoint(baseURL: URL(string: "https://api.kimi.com")!).path == "/coding/v1/usages")
        #expect(try KimiUsageFetcher.codeUsageEndpoint(baseURL: URL(string: "https://api.kimi.com/coding")!).path == "/coding/v1/usages")
        #expect(try KimiUsageFetcher.codeUsageEndpoint(baseURL: URL(string: "https://api.kimi.com/coding/v1")!).path == "/coding/v1/usages")
    }

    @Test func localCredentialRequiresFreshExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let data = Data(#"{"access_token":"local-token","refresh_token":"refresh","expires_at":4102444800}"#.utf8)
        try data.write(to: credentials.appendingPathComponent("kimi-code.json"))
        #expect(try KimiUsageFetcher.localCodeCredential(
            environment: ["KIMI_CODE_HOME": root.path], now: Date(timeIntervalSince1970: 1_800_000_000)
        ) == "local-token")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func catalogMatchesCredentialContract() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "kimi")]
        #expect(descriptor?.preferredSources == [.account, .token, .cookie])
        #expect(descriptor?.environmentKeys == ["KIMI_CODE_API_KEY", "KIMI_AUTH_TOKEN", "KIMI_MANUAL_COOKIE"])
        #expect(ProviderRecipes.recipe(for: ProviderID(rawValue: "kimi")) == nil)
    }
}
