import Foundation
import Testing
@testable import Yomi

struct ManusUsageTests {
    @Test
    func parsesSparseCreditsAndCreatesTwoRealWindows() throws {
        let data = Data(#"{"totalCredits":2869,"freeCredits":1500,"periodicCredits":1369,"proMonthlyCredits":4000,"maxRefreshCredits":300,"nextRefreshTime":"2026-04-13T00:00:00Z","refreshInterval":"daily"}"#.utf8)
        let credits = try ManusUsageFetcher.parse(data: data)
        let usage = ManusUsageFetcher.providerUsage(credits: credits)
        #expect(usage.windows.map(\.label) == ["Monthly credits", "Daily refresh"])
        #expect(abs(usage.windows[0].usedFraction - 0.65775) < 0.000_001)
        #expect(usage.windows[0].detail == "Total 2,869 • Free 1,500")
        #expect(usage.windows[1].usedFraction == 1)
        #expect(usage.windows[1].detail == "Daily: 0 / 300")
        #expect(usage.balance == "2,869 credits")
        #expect(usage.plan == nil)
    }

    @Test
    func acceptsWrappedAndStringValues() throws {
        let data = Data(#"{"data":{"totalCredits":"100","proMonthlyCredits":"200","periodicCredits":"50","maxRefreshCredits":"10","refreshCredits":"5"}}"#.utf8)
        let credits = try ManusUsageFetcher.parse(data: data)
        #expect(credits.totalCredits == 100)
        #expect(credits.periodicCredits == 50)
        #expect(credits.refreshCredits == 5)
    }

    @Test
    func rejectsUnrelatedPayloadInsteadOfShowingZeroCredits() {
        #expect(throws: UsageCollectionError.self) {
            try ManusUsageFetcher.parse(data: Data(#"{"error":"unauthorized"}"#.utf8))
        }
    }

    @Test
    func tokenParsesBareValueAndCookieHeader() {
        #expect(ManusUsageFetcher.token(from: "bare-token") == "bare-token")
        #expect(ManusUsageFetcher.token(from: "foo=bar; session_id=the-token; baz=qux") == "the-token")
        #expect(ManusUsageFetcher.token(from: "foo=bar") == nil)
    }

    @Test
    func environmentAliasesMatchProviderContract() {
        #expect(ManusUsageFetcher.environmentToken(["MANUS_SESSION_ID": "session_id=abc"]) == "abc")
        #expect(ManusUsageFetcher.environmentToken(["manus_cookie": "session_id=lower"]) == "lower")
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "manus")]
        #expect(descriptor?.preferredSources == [.cookie])
        #expect(descriptor?.environmentKeys == ["MANUS_SESSION_TOKEN", "MANUS_SESSION_ID", "MANUS_COOKIE"])
    }
}
