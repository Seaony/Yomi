import Foundation
import Testing
@testable import Yomi

struct CopilotUsageTests {
    @Test
    func parsesPremiumAndChatWindows() throws {
        let data = Data(#"{"copilot_plan":"individual","quota_reset_date":"2026-09-01","quota_snapshots":{"premium_interactions":{"entitlement":200,"remaining":156.2,"percent_remaining":78.1,"quota_id":"premium"},"chat":{"entitlement":100,"remaining":60,"percent_remaining":60,"quota_id":"chat"}}}"#.utf8)
        let usage = try CopilotUsageFetcher.parse(data: data)
        #expect(usage.windows.map(\.label) == ["Premium", "Chat"])
        #expect(abs(usage.windows[0].usedFraction - 0.219) < 0.000_001)
        #expect(usage.windows[1].usedFraction == 0.4)
        #expect(usage.plan == "Individual")
        #expect(usage.windows[0].resetsAt != nil)
    }

    @Test
    func derivesPercentFromEntitlementAndRemaining() throws {
        let data = Data(#"{"copilot_plan":"free","quota_snapshots":{"chat":{"entitlement":"200","remaining":"75","quota_id":"chat"}}}"#.utf8)
        let usage = try CopilotUsageFetcher.parse(data: data)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Chat")
        #expect(usage.windows[0].usedFraction == 0.625)
    }

    @Test
    func monthlyFallbackDoesNotInventMissingLane() throws {
        let data = Data(#"{"copilot_plan":"free","monthly_quotas":{"chat":500,"completions":300},"limited_user_quotas":{"completions":60}}"#.utf8)
        let usage = try CopilotUsageFetcher.parse(data: data)
        #expect(usage.windows.map(\.label) == ["Premium"])
        #expect(usage.windows[0].usedFraction == 0.8)
    }

    @Test
    func unlimitedAndTokenBillingDoNotCreateFakeBars() throws {
        let data = Data(#"{"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"unlimited":true,"credits_used":31,"quota_id":"premium"}}}"#.utf8)
        let usage = try CopilotUsageFetcher.parse(data: data)
        #expect(usage.windows.isEmpty)
        #expect(usage.details.first?.value == "31")
        #expect(usage.plan == "Business")
    }

    @Test
    func unknownQuotaKeyFallsBackToChat() throws {
        let data = Data(#"{"copilot_plan":"free","quota_snapshots":{"mystery":{"entitlement":100,"remaining":40,"percent_remaining":40,"quota_id":"mystery"}}}"#.utf8)
        let usage = try CopilotUsageFetcher.parse(data: data)
        #expect(usage.windows.map(\.label) == ["Chat"])
        #expect(usage.windows[0].usedFraction == 0.6)
    }

    @Test
    func endpointSupportsPublicAndEnterpriseHosts() {
        #expect(CopilotUsageFetcher.usageURL(enterpriseHost: nil)?.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(CopilotUsageFetcher.usageURL(enterpriseHost: "https://github.example.com/path")?.absoluteString == "https://api.github.example.com/copilot_internal/user")
        #expect(CopilotUsageFetcher.usageURL(enterpriseHost: "api.github.example.com")?.host == "api.github.example.com")
    }

    @Test
    func tokenAndCatalogUseCopilotCredentialContract() {
        #expect(CopilotUsageFetcher.cleanToken(" token abc ") == "abc")
        #expect(CopilotUsageFetcher.cleanToken("Bearer xyz") == "xyz")
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "copilot")]
        #expect(descriptor?.preferredSources == [.token])
        #expect(descriptor?.environmentKeys == ["COPILOT_API_TOKEN"])
    }
}
