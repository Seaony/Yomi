import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyBillReceiptView: View {
    let data: DailyBillData
    let language: AppLanguage
    let colorScheme: ColorScheme

    static let width: CGFloat = 380
    private var copy: AppCopy { AppCopy(language: language) }
    private var ink: Color { ReceiptPalette.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(copy.text("今日 AI 账单", "Today's AI bill"))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                    Text(copy.text("由 Yomi 统计", "Tallied by Yomi"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    informationRow(copy.text("日期", "Date"), value: data.day.formatted(
                        .dateTime.year().month().day().locale(language.locale)
                    ))
                    informationRow(copy.text("开具", "Issued"), value: data.issuedAt.formatted(
                        .dateTime.year().month().day().hour().minute().locale(language.locale)
                    ))
                }
                .font(.system(size: 11, design: .monospaced))
            }

            dashedDivider

            VStack(spacing: 6) {
                Text(copy.text("API 总费用", "API TOTAL"))
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(2)
                Text(DailyBillReceiptText.amount(data.totalUsage, language: language))
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(copy.text("按 API 价格折算 · 非发票", "Estimated at API prices · Not an invoice"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if data.totalUsage.valueUSD == nil {
                    Text(copy.text("部分模型没有价格，金额仅含已计价部分。", "Some models have no price; only priced usage is included."))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)

            dashedDivider

            VStack(spacing: 8) {
                summaryRow(copy.text("连续使用", "Usage streak"), value: streakText)
                if let ratio = data.comparisonToDailyAverage {
                    summaryRow(copy.text("对比日均", "vs. daily average"),
                               value: DailyBillReceiptText.dailyAverageComparison(ratio, language: language))
                }
            }

            dashedDivider

            VStack(alignment: .leading, spacing: 12) {
                informationRow(copy.text("服务商 / 模型", "PROVIDER / MODEL"), value: copy.text("费用", "COST"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.5))

                if data.providers.isEmpty {
                    Text(copy.text("今天还没有本地 Token 记录。", "No local token usage recorded today."))
                        .foregroundStyle(ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(data.providers) { provider in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    HStack(spacing: 4) {
                                        providerIcon(provider.providerID)
                                        Text(DailyBillReceiptText.providerName(provider.providerID, language: language).uppercased())
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(DailyBillReceiptText.providerName(provider.providerID, language: language))
                                    }
                                    Spacer(minLength: 8)
                                    amount(provider.usage, size: 13, weight: .semibold)
                                }
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))

                                ForEach(provider.models) { model in
                                    let name = model.model == ModelUsageBreakdown.unknownModel ? "" : model.model
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(compactModelUsageName(name, language: language).uppercased())
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(fullModelUsageName(name, language: language))
                                        Spacer(minLength: 8)
                                        amount(model.usage)
                                    }
                                    .foregroundStyle(ink.opacity(0.8))
                                    .padding(.leading, 18)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
            }

            dashedDivider

            VStack(spacing: 8) {
                summaryRow(copy.text("TOKEN 总量", "TOTAL TOKENS"), value: DailyBillReceiptText.tokens(data.totalUsage.tokens))
                summaryRow(copy.text("输入（不含缓存）", "Input (excl. cache)"), value: DailyBillReceiptText.tokens(data.inputTokens))
                summaryRow(copy.text("缓存读取", "Cache reads"), value: DailyBillReceiptText.tokens(data.cacheReadTokens))
                summaryRow(copy.text("输出", "Output"), value: DailyBillReceiptText.tokens(data.outputTokens))
                summaryRow(copy.text("缓存命中率", "Cache hit rate"), value: data.cacheHitRate.map {
                    $0.formatted(.percent.precision(.fractionLength(0...1)).locale(language.locale))
                } ?? "—")
            }

            dashedDivider

            Text(copy.text("仅统计本地日志，不是付款凭证", "Based on local logs. Not a payment receipt."))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundStyle(ink)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: Self.width, alignment: .leading)
        .background(ReceiptPalette.paper, in: ReceiptPaperShape())
        .clipShape(ReceiptPaperShape())
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, language.locale)
    }

    private var streakText: String {
        let days = data.consecutiveDaysCapped ? "30+" : "\(data.consecutiveDays)"
        return copy.text("\(days) 天", "\(days) \(data.consecutiveDays == 1 ? "day" : "days")")
    }

    private var dashedDivider: some View {
        ReceiptDashLine()
            .stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }

    private func providerIcon(_ id: ProviderID) -> some View {
        Group {
            if let provider = ProviderCatalog.byID[id] {
                ProviderIconView(provider: provider)
            } else {
                Image(systemName: "questionmark")
            }
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(ink)
        .accessibilityHidden(true)
    }

    private func amount(_ usage: DailyTokenUsage, size: CGFloat = 12.5, weight: Font.Weight = .regular) -> some View {
        Text(DailyBillReceiptText.amount(usage, language: language))
            .font(.system(size: size, weight: weight, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        informationRow(title, value: value)
    }
}

struct DailyBillPanelView: View {
    let data: DailyBillData
    let language: AppLanguage
    let colorScheme: ColorScheme
    @State private var feedback: String?
    @State private var copied = false
    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                DailyBillReceiptView(data: data, language: language, colorScheme: colorScheme)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button(action: copyImage) {
                            Label(copied ? copy.text("已复制", "Copied") : copy.text("复制图片", "Copy Image"),
                                  systemImage: "doc.on.doc")
                        }
                        .help(copy.text("复制小票图片", "Copy the receipt image"))
                        Button(action: saveImage) {
                            Label(copy.text("存为 PNG…", "Save PNG…"), systemImage: "square.and.arrow.down")
                        }
                        .help(copy.text("选择位置保存小票图片", "Choose where to save the receipt image"))
                    }
                    .buttonStyle(ReceiptActionButtonStyle())
                    if let feedback {
                        Text(feedback)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: DailyBillReceiptView.width + 64)
        .background(ReceiptPalette.background(for: colorScheme))
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, language.locale)
    }

    private func copyImage() {
        guard let png = DailyBillImageExporter.pngData(data: data, language: language, colorScheme: colorScheme) else {
            feedback = copy.text("无法生成图片，请重试。", "Unable to create the image. Try again.")
            return
        }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setData(png, forType: .png)
        feedback = copied ? nil : copy.text("复制失败，请重试。", "Unable to copy the image. Try again.")
    }

    private func saveImage() {
        guard let png = DailyBillImageExporter.pngData(data: data, language: language, colorScheme: colorScheme) else {
            feedback = copy.text("无法生成图片，请重试。", "Unable to create the image. Try again.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = DailyBillImageExporter.filename(for: data.day)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                feedback = copy.text("已保存。", "Saved.")
            } catch {
                feedback = copy.text("保存失败，请换个位置重试。", "Unable to save the image. Try another location.")
            }
        }
    }
}

enum DailyBillImageExporter {
    static func pngData(data: DailyBillData, language: AppLanguage, colorScheme: ColorScheme) -> Data? {
        let receipt = DailyBillReceiptView(data: data, language: language, colorScheme: colorScheme)
            .fixedSize(horizontal: true, vertical: true)
            .padding(48)
            .background(ReceiptPalette.background(for: colorScheme))
        let renderer = ImageRenderer(content: receipt)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func filename(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return "Yomi-\(formatter.string(from: day)).png"
    }
}

enum DailyBillReceiptText {
    static func dailyAverageComparison(_ ratio: Double, language: AppLanguage) -> String {
        ratio.formatted(.number.precision(.fractionLength(1)).locale(language.locale)) + "×"
    }

    static func providerName(_ id: ProviderID, language: AppLanguage) -> String {
        ProviderCatalog.byID[id]?.name ?? AppCopy(language: language).text("本地用量", "Local usage")
    }

    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "0" : formatDetailTokensInMillions(value)
    }

    static func amount(_ usage: DailyTokenUsage, language _: AppLanguage) -> String {
        let value = usage.valueUSD ?? usage.partialValueUSD
        guard let value else { return "—" }
        let number = value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(value > 0 && value < 0.01 ? 4...6 : 2...2)))
        return usage.valueUSD == nil ? "≥ \(number)" : number
    }
}

