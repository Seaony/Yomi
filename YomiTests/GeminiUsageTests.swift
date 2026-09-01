import Foundation
import Testing
@testable import Yomi

struct GeminiUsageTests {
    @Test
    func quotaUsesLowestBucketInEachModelTier() throws {
        let data = Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-09-01T12:00:00Z"},{"modelId":"gemini-2.5-pro","remainingFraction":0.3,"resetTime":"2026-09-01T13:00:00Z"},{"modelId":"gemini-2.5-flash","remainingFraction":0.6},{"modelId":"gemini-2.5-flash-lite","remainingFraction":0.9}]}"#.utf8)
        let usage = try GeminiUsageFetcher.parseQuota(data: data, email: "person@example.com", plan: "Paid")
        #expect(usage.windows.map(\.label) == ["Pro", "Flash", "Flash Lite"])
        #expect(zip(usage.windows.map(\.usedFraction), [0.7, 0.4, 0.1]).allSatisfy {
            abs($0 - $1) < 0.000_000_001
        })
        #expect(usage.plan == "Paid")
        #expect(usage.details.isEmpty)
    }

    @Test
    func missingModelTierIsNotInvented() throws {
        let data = Data(#"{"buckets":[{"modelId":"gemini-2.5-flash","remainingFraction":0.25}]}"#.utf8)
        let usage = try GeminiUsageFetcher.parseQuota(data: data)
        #expect(usage.windows.map(\.label) == ["Flash"])
    }

    @Test
    func codeAssistReadsProjectTierAndPaidName() throws {
        let data = Data(#"{"cloudaicompanionProject":{"id":"gen-lang-client-123"},"currentTier":{"id":"standard-tier"},"paidTier":{"name":"Premium"}}"#.utf8)
        let status = try GeminiUsageFetcher.parseCodeAssist(data: data, hostedDomain: nil)
        #expect(status.projectID == "gen-lang-client-123")
        #expect(status.tier == .standard)
        #expect(status.paidTierName == "Premium")
    }

    @Test
    func planMappingMatchesAccountContract() {
        #expect(GeminiUsageFetcher.plan(tier: .free, hostedDomain: nil, paidTierName: nil) == "Free")
        #expect(GeminiUsageFetcher.plan(tier: .free, hostedDomain: "example.com", paidTierName: nil) == "Workspace")
        #expect(GeminiUsageFetcher.plan(tier: .standard, hostedDomain: nil, paidTierName: nil) == "Paid")
        #expect(GeminiUsageFetcher.plan(tier: .free, hostedDomain: nil, paidTierName: "Premium") == "Premium")
    }

    @Test
    func tokenClaimsReadEmailAndHostedDomain() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "person@example.com", "hd": "example.com"])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let claims = GeminiUsageFetcher.tokenClaims("header.\(payload).signature")
        #expect(claims.email == "person@example.com")
        #expect(claims.hostedDomain == "example.com")
    }

    @Test
    func rejectsUnsupportedLocalAuthModes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appending(path: "settings.json")
        try Data(#"{"security":{"auth":{"selectedType":"api-key"}}}"#.utf8).write(to: settings)
        #expect(GeminiUsageFetcher.authType(settingsURL: settings) == .apiKey)
    }

    @Test
    func catalogUsesOAuthAccountSourceOnly() {
        let descriptor = ProviderCatalog.byID[ProviderID(rawValue: "gemini")]
        #expect(descriptor?.preferredSources == [.account])
        #expect(descriptor?.defaultEnabled == false)
    }
}
