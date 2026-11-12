import Foundation
import Testing
@testable import CodeEdge

struct ProviderWindowDurationTests {
    @Test
    func cursorMonthlyWindowsUseTheReportedBillingCycle() throws {
        let cases: [(String?, String?, Int?)] = [
            ("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 44640),
            ("2028-02-01T00:00:00Z", "2028-03-01T00:00:00Z", 41760),
            (nil, "2026-09-01T00:00:00Z", nil),
            ("2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z", nil),
            ("2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z", nil),
        ]
        for (start, end, expected) in cases {
            var summary: [String: Any] = [
                "individualUsage": ["plan": ["totalPercentUsed": 40, "autoPercentUsed": 30, "apiPercentUsed": 50]],
            ]
            summary["billingCycleStart"] = start
            summary["billingCycleEnd"] = end
            let usage = try CursorUsageFetcher.parse(summaryData: JSONSerialization.data(withJSONObject: summary))
            #expect(usage.windows.map(\.id) == ["cursor-total", "cursor-auto", "cursor-api"])
            #expect(usage.windows.map(\.windowMinutes) == [expected, expected, expected])
        }
    }

    @Test
    func cursorLegacyQuotaKeepsTheSameReportedBillingCycle() throws {
        let summary = Data(#"{"billingCycleStart":"2026-08-01T00:00:00Z","billingCycleEnd":"2026-09-01T00:00:00Z","individualUsage":{"plan":{"totalPercentUsed":40}}}"#.utf8)
        let legacy = CursorLegacyUsage(gpt4: .init(numRequests: 2, numRequestsTotal: 2, maxRequestUsage: 10))
        let usage = try CursorUsageFetcher.parse(summaryData: summary, legacy: legacy)
        #expect(usage.windows.map(\.id) == ["cursor-total"])
        #expect(usage.windows.first?.windowMinutes == 44640)
    }

    @Test
    func cursorWeeklyAndTrialPoolsKeepDifferentDurationSemantics() throws {
        let summary = Data(#"{"individualUsage":{"plan":{"totalPercentUsed":40}}}"#.utf8)
        let now = date("2026-11-03T00:00:00Z")
        let unified = CursorSand(nextResetTimestampUtc: "2026-11-07T00:00:00Z", usagePercent: 30,
                                 hasNonZeroIncludedLimit: true, isUnified: true)
        let weekly = try CursorUsageFetcher.parse(summaryData: summary, sand: unified, now: now)
        #expect(weekly.windows.map(\.id) == ["cursor-weekly"])
        #expect(weekly.windows.first?.windowMinutes == 10080)
        let separate = CursorSand(nextResetTimestampUtc: "2026-11-07T00:00:00Z", usagePercent: 30,
                                  hasNonZeroIncludedLimit: true, isUnified: false)
        let paid = try CursorUsageFetcher.parse(summaryData: summary, sand: separate, now: now)
        #expect(paid.additionalWindows.first?.windowMinutes == 10080)
        let trial = CursorSand(nextResetTimestampUtc: "2026-11-07T00:00:00Z", usagePercent: 30,
                               hasNonZeroIncludedLimit: false, sandTrialExpiresAt: "2026-11-09T00:00:00Z",
                               isUnified: false)
        let usage = try CursorUsageFetcher.parse(summaryData: summary, sand: trial, now: now)
        #expect(usage.additionalWindows.first?.id == "cursor-grok-bot")
        #expect(usage.additionalWindows.first?.windowMinutes == nil)
    }

    @Test
    func copilotUsesCalendarMonthsAndDoesNotInventMissingResetDates() throws {
        let cases: [(String?, Int?)] = [
            ("2026-03-01", 40320), ("2028-03-01", 41760), ("2026-07-01", 43200),
            ("2026-09-01", 44640), (nil, nil),
        ]
        for (reset, expected) in cases {
            var body: [String: Any] = [
                "copilot_plan": "individual",
                "quota_snapshots": ["premium_interactions": ["entitlement": 100, "remaining": 80],
                                    "chat": ["entitlement": 100, "remaining": 60]],
            ]
            body["quota_reset_date"] = reset
            let usage = try CopilotUsageFetcher.parse(data: JSONSerialization.data(withJSONObject: body))
            #expect(usage.windows.count == 2)
            #expect(usage.windows.map(\.windowMinutes) == [expected, expected])
        }
    }

    @Test
    func kiroMainCreditsUseTheCalendarMonthWhileBonusExpiryDoesNot() throws {
        let reset = date("2028-03-01T00:00:00Z")
        let report = KiroCLIUsage(
            planName: "KIRO PRO", accountEmail: nil, authMethod: nil,
            creditsUsed: 10, creditsTotal: 100, creditsPercent: 10, hasUsageMetrics: true,
            bonusCreditsUsed: 1, bonusCreditsTotal: 20, bonusExpiryDays: 5,
            overagesStatus: nil, overageCreditsUsed: nil, estimatedOverageCostUSD: nil,
            manageURL: nil, contextUsage: nil, resetsAt: reset
        )
        let limits = KiroUsageLimits(
            planLimit: 100, planUsed: 10, overageUsed: 2, overageCap: 100, overageEnabled: true,
            overageCharges: nil, overageRate: 0.1, currencyCode: "USD", resetsAt: reset,
            hasUnseparatedBonus: false
        )
        let usage = KiroUsageFetcher.providerUsage(report: report, limits: limits)
        #expect(usage.windows.first { $0.id == "kiro-credits" }?.windowMinutes == 41760)
        #expect(usage.windows.first { $0.id == "kiro-bonus" }?.windowMinutes == nil)
        #expect(usage.additionalWindows.first { $0.id == "kiro-overage" }?.windowMinutes == nil)
        let cli = KiroUsageFetcher.providerUsage(report: report, limits: nil)
        #expect(cli.windows.first?.windowMinutes == 41760)
    }

    @Test
    func geminiDailyAndBrowserPoolsUseTheirOwnDeclaredDurations() throws {
        let oauth = Data(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.8},{"modelId":"gemini-flash","remainingFraction":0.7}]}"#.utf8)
        let daily = try GeminiUsageFetcher.parseQuota(data: oauth)
        #expect(daily.windows.map(\.windowMinutes) == [1440, 1440])
        let browser = #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[{"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.1},{"poolType":"GXU_WEEKLY","percentageUsed":0.3}]}}}}}]"#
        let usage = try #require(try GeminiAppUsageFetcher.parse(browser))
        #expect(usage.windows.map(\.windowMinutes) == [300, 10080])
    }

    @Test
    func antigravityKnownCadencesPropagateToRepresentativesAndUnknownStaysUnknown() throws {
        let data = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"Five Hour Limit","remainingFraction":0.2},{"bucketId":"gemini-weekly","displayName":"Weekly Limit","remainingFraction":0.7},{"bucketId":"gemini-session-history","displayName":"Session History","remainingFraction":0.9}]}]}"#.utf8)
        let usage = try AntigravityUsageFetcher.parseQuotaSummary(data: data)
        #expect(usage.additionalWindows.map(\.windowMinutes) == [300, 10080, nil])
        #expect(usage.windows.first?.windowMinutes == 300)
        let legacy = Data(#"{"clientModelConfigs":[{"label":"Gemini Pro","modelOrAlias":{"model":"gemini-pro"},"quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-12-01T00:00:00Z"}}]}"#.utf8)
        let old = try AntigravityUsageFetcher.parseModelResponse(data: legacy)
        #expect(old.windows.allSatisfy { $0.windowMinutes == nil })
        #expect(old.additionalWindows.allSatisfy { $0.windowMinutes == nil })
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
