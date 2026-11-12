import Foundation
import Testing
@testable import CodeEdge

struct AbliterationUsageTests {
    @Test
    func creditsBecomeUsageWindowAndBalance() throws {
        let usage = try AbliterationUsageFetcher.parse(Data(#"{"data":{"total_credits":50.0,"total_usage":12.5}}"#.utf8))

        #expect(usage.windows.map(\.id) == ["abliteration-credits"])
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.details.first { $0.id == "abliteration-balance" }?.value == "$37.50")
    }

    @Test
    func overspentBalanceStopsAtZero() throws {
        let usage = try AbliterationUsageFetcher.parse(Data(#"{"data":{"total_credits":50,"total_usage":60}}"#.utf8))

        #expect(usage.windows.first?.usedFraction == 1)
        #expect(usage.details.first { $0.id == "abliteration-balance" }?.value == "$0.00")
    }

    @Test(arguments: [
        "not-json", "{}", #"{"data":{"total_credits":50}}"#,
        #"{"data":{"total_credits":"50","total_usage":0}}"#,
        #"{"data":{"total_credits":-1,"total_usage":0}}"#,
        #"{"data":{"total_credits":50,"total_usage":true}}"#,
    ])
    func malformedCreditsFail(body: String) {
        #expect(throws: (any Error).self) { try AbliterationUsageFetcher.parse(Data(body.utf8)) }
    }
}
