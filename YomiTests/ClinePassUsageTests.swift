import Foundation
import Testing
@testable import Yomi

struct ClinePassUsageTests {
    @Test
    func parsesKnownWindowsAndIgnoresUnknownLimitTypes() throws {
        let descriptor = try #require(
            ProviderCatalog.byID[ProviderID(rawValue: "clinepass")]
        )
        let data = Data("""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"five_hour","percentUsed":12.5,"resetsAt":"2026-07-16T15:00:00Z"},
              {"type":"experimental_pool","percentUsed":77,"resetsAt":"2026-07-16T15:00:00Z"},
              {"type":"weekly","percentUsed":25,"resetsAt":"2026-07-20T00:00:00Z"},
              {"type":"monthly","percentUsed":40,"resetsAt":null}
            ]
          }
        }
        """.utf8)

        let usage = try UsageParser.parse(data, descriptor: descriptor)

        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        #expect(usage.windows.map(\.usedFraction) == [0.125, 0.25, 0.4])
        #expect(usage.windows.last?.resetsAt == nil)
    }

    @Test
    func catalogIncludesBothDocumentedCredentialAliases() throws {
        let descriptor = try #require(
            ProviderCatalog.byID[ProviderID(rawValue: "clinepass")]
        )
        #expect(descriptor.environmentKeys == ["CLINE_API_KEY", "CLINEPASS_API_KEY"])
        #expect(
            ProviderRecipes.recipe(for: descriptor.id)?.endpoint ==
                "https://api.cline.bot/api/v1/users/me/plan/usage-limits"
        )
    }
}
