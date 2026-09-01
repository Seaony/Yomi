import Foundation
import Testing
@testable import Yomi

@Suite("Augment usage")
struct AugmentUsageTests {
    @Test func parsesCurrentCLIOutput() throws {
        let output = """
        319,054 credits remaining                     Max Plan
        450,000 credits / month
        9 days remaining in this billing cycle (ends 6/9/2026)
        """
        let snapshot = try AugmentUsageFetcher.parseCLI(output, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(snapshot.remaining == 319_054)
        #expect(snapshot.used == 130_946)
        #expect(snapshot.limit == 450_000)
        #expect(snapshot.resetsAt != nil)
    }

    @Test func parsesLegacyCLIOutput() throws {
        let output = """
        Max Plan 450,000 credits / month
        11,657 remaining · 953,170 / 964,827 credits used
        2 days remaining in this billing cycle (ends 1/8/2026)
        """
        let snapshot = try AugmentUsageFetcher.parseCLI(output)
        #expect(snapshot.remaining == 11_657)
        #expect(snapshot.used == 953_170)
        #expect(snapshot.limit == 964_827)
    }

    @Test func webUsesAvailableLimitAndSubscriptionPlan() throws {
        let credits = Data(#"{"usageUnitsRemaining":75,"usageUnitsConsumedThisBillingCycle":25,"usageUnitsAvailable":100,"usageBalanceStatus":"active"}"#.utf8)
        let subscription = Data(#"{"planName":"Pro","billingPeriodEnd":"2026-10-01T00:00:00Z","email":"person@example.com","organization":"Acme"}"#.utf8)
        let usage = AugmentUsageFetcher.providerUsage(
            try AugmentUsageFetcher.parseWeb(creditsData: credits, subscriptionData: subscription)
        )
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].detail == "25/100 credits")
        #expect(usage.plan == "Pro")
        #expect(usage.details.isEmpty)
    }

    @Test func webDerivesLimitWhenAvailableIsMissing() throws {
        let data = Data(#"{"usageUnitsRemaining":70,"usageUnitsConsumedThisBillingCycle":30}"#.utf8)
        let snapshot = try AugmentUsageFetcher.parseWeb(creditsData: data, subscriptionData: nil)
        #expect(snapshot.limit == 100)
        #expect(snapshot.used == 30)
    }

    @Test func unrelatedWebPayloadDoesNotCreateZeroQuota() {
        #expect(throws: (any Error).self) {
            try AugmentUsageFetcher.parseWeb(creditsData: Data(#"{"status":"ok"}"#.utf8), subscriptionData: nil)
        }
    }

    @Test func normalizesCookieAndCurlHeader() {
        #expect(AugmentUsageFetcher.normalizedCookie("session=abc; foo=bar") == "session=abc; foo=bar")
        #expect(AugmentUsageFetcher.normalizedCookie("-H 'Cookie: session=abc; foo=bar'") == "session=abc; foo=bar")
        #expect(AugmentUsageFetcher.normalizedCookie("not-a-cookie") == nil)
    }

    @Test func authenticationFailureIsNotParsedAsUsage() {
        #expect(throws: AugmentUsageError.cliNotAuthenticated) {
            try AugmentUsageFetcher.parseCLI("Authentication failed. Run auggie login")
        }
    }

    @Test func catalogMatchesCLIAndCookieContract() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "augment")]
        #expect(descriptor?.preferredSources == [.account, .cookie])
        #expect(descriptor?.environmentKeys.isEmpty == true)
    }
}
