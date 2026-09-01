import Foundation
import Testing
@testable import Yomi

struct AlibabaCodingPlanTests {
    @Test
    func parsesFiveHourWeeklyAndMonthlyQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data("""
        {
          "data": {
            "codingPlanInstanceInfos": [{"planName":"Alibaba Coding Plan Pro"}],
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota":52,"per5HourTotalQuota":1000,
              "per5HourQuotaNextRefreshTime":1700000300000,
              "perWeekUsedQuota":800,"perWeekTotalQuota":5000,
              "perWeekQuotaNextRefreshTime":1700100000000,
              "perBillMonthUsedQuota":1200,"perBillMonthTotalQuota":20000,
              "perBillMonthQuotaNextRefreshTime":1701000000000
            }
          },
          "status_code":0
        }
        """.utf8)

        let usage = try AlibabaCodingPlanFetcher.parse(data: data, now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.052, 0.16, 0.06])
        #expect(usage.windows.first?.detail == "52 / 1000 used")
        #expect(usage.plan == "Pro")
    }

    @Test
    func activeInstanceDoesNotBorrowExpiredInstanceQuota() throws {
        let data = Data("""
        {
          "data": {"codingPlanInstanceInfos": [
            {"planName":"Expired Starter","status":"EXPIRED","codingPlanQuotaInfo":{"per5HourUsedQuota":7,"per5HourTotalQuota":100}},
            {"planName":"Active Pro","status":"VALID"}
          ]},
          "status_code":0
        }
        """.utf8)

        let usage = try AlibabaCodingPlanFetcher.parse(data: data)

        #expect(usage.windows.isEmpty)
        #expect(usage.plan == "Pro")
    }

    @Test
    func inactivePlanWithoutQuotaIsRejected() {
        let data = Data(#"{"data":{"codingPlanInstanceInfos":[{"planName":"Lite","status":"EXPIRED"}]},"status_code":0}"#.utf8)
        #expect(throws: UsageCollectionError.self) {
            try AlibabaCodingPlanFetcher.parse(data: data)
        }
    }

    @Test
    func expandsWrappedConsoleJSONBody() throws {
        let inner = #"{"data":{"codingPlanInstanceInfos":[{"planName":"Coding Plan Lite","status":"VALID","codingPlanQuotaInfo":{"per5HourUsedQuota":0,"per5HourTotalQuota":1000}}]},"statusCode":200}"#
        let wrapped = try JSONSerialization.data(withJSONObject: ["successResponse": ["body": inner]])

        let usage = try AlibabaCodingPlanFetcher.parse(data: wrapped)

        #expect(usage.plan == "Lite")
        #expect(usage.windows.first?.usedFraction == 0)
    }

    @Test
    func staleFiveHourResetIsShiftedIntoFuture() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"{"data":{"codingPlanInstanceInfos":[{"planName":"Lite"}],"codingPlanQuotaInfo":{"per5HourUsedQuota":70,"per5HourTotalQuota":1200,"per5HourQuotaNextRefreshTime":1699999900000}},"status_code":0}"#.utf8)

        let usage = try AlibabaCodingPlanFetcher.parse(data: data, now: now)

        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_700_017_900))
    }

    @Test
    func catalogUsesDocumentedCredentialAliasesAndRegions() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "alibaba")]
        #expect(descriptor?.environmentKeys == [
            "ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY",
            "DASHSCOPE_API_KEY", "ALIBABA_CODING_PLAN_COOKIE",
        ])
        #expect(AlibabaCodingPlanFetcher.Region.international.currentRegionID == "ap-southeast-1")
        #expect(AlibabaCodingPlanFetcher.Region.chinaMainland.currentRegionID == "cn-beijing")
        #expect(AlibabaCodingPlanFetcher.clean("'quoted-key'") == "quoted-key")
    }
}
