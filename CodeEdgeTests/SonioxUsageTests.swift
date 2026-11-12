import Foundation
import Testing
@testable import CodeEdge

struct SonioxUsageTests {
    private static let balance = #"{"available_balance_usd":"18.50","invoice_billing_enabled":false}"#
    private static let monthly = #"{"month":"2026-10","usage_usd":"6.00","monthly_budget_usd":"100.00"}"#

    @Test
    func prepaidBalanceAndMonthlyBudget() throws {
        let usage = try SonioxUsageFetcher.parse(
            balance: Data(Self.balance.utf8), monthly: Data(Self.monthly.utf8),
            now: Date(timeIntervalSince1970: 1_792_454_400)
        )

        #expect(usage.windows.map(\.id) == ["soniox-budget"])
        #expect(usage.windows.first?.usedFraction == 0.06)
        // 预算在下个月 1 日（UTC）重置。
        #expect(usage.windows.first?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(usage.balance != nil)
    }

    @Test
    func invoiceBillingHidesBalance() throws {
        let usage = try SonioxUsageFetcher.parse(
            balance: Data(#"{"available_balance_usd":"0","invoice_billing_enabled":true}"#.utf8),
            monthly: Data(Self.monthly.utf8)
        )

        #expect(usage.balance == nil)
    }

    @Test(arguments: [
        #"{"available_balance_usd":18.5,"invoice_billing_enabled":false}"#,
        #"{"available_balance_usd":"NaN","invoice_billing_enabled":false}"#,
        #"{"available_balance_usd":"18.5","invoice_billing_enabled":"false"}"#,
    ])
    func malformedBalanceFails(balance: String) {
        #expect(throws: (any Error).self) {
            try SonioxUsageFetcher.parse(balance: Data(balance.utf8), monthly: Data(Self.monthly.utf8))
        }
    }
}
