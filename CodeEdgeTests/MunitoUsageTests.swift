import Foundation
import Testing
@testable import CodeEdge

struct MunitoUsageTests {
    private static let limits = #"{"object":"spend_limits","usage_tier":"fixture-tier","periods":["#
        + #"{"period":"day","spent_usd":4.25,"limit_usd":50,"organization_limit_usd":500,"account_limit_usd":40,"stopped_until":null},"#
        + #"{"period":"month","spent_usd":123.4,"limit_usd":1000,"organization_limit_usd":5000,"account_limit_usd":900}]}"#

    @Test
    func dayAndMonthLimitsBecomeSpendWindows() throws {
        let organization: [String: Any] = ["name": "Fixture Org", "status": "active", "data_region": "eu"]
        let usage = try MunitoUsageFetcher.parse(Data(Self.limits.utf8), organization: organization)

        #expect(usage.windows.map(\.id) == ["munito-day", "munito-month"])
        #expect(usage.windows.first?.usedFraction == 0.085)
        #expect(abs((usage.windows.last?.usedFraction ?? 0) - 0.1234) < 0.000_001)
        #expect(usage.plan == "Fixture Org")
        #expect(usage.details.contains { $0.id == "munito-region" && $0.value == "eu" })
    }

    @Test
    func periodsWithoutLimitsKeepSpendRowsOnly() throws {
        let body = #"{"object":"spend_limits","periods":[{"period":"day","spent_usd":2,"limit_usd":null},"#
            + #"{"period":"month","spent_usd":"12.75","limit_usd":0}]}"#
        let usage = try MunitoUsageFetcher.parse(Data(body.utf8))

        #expect(usage.windows.isEmpty)
        #expect(usage.details.map(\.id).prefix(2) == ["munito-day", "munito-month"])
    }
}
