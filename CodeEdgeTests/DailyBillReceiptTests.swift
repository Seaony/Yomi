import AppKit
import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
struct DailyBillReceiptTests {
    @Test(arguments: [AppLanguage.simplifiedChinese, .english], [false, true])
    func rendersNonemptyPNGInBothLanguagesAndAppearances(language: AppLanguage, dark: Bool) throws {
        let png = try #require(DailyBillImageExporter.pngData(
            data: fixture(), language: language, colorScheme: dark ? .dark : .light
        ))
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(png.count > 1_000)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 952)
        #expect(image.pixelsHigh > 600)
    }

    @Test
    func emptyAndUnpricedReceiptsStillRenderAndLongBillsAreNotCropped() throws {
        let empty = DailyBill.calculate(usages: [], now: now)
        let emptyPNG = try #require(DailyBillImageExporter.pngData(data: empty, language: .english, colorScheme: .light))
        let emptyImage = try #require(NSBitmapImageRep(data: emptyPNG))
        let rows = (0..<24).map { index in
            ModelTokenUsage(model: "model-\(index)", inputTokens: 10, cacheReadTokens: 0,
                            cacheWriteTokens: 0, outputTokens: 5, inputIncludesCache: true,
                            valueUSD: nil)
        }
        let bill = DailyBill.calculate(usages: [ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: .ready, windows: [], todayDate: now,
            updatedAt: now, todayByModel: rows
        )], now: now)
        let longPNG = try #require(DailyBillImageExporter.pngData(data: bill, language: .english, colorScheme: .dark))
        let longImage = try #require(NSBitmapImageRep(data: longPNG))
        #expect(longImage.pixelsHigh > emptyImage.pixelsHigh + 400)
        #expect(longImage.pixelsWide == 952)
    }

    @Test
    func modelLabelsAreCompactAndHoverNamesRetainTheOriginalKeys() {
        let models = [
            ("deepseek/deepseek-v4.1-flash", "deepseek-v4.1-flash"),
            ("claude-new-model-20261001", "claude-new-model"),
            ("claude-sonnet-4-5-20250929", "claude-sonnet-4-5"),
            ("模型/自定义名称", "自定义名称"),
        ]
        for (model, compact) in models {
            #expect(compactModelUsageName(model, language: .english) == compact)
            #expect(compactModelUsageName(model, language: .simplifiedChinese) == compact)
            #expect(fullModelUsageName(model, language: .english) == model)
        }
        #expect(DailyBillReceiptText.providerName(ProviderID(rawValue: "private.person@example.com"), language: .english) == "Local usage")
        #expect(DailyBillReceiptText.providerName(ProviderID(rawValue: "codex"), language: .english) == "Codex")
    }

    @Test
    func dailyAverageComparisonUsesOneDecimalAndTheSameSymbolInBothLanguages() {
        #expect(DailyBillReceiptText.dailyAverageComparison(4.284, language: .simplifiedChinese) == "4.3×")
        #expect(DailyBillReceiptText.dailyAverageComparison(4.284, language: .english) == "4.3×")
        #expect(DailyBillReceiptText.dailyAverageComparison(1, language: .english) == "1.0×")
    }

    @Test
    func partialPricesAreMarkedAndFilenameOnlyContainsTheDate() {
        let partial = DailyTokenUsage(tokens: 10, valueUSD: nil, partialValueUSD: 1.25)
        #expect(DailyBillReceiptText.amount(partial, language: .english) == "≥ $1.25")
        #expect(DailyBillReceiptText.amount(partial, language: .simplifiedChinese) == "≥ $1.25")
        #expect(DailyBillReceiptText.amount(DailyTokenUsage(tokens: 10, valueUSD: nil), language: .english) == "—")
        let filename = DailyBillImageExporter.filename(for: now)
        #expect(filename.range(of: #"^CodeEdge-[0-9]{4}-[0-9]{2}-[0-9]{2}\.png$"#, options: .regularExpression) != nil)
    }

    @Test
    func receiptZeroTokensStayPlainWithoutChangingDetailFormatting() {
        #expect(DailyBillReceiptText.tokens(0) == "0")
        #expect(DailyBillReceiptText.tokens(nil) == "—")
        #expect(DailyBillReceiptText.tokens(18_638_617) == "18.6M")
        #expect(formatDetailTokensInMillions(0) == "0M")
    }

    private var now: Date { Date(timeIntervalSince1970: 1_794_403_800) }

    private func fixture() -> DailyBillData {
        let usage = ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: .ready, windows: [], todayDate: now,
            updatedAt: now, todayByModel: [
                ModelTokenUsage(model: "claude-sonnet-4-5-20250929", inputTokens: 10_000, cacheReadTokens: 4_000,
                                cacheWriteTokens: 0, outputTokens: 2_000, inputIncludesCache: true,
                                valueUSD: 1.25),
            ]
        )
        return DailyBill.calculate(usages: [usage], now: now)
    }
}
