import Foundation
import Testing
@testable import CodeEdge

struct CursorUsageTests {
    @Test
    func parsesUsageSummaryPercentFieldsAsPercentUnits() throws {
        let data = Data("""
        {
          "billingCycleStart":"2026-08-01T00:00:00.000Z",
          "billingCycleEnd":"2026-09-01T00:00:00.000Z",
          "membershipType":"pro_plus",
          "individualUsage":{
            "plan":{
              "used":2000,
              "limit":5000,
              "autoPercentUsed":0.36,
              "apiPercentUsed":75,
              "totalPercentUsed":40
            },
            "onDemand":{"used":250,"limit":1000}
          }
        }
        """.utf8)

        let usage = try CursorUsageFetcher.parse(summaryData: data)

        #expect(usage.windows.map(\.label) == ["Total", "Cursor", "Third Party"])
        #expect(usage.windows.map(\.usedFraction) == [0.4, 0.0036, 0.75])
        #expect(usage.providerCost?.used == 2.5)
        #expect(usage.providerCost?.limit == 10)
        #expect(usage.plan == "Cursor Pro+")
    }

    @Test
    func legacyRequestQuotaSuppressesTokenBasedSubWindows() throws {
        let data = Data("""
        {
          "individualUsage":{
            "plan":{"used":10,"limit":20,"autoPercentUsed":50,"apiPercentUsed":60}
          }
        }
        """.utf8)
        let legacy = CursorLegacyUsage(gpt4: .init(
            numRequests: 12,
            numRequestsTotal: 15,
            maxRequestUsage: 50
        ))

        let usage = try CursorUsageFetcher.parse(summaryData: data, legacy: legacy)

        #expect(usage.windows.map(\.label) == ["Total"])
        #expect(usage.windows.first?.usedFraction == 0.3)
        #expect(usage.windows.first?.detail == "15 / 50 requests")
    }

    @Test
    func enterpriseOverallQuotaIsUsedWhenPlanBlockIsAbsent() throws {
        let data = Data("""
        {
          "membershipType":"enterprise",
          "individualUsage":{"overall":{"used":7384,"limit":10000}}
        }
        """.utf8)

        let usage = try CursorUsageFetcher.parse(summaryData: data)

        #expect(usage.windows.first?.usedFraction == 0.7384)
        #expect(usage.plan == "Cursor Enterprise")
    }

    @Test
    func buildsCursorCookieFromLocalJWT() throws {
        let payload = Data(#"{"sub":"auth0|user-123","email":"user@example.com"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let cookie = try CursorUsageFetcher.cookieHeader("header.\(payload).signature")

        #expect(cookie.hasPrefix("WorkosCursorSessionToken=user-123%3A%3A"))
    }

    @Test(arguments: [
        ("2026-11-07T00:00:00Z", ["cursor-weekly"]),
        ("2026-11-01T00:00:00Z", ["cursor-total", "cursor-auto", "cursor-api"]),
    ])
    func xSubscriptionWeeklyPoolBecomesMainMeterOnlyWhileItsResetIsAhead(reset: String, expectedIDs: [String]) throws {
        let data = Data("""
        {"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z",
         "membershipType":"unified_pro","limitType":"user",
         "individualUsage":{"plan":{"autoPercentUsed":100,"apiPercentUsed":100,"totalPercentUsed":100},
           "onDemand":{"used":0,"limit":0}}}
        """.utf8)
        let sand = CursorSand(
            nextResetTimestampUtc: reset, usagePercent: 3, hasNonZeroIncludedLimit: true, isUnified: true
        )
        let now = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!

        let usage = try CursorUsageFetcher.parse(summaryData: data, sand: sand, now: now)

        // 每周池过期后回到原来的月度布局，不拿过时的数据当主额度。
        #expect(usage.windows.map(\.id) == expectedIDs)
        if expectedIDs == ["cursor-weekly"] {
            #expect(usage.windows[0].usedFraction == 0.03)
            #expect(usage.additionalWindows.isEmpty)
        }
    }

    @Test
    func unifiedMonthlySpendReplacesSummaryOnDemand() throws {
        let data = Data("""
        {"membershipType":"unified_ultra","limitType":"user",
         "individualUsage":{"plan":{"totalPercentUsed":10},"onDemand":{"used":100,"limit":2000}}}
        """.utf8)
        let unified = try JSONDecoder().decode(CursorUnifiedUsage.self, from: Data("""
        {"availability":"available","monthlyUsage":{"usedCents":1234,"limitCents":40000,
          "periodStart":"2026-11-01T00:00:00Z","resetsAt":"2026-12-01T00:00:00Z"}}
        """.utf8))
        let now = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!

        let usage = try CursorUsageFetcher.parse(summaryData: data, unified: unified, now: now)
        #expect(usage.providerCost?.used == 12.34)
        #expect(usage.providerCost?.limit == 400)

        // 不在当前周期内的数据不采用，保留原来的按需花费。
        let stale = try CursorUsageFetcher.parse(
            summaryData: data, unified: unified, now: ISO8601DateFormatter().date(from: "2026-12-02T00:00:00Z")!
        )
        #expect(stale.providerCost?.used == 1)
        #expect(stale.providerCost?.limit == 20)
    }

    @Test
    func detectsExpiredAppTokenOnly() {
        func jwt(_ payload: String) -> String {
            let encoded = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJIUzI1NiJ9.\(encoded).sig"
        }
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(CursorUsageFetcher.isExpiredAppToken(jwt(#"{"sub":"auth0|u1","exp":1000}"#), now: now))
        #expect(!CursorUsageFetcher.isExpiredAppToken(jwt(#"{"sub":"auth0|u1","exp":3000}"#), now: now))
        #expect(!CursorUsageFetcher.isExpiredAppToken(jwt(#"{"sub":"auth0|u1"}"#), now: now))
        // 手动填写的 Cookie 不按应用令牌判断。
        #expect(!CursorUsageFetcher.isExpiredAppToken("WorkosCursorSessionToken=" + jwt(#"{"exp":1000}"#), now: now))
    }
}
