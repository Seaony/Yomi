import Foundation
import SQLite3
import Testing
@testable import Yomi

@Suite("Kiro usage")
struct KiroUsageTests {
    private static let overageResponse = """
    {"nextDateReset":1788220800,
     "overageConfiguration":{"overageStatus":"ENABLED"},
     "usageBreakdownList":[{"bonuses":[],"currency":"USD",
       "currentOveragesWithPrecision":3603.49,"currentUsageWithPrecision":13603.49,
       "nextDateReset":1788220800,"overageCapWithPrecision":10000,
       "overageCharges":144.139711109352,"overageRate":0.04,
       "resourceType":"CREDIT","usageLimitWithPrecision":10000}]}
    """

    @Test
    func parsesLegacyCreditsAndReset() throws {
        let calendar = Self.utcCalendar()
        let report = try KiroUsageFetcher.parseCLI(
            """
            | KIRO FREE |
            ████████████████████ 25%
            (12.50 of 50 covered in plan), resets on 01/15
            """,
            now: Self.date("2026-01-01T00:00:00Z"),
            calendar: calendar
        )
        #expect(report.planName == "KIRO FREE")
        #expect(report.displayPlanName == "Kiro Free")
        #expect(report.creditsUsed == 12.5)
        #expect(report.creditsTotal == 50)
        #expect(report.creditsPercent == 25)
        #expect(report.resetsAt == Self.date("2026-01-15T00:00:00Z"))
    }

    @Test
    func parsesCurrentFormatBonusOverageAndIdentity() throws {
        let report = try KiroUsageFetcher.parseCLI(
            """
            \u{001B}[1mEstimated Usage\u{001B}[0m | resets on 2026-06-01 | KIRO POWER
            🎁 Bonus credits: 45.53/2000 credits used, expires in 19 days
            Credits (10000.00 of 10000 covered in plan)
            ████████████████████████████████████████ 100%
            Overages: Enabled  billed at $0.04 per request
            Credits used: 40.29
            Est. cost: $1.61 USD
            https://app.kiro.dev/account/usage
            """,
            accountEmail: "person@example.com",
            authMethod: "Google"
        )
        #expect(report.planName == "KIRO POWER")
        #expect(report.accountEmail == "person@example.com")
        #expect(report.authMethod == "Google")
        #expect(report.bonusCreditsUsed == 45.53)
        #expect(report.bonusCreditsTotal == 2000)
        #expect(report.bonusExpiryDays == 19)
        #expect(report.overagesStatus == "Enabled  billed at $0.04 per request")
        #expect(report.overageCreditsUsed == 40.29)
        #expect(report.estimatedOverageCostUSD == 1.61)
        #expect(report.manageURL == "https://app.kiro.dev/account/usage")
    }

