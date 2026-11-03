import Foundation
import Testing
@testable import Yomi

struct GeminiAppUsageTests {
    @Test
    func parsesFiveHourAndWeeklyPools() throws {
        let body = """
        )]}'
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[
          {"poolType":"GXU_WEEKLY","percentageUsed":0.4,"gxu":{"windowRefreshesAt":"2026-11-10T00:00:00Z"}},
          {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.125},
          {"poolType":"OTHER","percentageUsed":0.9}
        ]}}}}}]
        """

        let usage = try #require(try GeminiAppUsageFetcher.parse(body))

        #expect(usage.windows.map(\.id) == ["gemini-app-5h", "gemini-app-weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.125, 0.4])
        #expect(usage.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
        #expect(usage.plan == "Pro")
    }

    @Test
    func signedOutViewerMeansTryNextSession() throws {
        #expect(try GeminiAppUsageFetcher.parse(#"[{"data":{"viewer":null}}]"#) == nil)
    }

    @Test
    func missingPoolsAreReportedInsteadOfInventingQuota() {
        #expect(throws: GeminiAppUsageFetcher.FetchError.noWindows) {
            try GeminiAppUsageFetcher.parse(#"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[]}}}}}]"#)
        }
    }

    @Test
    func usageURLCarriesEncodedQuerySignature() {
        let query = GeminiAppUsageFetcher.usageURL.query ?? ""
        #expect(query.contains("query_signature=2%2FdWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g%3D"))
        #expect(query.contains("variables=%7B%22g1Request%22"))
    }
}
