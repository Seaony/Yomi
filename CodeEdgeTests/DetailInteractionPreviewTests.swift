import AppKit
import SwiftUI
import Testing
@testable import CodeEdge

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEEDGE_UI_PREVIEWS"] != nil || ProcessInfo.processInfo.environment["CODEEDGE_DAY_SELECT_PREVIEWS"] != nil))
struct DetailInteractionPreviewTests {
    @Test
    func renderFeedbackStates() throws {
        let daySelect = ProcessInfo.processInfo.environment["CODEEDGE_DAY_SELECT_PREVIEWS"] != nil
        let output = URL(fileURLWithPath: "/tmp/codeedge-ui-preview/" + (daySelect ? "day-select" : "feedback"), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let selected = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let missing = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let singleDay = Calendar.current.date(byAdding: .day, value: -3, to: today)!
        let models = [model("gpt-6.1-sol", tokens: 16_000_000, cost: 12),
                      model("claude-sonnet-4-5", tokens: 8_000_000, cost: 7),
                      model("gemini-2.5-pro", tokens: 4_000_000, cost: 3)]
        let historical = [model("claude-opus-4-5", tokens: 40_000_000, cost: 36),
                          model("gpt-6.1-sol", tokens: 20_000_000, cost: 15)]
        var overview = ProviderUsage(id: ProviderCatalog.overview.id, state: .ready, windows: [],
                                     today: DailyTokenUsage(tokens: 28_000_000, valueUSD: 22), updatedAt: now,
                                     todayByModel: models)
        overview.last30DaysDaily = (0..<30).map { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset - 29, to: today)!
            let dailyModels = day == singleDay ? [models[0]] : (day == selected ? historical : models)
            return DailyTokenUsagePoint(date: day,
                                        usage: DailyTokenUsage(tokens: dailyModels.map(\.tokens).reduce(0, +),
                                                               valueUSD: dailyModels.compactMap(\.valueUSD).reduce(0, +)),
                                        models: day == missing ? nil : dailyModels)
        }
        overview.last30Days = DailyTokenUsage(tokens: overview.last30DaysDaily.map(\.usage.tokens).reduce(0, +),
                                                valueUSD: overview.last30DaysDaily.compactMap(\.usage.valueUSD).reduce(0, +))
        var claude = ProviderUsage(id: ProviderID(rawValue: "claude"), state: .ready, windows: [
            UsageWindow(id: "session", label: "Session", usedFraction: 0.46, resetsAt: now.addingTimeInterval(7200)),
            UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.27, resetsAt: now.addingTimeInterval(86400)),
        ], plan: "Max", today: models[1].usage, updatedAt: now)
        claude.last30Days = DailyTokenUsage(tokens: 160_000_000, valueUSD: 140)
        claude.weeklyEstimate = DailyTokenUsage(tokens: 80_000_000, valueUSD: 70)
        var codex = ProviderUsage(id: ProviderID(rawValue: "codex"), state: .ready, windows: [
            UsageWindow(id: "session", label: "Session", usedFraction: 0.38, resetsAt: now.addingTimeInterval(7200)),
        ], balance: "290 Credits", plan: "Plus", today: models[0].usage, updatedAt: now)
        codex.last30Days = DailyTokenUsage(tokens: 100_000_000, valueUSD: 70)
        codex.weeklyEstimate = DailyTokenUsage(tokens: 80_000_000, valueUSD: 60)
        let raycast = ProviderUsage(id: ProviderID(rawValue: "raycast"), state: .ready, windows: [
            UsageWindow(id: "credits", label: "Credits", usedFraction: 0.5,
                        detail: "剩余 100 / 200 Credits"),
        ], plan: "Pro", updatedAt: now)
        let incident = ProviderServiceStatus(severity: .major, title: "部分请求失败，服务正在恢复", components: [],
                                             updatedAt: now, pageURL: URL(string: "https://status.claude.com/")!)
        let states: [(String, ProviderUsage, ProviderDetailPreviewState?, ProviderServiceStatus?)] = daySelect ? [
            ("selected-day", overview, .init(selectedDay: selected), nil),
            ("fewer-models", overview, .init(selectedDay: singleDay), nil),
            ("status-hover", claude, .init(statusHover: true), incident),
            ("model-bar-default", overview, .init(), nil),
            ("model-bar-hover-last", overview, .init(modelIndex: 2), nil),
        ] : [
            ("incident", claude, nil, incident),
            ("quota-hover", claude, .init(quotaSegment: 19), nil),
            ("credits", codex, nil, nil),
            ("credits-remaining", raycast, nil, nil),
            ("selected-day", overview, .init(selectedDay: selected), nil),
            ("missing-models", overview, .init(selectedDay: missing), nil),
            ("model-hover", overview, .init(modelIndex: 1), nil),
        ]
        for dark in [false, true] {
            for (name, usage, preview, incident) in states {
                let image = try snapshot(usage, preview: preview, incident: incident, dark: dark)
                let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: output.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        var emptyToday = overview
        emptyToday.today = nil
        emptyToday.todayByModel = nil
        let baseline = try snapshot(overview, preview: .init()).size
        let historicalSize = try snapshot(overview, preview: .init(selectedDay: selected)).size
        #expect(historicalSize.height < baseline.height)
        #expect(try snapshot(overview, preview: .init(selectedDay: singleDay)).size.height < historicalSize.height)
        #expect(try snapshot(emptyToday, preview: .init(selectedDay: selected)).size.height
                > snapshot(emptyToday, preview: .init()).size.height)
    }

    private func snapshot(
        _ usage: ProviderUsage, preview: ProviderDetailPreviewState? = nil,
        incident: ProviderServiceStatus? = nil, dark: Bool = false
    ) throws -> NSImage {
        let descriptor = usage.id == ProviderCatalog.overview.id
            ? ProviderCatalog.overview : try #require(ProviderCatalog.byID[usage.id])
        let content = ProviderDetailCard(descriptor: descriptor, usage: usage, transitionDirection: .stationary,
                                         isRefreshing: false, refreshInterval: { 300 }, refresh: {},
                                         serviceStatus: incident)
            .background(AppTheme.detailBackground(for: dark ? .dark : .light),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(18)
            .environment(\.providerDetailPreview, preview ?? .init())
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.appLanguage, .simplifiedChinese)
            .environment(\.locale, AppLanguage.simplifiedChinese.locale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try #require(renderer.nsImage)
    }

    private func model(_ name: String, tokens: Int64, cost: Double) -> ModelTokenUsage {
        ModelTokenUsage(model: name, inputTokens: tokens, cacheReadTokens: 0, cacheWriteTokens: 0,
                        outputTokens: 0, inputIncludesCache: false, valueUSD: cost)
    }
}
