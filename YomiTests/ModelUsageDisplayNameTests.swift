import Foundation
import Testing
@testable import Yomi

struct ModelUsageDisplayNameTests {
    @Test(arguments: [
        "claude-sonnet-4-5-20250929", "claude-opus-4-5-20251101", "claude-haiku-4-5-20251001",
        "claude-opus-4-6-20260205", "claude-opus-4-20250514", "claude-sonnet-4-20250514",
        "gpt-daybreak-blue-latest", "gemini-3-pro-image-preview", "gemini-2.5-computer-use-preview-10-2025",
    ])
    func preservesOnlyVerifiedLongModelIDsWithoutChangingGeneralRedaction(model: String) {
        #expect(safeModelUsageName(model, language: .english) == model)
        #expect(safeModelUsageName(model, language: .simplifiedChinese) == model)
        #expect(DiagnosticsRedactor.redact(model) != model)
    }

    @Test(arguments: [
        "claude-sonnet-4-5-20251301", "claude-sonnet-4-5-20250230", "claude-sonnet-4-5-20990101",
        "claude-sonnet-42-5-20250929", "claude-private-4-5-20250929",
        "claude-sonnet-4-5-20250929-secret", "claude-sonnet-4-5-20250929-sk-private",
        "claude-sonnet-4-5-20250929@private.example", "private-long-account-identifier-value",
        "https://example.com/claude-sonnet-4-5-20250929", "/models/claude-sonnet-4-5-20250929",
        "~/models/gpt-6.1", "C:\\Users\\private\\model", "Bearer private-value", "secret-private-value",
        "token-private-value", "api-key-private-value", "api_key_private", "access_token_private",
        "refresh_token_private", "auth_private", "cookie_private", "org_private", "user_private", "acct_private",
        "account_id=private-value", "private.person@example.com",
        "gpt-6.1\nCookie: private-session", "550e8400-e29b-41d4-a716-446655440000",
    ])
    func rejectsSecretsPathsAndUnverifiedFamilyOrDateVariants(model: String) {
        #expect(safeModelUsageName(model, language: .english) == "Unknown model")
        #expect(safeModelUsageName(model, language: .simplifiedChinese) == "未知模型")
    }

    @Test
    func localizesSentinelsAndRetainsOrdinaryShortNames() {
        #expect(safeModelUsageName(ModelUsageBreakdown.unknownModel, language: .english) == "Unknown model")
        #expect(safeModelUsageName(ModelUsageBreakdown.unknownModel, language: .simplifiedChinese) == "未知模型")
        #expect(safeModelUsageName(ModelUsageBreakdown.otherModels, language: .english) == "Other")
        #expect(safeModelUsageName(ModelUsageBreakdown.otherModels, language: .simplifiedChinese) == "其他")
        #expect(safeModelUsageName("  gpt-6.1  ", language: .english) == "gpt-6.1")
        #expect(safeModelUsageName("claude-sonnet-4-5", language: .simplifiedChinese) == "claude-sonnet-4-5")
        #expect(safeModelUsageName("", language: .english) == "Unknown model")
    }
}
