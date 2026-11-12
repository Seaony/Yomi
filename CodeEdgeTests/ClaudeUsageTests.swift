import Foundation
import Testing
@testable import CodeEdge

struct ClaudeUsageTests {
    private nonisolated final class InvocationRecorder: @unchecked Sendable {
        struct Invocation: Sendable, Equatable {
            let binary: String
            let arguments: [String]
            let mode: ClaudeCLIUsageFetcher.InvocationMode
            let timeout: TimeInterval
            let environment: [String: String]
        }

        private let lock = NSLock()
        private var storage: [Invocation] = []

        func append(_ invocation: Invocation) {
            lock.withLock { storage.append(invocation) }
        }

        var invocations: [Invocation] {
            lock.withLock { storage }
        }
    }

    private var descriptor: ProviderDescriptor {
        ProviderCatalog.byID[ProviderID(rawValue: "claude")]!
    }

    @Test
    func keepsCoreAndAdditionalClaudeWindowsSeparate() throws {
        let data = Data("""
        {
          "five_hour": {"utilization": 12, "resets_at": "2026-09-01T12:00:00Z"},
          "seven_day": {"utilization": 34, "resets_at": "2026-09-07T12:00:00Z"},
          "seven_day_sonnet": {"utilization": 56, "resets_at": "2026-09-07T12:00:00Z"},
          "seven_day_routines": {"utilization": 0, "resets_at": "2026-09-07T12:00:00Z"},
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 67,
              "is_active": false,
              "resets_at": "2026-09-07T12:00:00Z",
              "scope": {"model": {"id": "model-fable", "display_name": "Fable"}}
            },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 99,
              "scope": {"model": {"id": "all-models", "display_name": "All Models"}}
            }
          ]
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["Session", "Weekly", "Sonnet"])
        #expect(usage.additionalWindows.map(\.label) == ["Daily Routines", "Fable"])
        #expect(usage.additionalWindows.last?.usedFraction == 0.67)
    }

    @Test
    func malformedLimitEntryDoesNotDropValidSiblings() throws {
        let data = Data("""
        {
          "seven_day": {"utilization": 34},
          "limits": [
            "unexpected",
            {"kind": "weekly_scoped", "group": "weekly", "percent": true,
             "scope": {"model": {"id": "model-flag", "display_name": "Flag"}}},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 40,
             "scope": {"model": {"id": "model-fable", "display_name": "Fable"}}}
          ]
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.additionalWindows.map(\.label) == ["Fable"])
        #expect(usage.additionalWindows.first?.usedFraction == 0.4)
    }

