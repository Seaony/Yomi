import AppKit
import SwiftUI
import Testing
@testable import Yomi

// 用真实界面组件和演示数据生成 README 产品图，成品 JPEG 写入 docs/assets，中间图留在 /tmp。
// 平时跳过；运行：TEST_RUNNER_YOMI_PRODUCT_SHOTS=1 xcodebuild test -only-testing:YomiTests/ProductShotTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YOMI_PRODUCT_SHOTS"] != nil))
struct ProductShotTests {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/yomi-product-shots", isDirectory: true)
    private static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    fileprivate static let demoProviders = ["codex", "claude", "cursor", "gemini", "copilot", "kiro"]

    @Test
    func renderProductShots() async throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let restore = Self.overrideAppPreferences()
        defer { restore() }

        for language in [AppLanguage.english, .simplifiedChinese] {
            AppPreferences.shared.language = language
            for dark in [true, false] {
                let suffix = "\(dark ? "dark" : "light")-\(language == .english ? "en" : "zh")"
                let (rail, card) = try await renderInterface(dark: dark, language: language)
                try Self.write(rail, to: "rail-\(suffix).png")
                try Self.write(card, to: "card-\(suffix).png")
                let shot = try #require(Self.compose(rail: rail, card: card, dark: dark, language: language))
                try Self.write(shot, to: "product-\(suffix).png")
                try Self.writeJPEG(shot, to: Self.repositoryRoot.appending(path: "docs/assets/product-\(suffix).jpg"))
            }
        }
    }

    // MARK: - 渲染真实界面

    private func renderInterface(dark: Bool, language: AppLanguage) async throws -> (NSImage, NSImage) {
        let suite = "yomi-product-shots-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        defaults.set(true, forKey: "show-provider-names")
        defaults.set(UsageRailSide.right.rawValue, forKey: UsageRailSide.storageKey)
        let configurations = ProviderCatalog.all.map { descriptor in
            var configuration = ProviderConfiguration(descriptor: descriptor)
            configuration.isEnabled = Self.demoProviders.contains(descriptor.id.rawValue)
            return configuration
        }
        defaults.set(try JSONEncoder().encode(configurations), forKey: "providers.v1")

        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)
        store.showPreviewUsage(Self.demoUsage(now: Date()))

        var railHeight: CGFloat = 520
        let railView = UsageRailView(
            store: store,
            openSettings: { _ in },
            showProviderDetail: { _, _ in },
            hideProviderDetail: { _ in },
            contentHeightChanged: { railHeight = $0 }
        )
        .defaultAppStorage(defaults)
        let rail = try await snapshot(railView, size: CGSize(width: UsageRailLayout.panelWidth, height: 520), dark: dark) {
            CGSize(width: UsageRailLayout.panelWidth, height: railHeight)
        }

        let claude = try #require(ProviderCatalog.byID[ProviderID(rawValue: "claude")])
        let cardView = ProviderDetailPanelView(
            store: store,
            presentation: ProviderDetailPresentation(descriptor: claude),
            railSide: .right
        )
        .defaultAppStorage(defaults)
        let card = try await snapshot(cardView, size: nil, dark: dark)
        return (rail, card)
    }

    /// 放进离屏窗口等入场动画结束后截取，保留真实的外观和 2 倍分辨率。
    private func snapshot<Content: View>(
        _ view: Content,
        size: CGSize?,
        dark: Bool,
        finalSize: (() -> CGSize)? = nil
    ) async throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        let initial = size ?? hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: initial.width, height: initial.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(1200))
        if let finalSize {
            window.setContentSize(finalSize())
        } else {
            window.setContentSize(hosting.fittingSize)
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1800))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - 演示数据

    private static func demoUsage(now: Date) -> [ProviderUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func hours(_ value: Double) -> Date { now.addingTimeInterval(value * 3600) }
        // 最近 30 天的每日用量，带一点工作日起伏。
        let shape: [Double] = [
            0.42, 0.55, 0.61, 0.38, 0.12, 0.08, 0.47, 0.66, 0.72, 0.58, 0.69, 0.18, 0.1, 0.52, 0.75,
            0.81, 0.63, 0.7, 0.21, 0.14, 0.6, 0.78, 0.86, 0.74, 0.9, 0.26, 0.17, 0.71, 0.88, 0.64,
        ]
        let daily = shape.enumerated().map { index, value in
            DailyTokenUsagePoint(
                date: calendar.date(byAdding: .day, value: index - 29, to: today)!,
                usage: DailyTokenUsage(tokens: Int64(value * 66_000_000), valueUSD: value * 72)
            )
        }
        let last30Tokens = daily.reduce(Int64(0)) { $0 + $1.usage.tokens }
        let last30Cost = daily.reduce(0.0) { $0 + ($1.usage.valueUSD ?? 0) }
        func usage(_ id: String, plan: String?, windows: [UsageWindow]) -> ProviderUsage {
            ProviderUsage(id: ProviderID(rawValue: id), state: .ready, windows: windows, plan: plan, updatedAt: now)
        }
        var codex = usage("codex", plan: "Plus", windows: [
            UsageWindow(id: "codex-primary", label: "Session", usedFraction: 0.38, resetsAt: hours(2.2)),
            UsageWindow(id: "codex-secondary", label: "Weekly", usedFraction: 0.27, resetsAt: hours(76)),
        ])
        codex.today = DailyTokenUsage(tokens: 17_400_000, valueUSD: 11.62)
        var claude = usage("claude", plan: "Max", windows: [
            UsageWindow(id: "claude-session", label: "Session", usedFraction: 0.46, resetsAt: hours(1.9)),
            UsageWindow(id: "claude-weekly", label: "Weekly", usedFraction: 0.31, resetsAt: hours(91)),
        ])
        claude.today = daily.last!.usage
        claude.last30Days = DailyTokenUsage(tokens: last30Tokens, valueUSD: last30Cost)
        claude.last30DaysDaily = daily
        claude.weeklyEstimate = DailyTokenUsage(tokens: 640_000_000, valueUSD: 486)
        return [
            codex,
            claude,
            usage("cursor", plan: "Pro", windows: [
                UsageWindow(id: "cursor-total", label: "Total", usedFraction: 0.57, resetsAt: hours(310)),
            ]),
            usage("gemini", plan: "Pro", windows: [
                UsageWindow(id: "gemini-pro", label: "Pro", usedFraction: 0.12, resetsAt: hours(14)),
            ]),
            usage("copilot", plan: "Pro", windows: [
                UsageWindow(id: "copilot-premium", label: "Premium", usedFraction: 0.64, resetsAt: hours(420)),
            ]),
            usage("kiro", plan: "Pro", windows: [
                UsageWindow(id: "kiro-credits", label: "Credits", usedFraction: 0.81, resetsAt: hours(500)),
            ]),
        ]
    }

    // MARK: - 合成成品图

    private static func compose(rail: NSImage, card: NSImage, dark: Bool, language: AppLanguage) -> NSImage? {
        let icon = NSImage(contentsOf: repositoryRoot.appending(path: "docs/assets/icon-512.png"))
        let renderer = ImageRenderer(content: ProductShotCanvas(
            rail: rail, card: card, icon: icon, dark: dark, language: language
        ))
        renderer.scale = 2
        return renderer.nsImage
    }

    private static func write(_ image: NSImage, to name: String) throws {
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appending(path: name))
    }

    // README 用 JPEG，质量 0.88 时渐变和文字都没有明显压缩痕迹，每张约 250KB。
    private static func writeJPEG(_ image: NSImage, to url: URL) throws {
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]))
        try data.write(to: url)
    }

    /// 临时改成跟随系统外观、默认底色，结束后把这些设置原样写回。
    private static func overrideAppPreferences() -> () -> Void {
        let keys = [AppLocalization.languageKey, "app-appearance", "rail-background-color"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let preferences = AppPreferences.shared
        let language = preferences.language
        let appearance = preferences.appearance
        let background = preferences.railBackgroundColorHex
        preferences.appearance = .system
        preferences.setRailBackgroundColor(nil)
        return {
            preferences.language = language
            preferences.appearance = appearance
            if let background { preferences.setRailBackgroundColor(hex: background) }
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }
}

// MARK: - 画布

private struct ProductShotCanvas: View {
    let rail: NSImage
    let card: NSImage
    let icon: NSImage?
    let dark: Bool
    let language: AppLanguage

    private let canvas = CGSize(width: 1040, height: 640)
    private let screenFrame = CGRect(x: 470, y: 52, width: 528, height: 536)

    private var english: Bool { language == .english }
    private var ink: Color { dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.14) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            copy
                .frame(width: 380, alignment: .leading)
                .offset(x: 64, y: 0)
                .frame(maxHeight: .infinity, alignment: .center)
            screen
                .frame(width: screenFrame.width, height: screenFrame.height)
                .offset(x: screenFrame.minX, y: screenFrame.minY)
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.03, green: 0.05, blue: 0.11), Color(red: 0.06, green: 0.08, blue: 0.2)]
                    : [Color(red: 0.93, green: 0.97, blue: 1.0), Color(red: 0.97, green: 0.95, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.13, green: 0.65, blue: 0.96).opacity(dark ? 0.32 : 0.28))
                .frame(width: 560, height: 560)
                .blur(radius: 120)
                .offset(x: 260, y: -160)
            Circle()
                .fill(Color(red: 0.55, green: 0.36, blue: 0.96).opacity(dark ? 0.26 : 0.18))
                .frame(width: 480, height: 480)
                .blur(radius: 120)
                .offset(x: -300, y: 220)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
                Text("Yomi")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
            }
            .padding(.bottom, 26)
            Text(english ? "Every AI quota.\nOne glance." : "所有 AI 额度，\n一眼看清。")
                .font(.system(size: english ? 46 : 44, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            Text(english
                ? "Codex, Claude, Cursor, Gemini and 100+ more, pinned to the edge of your screen."
                : "Codex、Claude、Cursor、Gemini 等\n100 多个服务，固定在屏幕边缘。")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.62))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 模拟一块屏幕：侧边栏贴着右边缘，详情卡指向 Claude。
    private var screen: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: dark
                        ? [Color(red: 0.1, green: 0.13, blue: 0.24), Color(red: 0.05, green: 0.07, blue: 0.14)]
                        : [Color(red: 0.8, green: 0.89, blue: 0.99), Color(red: 0.9, green: 0.87, blue: 0.99)],
                    startPoint: .top, endPoint: .bottom
                ))
            menuBar
            editor
                .frame(width: 300, height: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -70, y: 120)
            HStack(alignment: .top, spacing: ProviderDetailLayout.railGap - ProviderDetailLayout.outerPadding) {
                Image(nsImage: card)
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 24, y: 10)
                    .offset(y: cardOffset)
                Image(nsImage: rail)
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 16)
            }
            .offset(y: 34)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(ink.opacity(dark ? 0.12 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(dark ? 0.5 : 0.14), radius: 40, y: 20)
    }

    // 详情卡箭头在卡片垂直中点，对准侧边栏第三个圆环（Claude）的圆心。
    // 侧边栏高度按 UsageRailView.reportContentHeight 的公式算出，这里反推每行高度。
    private var cardOffset: CGFloat {
        let rows = CGFloat(ProductShotTests.demoProviders.count + 1)
        let fixed = UsageRailLayout.contentInset + UsageRailLayout.bottomContentInset
            + UsageRailLayout.settingsAreaHeight + UsageRailLayout.providerSectionVerticalPadding * 2
        let rowHeight = (rail.size.height - fixed - (rows - 1) * UsageRailLayout.providerSpacing) / rows
        let rowPitch = rowHeight + UsageRailLayout.providerSpacing
        let claudeCenter = UsageRailLayout.contentInset + UsageRailLayout.providerSectionVerticalPadding
            + 2 * rowPitch + UsageRailLayout.providerRingDiameter / 2
        return max(0, claudeCenter - card.size.height / 2)
    }

    // 屏幕顶部的菜单栏，只是装饰。
    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
                .font(.system(size: 12, weight: .semibold))
            ForEach([34, 28, 40, 30], id: \.self) { width in
                Capsule().frame(width: CGFloat(width), height: 5).opacity(0.45)
            }
            Spacer()
            ForEach([14, 14, 18], id: \.self) { width in
                RoundedRectangle(cornerRadius: 2).frame(width: CGFloat(width), height: 8).opacity(0.45)
            }
            Text("9:41")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(ink.opacity(0.7))
        .padding(.horizontal, 18)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(dark ? Color.white.opacity(0.05) : Color.white.opacity(0.4))
    }

    // 背景里的编辑器窗口，只是装饰，降低存在感。
    private var editor: some View {
        let lines: [(CGFloat, CGFloat, Color)] = [
            (0, 120, .purple), (16, 180, .blue), (16, 90, .teal), (32, 210, .blue), (32, 140, .orange),
            (16, 60, .purple), (0, 40, .gray), (0, 150, .purple), (16, 200, .blue), (32, 120, .teal),
            (32, 170, .orange), (16, 80, .gray), (0, 40, .gray),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.7)).frame(width: 9, height: 9)
                }
            }
            .padding(12)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Capsule()
                        .fill(line.2.opacity(dark ? 0.35 : 0.3))
                        .frame(width: line.1, height: 6)
                        .padding(.leading, line.0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Spacer()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ink.opacity(0.08), lineWidth: 1)
        )
    }
}
