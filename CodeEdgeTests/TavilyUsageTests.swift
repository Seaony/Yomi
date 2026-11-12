import Foundation
import Testing
@testable import CodeEdge

struct TavilyUsageTests {
    @Test
    func nullPayAsYouGoLimitShowsOnlyUsage() throws {
        let data = Data(#"{"account":{"plan_usage":10,"plan_limit":100,"paygo_usage":3,"paygo_limit":null},"key":{"usage":5,"limit":null}}"#.utf8)

        let usage = try TavilyUsageFetcher.parse(data)

        let ids = usage.details.map(\.id)
        #expect(ids.contains("tavily-paygo-used"))
        #expect(!ids.contains("tavily-paygo-limit"))
        #expect(!ids.contains("tavily-paygo-remaining"))
        #expect(ids.contains("tavily-key-limit"))
    }

    @Test
    func malformedPayAsYouGoLimitStillFails() {
        let data = Data(#"{"account":{"plan_usage":10,"plan_limit":100,"paygo_usage":3,"paygo_limit":"x"},"key":{"usage":5,"limit":null}}"#.utf8)

        #expect(throws: TavilyUsageError.parseFailed) {
            try TavilyUsageFetcher.parse(data)
        }
    }
}
