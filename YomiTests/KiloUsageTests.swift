import Foundation
import Testing
@testable import Yomi

@Suite("Kilo usage")
struct KiloUsageTests {
    @Test func batchRequestMatchesCurrentTRPCContract() throws {
        let request = try KiloUsageFetcher.makeRequest(
            token: "secret", organization: "org_42", baseURL: URL(string: "https://app.kilo.ai/api/trpc")!
        )
        #expect(request.url?.path.contains("user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID") == "org_42")
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "batch" })?.value == "1")
    }

    @Test func parsesCreditBlocksAndKiloPass() throws {
        let json = """
        [
          {"result":{"data":{"creditBlocks":[{"balance_mUsd":19000000,"amount_mUsd":20000000}],"autoTopUpEnabled":false}}},
          {"result":{"data":{"subscription":{"tier":"tier_19","currentPeriodUsageUsd":3.5,"currentPeriodBaseCreditsUsd":19,"currentPeriodBonusCreditsUsd":9.5,"nextBillingAt":"2026-10-01T00:00:00Z"}}}},
          {"result":{"data":{"enabled":false,"paymentMethod":null}}}
        ]
        """
        let snapshot = try KiloUsageFetcher.parse(Data(json.utf8))
        let usage = KiloUsageFetcher.providerUsage(snapshot)
        #expect(usage.windows.map(\.id) == ["kilo-credits", "kilo-pass"])
        #expect(usage.windows[0].usedFraction == 0.05)
        #expect(usage.windows[1].detail == "$3.50 / $19.00 (+ $9.50 bonus)")
        #expect(usage.plan == "Starter")
    }

    @Test func parsesGenericFallbackFieldsAndAutoTopUpAmount() throws {
        let json = """
        [
          {"result":{"data":{"json":{"creditsUsed":40,"creditsRemaining":60}}}},
          {"result":{"data":{"json":{"planName":"Kilo Pass Pro"}}}},
          {"result":{"data":{"json":{"enabled":true,"amountCents":5000,"paymentMethod":null}}}}
        ]
        """
        let usage = KiloUsageFetcher.providerUsage(try KiloUsageFetcher.parse(Data(json.utf8)))
        #expect(usage.windows[0].usedFraction == 0.4)
        #expect(usage.windows[0].detail == "40/100 credits")
        #expect(usage.plan == "Kilo Pass Pro")
        #expect(usage.details.isEmpty)
    }

    @Test func zeroBalanceIsVisibleAsExhausted() throws {
        let json = """
        [
          {"result":{"data":{"creditBlocks":[],"totalBalance_mUsd":0}}},
          {"result":{"data":{"subscription":null}}},
          {"result":{"data":{"enabled":false}}}
        ]
        """
        let usage = KiloUsageFetcher.providerUsage(try KiloUsageFetcher.parse(Data(json.utf8)))
        #expect(usage.windows[0].usedFraction == 1)
        #expect(usage.windows[0].detail == "0/0 credits")
    }

    @Test func optionalAutoTopUpErrorDoesNotDiscardQuota() throws {
        let json = """
        [
          {"result":{"data":{"json":{"creditsUsed":10,"creditsRemaining":90}}}},
          {"result":{"data":{"json":{"planName":"Starter"}}}},
          {"error":{"json":{"message":"Internal server error","data":{"code":"INTERNAL_SERVER_ERROR"}}}}
        ]
        """
        let usage = KiloUsageFetcher.providerUsage(try KiloUsageFetcher.parse(Data(json.utf8)))
        #expect(usage.windows[0].usedFraction == 0.1)
        #expect(usage.plan == "Starter")
    }

    @Test func requiredTRPCAuthErrorIsFatal() {
        let data = Data(#"[{"error":{"json":{"message":"Unauthorized","data":{"code":"UNAUTHORIZED"}}}}]"#.utf8)
        #expect(throws: KiloUsageError.unauthorized) { try KiloUsageFetcher.parse(data) }
    }

    @Test func cliCredentialReadsOfficialAuthFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".local/share/kilo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"kilo":{"access":"cli-token"}}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
        #expect(try KiloUsageFetcher.cliToken(environment: ["HOME": root.path]) == "cli-token")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func catalogDoesNotUseLegacyProfileRecipe() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "kilo")]
        #expect(descriptor?.preferredSources == [.account, .token])
        #expect(descriptor?.environmentKeys == ["KILO_API_KEY"])
        #expect(ProviderRecipes.recipe(for: ProviderID(rawValue: "kilo")) == nil)
    }
}
