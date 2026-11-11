import Foundation
import Testing
@testable import Yomi

struct ModelUsageDisplayNameTests {
    @Test(arguments: [
        "claude-sonnet-4-5-20250929", "claude-opus-4-5-20251101", "claude-sonnet-4-5-20990101",
        "vendor/future-model-v9", "openrouter/anthropic/claude-latest", "model@future", "自定义/未来模型",
        "experimental-model-name-with-a-long-version-suffix-2099-12-31",
    ])
    func preservesActualModelNamesWithoutCharacterOrDateRestrictions(model: String) {
        #expect(safeModelUsageName(model, language: .english) == model)
        #expect(safeModelUsageName(model, language: .simplifiedChinese) == model)
    }

    @Test
    func trimsOuterWhitespaceAndRemovesControlCharacters() {
        #expect(safeModelUsageName("  gpt-6.1  ", language: .english) == "gpt-6.1")
        #expect(safeModelUsageName("\u{0000}\u{001B}  vendor/\tmodel\r\n ", language: .english) == "vendor/model")
        #expect(safeModelUsageName("\n  模型 名称  \n", language: .simplifiedChinese) == "模型 名称")
    }

    @Test(arguments: ["", "  \t\n\r  ", "\u{0000}\u{001B}"])
    func onlyEmptyCleanedNamesBecomeUnknown(model: String) {
        #expect(safeModelUsageName(model, language: .english) == "Unknown model")
        #expect(safeModelUsageName(model, language: .simplifiedChinese) == "未知模型")
        #expect(safeModelUsageName(ModelUsageBreakdown.unknownModel, language: .english) == ModelUsageBreakdown.unknownModel)
    }

    @Test
    func limitsDisplayToNinetySixCharactersIncludingEllipsis() {
        let exact = String(repeating: "模", count: 96)
        #expect(safeModelUsageName(exact, language: .english) == exact)
        let truncated = safeModelUsageName(exact + "型", language: .english)
        #expect(truncated == String(repeating: "模", count: 95) + "…")
        #expect(truncated.count == 96)
        #expect(safeModelUsageName(String(repeating: "a", count: 95) + "\nb", language: .english)
                == String(repeating: "a", count: 95) + "b")
    }

    @Test
    func truncationDoesNotSplitACombinedCharacter() {
        let character = "e\u{301}"
        let value = String(repeating: character, count: 97)
        #expect(safeModelUsageName(value, language: .english) == String(repeating: character, count: 95) + "…")
    }

    @Test
    func retainsOtherGroupLocalization() {
        #expect(safeModelUsageName("  " + ModelUsageBreakdown.otherModels + "  ", language: .english) == "Other")
        #expect(safeModelUsageName(ModelUsageBreakdown.otherModels, language: .simplifiedChinese) == "其他")
    }

    @Test
    func compactNamesUseLastVendorSegmentAndRemoveOnlyTrailingDates() {
        let samples = [
            ("claude-sonnet-4-5-20250929", "claude-sonnet-4-5"),
            ("vendor/deepseek-v4.1-flash", "deepseek-v4.1-flash"),
            ("openrouter/anthropic/claude-sonnet-4-5-20250929", "claude-sonnet-4-5"),
            ("厂商/未来模型-20990101", "未来模型"),
            ("model-20250929-preview", "model-20250929-preview"),
            ("model-2025-09-29", "model-2025-09-29"),
            ("model-2025092", "model-2025092"),
        ]
        for (original, expected) in samples {
            #expect(compactModelUsageName(original, language: .english) == expected)
            #expect(compactModelUsageName(original, language: .simplifiedChinese) == expected)
            #expect(fullModelUsageName(original, language: .english) == original)
        }
    }

    @Test
    func namesWithTheSameCompactDisplayRemainSeparateModelGroups() {
        let names = ["anthropic/claude-sonnet-4-5-20250929", "anthropic/claude-sonnet-4-5-20251101"]
        let rows = names.map {
            ModelTokenUsage(model: $0, inputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0,
                            outputTokens: 2, inputIncludesCache: false, valueUSD: 0.01)
        }
        let grouped = ModelUsageBreakdown.merged(rows)
        #expect(grouped.count == 2)
        #expect(Set(grouped.map(\.model)) == Set(names))
        #expect(Set(grouped.map { compactModelUsageName($0.model, language: .english) }) == ["claude-sonnet-4-5"])
        #expect(rows.map(\.model) == names)
    }

    @Test
    func compactNamesTrimControlsAndKeepUnknownAndOtherLocalization() {
        #expect(compactModelUsageName("  vendor/\tmodel-20250929\n  ", language: .english) == "model")
        for original in ["", " \t\r\n ", "\u{0000}\u{001B}", "vendor/"] {
            #expect(compactModelUsageName(original, language: .english) == "Unknown model")
            #expect(compactModelUsageName(original, language: .simplifiedChinese) == "未知模型")
        }
        #expect(compactModelUsageName(ModelUsageBreakdown.otherModels, language: .english) == "Other")
        #expect(compactModelUsageName(ModelUsageBreakdown.otherModels, language: .simplifiedChinese) == "其他")
        #expect(fullModelUsageName(ModelUsageBreakdown.otherModels, language: .english) == "Other")
        #expect(fullModelUsageName(ModelUsageBreakdown.otherModels, language: .simplifiedChinese) == "其他")
    }

    @Test
    func fullHoverNamesKeepPrefixesDatesAndLengthAfterCleaning() {
        let longSegment = String(repeating: "模", count: 110)
        let original = "vendor/\(longSegment)-20250929"
        #expect(fullModelUsageName(" \u{0000}" + original + "\r\n ", language: .english) == original)
        #expect(compactModelUsageName(original, language: .english) == String(repeating: "模", count: 95) + "…")
        #expect(compactModelUsageName(original, language: .english).count == 96)
        let exact = String(repeating: "e\u{301}", count: 96)
        #expect(compactModelUsageName("vendor/" + exact + "-20250929", language: .english) == exact)
    }
}