    @Test
    func modelScopedLimitsAloneStillCountAsQuotaData() throws {
        let data = Data("""
        {
          "five_hour": null,
          "seven_day": null,
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 25,
             "scope": {"model": {"id": "model-fable", "display_name": "Fable"}}}
          ]
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.map(\.label) == ["Fable"])
    }

    @Test
    func weeklyOnlyPlanKeepsSessionAbsent() throws {
        // 按 CodexBar 抓到的 Max 20x 返回：没有五小时窗口时只显示周额度，不复制一份当会话。
        let data = Data("""
        {
          "five_hour": null,
          "seven_day": {"utilization": 0.0, "resets_at": "2026-11-09T16:59:59.902585+00:00"},
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null}
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.id) == ["claude-seven_day"])
        #expect(usage.windows.map(\.label) == ["Weekly"])
    }

    @Test
    func sonnetWithoutUtilizationDoesNotHideOpus() throws {
        let data = Data("""
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": {"resets_at": "2026-11-09T16:59:59Z"},
          "seven_day_opus": {"utilization": 17, "resets_at": "2026-11-09T16:59:59Z"}
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["Opus"])
        #expect(usage.windows.first?.usedFraction == 0.17)
    }

    @Test
    func oauthAppsFillsWeeklyLaneNextToSession() throws {
        let data = Data("""
        {
          "five_hour": {"utilization": 12},
          "seven_day_oauth_apps": {"utilization": 40}
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["Session", "OAuth apps"])
    }

    @Test(arguments: [false, true])
    func scopedWeeklyQuotaIsNotReplacedBySpendLimit(isWeb: Bool) throws {
        let data = Data("""
        {
          "five_hour": null,
          "seven_day": null,
          "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 2000},
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 17, "is_active": true,
             "resets_at": "2026-11-09T16:59:59Z",
             "scope": {"model": {"display_name": "Fable"}}}
          ]
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor, claudeWeb: isWeb)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.map(\.id) == ["claude-weekly-scoped-fable"])
        #expect(usage.additionalWindows.first?.usedFraction == 0.17)
        #expect(usage.providerCost?.period == "Monthly cap")
        #expect(usage.providerCost?.limit == 100)
    }

    @Test
    func labelsOpusSpecificWindowCorrectly() throws {
        let data = Data(#"{"seven_day_opus":{"utilization":25}}"#.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["Opus"])
    }

    @Test
    func usesExtraUsageAsSpendLimitWhenQuotaWindowsAreAbsent() throws {
        let data = Data("""
        {
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 1250,
            "monthly_limit": 5000,
            "currency": "USD"
          }
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["Spend limit"])
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.providerCost?.used == 12.5)
        #expect(usage.providerCost?.limit == 50)
    }

    @Test
    func webEnterpriseSpendDoesNotRequireOAuthEnabledFlag() throws {
        let data = Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"monthly_limit":100000,"used_credits":4132}}"#.utf8)
        let usage = try UsageParser.parse(data, descriptor: descriptor, claudeWeb: true)

        #expect(usage.providerCost?.used == 41.32)
        #expect(usage.providerCost?.limit == 1000)
        #expect(usage.windows.first?.usedFraction == 0.04132)
        #expect(throws: (any Error).self) {
            try UsageParser.parse(data, descriptor: descriptor)
        }
    }

    @Test
    func webPlanUsesSelectedMembershipRatherThanOrganizationName() throws {
        let data = Data(#"""
        {"memberships":[
          {"organization":{"uuid":"other","rate_limit_tier":"default_claude_pro"}},
          {"organization":{"uuid":"selected","name":"Personal workspace","rate_limit_tier":"default_claude_max_20x"}},
          {"organization":{"uuid":"name-only","name":"Max"}}
        ]}
        """#.utf8)

        #expect(ClaudeWebUsageFetcher.accountPlan(from: data, organizationID: "selected") == "Ultra")
        #expect(ClaudeWebUsageFetcher.accountPlan(from: data, organizationID: "name-only") == nil)
        #expect(ClaudeWebUsageFetcher.accountPlan(from: data, organizationID: "missing") == nil)
    }

    @Test(arguments: [
        ("default_claude_max_20x", "Ultra"),
        ("default_claude_max_5x", "Max"),
        ("default_claude_max", "Max"),
        ("default_claude_pro", "Pro"),
    ])
    func maxTiersUseRenamedPlans(tier: String, expected: String) {
        #expect(UsageParser.displayClaudeOAuthPlan(subscriptionType: nil, rateLimitTier: tier) == expected)
    }

    @Test(arguments: [("Max 20x", "Ultra"), ("Claude Max 5x", "Max"), ("Max", "Max"), ("Ultra", "Ultra")])
    func cachedOldPlanNamesShowRenamedPlans(cached: String, expected: String) throws {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        #expect(UsageParser.displayPlan(cached, descriptor: descriptor) == expected)
    }

    @Test @MainActor
    func restoredCacheShowsRenamedPlan() throws {
        struct Cached: Encodable { let usage: ProviderUsage; let revision: Int }
        let suite = "codeedge-claude-plan-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let id = ProviderID(rawValue: "claude")
        let cached = ProviderUsage(id: id, state: .ready, windows: [], plan: "Max 20x", updatedAt: Date())
        defaults.set(try JSONEncoder().encode([Cached(usage: cached, revision: 0)]), forKey: "usage-cache.v3")

        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)

        #expect(store.usage(for: id).plan == "Ultra")
    }

    @Test
    func parsesClaudeAdminCostAndTokenReports() throws {
        let now = Date(timeIntervalSince1970: 1_700_050_000)
        let costs = Data("""
        {"data":[{
          "starting_at":"2023-11-14T00:00:00Z",
          "ending_at":"2023-11-15T00:00:00Z",
          "results":[{"amount":"250","description":"Claude API"}]
        }]}
        """.utf8)
        let messages = Data("""
        {"data":[{
          "starting_at":"2023-11-14T00:00:00Z",
          "ending_at":"2023-11-15T00:00:00Z",
          "results":[{
            "uncached_input_tokens":100,
            "cache_creation":{"ephemeral_1h_input_tokens":20,"ephemeral_5m_input_tokens":10},
            "cache_read_input_tokens":40,
            "output_tokens":50,
            "model":"claude-test"
          }]
        }]}
        """.utf8)

        let usage = try ClaudeAdminAPIUsageFetcher.parse(
            costsData: costs,
            messagesData: messages,
            now: now
        )

        #expect(usage.windows.isEmpty)
        #expect(usage.plan == nil)
        #expect(usage.providerCost?.used == 2.5)
        #expect(usage.last30Days?.tokens == 220)
        #expect(usage.details.map(\.id) == [
            "claude-admin-today-spend", "claude-admin-7d-spend", "claude-admin-30d-spend",
            "claude-admin-today-tokens", "claude-admin-30d-tokens",
        ])
    }

    @Test
    func normalizesManualClaudeCookieHeader() {
        #expect(
            ClaudeWebUsageFetcher.normalizedSessionKey("foo=bar; sessionKey=sk-ant-test; other=x") ==
                "sk-ant-test"
        )
        #expect(ClaudeWebUsageFetcher.normalizedSessionKey("sk-ant-test") == "sk-ant-test")
    }

    @Test
    func parsesOnlyLabeledClaudeCLIQuotaWindows() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings: Status Config Usage Stats
        Current session
        12% used
        Resets 3:15pm (Asia/Taipei)

        Current week (all models)
        62% left
        Resets Sep 7 at 2pm (Asia/Taipei)

        Current week (Sonnet only)
        34% consumed
        """)

        #expect(snapshot.sessionPercentLeft == 88)
        #expect(snapshot.weeklyPercentLeft == 62)
        #expect(snapshot.modelPercentLeft == 66)
        #expect(snapshot.modelName == "Sonnet")
        #expect(snapshot.sessionResetDescription == "Resets 3:15pm (Asia/Taipei)")
        #expect(snapshot.weeklyResetDescription == "Resets Sep 7 at 2pm (Asia/Taipei)")
    }

    @Test
    func rateLimitedModelBreakdownKeepsSessionAndWeeklyQuota() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings: Status Config Usage Stats
        Current session
        12% used
        Resets 3:15pm (Asia/Taipei)

        Current week (all models)
        62% left
        Resets Sep 7 at 2pm (Asia/Taipei)

        Per-model breakdown unavailable (rate limited, press r to retry)
        """)

        #expect(snapshot.sessionPercentLeft == 88)
        #expect(snapshot.weeklyPercentLeft == 62)
    }

    @Test
    func doesNotInventWeeklyWhenCLIOnlyShowsSession() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        7% used
        """)

        #expect(snapshot.sessionPercentLeft == 93)
        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.modelPercentLeft == nil)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test
    func ignoresUnlabeledPercentAndStatusContextMeter() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Sonnet 4 | 99% used
        random log 45% used
        Current session
        10% available
        """)

        #expect(snapshot.sessionPercentLeft == 10)
        #expect(snapshot.weeklyPercentLeft == nil)
    }

    @Test(arguments: ["", "random log 45% used\n"])
    func rejectsSessionWithoutItsOwnPercentage(prefix: String) {
        #expect(throws: (any Error).self) {
            try ClaudeCLIUsageFetcher.parse(prefix + "Current session\nCurrent week (all models)\n62% used")
        }
    }

    @Test
    func CLIWeeklyOnlyPlanHasNoSession() throws {
        // 没有 "Current session" 行时，不能把周额度挪进会话位置。
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings:  Status   Config   Usage
        Account: session@example.test
        Current week (all models)
        █████                                              10% used
        Resets Nov 9 at 9am (America/New_York)
        Current week (Sonnet only)
        ▌                                                  1% used
        Resets Nov 9 at 9am (America/New_York)
        """)

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.sessionResetDescription == nil)
        #expect(snapshot.weeklyPercentLeft == 90)
        #expect(snapshot.modelPercentLeft == 99)

        let usage = ClaudeCLIUsageFetcher.providerUsage(snapshot: snapshot, now: Date())
        #expect(usage.windows.map(\.id) == ["claude-weekly", "claude-sonnet"])
    }

    @Test(arguments: ["Sonnet only", "Fable only"])
    func CLIModelOnlyQuotaStaysUsableWithoutSessionOrWeekly(label: String) throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings: Status Config Usage
        Current week (\(label))
        █████ 17% used
        Resets Nov 9 at 9am (America/New_York)
        """)
        let usage = ClaudeCLIUsageFetcher.providerUsage(snapshot: snapshot, now: Date())

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.weeklyPercentLeft == nil)
        let window = label == "Sonnet only" ? usage.windows.first : usage.additionalWindows.first
        #expect(window?.usedFraction == 0.17)
        #expect(label == "Sonnet only" ? usage.additionalWindows.isEmpty : usage.windows.isEmpty)
    }

    @Test
    func CLIWeeklyOnlyPanelAfterLoadingIsNotStillLoading() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings: Status Config Usage
        Loading usage data…
        Current week (all models)
        30% used
        """)

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.weeklyPercentLeft == 70)
    }

    @Test
    func CLIUsageCaptureWaitsForRefreshingFooterToClear() {
        func normalized(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
        }
        let refreshing = """
        Current session
        9% used
        Current week (all models)
        67% used
        What's contributing to your limits usage?
        Scanning local sessions…
        Refreshing…
        Esc to cancel
        """
        let finished = """
        Current session
        9% used
        Current week (all models)
        67% used
        Current week (Example Model)
        42% used
        What's contributing to your limits usage?
        Scanning local sessions…
        Esc to cancel
        """

        #expect(ClaudeCLIUsageFetcher.isRefreshingUsage(normalized(refreshing)))
        #expect(ClaudeCLIUsageFetcher.isRefreshingUsage(
            normalized(refreshing.replacingOccurrences(of: "Refreshing…", with: "Refreshing..."))
        ))
        #expect(!ClaudeCLIUsageFetcher.isRefreshingUsage(normalized(refreshing + "\n" + finished)))
        #expect(!ClaudeCLIUsageFetcher.isRefreshingUsage(normalized("Current session\n9% used")))
    }

    @Test
    func CLIProjectionKeepsOpusNameAndResetTogether() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        10% used
        Current week (Opus)
        70% used
        Resets Sep 7 at 2pm (Asia/Taipei)
        Current week (Sonnet)
        20% used
        Resets Sep 8 at 2pm (Asia/Taipei)
        """)
        let usage = ClaudeCLIUsageFetcher.providerUsage(snapshot: snapshot, now: Date())

        #expect(usage.windows.map(\.label) == ["Session", "Opus"])
        #expect(usage.windows.last?.id == "claude-opus")
        #expect(usage.windows.last?.usedFraction == 0.7)
        #expect(usage.windows.last?.detail == "Resets Sep 7 at 2pm (Asia/Taipei)")
    }

    @Test
    func parsesScopedWeeklyWithoutPromotingItToAggregateWeekly() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        9% used

        Current week (Fable)
        68% used
        Reset Sep 7 at 2pm (Asia/Taipei)
        """)

        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.scopedWeekly.count == 1)
        #expect(snapshot.scopedWeekly.first?.modelName == "Fable")
        #expect(snapshot.scopedWeekly.first?.percentLeft == 32)
    }

    @Test
    func deduplicatesGarbledAllModelsAndKeepsExactAggregate() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        0% used

        Current week (all modls)
        67% used

        Current week (all models)
        66% used

        Current week (Fable)
        71% used
        """)

        #expect(snapshot.weeklyPercentLeft == 34)
        #expect(snapshot.scopedWeekly.map(\.modelName) == ["Fable"])
    }

    @Test
    func latestRenderedUsagePanelWins() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Settings: Status Config Usage Stats
        Current session
        80% used

        Settings: Status Config Usage Stats
        Current session
        20% used
        """)

        #expect(snapshot.sessionPercentLeft == 80)
    }

    @Test
    func rejectsLoadingAndSubscriptionNoticeWithoutQuota() {
        #expect(throws: ClaudeCLIUsageError.self) {
            try ClaudeCLIUsageFetcher.parse("Settings: Status Config Usage\nLoading usage data…")
        }
        #expect(throws: ClaudeCLIUsageError.self) {
            try ClaudeCLIUsageFetcher.parse(
                "You are currently using your subscription to power your Claude Code usage"
            )
        }
    }

    @Test
    func classifiesCLIAuthenticationAndRateLimitFailures() {
        do {
            _ = try ClaudeCLIUsageFetcher.parse("Failed to load usage data: authentication_error")
            Issue.record("Expected authentication failure")
        } catch let error as ClaudeCLIUsageError {
            guard case .authenticationFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        do {
            _ = try ClaudeCLIUsageFetcher.parse("Failed to load usage data: rate_limit_error")
            Issue.record("Expected rate limit failure")
        } catch let error as ClaudeCLIUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message.lowercased().contains("rate limited"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func configuredCLIValueIsExecutableOnlyNotShell() {
        let resolved = ClaudeCLIUsageFetcher.resolveBinary(
            configuredBinary: "/usr/bin/true; echo forged",
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        #expect(resolved == nil)
        #expect(ClaudeCLIUsageFetcher.resolveBinary(
            configuredBinary: "/usr/bin/true",
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        ) == "/usr/bin/true")
    }

    @Test
    func scrubsAnthropicCredentialsAndDisablesCLIUpdater() {
        let environment = ClaudeCLIUsageFetcher.scrubbedEnvironment([
            "ANTHROPIC_API_KEY": "secret",
            "ANTHROPIC_AUTH_TOKEN": "secret-2",
            "PATH": "/usr/bin",
        ])

        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(environment["TERM"] == "xterm-256color")
    }

    @Test
    func fetchUsesFixedPTYArgumentsAndNeverRunsConfiguredShell() async throws {
        let recorder = InvocationRecorder()
        let usage = try await ClaudeCLIUsageFetcher.fetch(
            configuredBinary: "/usr/bin/true",
            environment: ["ANTHROPIC_API_KEY": "must-not-leak"],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            runner: { binary, arguments, mode, timeout, environment in
                recorder.append(.init(
                    binary: binary,
                    arguments: arguments,
                    mode: mode,
                    timeout: timeout,
                    environment: environment
                ))
                return "Current session\n25% used"
            }
        )

        let invocation = recorder.invocations.first
        #expect(recorder.invocations.count == 1)
        #expect(invocation?.binary == "/usr/bin/true")
        #expect(invocation?.mode == .pty)
        let sessionID = try #require(invocation?.arguments.last)
        #expect(UUID(uuidString: sessionID) != nil)
        #expect(invocation?.arguments == [
            "--allowed-tools", "", "--strict-mcp-config",
            "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#,
            "--session-id", sessionID,
        ])
        #expect(invocation?.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(usage.windows.map(\.label) == ["Session"])
        #expect(usage.windows.first?.usedFraction == 0.25)
    }

    @Test
    func PTYLoadingFallsBackToFixedDirectUsageWithBoundedTimeout() async throws {
        let recorder = InvocationRecorder()
        let snapshot = try await ClaudeCLIUsageFetcher.fetchSnapshot(
            binary: "/usr/bin/true",
            environment: [:],
            ptyTimeout: 24,
            execute: { binary, arguments, mode, timeout, environment in
                recorder.append(.init(
                    binary: binary,
                    arguments: arguments,
                    mode: mode,
                    timeout: timeout,
                    environment: environment
                ))
                if mode == .pty { return "Loading usage data…" }
                return "Current session\n40% left"
            }
        )

        #expect(snapshot.sessionPercentLeft == 40)
        #expect(recorder.invocations.count == 2)
        #expect(recorder.invocations.last?.mode == .direct)
        #expect(recorder.invocations.last?.arguments == [
            "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#, "/usage",
        ])
        #expect(recorder.invocations.last?.timeout == 8)
    }

    @Test
    func providerProjectionPreservesOnlyRealCLIWindows() throws {
        let now = Date(timeIntervalSince1970: 1_788_250_000)
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        25% used
        Resets 3:15pm (Asia/Taipei)

        Current week (all models)
        60% used

        Current week (Fable)
        70% used
        """)
        let usage = ClaudeCLIUsageFetcher.providerUsage(snapshot: snapshot, now: now)

        #expect(usage.windows.map(\.id) == ["claude-session", "claude-weekly"])
        #expect(usage.windows.map(\.label) == ["Session", "Weekly"])
        let chineseCopy = AppCopy(language: .simplifiedChinese)
        #expect(usage.windows.map { chineseCopy.usageLabel($0.label) } == ["会话", "每周"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.60])
        #expect(usage.additionalWindows.map(\.id) == ["claude-weekly-scoped-fable"])
        #expect(usage.additionalWindows.first?.usedFraction == 0.70)
        #expect(usage.plan == nil)
    }

    @Test
    func ClaudeSourceMappingKeepsExplicitModesTerminal() {
        #expect(ClaudeUsageSourcePlanner.explicitSource(for: .account, credential: "") == .oauthAPI)
        #expect(ClaudeUsageSourcePlanner.explicitSource(for: .token, credential: "sk-ant-admin-test") == .adminAPI)
        #expect(ClaudeUsageSourcePlanner.explicitSource(for: .token, credential: "sk-ant-oat-test") == .oauthAPI)
        #expect(ClaudeUsageSourcePlanner.explicitSource(for: .cookie, credential: "sessionKey=x") == .webAPI)
        #expect(ClaudeUsageSourcePlanner.explicitSource(for: .command, credential: "") == .cli)
    }

    @Test
    func ClaudeAutomaticAppOrderMatchesCodexBar() {
        #expect(ClaudeUsageSourcePlanner.automaticAppOrder(
            hasOAuthCredentials: true,
            hasCLI: true,
            hasWebSession: true
        ) == [.oauthAPI, .cli, .webAPI])
        #expect(ClaudeUsageSourcePlanner.automaticAppOrder(
            hasOAuthCredentials: false,
            hasCLI: true,
            hasWebSession: true
        ) == [.cli, .webAPI])
    }

    @Test
    func ClaudeExplicitOAuthAllowsOnlyOwnerMediatedCLIFallback() {
        #expect(ClaudeUsageSourcePlanner.explicitOAuthAppOrder(hasCLI: true) == [.oauthAPI, .cli])
        #expect(ClaudeUsageSourcePlanner.explicitOAuthAppOrder(hasCLI: false) == [.oauthAPI])
    }

    @Test
    func directRunKeepsOutputOfCommandsThatExitQuickly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "claude-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "claude")
        // 一次性写出 200 KB 后立即退出，模拟输出还在缓冲里进程就结束的情况。
        try Data("#!/bin/sh\nhead -c 200000 /dev/zero | tr '\\0' x\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        for _ in 0..<5 {
            let output = try await ClaudeCLIUsageFetcher.run(
                binary: script.path, arguments: [], mode: .direct, timeout: 10, environment: [:]
            )
            #expect(output.count == 200_000)
        }
    }
}
