import Foundation
import Testing
@testable import Yomi

@Suite("TypeSafe usage", .serialized)
struct TypeSafeUsageTests {
    private static let body = #"""
    {"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"00000000-0000-4000-8000-000000000001","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"},{"id":"00000000-0000-4000-8000-000000000002","amount":2,"remaining":0,"expiresAt":"2026-10-19T00:00:00Z"}]},"payments":[],"credits":[],"hasMore":false}
    """#

    @Test
    func billingOverviewMapsSpendBalancePlanAndActiveCredits() throws {
        let usage = try TypeSafeUsageFetcher.parse(Self.body)

        #expect(usage.providerCost?.used == 0.01)
        #expect(usage.providerCost?.balance == 4.98)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "September 2026")
        #expect(usage.windows.isEmpty)
        #expect(usage.balance == "$4.98")
        #expect(usage.plan == AppLocalization.text("免费", "Free"))
        #expect(usage.details.count == 1)
    }

    @Test
    func missingBillingObjectOrInvalidJSONFailsParsing() {
        #expect(throws: TypeSafeUsageError.parseFailed) {
            try TypeSafeUsageFetcher.parse(#"{"payments":[],"credits":[]}"#)
        }
        #expect(throws: TypeSafeUsageError.parseFailed) {
            try TypeSafeUsageFetcher.parse("not json")
        }
        let malformed = Self.body.replacingOccurrences(of: #""balance":4.98"#, with: #""balance":"bad""#)
        #expect(throws: TypeSafeUsageError.parseFailed) {
            try TypeSafeUsageFetcher.parse(malformed)
        }
    }

    @Test
    func loginLandingPageIsSessionExpiryAndOtherHTMLIsIntegrationFailure() {
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.parse("<html><title>TypeSafe</title><body>Sign in to continue</body></html>")
        }
        #expect(throws: TypeSafeUsageError.billingUnavailable) {
            try TypeSafeUsageFetcher.parse("<html>Billing moved</html>")
        }
    }

    @Test
    func onlyLoginRedirectsAndUnauthorizedResponsesExpireTheSession() throws {
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.validate(status: 307, location: "https://console.typesafe.ai/login?next=%2Fbilling")
        }
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.validate(status: 302, location: "https://accounts.example.com/")
        }
        #expect(throws: TypeSafeUsageError.billingUnavailable) {
            try TypeSafeUsageFetcher.validate(status: 307, location: "https://console.typesafe.ai/billing/")
        }
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.validate(status: 401, location: nil)
        }
        #expect(throws: TypeSafeUsageError.sessionExpired) {
            try TypeSafeUsageFetcher.validate(status: 403, location: nil)
        }
        #expect(throws: (any Error).self) {
            try TypeSafeUsageFetcher.validate(status: 404, location: nil)
        }
        try TypeSafeUsageFetcher.validate(status: 200, location: nil)
    }
}
