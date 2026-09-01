import Foundation
import Testing
@testable import Yomi

struct ProviderUsageCodingTests {
    @Test
    func olderCacheWithoutNewCollectionsStillDecodes() throws {
        let data = Data(#"{"id":"codex","state":"ready","windows":[]}"#.utf8)
        let usage = try JSONDecoder().decode(ProviderUsage.self, from: data)
        #expect(usage.id.rawValue == "codex")
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)
        #expect(usage.commandCodeSubscriptionEnrichmentUnavailable == false)
    }

    @Test
    func commandCodeLiveMarkersAreNeverPersisted() throws {
        let usage = ProviderUsage(
            id: ProviderID(rawValue: "commandcode"),
            state: .ready,
            windows: [],
            commandCodeSubscriptionEnrichmentUnavailable: true,
            commandCodeHasSubscriptionPlan: true,
            commandCodeMonthlyGrantDepleted: true
        )
        let data = try JSONEncoder().encode(usage)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["commandCodeSubscriptionEnrichmentUnavailable"] == nil)
        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: data)
        #expect(decoded.commandCodeSubscriptionEnrichmentUnavailable == false)
        #expect(decoded.commandCodeHasSubscriptionPlan == false)
        #expect(decoded.commandCodeMonthlyGrantDepleted == false)
    }
}
