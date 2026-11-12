import Foundation
import Testing
@testable import CodeEdge

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
        #expect(usage.windows.map(\.detail) == [
            AppLocalization.text("已用 250 / 2,000 点数", "250 / 2,000 credits used"),
            AppLocalization.text("已用 4,000 / 10,000 点数", "4,000 / 10,000 credits used"),
        ])
    }

    @Test
    func regionsMatchTeamAndPersonalContracts() {
        #expect(AlibabaTokenPlanFetcher.Region.allCases.map(\.rawValue) == [
            "intl", "cn", "intl-personal", "cn-personal",
        ])
        #expect(AlibabaTokenPlanFetcher.Region.international.productCode == "sfm_tokenplanteams_dp_intl")
        #expect(AlibabaTokenPlanFetcher.Region.chinaMainlandPersonal.productCode == "sfm_tokenplansolo_public_cn")
        #expect(AlibabaTokenPlanFetcher.cliArguments(region: .internationalPersonal) == [
            "console", "call", "--api", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
            "--data", "{}", "--console-region", "ap-southeast-1",
            "--console-site", "international", "--output", "json",
        ])
    }

    @Test
    func teamCLIListsSeatsWithRegionalBaseURL() {
        #expect(AlibabaTokenPlanFetcher.cliArguments(region: .chinaMainland, pageNo: 2) == [
            "token-plan", "list-seats", "--page-no", "2", "--page-size", "10", "--output", "json",
        ])
        #expect(AlibabaTokenPlanFetcher.teamBaseURL(region: .international) == "https://dashscope-intl.aliyuncs.com")
        #expect(AlibabaTokenPlanFetcher.teamBaseURL(region: .chinaMainland) == "https://dashscope.aliyuncs.com")
    }

    @Test
    func teamCreditsAggregateDistinctSeatsAndUseCycleReset() throws {
        let usage = try parseSeats([
            seat("seat-a", total: 1000, remaining: 750),
            seat("seat-b", total: 2000, remaining: 1000),
        ])
        #expect(usage.plan == "Token Plan")
        #expect(usage.windows.count == 1)
        #expect(abs(usage.windows[0].usedFraction - 1250.0 / 3000) < 0.000_001)
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: Self.cycleEnd / 1000))
        #expect(usage.windows[0].detail == AppLocalization.text("已用 1,250 / 3,000 点数", "1,250 / 3,000 credits used"))
    }

    @Test
    func differentSeatCyclesOmitAggregateReset() throws {
        let usage = try parseSeats([seat("seat-a"), seat("seat-b", cycleEnd: Self.cycleEnd + 1000)])
        #expect(usage.windows.first?.resetsAt == nil)
        #expect(usage.windows.first?.usedFraction == 0.5)
    }

    @Test
    func teamSeatsWithoutUsableCreditsFailForBrowserFallback() throws {
        let nowMilliseconds = Self.now.timeIntervalSince1970 * 1000
        #expect(throws: UsageCollectionError.self) {
            try parseSeats([
                seat("refunded", status: "REFUNDED"),
                seat("expired", end: nowMilliseconds),
                seat("future", start: nowMilliseconds + 1),
            ])
        }
        #expect(throws: UsageCollectionError.self) { try parseSeats([]) }
        #expect(throws: UsageCollectionError.self) { try parseSeats([seat("empty", total: 0, remaining: 0)]) }
        #expect(throws: UsageCollectionError.self) { try parseSeats([seat("duplicate"), seat("duplicate")]) }
        for end in [Self.cycleStart, nowMilliseconds] {
            #expect(throws: UsageCollectionError.self) { try parseSeats([seat("seat-a", cycleEnd: end)]) }
        }
        for (total, remaining) in [(-1.0, 0.0), (100.0, -1.0), (100.0, 101.0)] {
            #expect(throws: UsageCollectionError.self) {
                try parseSeats([seat("seat-a", total: total, remaining: remaining)])
            }
        }
    }

    @Test
    func resourcePacksAreNotCombinedWithCreditEquities() throws {
        var seatObject = seat("seat-a")
        var equities = try #require(seatObject["EquityList"] as? [[String: Any]])
        var resource = equities[0]
        resource["EquityType"] = "RESOURCE_PACK"
        equities.append(resource)
        seatObject["EquityList"] = equities
        let withResource = seatObject
        #expect(try parseSeats([withResource]).windows.first?.detail
            == AppLocalization.text("已用 50 / 100 点数", "50 / 100 credits used"))
        equities.append(equities[0])
        seatObject["EquityList"] = equities
        let duplicated = seatObject
        #expect(throws: UsageCollectionError.self) { try parseSeats([duplicated]) }
    }

    @Test
    func teamPagesRejectPersonalOutputFailedEnvelopesAndInconsistentPagination() throws {
        for data in try [
            Data(#"{"per1MonthPercentage":0.1}"#.utf8),
            pageData([], success: false),
            pageData([], total: 1001),
        ] {
            #expect(throws: UsageCollectionError.self) {
                try AlibabaTokenPlanFetcher.parseTeamSeatPage(data, pageNo: 1)
            }
        }
        let page = try AlibabaTokenPlanFetcher.parseTeamSeatPage(pageData([], total: 1), pageNo: 1)
        #expect(throws: UsageCollectionError.self) {
            try AlibabaTokenPlanFetcher.parseTeamSeats([page], now: Self.now)
        }
        #expect(throws: UsageCollectionError.self) {
            try AlibabaTokenPlanFetcher.parseTeamSeatPage(pageData([]), pageNo: 2)
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let cycleStart = 1_799_000_000_000.0
    private static let cycleEnd = 1_801_000_000_000.0

    private func parseSeats(_ seats: [[String: Any]]) throws -> ProviderUsage {
        let page = try AlibabaTokenPlanFetcher.parseTeamSeatPage(pageData(seats), pageNo: 1)
        return try AlibabaTokenPlanFetcher.parseTeamSeats([page], now: Self.now)
    }

    private func seat(
        _ id: String,
        total: Double = 100,
        remaining: Double = 50,
        status: String = "NORMAL",
        start: Double? = nil,
        end: Double? = nil,
        cycleEnd: Double? = nil
    ) -> [String: Any] {
        [
            "SeatId": id, "Status": status, "StartTime": start ?? Self.cycleStart,
            "EndTime": end ?? (Self.cycleEnd + 1_000_000_000),
            "EquityList": [[
                "EquityType": "CREDITS", "CycleStartTime": Self.cycleStart,
                "CycleEndTime": cycleEnd ?? Self.cycleEnd,
                "CycleTotalValue": total, "CycleSurplusValue": remaining,
            ]],
        ]
    }

    private func pageData(_ seats: [[String: Any]], total: Int? = nil, pageNo: Int = 1, success: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "Success": success,
            "Data": ["Items": seats, "Total": total ?? seats.count, "PageNo": pageNo, "PageSize": 10],
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
