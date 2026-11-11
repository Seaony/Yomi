import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyBillReceiptView: View {
    let data: DailyBillData
    let language: AppLanguage
    let colorScheme: ColorScheme

    static let width: CGFloat = 380
    private var copy: AppCopy { AppCopy(language: language) }
    private var ink: Color { AppTheme.primaryText(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.text("今日 AI 账单", "Today's AI bill"))
                    .font(.system(size: 20, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(data.day.formatted(.dateTime.year().month().day().locale(language.locale)))
                    Spacer(minLength: 8)
                    Text(copy.text("开具于 ", "Issued at ")
                         + data.issuedAt.formatted(.dateTime.hour().minute().locale(language.locale)))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(DailyBillReceiptText.amount(data.totalUsage, language: language))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(copy.text("按 API 价格折算", "Estimated at API prices"))
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.65))
                if data.totalUsage.valueUSD == nil {
                    Text(copy.text("部分模型没有价格，金额仅含已计价部分。", "Some models have no price; only priced usage is included."))
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                summaryRow(copy.text("连续使用", "Usage streak"), value: streakText)
                if let ratio = data.comparisonToDailyAverage {
                    summaryRow(copy.text("对比日均", "vs. daily average"),
                               value: DailyBillReceiptText.dailyAverageComparison(ratio, language: language))
                }
            }

            dashedDivider

            if data.providers.isEmpty {
                Text(copy.text("今天还没有本地 Token 记录。", "No local token usage recorded today."))
                    .foregroundStyle(ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(data.providers) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(DailyBillReceiptText.providerName(provider.providerID, language: language))
                                    .fontWeight(.semibold)
                                Spacer(minLength: 8)
                                amount(provider.usage, weight: .semibold)
                            }
                            ForEach(provider.models) { model in
                                let name = model.model == ModelUsageBreakdown.unknownModel ? "" : model.model
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(compactModelUsageName(name, language: language))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(fullModelUsageName(name, language: language))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    amount(model.usage)
                                }
                                .foregroundStyle(ink.opacity(0.7))
                                .padding(.leading, 8)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }

            dashedDivider

            VStack(spacing: 8) {
                summaryRow(copy.text("Token 总量", "Total tokens"), value: tokenText(data.totalUsage.tokens))
                summaryRow(copy.text("输入（不含缓存）", "Input (excluding cache)"), value: tokenText(data.inputTokens))
                summaryRow(copy.text("缓存读取", "Cache reads"), value: tokenText(data.cacheReadTokens))
                summaryRow(copy.text("输出", "Output"), value: tokenText(data.outputTokens))
                summaryRow(copy.text("缓存命中率", "Cache hit rate"), value: data.cacheHitRate.map {
                    $0.formatted(.percent.precision(.fractionLength(0...1)).locale(language.locale))
                } ?? "—")
            }

            Text(copy.text("仅统计本地日志，不是付款凭证。", "Based on local logs. Not a payment receipt."))
                .font(.system(size: 10.5))
                .foregroundStyle(ink.opacity(0.6))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(ink)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(width: Self.width, alignment: .leading)
        .background(AppTheme.detailBackground(for: colorScheme), in: ReceiptPaperShape())
        .clipShape(ReceiptPaperShape())
        .overlay { ReceiptPaperShape().stroke(ink.opacity(0.1), lineWidth: 1) }
        .environment(\.colorScheme, colorScheme)
        .environment(\.locale, language.locale)
    }

    private var streakText: String {
        let days = data.consecutiveDaysCapped ? "30+" : "\(data.consecutiveDays)"
        return copy.text("\(days) 天", "\(days) \(data.consecutiveDays == 1 ? "day" : "days")")
    }

    private var dashedDivider: some View {
        Rectangle()
            .fill(ink.opacity(0.2))
            .mask {
                ReceiptDashLine().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func amount(_ usage: DailyTokenUsage, weight: Font.Weight = .regular) -> some View {
        Text(DailyBillReceiptText.amount(usage, language: language))
            .font(.system(size: 12.5, weight: weight, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func tokenText(_ value: Int64?) -> String {
        value.map { $0.formatted(.number.grouping(.automatic).locale(language.locale)) } ?? "—"
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(ink.opacity(0.7))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
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
        VStack(spacing: 0) {
            ScrollView {
                DailyBillReceiptView(data: data, language: language, colorScheme: colorScheme)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button(copied ? copy.text("已复制", "Copied") : copy.text("复制图片", "Copy Image"), action: copyImage)
                    .help(copy.text("复制小票图片", "Copy the receipt image"))
                    Button(copy.text("存为 PNG…", "Save PNG…"), action: saveImage)
                    .help(copy.text("选择位置保存小票图片", "Choose where to save the receipt image"))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointerStyle(.link)
                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(minWidth: DailyBillReceiptView.width + 48)
        .background(AppTheme.railBackground(for: colorScheme))
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
        let renderer = ImageRenderer(content: receipt)
        renderer.scale = 2
        renderer.isOpaque = false
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
        let multiple = ratio.formatted(.number.precision(.fractionLength(1)).locale(language.locale))
        return AppCopy(language: language).text("\(multiple) 倍", "\(multiple)×")
    }

    static func providerName(_ id: ProviderID, language: AppLanguage) -> String {
        ProviderCatalog.byID[id]?.name ?? AppCopy(language: language).text("本地用量", "Local usage")
    }

    static func amount(_ usage: DailyTokenUsage, language: AppLanguage) -> String {
        let value = usage.valueUSD ?? usage.partialValueUSD
        guard let value else { return "—" }
        let number = value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(value > 0 && value < 0.01 ? 4...6 : 2...2)))
        return usage.valueUSD == nil ? AppCopy(language: language).text("至少 \(number)", "At least \(number)") : number
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
