import Foundation
import Testing
@testable import Yomi

struct OpenCodeGoUsageTests {
    @Test
    func parsesAuthoritativeAPIWindowsAsPercentUnits() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"{"usage":{"rolling":{"usagePercent":0.25,"resetInSec":600},"weekly":{"usagePercent":75,"resetInSec":7200},"monthly":{"usagePercent":90,"resetInSec":86400}}}"#.utf8)

        let usage = try OpenCodeGoUsageFetcher.parseAPI(data: data, now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.0025, 0.75, 0.9])
    }

    @Test
    func parsesWebFractionsAndOptionalMonthlyWindow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "usage": [
                "rollingUsage": ["usagePercent": 0.25, "resetInSec": 600],
                "weeklyUsage": ["window": ["usagePercent": 0.75, "resetInSec": 7200]],
            ],
        ])

        let usage = try OpenCodeGoUsageFetcher.parseWeb(text: String(decoding: data, as: UTF8.self), now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.75])
    }

    @Test
    func parsesHydrationPayloadWithAllThreeWindows() throws {
        let text = "$R[24]($R[18],$R[27]={rollingUsage:$R[28]={resetInSec:17591,usagePercent:17},"
            + "weeklyUsage:$R[29]={resetInSec:444552,usagePercent:75},"
            + "monthlyUsage:$R[30]={resetInSec:2591424,usagePercent:91}});"

        let usage = try OpenCodeGoUsageFetcher.parseWeb(text: text, now: .distantPast)

        #expect(usage.windows.map(\.usedFraction) == [0.17, 0.75, 0.91])
    }

    @Test
    func parsesExplicitAndScaledZenBalances() {
        #expect(OpenCodeGoUsageFetcher.parseZenBalance(text: "現在の残高 $1,234.56") == 1234.56)
        let billing = #"$R[0]={customerID:"cus_test",balance:$R[2]=2375000000,reload:!1}"#
        #expect(OpenCodeGoUsageFetcher.parseBillingBalance(text: billing) == 23.75)
        #expect(OpenCodeGoUsageFetcher.parseBillingBalance(text: #"{"balance":100}"#) == nil)
    }

    @Test
    func normalizesDocumentedAPIKeyEnvironmentFormat() {
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("  go_test  ") == "go_test")
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("'go_quoted'") == "go_quoted")
        #expect(OpenCodeGoUsageFetcher.normalizeAPIKey("  ").isEmpty)
        #expect(ProviderCatalog.byID[ProviderID(rawValue: "opencodego")]?.environmentKeys == ["OPENCODE_API_KEY"])
    }

    @Test
    func renewalIsAdditionalMetadataNotQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let renewal = "2030-01-02T03:04:05.000Z"
        let data = Data(#"{"renewAt":"\#(renewal)","usage":{"rolling":{"usagePercent":10,"resetInSec":600}}}"#.utf8)

        let usage = try OpenCodeGoUsageFetcher.parseAPI(data: data, now: now)

        #expect(usage.windows.count == 1)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func localDatabaseRowsOnlyAddVerifiableCostAndRequestCounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = ProviderUsage(
            id: ProviderID(rawValue: "opencodego"), state: .ready,
            windows: [UsageWindow(
                id: "opencodego-rolling", label: "5-hour", usedFraction: 0.2,
                resetsAt: nil, detail: nil
            )],
            updatedAt: now
        )
        let rows = OpenCodeGoLocalUsageReader.parseRows(
            "1799996400000\t1.25\t2\n1797580800000\t3.50\t1\ninvalid\trow\t0\n"
        )

        let enriched = OpenCodeGoLocalUsageReader.enrich(original, rows: rows, now: now)

        #expect(enriched.windows == original.windows)
        #expect(enriched.today?.tokens == 2)
        #expect(enriched.today?.valueUSD == 1.25)
        #expect(enriched.last30Days?.tokens == 3)
        #expect(enriched.last30Days?.valueUSD == 4.75)
    }
}
