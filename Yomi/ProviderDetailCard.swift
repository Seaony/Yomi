import SwiftUI

enum ProviderDetailLayout {
    static let arrowWidth: CGFloat = 8
    static let arrowHalfHeight: CGFloat = 7
    static let outerPadding: CGFloat = 16
    static let railGap: CGFloat = 6
    static let transitionOffset: CGFloat = 8
}

struct ProviderDetailCard: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let isRefreshing: Bool
    let refresh: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    @State private var isRefreshHovering = false

    private var copy: AppCopy { AppCopy(language: language) }

    private var tint: Color {
        ProviderBrandColors.color(for: descriptor.id)
    }

    private var headlineValue: String {
        guard let tokens = usage.today?.tokens else { return "—" }
        return compactTokenCount(tokens, language: language)
    }

    private var headlineCaption: String {
        let value = usage.today?.valueUSD.map { String(format: "$%.2f", $0) } ?? "$—"
        return copy.text("今日 Token", "Tokens today") + " · \(value)"
    }

    private var last30DaysValue: String {
        guard let tokens = usage.last30Days?.tokens else { return "—" }
        return compactTokenCount(tokens, language: language)
    }

    private var last30DaysCostValue: String {
        usage.last30Days?.valueUSD.map { String(format: "$%.2f", $0) } ?? "$—"
    }

    private var weeklyEstimateValue: String {
        guard let value = usage.weeklyEstimate?.valueUSD else { return "—" }
        return "≈ " + compactDollarValue(value)
    }

    private var displayedWindows: [UsageWindow] {
        if descriptor.id.rawValue == "antigravity", !usage.additionalWindows.isEmpty {
            return usage.additionalWindows
        }
        return usage.windows + usage.additionalWindows
    }

    private func formattedProviderCost(_ cost: ProviderCostSummary) -> String {
        let code = cost.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == "POINTS" || code == "CREDITS" {
            return cost.used.formatted(.number.precision(.fractionLength(0...2))) + " " + code.capitalized
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code.isEmpty ? "USD" : code
        formatter.locale = language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: cost.used))
            ?? "\(cost.used.formatted(.number.precision(.fractionLength(2)))) \(code)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if displayedWindows.isEmpty, usage.providerCost != nil || !usage.details.isEmpty {
                providerSummaryContent
            } else if displayedWindows.isEmpty {
                emptyState
            } else {
                headline

                VStack(spacing: 11) {
                    ForEach(displayedWindows) { window in
                        UsageWindowRow(window: window, tint: tint)
                    }
                }

                if usage.providerCost != nil || !usage.details.isEmpty {
                    providerSummaryContent
                }

                footer
            }
        }
        .padding(14)
        .frame(width: 300)
        .fontDesign(.rounded)
        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderIconView(provider: descriptor)
                .frame(width: 20, height: 20)
                .foregroundStyle(tint)

            Text(descriptor.name)
                .font(.system(size: 15, weight: .bold, design: .rounded))

            Spacer()

            if let plan = usage.plan {
                Text(plan)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        AppTheme.primaryText(for: colorScheme).opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                    .frame(width: 23, height: 22)
                    .background(
                        AppTheme.primaryText(for: colorScheme).opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .opacity(isRefreshing ? 0.45 : 1)
            .scaleEffect(isRefreshHovering ? 1.06 : 1)
            .help(copy.text("立即刷新", "Refresh now"))
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() }
                else { NSCursor.arrow.set() }
                withAnimation(.easeOut(duration: 0.12)) {
                    isRefreshHovering = hovering
                }
            }
            .onDisappear {
                if isRefreshHovering { NSCursor.arrow.set() }
            }
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(headlineValue)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(headlineCaption)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.48))
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                usage.state == .loading
                    ? copy.text("正在读取用量", "Loading usage")
                    : copy.text("暂时无法显示用量", "Usage is currently unavailable"),
                systemImage: statusSymbol
            )
            .font(.system(size: 12, weight: .semibold))

            if let message = usage.message {
                Text(copy.usageMessage(message))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private var providerSummaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cost = usage.providerCost {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(formattedProviderCost(cost))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(cost.period ?? copy.text("费用", "Spend"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.48))
                }
            }
            ForEach(usage.details) { detail in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(copy.usageLabel(detail.label))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.42))
                    Spacer(minLength: 8)
                    Text(detail.value)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(last30DaysValue) · \(last30DaysCostValue)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(weeklyEstimateValue) Weekly")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.42))
        .padding(.top, 2)
    }

    private var statusSymbol: String {
        switch usage.state {
        case .loading: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "exclamationmark.triangle"
        case .unavailable: "questionmark.circle"
        case .ready: "checkmark.circle"
        }
    }
}

