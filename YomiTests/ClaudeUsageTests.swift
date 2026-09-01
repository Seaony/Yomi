import Foundation
import Testing
@testable import Yomi

struct ClaudeUsageTests {
    private final class InvocationRecorder: @unchecked Sendable {
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
        #expect(snapshot.sonnetPercentLeft == 66)
        #expect(snapshot.sessionResetDescription == "Resets 3:15pm (Asia/Taipei)")
        #expect(snapshot.weeklyResetDescription == "Resets Sep 7 at 2pm (Asia/Taipei)")
    }

    @Test
    func doesNotInventWeeklyWhenCLIOnlyShowsSession() throws {
        let snapshot = try ClaudeCLIUsageFetcher.parse("""
        Current session
        7% used
        """)

        #expect(snapshot.sessionPercentLeft == 93)
        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.sonnetPercentLeft == nil)
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
        #expect(invocation?.arguments.prefix(4) == ["--allowed-tools", "", "--strict-mcp-config", "--session-id"])
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
        #expect(recorder.invocations.last?.arguments == ["/usage"])
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
}
