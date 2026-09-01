import Foundation
import Testing
@testable import Yomi

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
}