    @Test
    func computesPercentFromCreditsWhenBarIsAbsent() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        | KIRO FREE |
        (12.50 of 50 covered in plan), resets on 01/15
        """)
        #expect(report.creditsPercent == 25)
    }

    @Test
    func acceptsManagedPlanWithoutExposedMetrics() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        Plan: Q Developer Pro
        Your plan is managed by admin
        """)
        #expect(report.planName == "Q Developer Pro")
        #expect(report.creditsUsed == 0)
        #expect(report.creditsTotal == 0)
        #expect(report.resetsAt == nil)
    }

    @Test
    func managedPlanKeepsMetricsWhenPresent() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        Plan: Q Developer Enterprise
        Your plan is managed by organization
        ████████████████████ 40%
        (20.00 of 50 covered in plan), resets on 03/15
        """)
        #expect(report.planName == "Q Developer Enterprise")
        #expect(report.creditsUsed == 20)
        #expect(report.creditsTotal == 50)
        #expect(report.creditsPercent == 40)
    }

    @Test
    func rejectsMissingUsageAndLoginPrompts() {
        #expect(throws: KiroUsageError.self) {
            try KiroUsageFetcher.parseCLI("Plan: Q Developer Pro")
        }
        #expect(throws: KiroUsageError.notLoggedIn) {
            try KiroUsageFetcher.parseCLI("Failed to initialize auth portal. Run kiro-cli login.")
        }
        #expect(throws: KiroUsageError.self) {
            try KiroUsageFetcher.parseCLI("Could not retrieve usage information from backend")
        }
    }

    @Test
    func parsesContextBreakdown() throws {
        let context = try #require(KiroUsageFetcher.parseContext("""
        Context window: 1.3% used (estimated)
        █ Context files 0.5% (estimated)
        █ Tools 0.8% (estimated)
        █ Kiro responses 0.0% (estimated)
        █ Your prompts 0.0% (estimated)
        """))
        #expect(context.totalPercentUsed == 1.3)
        #expect(context.contextFilesPercent == 0.5)
        #expect(context.toolsPercent == 0.8)
        #expect(context.kiroResponsesPercent == 0)
        #expect(context.promptsPercent == 0)
    }

    @Test
    func splitsPlanFromOverageWithoutDoubleCounting() throws {
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(Self.overageResponse.utf8))
        #expect(limits.planLimit == 10000)
        #expect(limits.planUsed == 10000)
        #expect(limits.overageUsed == 3603.49)
        #expect(limits.overageCap == 10000)
        #expect(limits.overageEnabled == true)
        #expect(limits.overageChargeLimit == 400)
        #expect(limits.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func rejectsImpossibleUsageLimitResponses() {
        let overageExceedsTotal = Self.overageResponse.replacingOccurrences(
            of: "\"currentUsageWithPrecision\":13603.49",
            with: "\"currentUsageWithPrecision\":100"
        )
        #expect(throws: KiroUsageError.self) {
            try KiroUsageFetcher.parseUsageLimits(Data(overageExceedsTotal.utf8))
        }

        let planExceedsLimit = Self.overageResponse.replacingOccurrences(
            of: "\"currentOveragesWithPrecision\":3603.49",
            with: "\"currentOveragesWithPrecision\":0"
        )
        #expect(throws: KiroUsageError.self) {
            try KiroUsageFetcher.parseUsageLimits(Data(planExceedsLimit.utf8))
        }

        let milliseconds = Self.overageResponse.replacingOccurrences(
            of: "1788220800",
            with: "1788220800000"
        )
        #expect(throws: KiroUsageError.self) {
            try KiroUsageFetcher.parseUsageLimits(Data(milliseconds.utf8))
        }
    }

    @Test
    func disabledOverageRemovesCapButPreservesSpentAmount() throws {
        let response = Self.overageResponse.replacingOccurrences(of: "ENABLED", with: "DISABLED")
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(response.utf8))
        #expect(limits.overageEnabled == false)
        #expect(limits.overageCap == nil)
        #expect(limits.overageUsed == 3603.49)
        #expect(limits.planUsed == 10000)
    }

    @Test
    func bonusInclusiveResponseMayExceedPlanLimit() throws {
        let response = Self.overageResponse
            .replacingOccurrences(of: "\"bonuses\":[]", with: "\"bonuses\":[{}]")
            .replacingOccurrences(
                of: "\"currentUsageWithPrecision\":13603.49",
                with: "\"currentUsageWithPrecision\":14603.49"
            )
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(response.utf8))
        #expect(limits.hasUnseparatedBonus)
        #expect(limits.planUsed == 11000)
        #expect(limits.overageUsed == 3603.49)
    }

    @Test
    func mapsPlanBonusOverageAndCostToProviderUsage() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Bonus credits: 5.00/10 credits used, expires in 7 days
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████ 100%
        Overages: Enabled billed at $0.04 per request
        """)
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(Self.overageResponse.utf8))
        let usage = KiroUsageFetcher.providerUsage(report: report, limits: limits)
        #expect(usage.windows.map(\.id) == ["kiro-credits", "kiro-bonus"])
        #expect(usage.additionalWindows.map(\.id) == ["kiro-overage"])
        #expect(abs(usage.additionalWindows[0].usedFraction - 0.360349) < 0.000001)
        #expect(usage.providerCost?.used == 144.139711109352)
        #expect(usage.providerCost?.limit == 400)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.plan == "Kiro Power")
        #expect(usage.details.contains { $0.id == "kiro-overage-left" && $0.value == "6,396.51" })
        #expect(usage.details.contains { $0.id == "kiro-overage-cost" })
    }

    @Test
    func bonusEntriesKeepAuthoritativeCLIPlanGauge() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (40.00 of 10000 covered in plan)
        ████████████████████████████████████████ 0%
        Bonus credits: 5.00/10 credits used
        Overages: Enabled billed at $0.04 per request
        """)
        let response = Self.overageResponse
            .replacingOccurrences(of: "\"bonuses\":[]", with: "\"bonuses\":[{}]")
            .replacingOccurrences(
                of: "\"currentUsageWithPrecision\":13603.49",
                with: "\"currentUsageWithPrecision\":14603.49"
            )
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(response.utf8))
        let usage = KiroUsageFetcher.providerUsage(report: report, limits: limits)
        #expect(usage.windows[0].usedFraction == 0)
        #expect(usage.windows[0].detail?.contains("9,960") == true)
        #expect(usage.additionalWindows.map(\.id) == ["kiro-overage"])
    }

    @Test
    func nonUSDCurrencyWithoutChargesDropsCLIUSDEstimate() throws {
        let report = try KiroUsageFetcher.parseCLI("""
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████ 100%
        Overages: Enabled billed at $0.04 per request
        Credits used: 40.29
        Est. cost: $1.61 USD
        """)
        let response = Self.overageResponse
            .replacingOccurrences(of: "\"currency\":\"USD\"", with: "\"currency\":\"EUR\"")
            .replacingOccurrences(of: "\"overageCharges\":144.139711109352,", with: "")
        let limits = try KiroUsageFetcher.parseUsageLimits(Data(response.utf8))
        let usage = KiroUsageFetcher.providerUsage(report: report, limits: limits)
        #expect(usage.providerCost == nil)
        #expect(usage.details.contains { $0.id == "kiro-overage-cost" } == false)
    }

    @Test
    func requestMatchesOfficialRuntimeContract() throws {
        let request = try KiroUsageFetcher.makeUsageLimitsRequest(
            identity: ("access-token", "arn:aws:codewhisperer:us-east-1:123:profile/test"),
            endpoint: KiroUsageFetcher.usageLimitsEndpoint
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "AmazonCodeWhispererService.GetUsageLimits")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        #expect(body["profileArn"] == "arn:aws:codewhisperer:us-east-1:123:profile/test")
    }

    @Test
    func resolvesBinaryAndStateDatabaseLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("kiro-cli")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(KiroUsageFetcher.resolveBinary(
            configuredCommand: nil,
            environment: ["PATH": bin.path],
            homeDirectory: root
        ) == executable.path)
        #expect(KiroUsageFetcher.resolveBinary(
            configuredCommand: executable.path,
            environment: [:],
            homeDirectory: root
        ) == executable.path)

        let mac = KiroUsageFetcher.stateDatabaseURL(
            homeDirectory: root,
            environment: [:],
            usesMacOSApplicationSupport: true
        )
        #expect(mac.path == root.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3").path)
        let override = KiroUsageFetcher.stateDatabaseURL(
            homeDirectory: root,
            environment: ["KIRO_DATA_DIR": root.appendingPathComponent("state").path],
            usesMacOSApplicationSupport: true
        )
        #expect(override.lastPathComponent == "data.sqlite3")
        #expect(override.deletingLastPathComponent().lastPathComponent == "state")
    }

    @Test
    func readsOfficialBuilderIdentityFromStateDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("data.sqlite3")
        defer { try? FileManager.default.removeItem(at: root) }

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE auth_kv (key TEXT, value TEXT);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE state (key TEXT, value TEXT);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(
            database,
            "INSERT INTO auth_kv VALUES ('kirocli:odic:token', '{\"access_token\":\"local-token\"}');",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        #expect(sqlite3_exec(
            database,
            "INSERT INTO state VALUES ('api.codewhisperer.profile', '{\"arn\":\"profile-arn\"}');",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let identity = try KiroUsageFetcher.readIdentity(databaseURL: databaseURL)
        #expect(identity.accessToken == "local-token")
        #expect(identity.profileARN == "profile-arn")
    }

    @Test
    func fetchUsesOfficialCLIAndKeepsCLIUsageWhenEnrichmentIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("kiro-cli")
        try """
        #!/bin/sh
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
          printf 'Estimated Usage | resets on 2026-09-01 | KIRO FREE\\n'
          printf 'Credits (12.50 of 50 covered in plan)\\n'
          printf '████████████████████ 25%%\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
          printf 'Context window: 7.5%% used\\n'
          exit 0
        fi
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let usage = try await KiroUsageFetcher.fetch(
            configuredCommand: executable.path,
            session: URLSession(configuration: .ephemeral),
            environment: ["PATH": root.path],
            homeDirectory: root
        )
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.plan == "Kiro Free")
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.providerCost == nil)
        #expect(usage.details.allSatisfy { $0.id != "kiro-account" && $0.id != "kiro-context" })
    }

    @Test
    func cancellationStopsAnInFlightCLIProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("kiro-cli")
        try """
        #!/bin/sh
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi
        trap '' TERM
        while true; do sleep 1; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task {
            try await KiroUsageFetcher.fetch(
                configuredCommand: executable.path,
                session: URLSession(configuration: .ephemeral),
                environment: ["PATH": root.path],
                homeDirectory: root
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
