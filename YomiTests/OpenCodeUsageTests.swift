import Foundation
import Testing
@testable import Yomi

struct OpenCodeUsageTests {
    @Test
    func parsesSubscriptionServerPayload() throws {
        let text = "$R[16]($R[30],$R[41]={rollingUsage:$R[42]={status:\"ok\",resetInSec:5944,usagePercent:17},"
            + "weeklyUsage:$R[43]={status:\"ok\",resetInSec:278201,usagePercent:75}});"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let usage = try OpenCodeUsageFetcher.parseSubscription(text: text, now: now)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.17, 0.75])
        #expect(usage.windows[0].resetsAt == now.addingTimeInterval(5944))
        #expect(usage.windows[1].resetsAt == now.addingTimeInterval(278_201))
    }

    @Test
    func parsesJSONFractionsAndRenewalSeparately() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let renewsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try JSONSerialization.data(withJSONObject: [
            "renewAt": formatter.string(from: renewsAt),
            "usage": [
                "rollingUsage": ["usagePercent": 0.25, "resetInSec": 3600],
                "weeklyUsage": ["usagePercent": 75, "resetInSec": 7200],
            ],
        ])

        let usage = try OpenCodeUsageFetcher.parseSubscription(
            text: String(decoding: data, as: UTF8.self),
            now: now
        )

        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.75])
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func parsesWorkspaceIDsFromServerAndJSONPayloads() {
        let server = #"$R[0]=[$R[1]={id:"wrk_01K6AR1ZET89H8NB691FQ2C2VB",name:"Default"}]"#
        #expect(OpenCodeUsageFetcher.parseWorkspaceIDs(text: server) == ["wrk_01K6AR1ZET89H8NB691FQ2C2VB"])
        #expect(OpenCodeUsageFetcher.parseWorkspaceIDs(text: #"{"data":["wrk_JSON123"]}"#) == ["wrk_JSON123"])
    }

    @Test
    func parsesPayAsYouGoBillingWithoutCreatingFakeQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = #"{"customerID":"cus_TEST","balance":1250000000,"monthlyLimit":null,"monthlyUsage":1500000000,"subscription":null}"#
        let usage = try #require(OpenCodeUsageFetcher.parseBilling(text: text, now: now))

        #expect(usage.windows.isEmpty)
        #expect(usage.providerCost?.used == 15)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.balance == 12.5)
    }

    @Test
    func filtersCookieHeaderToOpenCodeAuthenticationCookies() {
        let header = OpenCodeUsageFetcher.requestCookieHeader(
            from: "tracking=ignored; auth=secret; __Host-auth=host-secret; preference=value"
        )
        #expect(header == "auth=secret; __Host-auth=host-secret")
        #expect(OpenCodeUsageFetcher.requestCookieHeader(from: "tracking=ignored") == nil)
    }

    @Test
    func normalizesWorkspaceIDAndURL() {
        #expect(OpenCodeUsageFetcher.normalizeWorkspaceID("wrk_DIRECT123") == "wrk_DIRECT123")
        #expect(OpenCodeUsageFetcher.normalizeWorkspaceID(
            "https://opencode.ai/workspace/wrk_URL123/billing"
        ) == "wrk_URL123")
        #expect(OpenCodeUsageFetcher.normalizeWorkspaceID("not-a-workspace") == nil)
    }
}