struct ProviderDetailPanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var appPreferences = AppPreferences.shared
    let descriptor: ProviderDescriptor
    let railSide: UsageRailSide
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ProviderDetailCard(
            descriptor: descriptor,
            usage: store.usage(for: descriptor.id),
            isRefreshing: store.isRefreshing,
            refresh: {
                Task { await store.refresh(providerID: descriptor.id) }
            }
        )
        .padding(
            railSide == .right ? .trailing : .leading,
            ProviderDetailLayout.arrowWidth
        )
        .background {
            ProviderDetailPanelShape(railSide: railSide)
                .fill(AppTheme.detailBackground(for: colorScheme))
        }
        .padding(ProviderDetailLayout.outerPadding)
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
        .preferredColorScheme(appPreferences.appearance.colorScheme)
    }
}

private struct ProviderDetailPanelShape: Shape {
    let railSide: UsageRailSide

    func path(in rect: CGRect) -> Path {
        let cardRect = CGRect(
            x: railSide == .right ? rect.minX : rect.minX + ProviderDetailLayout.arrowWidth,
            y: rect.minY,
            width: rect.width - ProviderDetailLayout.arrowWidth,
            height: rect.height
        )
        let midpoint = rect.midY

        var path = Path(
            roundedRect: cardRect,
            cornerRadius: 18,
            style: .continuous
        )
        let cardEdge = railSide == .right ? cardRect.maxX - 1 : cardRect.minX + 1
        let arrowTip = railSide == .right ? rect.maxX : rect.minX
        path.move(to: CGPoint(
            x: cardEdge,
            y: midpoint - ProviderDetailLayout.arrowHalfHeight
        ))
        path.addLine(to: CGPoint(x: arrowTip, y: midpoint))
        path.addLine(to: CGPoint(
            x: cardEdge,
            y: midpoint + ProviderDetailLayout.arrowHalfHeight
        ))
        path.closeSubpath()
        return path
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    private var remainingFraction: Double {
        1 - window.clampedFraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(copy.usageLabel(window.label))
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(copy.text(
                    "剩余 \(Int((remainingFraction * 100).rounded()))%",
                    "\(Int((remainingFraction * 100).rounded()))% left"
                ))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                if !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.3))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.primaryText(for: colorScheme).opacity(0.13))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * remainingFraction))
                }
            }
            .frame(height: 5)

            if let detail = window.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.38))
                    .lineLimit(2)
            }
        }
    }

    private var resetText: String {
        guard let date = window.resetsAt else { return "" }
        return compactDuration(until: date, language: language)
    }
}

private func compactDuration(until date: Date, language: AppLanguage) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60

    if language == .simplifiedChinese {
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func compactTokenCount(_ value: Int64, language: AppLanguage) -> String {
    if language == .simplifiedChinese {
        if value >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
    } else {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
    }
    return value.formatted(.number.grouping(.automatic))
}

private func compactDollarValue(_ value: Double) -> String {
    if value >= 1_000 {
        return "$" + value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0))
        )
    }
    return String(format: "$%.2f", value)
}