private enum ReceiptPalette {
    // 小票是一张打印纸，纸色和墨色不随系统外观变化。
    static let paper = Color(red: 247 / 255.0, green: 244 / 255.0, blue: 237 / 255.0)
    static let ink = Color(red: 31 / 255.0, green: 29 / 255.0, blue: 26 / 255.0)

    static func background(for colorScheme: ColorScheme) -> LinearGradient {
        let top = colorScheme == .dark ? Color(red: 13 / 255.0, green: 47 / 255.0, blue: 87 / 255.0)
            : Color(red: 77 / 255.0, green: 163 / 255.0, blue: 245 / 255.0)
        let bottom = colorScheme == .dark ? Color(red: 26 / 255.0, green: 79 / 255.0, blue: 134 / 255.0)
            : Color(red: 168 / 255.0, green: 213 / 255.0, blue: 1)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

private struct ReceiptActionButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().fill(.white.opacity(hovering ? 0.12 : 0)) }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ReceiptDashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct ReceiptPaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        let toothHeight: CGFloat = 6
        let count = max(1, Int(rect.width / 12))
        let step = rect.width / CGFloat(count)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothHeight))
        for index in (0..<count).reversed() {
            path.addLine(to: CGPoint(x: rect.minX + (CGFloat(index) + 0.5) * step, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - toothHeight))
        }
        path.closeSubpath()
        return path
    }
}
