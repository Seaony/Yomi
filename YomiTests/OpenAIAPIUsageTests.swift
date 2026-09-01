import Foundation
import Testing
@testable import Yomi

struct OpenAIAPIUsageTests {
    @Test
    func parsesAdminCostsAndCompletionUsageWithoutQuotaWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_050_000)
        let costs = Data("""
        {
          "data": [{
            "start_time": 1700000000,
            "end_time": 1700086400,
            "results": [
              {"amount": {"value": "1.25", "currency": "usd"}, "line_item": "Text tokens"}
            ]
          }],
          "has_more": false,
          "next_page": null
        }
        """.utf8)
        let completions = Data("""
        {
          "data": [{
            "start_time": 1700000000,
            "end_time": 1700086400,
            "results": [{
              "input_tokens": 100,
              "input_cached_tokens": 25,
              "input_audio_tokens": 10,
              "output_tokens": 50,
              "output_audio_tokens": 5,
              "num_model_requests": 3,
              "model": "gpt-test"
            }]
          }],
          "has_more": false,
          "next_page": null
        }
        """.utf8)

        let snapshot = try OpenAIAPIUsageFetcher.parseAdminUsage(
            costsData: costs,
            completionsData: completions,
            now: now,
            projectID: "proj_test"
        )

        #expect(snapshot.history.costUSD == 1.25)
        #expect(snapshot.history.requests == 3)
        #expect(snapshot.history.inputTokens == 110)
        #expect(snapshot.history.cachedInputTokens == 25)
        #expect(snapshot.history.outputTokens == 55)
        #expect(snapshot.history.totalTokens == 165)
        #expect(snapshot.projectID == "proj_test")
        #expect(snapshot.topModel?.name == "gpt-test")
    }

    @Test
    func rejectsMalformedAdminCostResponse() {
        #expect(throws: OpenAIAPIUsageError.malformedResponse(endpoint: "costs")) {
            _ = try OpenAIAPIUsageFetcher.parseAdminUsage(
                costsData: Data("{}".utf8),
                completionsData: Data("{\"data\":[],\"has_more\":false}".utf8),
                now: Date()
            )
        }
    }

    @Test
    func catalogPrefersAdminKeyBeforeLegacyAPIKey() throws {
        let descriptor = try #require(ProviderCatalog.byID[ProviderID(rawValue: "openai")])
        #expect(descriptor.environmentKeys == ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"])
    }
}
