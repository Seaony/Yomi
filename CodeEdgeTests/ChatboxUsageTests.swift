import Foundation
import Testing
@testable import CodeEdge

struct ChatboxUsageTests {
    private static let fixture = #"""
    {"data":{"key":"private-response-key","name":"Chatbox AI Pro","plan":"pro","status":"active",
    "unified_token_usage":300,"unified_token_limit":1500,
    "unified_token_usage_details":[{"type":"plan","token_usage":200,"token_limit":1000},
    {"type":"invitation_reward","token_usage":100,"token_limit":500}],
    "aggregated_reward_details":{"token_usage":100,"token_limit":500},
    "expansion_pack_usage":50,"expansion_pack_limit":400,"image_used_count":3,"image_total_quota":20,
    "token_refreshed_time":"2026-10-01T00:00:00Z","token_next_refresh_time":"2026-11-01T00:00:00Z",
    "token_expire_time":"2027-01-01T00:00:00Z"}}
    """#
    private static let now = Date(timeIntervalSince1970: 1_792_454_400)

    @Test
    func planAndTopUpPoolsBecomeWindows() throws {
        let usage = try ChatboxUsageFetcher.parse(Data(Self.fixture.utf8), now: Self.now)

        #expect(usage.plan == "Chatbox AI Pro")
        #expect(usage.windows.map(\.id) == ["chatbox-plan", "chatbox-top-up"])
        #expect(usage.windows.first?.usedFraction == 0.2)
        #expect(usage.windows.first?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(usage.windows.last?.usedFraction == 0.125)
        #expect(usage.details.first { $0.id == "chatbox-plan" }?.value == "800 / 1,000")
        #expect(usage.details.first { $0.id == "chatbox-images" }?.value == "17 / 20")
        #expect(!usage.details.contains { $0.value.contains("private-response-key") })
    }

    @Test
    func expiredSubscriptionHasNoPlanWindow() throws {
        let expired = Self.fixture.replacingOccurrences(of: "2027-01-01T00:00:00Z", with: "2026-10-10T00:00:00Z")
        let usage = try ChatboxUsageFetcher.parse(Data(expired.utf8), now: Self.now)

        #expect(usage.windows.map(\.id) == ["chatbox-top-up"])
    }

    @Test
    func fractionalCounterFails() {
        let body = #"{"data":{"unified_token_usage":1.5,"unified_token_limit":10}}"#
        #expect(throws: ChatboxUsageError.parseFailure) { try ChatboxUsageFetcher.parse(Data(body.utf8)) }
    }
}
