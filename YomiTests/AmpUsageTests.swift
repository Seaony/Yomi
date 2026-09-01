import Foundation
import Testing
@testable import Yomi

@Suite("Amp usage")
struct AmpUsageTests {
    @Test func parsesLegacyFreeCreditsAndIdentity() throws {
        let output = """
        \u{001B}[2mSigned in as user@example.com (team)\u{001B}[0m
        Amp Free: $4.71/$10 remaining (replenishes +$0.42/hour)
        Individual credits: $25.64 remaining
        Workspace Alpha Team: $1,234.56 remaining
        """
        let snapshot = try AmpUsageFetcher.parseDisplayText(output)
        let usage = AmpUsageFetcher.providerUsage(snapshot)

        #expect(snapshot.freeQuota == 10)
        #expect(abs((snapshot.freeUsed ?? 0) - 5.29) < 0.001)
        #expect(snapshot.hourlyReplenishment == 0.42)
        #expect(snapshot.windowHours == 24)
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountOrganization == "team")
        #expect(snapshot.workspaceBalances == [.init(name: "Alpha Team", remaining: 1234.56)])
        #expect(usage.windows.map(\.label) == ["Amp Free"])
        #expect(abs(usage.windows[0].usedFraction - 0.529) < 0.001)
        #expect(usage.details.first(where: { $0.id == "amp-individual-credits" })?.value == "$25.64")
        #expect(usage.details.first(where: { $0.id == "amp-workspace-0" })?.label == "Workspace credits")
        #expect(usage.details.first(where: { $0.id == "amp-workspace-0" })?.value == "$1,234.56")
    }

    @Test func dailyFreeUsesNewYorkEightPMReset() throws {
        let now = try date("2026-08-03T23:59:59Z")
        let snapshot = try AmpUsageFetcher.parseDisplayText(
            "Amp Free: 61% remaining today (resets daily)",
            now: now
        )
        let usage = AmpUsageFetcher.providerUsage(snapshot, now: now)

        #expect(snapshot.freeUsed == 39)
        #expect(usage.windows[0].usedFraction == 0.39)
        #expect(try usage.windows[0].resetsAt == date("2026-08-04T00:00:00Z"))
        #expect(snapshot.freeResetDescription == "resets daily")
    }

    @Test func percentageWithoutResetTextDoesNotInventReset() throws {
        let snapshot = try AmpUsageFetcher.parseDisplayText("Amp Free: 61% remaining")
        let usage = AmpUsageFetcher.providerUsage(snapshot)
        #expect(snapshot.freeResetDescription == nil)
        #expect(usage.windows[0].resetsAt == nil)
    }

    @Test func subscriptionCreatesOtherOrbAndSeparateFreeWindows() throws {
        let now = try date("2026-08-24T12:00:00Z")
        let output = """
        Signed in as you@example.com (name)
        **Amp Free:** 0% remaining today (resets daily)
        **Amp Megawatt Subscription:** 68% other usage and 97% orb usage remaining - resets upon renewal in 5 days
        **Individual credits:** $3.23 remaining
        """
        let usage = AmpUsageFetcher.providerUsage(
            try AmpUsageFetcher.parseDisplayText(output, now: now),
            now: now
        )

        #expect(usage.windows.map(\.label) == ["Other usage", "Orb usage"])
        #expect(usage.windows.map(\.usedFraction) == [0.32, 0.03])
        #expect(usage.additionalWindows.map(\.label) == ["Amp Free"])
        #expect(usage.additionalWindows[0].usedFraction == 1)
        #expect(usage.plan == "Megawatt")
        #expect(usage.windows[0].resetsAt == now.addingTimeInterval(5 * 24 * 60 * 60))
    }

    @Test func parsesLegacySubscriptionFormatAndCalendarMonth() throws {
        let now = try date("2026-08-18T12:00:00Z")
        let snapshot = try AmpUsageFetcher.parseDisplayText(
            "Subscription Gigawatt: 73% other usage and 91% orb usage remaining - resets upon renewal in 1 month",
            now: now
        )
        #expect(snapshot.subscription?.plan == "Gigawatt")
        #expect(snapshot.subscription?.otherUsedFraction == 0.27)
        #expect(snapshot.subscription?.orbUsedFraction == 0.09)
        #expect(try snapshot.subscription?.resetsAt == date("2026-09-18T12:00:00Z"))
    }

    @Test func legacyFreeWinsWhenBothFormatsExist() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try AmpUsageFetcher.parseDisplayText("""
        Amp Free: $6/$10 remaining (replenishes +$0.5/hour)
        Amp Free: 61% remaining today (resets daily)
        """, now: now)
        let usage = AmpUsageFetcher.providerUsage(snapshot, now: now)
        #expect(snapshot.freeUsed == 4)
        #expect(snapshot.freeResetDescription == nil)
        #expect(usage.windows[0].resetsAt == now.addingTimeInterval(8 * 60 * 60))
    }

    @Test func creditsOnlyDoesNotCreateQuotaWindow() throws {
        let usage = AmpUsageFetcher.providerUsage(
            try AmpUsageFetcher.parseDisplayText("Individual credits: $12.50 remaining")
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == nil)
        #expect(usage.details.map(\.label) == ["Individual credits"])
    }

    @Test func parsesCurrentAPIResponseWithoutLosingBalances() throws {
        let displayText = """
        Signed in as api@example.com (team)
        Amp Free: $8/$10 remaining (replenishes +$0.5/hour)
        Individual credits: $12.50 remaining
        Workspace Beta: $7 remaining
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": ["displayText": displayText],
        ])
        let snapshot = try AmpUsageFetcher.parseAPIResponse(data)
        #expect(snapshot.freeUsed == 2)
        #expect(snapshot.individualCredits == 12.5)
        #expect(snapshot.workspaceBalances == [.init(name: "Beta", remaining: 7)])
        #expect(snapshot.accountEmail == "api@example.com")
    }

    @Test func APIRequestUsesExactRPCAndBearerAuthentication() throws {
        let request = try AmpUsageFetcher.makeAPIRequest(token: "sgamp_test")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request.url?.absoluteString == "https://ampcode.com/api/internal?userDisplayBalanceInfo")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sgamp_test")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(object["method"] as? String == "userDisplayBalanceInfo")
        #expect(object["params"] is [String: Any])
    }

    @Test func accountSourceRunsAmpUsageCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("amp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        [ "$1" = "usage" ] || exit 2
        printf '%s\n' 'Signed in as cli@example.com (team)' 'Amp Free: $6/$10 remaining (replenishes +$0.5/hour)'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let usage = try await AmpUsageFetcher.fetch(
            credential: "",
            source: .account,
            session: URLSession(configuration: .ephemeral),
            environment: ["AMP_CLI_PATH": executable.path]
        )
        #expect(usage.windows.map(\.label) == ["Amp Free"])
        #expect(usage.windows[0].usedFraction == 0.4)
        #expect(usage.details.isEmpty)
    }

    @Test func APIAuthErrorIsNotParsedAsUsage() {
        let data = Data(#"{"ok":false,"error":{"code":"auth-required","message":"Sign in"}}"#.utf8)
        #expect(throws: AmpUsageError.invalidAPIToken) {
            try AmpUsageFetcher.parseAPIResponse(data)
        }
    }

    @Test func parsesLegacySettingsHTMLOnlyFromUsageObject() throws {
        let html = """
        <script>
        data = {freeTierUsage:{bucket:"ubi",quota:1000,hourlyReplenishment:42,windowHours:24,used:338.5}};
        </script>
        """
        let snapshot = try AmpUsageFetcher.parseLegacyHTML(html)
        #expect(snapshot.freeQuota == 1000)
        #expect(snapshot.freeUsed == 338.5)
        #expect(snapshot.hourlyReplenishment == 42)
        #expect(snapshot.windowHours == 24)
    }

    @Test func missingOrSignedOutHTMLDoesNotCreateZeroQuota() {
        #expect(throws: AmpUsageError.parseFailed("Missing Amp Free usage data")) {
            try AmpUsageFetcher.parseLegacyHTML("<html>No usage here</html>")
        }
        #expect(throws: AmpUsageError.notLoggedIn) {
            try AmpUsageFetcher.parseLegacyHTML("<html>Please sign in to Amp</html>")
        }
    }

    @Test func manualCookieKeepsOnlySessionAndRejectsUnrelatedValues() {
        #expect(AmpUsageFetcher.sessionCookieHeader("Cookie: other=x; session=abc; theme=dark") == "session=abc")
        #expect(AmpUsageFetcher.sessionCookieHeader("-H 'Cookie: session=abc; other=x'") == "session=abc")
        #expect(AmpUsageFetcher.sessionCookieHeader("other=x") == nil)
    }

    @Test func cookiesAreRestrictedToSecureAmpHostsAndLoginRoutesAreDetected() throws {
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://app.ampcode.com/path")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "http://ampcode.com/settings")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://ampcode.com.evil.test")))
        #expect(AmpUsageFetcher.isLoginRedirect(
            URL(string: "https://ampcode.com/auth/sign-in?returnTo=%2Fsettings")
        ))
        #expect(!AmpUsageFetcher.isLoginRedirect(URL(string: "https://ampcode.com/settings")))
    }

    @Test func environmentTokenIsTrimmedAndUnquotedAndCLIOverrideIsResolved() {
        #expect(AmpUsageFetcher.resolvedAPIToken(
            configured: "",
            environment: ["AMP_API_KEY": " 'sgamp_test' "]
        ) == "sgamp_test")
        #expect(AmpUsageFetcher.resolvedAPIToken(
            configured: "session=cookie",
            environment: [:]
        ) == nil)
        #expect(AmpUsageFetcher.executable(environment: ["AMP_CLI_PATH": "/bin/sh"])?.path == "/bin/sh")
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
