import AppKit
import SwiftUI
import Testing
@testable import Yomi

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
        #expect(image.pixelsWide == 760)
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
        #expect(longImage.pixelsWide == 760)
    }

    @Test
    func sharedNamesNeverExposeAccountsCredentialsOrPaths() {
        let unsafeNames = [
            "private.person@example.com", "/Users/private/models/gpt", "~/private/model",
            "C:\\Users\\private\\model", "https://example.com/private/model", "account_id=private-account",
            "Bearer private-token", "sk-private-key", "acct-private-account", "user-private-id", "org-private-id",
            "model\nCookie: private-cookie", "private 模型", "550e8400-e29b-41d4-a716-446655440000",
        ]
        for name in unsafeNames {
            #expect(safeModelUsageName(name, language: .english) == "Unknown model")
            #expect(safeModelUsageName(name, language: .simplifiedChinese) == "未知模型")
        }
        #expect(safeModelUsageName("gpt-6.1", language: .english) == "gpt-6.1")
        #expect(safeModelUsageName("claude-sonnet-4-5", language: .simplifiedChinese) == "claude-sonnet-4-5")
        #expect(safeModelUsageName("claude-sonnet-4-5-20250929", language: .english) == "claude-sonnet-4-5-20250929")
        #expect(safeModelUsageName("claude-opus-4-5-20251101", language: .simplifiedChinese) == "claude-opus-4-5-20251101")
        #expect(DailyBillReceiptText.providerName(ProviderID(rawValue: "private.person@example.com"), language: .english) == "Local usage")
        #expect(DailyBillReceiptText.providerName(ProviderID(rawValue: "codex"), language: .english) == "Codex")
    }

    @Test
    func partialPricesAreMarkedAndFilenameOnlyContainsTheDate() {
        let partial = DailyTokenUsage(tokens: 10, valueUSD: nil, partialValueUSD: 1.25)
        #expect(DailyBillReceiptText.amount(partial, language: .english) == "At least $1.25")
        #expect(DailyBillReceiptText.amount(partial, language: .simplifiedChinese) == "至少 $1.25")
        #expect(DailyBillReceiptText.amount(DailyTokenUsage(tokens: 10, valueUSD: nil), language: .english) == "—")
        let filename = DailyBillImageExporter.filename(for: now)
        #expect(filename.range(of: #"^Yomi-[0-9]{4}-[0-9]{2}-[0-9]{2}\.png$"#, options: .regularExpression) != nil)
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
