import Foundation
import Testing
@testable import Yomi

struct AlibabaTokenPlanTests {
    @Test
    func parsesCLIWindowsAsRatios() throws {
        let data = Data(#"{"per5HourPercentage":0.25,"per5HourResetTime":1700000000000,"per1WeekPercentage":0.6,"per1WeekResetTime":1700100000000}"#.utf8)
        let usage = try AlibabaTokenPlanFetcher.parseCLI(data: data)
        #expect(usage.windows.map(\.label) == ["5-hour", "7-day"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.6])
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func rejectsCLIPercentagePointsInsteadOfRatios() {
        let data = Data(#"{"per5HourPercentage":25}"#.utf8)
        #expect(throws: UsageCollectionError.self) {
            try AlibabaTokenPlanFetcher.parseCLI(data: data)
        }
    }

    @Test
    func parsesTeamSubscriptionCredits() throws {
        let data = Data(#"{"code":"200","successResponse":true,"data":{"Data":{"EquityList":[{"ProductName":"Team Pro","TotalValue":"10000","TotalSurplusValue":"6250","CycleEndTime":1701000000000}],"TotalCount":1}}}"#.utf8)
        let usage = try AlibabaTokenPlanFetcher.parseTeam(data: data)
        #expect(usage.plan == "Team Pro")
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.375)
        #expect(usage.windows[0].detail == "3,750 / 10,000 credits used")
    }

    @Test
    func parsesPersonalRollingWindowsAndQuotaDetails() throws {
        let usageData = Data(#"{"successResponse":true,"data":{"per5HourPercentage":0.125,"per5HourResetTime":1700000000000,"per1WeekPercentage":0.4,"per1WeekResetTime":1700100000000}}"#.utf8)
        let subscription = Data(#"{"data":{"specCode":"pro"}}"#.utf8)
        let quota = Data(#"{"data":{"pro":{"five_hour":2000,"weekly":10000}}}"#.utf8)
        let usage = try AlibabaTokenPlanFetcher.parsePersonal(
            usageData: usageData, subscriptionData: subscription, quotaConfigData: quota
        )
        #expect(usage.plan == "Pro")
        #expect(usage.windows.map(\.usedFraction) == [0.125, 0.4])
        #expect(usage.windows.map(\.detail) == ["250 / 2,000 credits used", "4,000 / 10,000 credits used"])
    }

    @Test
    func regionsMatchTeamAndPersonalContracts() {
        #expect(AlibabaTokenPlanFetcher.Region.allCases.map(\.rawValue) == [
            "intl", "cn", "intl-personal", "cn-personal",
        ])
        #expect(AlibabaTokenPlanFetcher.Region.international.productCode == "sfm_tokenplanteams_dp_intl")
        #expect(AlibabaTokenPlanFetcher.Region.chinaMainlandPersonal.productCode == "sfm_tokenplansolo_public_cn")
        #expect(AlibabaTokenPlanFetcher.cliArguments(region: .internationalPersonal) == [
            "usage", "token-plan", "--console-region", "ap-southeast-1",
            "--console-site", "international", "--output", "json",
        ])
    }

    @Test
    func catalogDoesNotAdvertiseUnsupportedAPIKey() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "alibabatokenplan")]
        #expect(descriptor?.preferredSources == [.command, .cookie])
        #expect(descriptor?.environmentKeys == ["ALIBABA_TOKEN_PLAN_COOKIE"])
    }

    @Test
    func extractsAllSupportedSECTokenSpellings() {
        #expect(AlibabaTokenPlanFetcher.extractSECToken(#"{"secToken":"abc"}"#) == "abc")
        #expect(AlibabaTokenPlanFetcher.extractSECToken("var x = { sec_token: 'def' };") == "def")
        #expect(AlibabaTokenPlanFetcher.extractSECToken("SEC_TOKEN: \"ghi\"") == "ghi")
    }
}
