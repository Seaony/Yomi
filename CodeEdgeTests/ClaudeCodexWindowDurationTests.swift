import Foundation
import Testing
@testable import CodeEdge

struct ClaudeCodexWindowDurationTests {
    @Test(arguments: [
        (604_800, 10_080), (2_592_000, 43_200), (123_456, 2_057),
    ])
    func codexHTTPKeepsReportedDurationAndExistingWindowSelection(seconds: Int, minutes: Int) throws {
        let usage = try parse("codex", ["rate_limit": ["primary_window": [
            "used_percent": 38, "limit_window_seconds": seconds, "reset_at": 1_800_604_800,
        ]]])

        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.id == "codex-primary")
        #expect(usage.windows.first?.windowMinutes == minutes)
        #expect(usage.windows.first?.usedFraction == 0.38)
    }

    @Test(arguments: [-60, 0, 59])
    func codexHTTPDoesNotInventDurationForInvalidWindows(seconds: Int) throws {
        let usage = try parse("codex", ["rate_limit": ["primary_window": [
            "used_percent": 38, "limit_window_seconds": seconds,
        ]]])

        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.windowMinutes == nil)
    }

    @Test
    func codexMissingDurationStaysUnknown() throws {
        let usage = try parse("codex", ["rate_limit": ["primary_window": ["used_percent": 38]]])
        #expect(usage.windows.first?.windowMinutes == nil)
    }

    @Test(arguments: [10_080, 43_200])
    func codexRPCPreservesReliableDurations(minutes: Int) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["rateLimits": ["primary": [
            "usedPercent": 42, "windowDurationMins": minutes, "resetsAt": 1_800_604_800,
        ]]])
        let usage = try CodexUsageFetcher.parseRPCResponse(payload)

        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.windowMinutes == minutes)
        #expect(usage.windows.first?.usedFraction == 0.42)
    }

    @Test(arguments: [-1, 0])
    func codexRPCInvalidDurationDoesNotBecomeAWeeklyDuration(minutes: Int) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["rateLimits": ["secondary": [
            "usedPercent": 42, "windowDurationMins": minutes,
        ]]])
        let usage = try CodexUsageFetcher.parseRPCResponse(payload)

        #expect(usage.windows.first?.label == "Weekly")
        #expect(usage.windows.first?.windowMinutes == nil)
    }

    @Test(arguments: [
        ("five_hour", 300), ("seven_day", 10_080), ("seven_day_oauth_apps", 10_080),
        ("seven_day_sonnet", 10_080), ("seven_day_opus", 10_080),
    ])
    func claudeAPIAndWebUseDeclaredSessionAndWeeklyDurations(key: String, minutes: Int) throws {
        for isWeb in [false, true] {
            let usage = try parse("claude", [key: ["utilization": 34]], claudeWeb: isWeb)
            #expect(usage.windows.count == 1)
            #expect(usage.windows.first?.windowMinutes == minutes)
            #expect(usage.windows.first?.usedFraction == 0.34)
        }
    }

    @Test
    func claudeScopedWeeklyHasDurationAndUnknownRoutineDoesNot() throws {
        let usage = try parse("claude", [
            "seven_day_routines": ["utilization": 12],
            "limits": [[
                "kind": "weekly_scoped", "group": "weekly", "percent": 25,
                "scope": ["model": ["id": "model-fable", "display_name": "Fable"]],
            ]],
        ])

        #expect(usage.additionalWindows.map(\.windowMinutes) == [nil, 10_080])
        #expect(usage.windows.isEmpty)
    }

    @Test
    func claudeSpendCapDoesNotGuessDuration() throws {
        let usage = try parse("claude", ["extra_usage": [
            "is_enabled": true, "used_credits": 120, "monthly_limit": 1_000,
        ]])

        #expect(usage.windows.first?.id == "claude-spend-limit")
        #expect(usage.windows.first?.windowMinutes == nil)
    }

    @Test
    func claudeCLIUsesExistingExpectedWindowForAllQuotaRows() {
        let snapshot = ClaudeCLIUsageSnapshot(
            sessionPercentLeft: 80, weeklyPercentLeft: 70, modelName: "Sonnet", modelPercentLeft: 60,
            scopedWeekly: [.init(modelName: "Fable", percentLeft: 50, resetDescription: nil)],
            sessionResetDescription: nil, weeklyResetDescription: nil, modelResetDescription: nil,
            accountEmail: nil, organization: nil, loginMethod: nil
        )
        let usage = ClaudeCLIUsageFetcher.providerUsage(
            snapshot: snapshot, now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(usage.windows.map(\.windowMinutes) == [300, 10_080, 10_080])
        #expect(usage.additionalWindows.map(\.windowMinutes) == [10_080])
        #expect(usage.windows.map(\.usedFraction) == [0.2, 0.3, 0.4])
    }

    @Test
    func geminiGenericParserRetainsDailyResetPeriod() throws {
        let usage = try parse("gemini", ["buckets": [
            ["modelId": "gemini-pro", "remainingFraction": 0.8],
            ["modelId": "gemini-flash", "remainingFraction": 0.9],
        ]])

        #expect(usage.windows.map(\.label) == ["Pro", "Flash"])
        #expect(usage.windows.map(\.windowMinutes) == [1_440, 1_440])
    }

    private func parse(_ provider: String, _ payload: [String: Any], claudeWeb: Bool = false) throws -> ProviderUsage {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: provider)])
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try UsageParser.parse(data, descriptor: descriptor, claudeWeb: claudeWeb)
    }
}
