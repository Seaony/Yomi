import Foundation
import Testing
@testable import CodeEdge

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
        // 月度总额度拆成 Kimi Code 20% 和其他功能 50%。
        #expect(result.details.map(\.id) == ["kimi-monthly-code", "kimi-monthly-other"])
        #expect(result.details[0].value.contains("20%"))
        #expect(result.details[1].value.contains("50%"))
    }

    @Test func codeAPIMonthlyCodeShareBecomesBreakdown() throws {
        let data = Data(#"""
        {"usages":{
          "limit_month_total":{"used_ratio":0.6,"reset_time":"2030-01-01T00:00:00Z"},
          "limit_month_code":{"used_ratio":0.45}
        }}
        """#.utf8)
        let usage = KimiUsageFetcher.providerUsage(snapshot: try KimiUsageFetcher.parseCode(data))
        #expect(usage.additionalWindows.map(\.id) == ["kimi-monthly"])
        #expect(usage.details.map(\.id) == ["kimi-monthly-code", "kimi-monthly-other"])
        #expect(usage.details[0].value.contains("45%"))
        #expect(usage.details[1].value.contains("15%"))
    }

    @Test func giftBalancesShowRemainingAndSkipExpiredOrMalformed() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let usageData = Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"40"}}]}"#.utf8)
        let subscription = Data(#"""
        {
          "subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.3},
          "giftBalances":[
            {"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0.25,"expireTime":"2030-01-01T00:00:00Z","displayName":"Invite reward"},
            {"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0.1,"expireTime":"2020-01-01T00:00:00Z"},
            {"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.5}
          ]
        }
        """#.utf8)
        let result = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(usageData, subscriptionData: subscription), now: now
        )
        let gifts = result.details.filter { $0.id.hasPrefix("kimi-gift-") }
        #expect(gifts.map(\.label) == ["Invite reward"])
        #expect(gifts.first?.value.contains("75%") == true)

        // 赠送额度格式不对时，订阅余额照常显示。
        let malformed = Data(#"""
        {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.3},"giftBalances":"oops"}
        """#.utf8)
        let kept = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(usageData, subscriptionData: malformed), now: now
        )
        #expect(kept.additionalWindows.map(\.id) == ["kimi-monthly"])

        // 没有任何额度窗口、只有赠送余额时也要显示，不能当成解析失败。
        let giftOnly = Data(#"""
        {"giftBalances":[{"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0.5,"expireTime":"2030-01-01T00:00:00Z"}]}
        """#.utf8)
        let gift = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(Data(#"{"usages":[]}"#.utf8), subscriptionData: giftOnly), now: now
        )
        #expect(gift.state == .ready)
        #expect(gift.details.map(\.id) == ["kimi-gift-0"])
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

    @Test func lapsedCodePlanKeepsMembershipUsage() throws {
        let usageData = Data(#"{"usages":[{"scope":"FEATURE_OMNI","detail":{"limit":"10","used":"9"}}]}"#.utf8)
        let subscription = Data(#"""
        {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.3}}
        """#.utf8)
        let result = KimiUsageFetcher.providerUsage(
            snapshot: try KimiUsageFetcher.parseWeb(usageData, subscriptionData: subscription)
        )
        #expect(result.state == .ready)
        #expect(result.additionalWindows.map(\.id) == ["kimi-monthly"])

        let empty = KimiUsageFetcher.providerUsage(snapshot: try KimiUsageFetcher.parseWeb(Data("{}".utf8)))
        #expect(empty.state == .failed)
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
