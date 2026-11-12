import Combine
import SwiftUI

enum ProviderDetailLayout {
    static let arrowWidth: CGFloat = 8
    static let arrowHalfHeight: CGFloat = 7
    static let outerPadding: CGFloat = 22
    static let shadowOverflow: CGFloat = 16
    static let panelPadding = outerPadding + shadowOverflow
    static let screenMargin: CGFloat = 24
    static let railGap: CGFloat = 6
    static let transitionOffset: CGFloat = 8

    static func visibleCardFrame(panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: panelPadding, dy: panelPadding)
    }
}

enum ProviderDetailTransitionDirection {
    case up
    case down
    case stationary

    init(previousLocalY: CGFloat?, newLocalY: CGFloat) {
        guard let previousLocalY else {
            self = .stationary
            return
        }
        if newLocalY < previousLocalY {
            self = .up
        } else if newLocalY > previousLocalY {
            self = .down
        } else {
            self = .stationary
        }
    }
}

@MainActor
final class ProviderDetailPresentation: ObservableObject {
    @Published private(set) var descriptor: ProviderDescriptor
    private(set) var direction = ProviderDetailTransitionDirection.stationary

    init(descriptor: ProviderDescriptor) {
        self.descriptor = descriptor
    }

    func update(
        descriptor: ProviderDescriptor,
        direction: ProviderDetailTransitionDirection,
        animated: Bool
    ) {
        self.direction = direction
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.descriptor = descriptor
            }
        } else {
            self.descriptor = descriptor
        }
    }
}

struct ProviderDetailCard: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let transitionDirection: ProviderDetailTransitionDirection
    let isRefreshing: Bool
    let refreshInterval: () -> TimeInterval
    let refresh: () -> Void
    var openDailyBill: (() -> Void)? = nil
    var serviceStatus: ProviderServiceStatus? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRefreshHovering = false
    @State private var isBillHovering = false
    @State private var isStatusLinkHovering = false

    private var copy: AppCopy { AppCopy(language: language) }
    private var isOverview: Bool { descriptor.id == ProviderCatalog.overview.id }

    private var tint: Color {
        ProviderBrandColors.color(for: descriptor.id)
    }

    private var headlineValue: String {
        if let requests = usage.todayRequests?.requests {
            return compactTokenCount(requests)
        }
        guard let tokens = usage.today?.tokens else { return "—" }
        return formatDetailTokensInMillions(tokens)
    }

    private var headlineCaption: String {
        if let cost = usage.todayRequests?.valueUSD { return "≈ " + compactDollarValue(cost) }
        return costText(usage.today)
    }

    // 部分 Token 没有价格时只显示已计价部分，用“≥”表示实际至少这么多。
    private func costText(_ usage: DailyTokenUsage?) -> String {
        if let value = usage?.valueUSD { return "≈ " + compactDollarValue(value) }
        if let value = usage?.partialValueUSD { return "≥ " + compactDollarValue(value) }
        return "$—"
    }

    private func partialCostHelp(_ usage: DailyTokenUsage?) -> String {
        guard usage?.valueUSD == nil, usage?.partialValueUSD != nil else { return "" }
        return copy.text(
            "部分模型没有价格，金额只包含已计价的部分。",
            "Some models have no price; the amount only covers priced usage."
        )
    }

    private var displayedBalance: String? {
        guard let balance = usage.balance else { return nil }
        guard descriptor.id.rawValue == "codex" else { return balance }
        let raw = balance.replacingOccurrences(of: " credits", with: "")
            .replacingOccurrences(of: " 积分", with: "")
        guard let value = Double(raw), value.isFinite else { return balance }
        return value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }

    private var overviewCaption: String {
        let cost = costText(usage.last30Days)
        let tokens = usage.last30Days.map {
            formatDetailTokensInMillions($0.tokens)
        } ?? "—"
        return copy.text(
            "\(tokens) Token · \(cost) · 30 天",
            "\(tokens) Tokens · \(cost) · 30d"
        )
    }

    private var last30DaysValue: String {
        if let requests = usage.last30DaysRequests?.requests {
            return compactTokenCount(requests)
                + " " + copy.text("次请求", "requests")
        }
        guard let tokens = usage.last30Days?.tokens else { return "—" }
        return formatDetailTokensInMillions(tokens)
    }

    private var last30DaysCostValue: String {
        if let value = usage.last30DaysRequests?.valueUSD ?? usage.last30Days?.valueUSD {
            return compactDollarValue(value)
        }
        return usage.last30Days?.partialValueUSD.map { "≥ " + compactDollarValue($0) } ?? "$—"
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

    private var detailAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var sectionTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let insertionOffset: CGFloat
        let removalOffset: CGFloat
        switch transitionDirection {
        case .up:
            insertionOffset = -7
            removalOffset = 7
        case .down:
            insertionOffset = 7
            removalOffset = -7
        case .stationary:
            insertionOffset = 0
            removalOffset = 0
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: insertionOffset)),
            removal: .opacity.combined(with: .offset(y: removalOffset))
        )
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                headerContent

                if let status = cachedUsageStatus(usage, language: language) {
                    Label(status, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                } else if UsageFreshness.isStale(
                    updatedAt: usage.updatedAt,
                    refreshInterval: refreshInterval(),
                    now: context.date
                ), let updatedAt = usage.updatedAt {
                    Text(UsageFreshness.updatedText(updatedAt: updatedAt, now: context.date, language: language))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                        .help(usage.message.map { DiagnosticsRedactor.redact(copy.usageMessage($0)) } ?? "")
                }

                if isOverview || !displayedWindows.isEmpty || usage.today != nil {
                    usageHeadline
                }
                if !isOverview, !displayedWindows.isEmpty {
                    VStack(spacing: 11) {
                        ForEach(displayedWindows) { window in
                            UsageWindowRow(window: window, tint: tint, usageUpdatedAt: usage.updatedAt, refreshInterval: refreshInterval)
                                .transition(sectionTransition)
                        }
                    }
                }
                serviceIncidentBanner
                detailContent
            }
            .padding(14)
            .frame(width: 300)
            .fontDesign(.rounded)
            .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            .animation(detailAnimation, value: descriptor.id)
            .animation(detailAnimation, value: usage)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if isOverview {
            overviewChart
                .transition(sectionTransition)
        } else {
            if let models = usage.todayByModel, !models.isEmpty {
                modelBreakdown(models)
            }

            if usage.balance != nil || usage.providerCost != nil || !usage.details.isEmpty {
                providerSummaryContent
            } else if displayedWindows.isEmpty, usage.today == nil {
                emptyState
            }

            if !displayedWindows.isEmpty { footer }
        }
    }

    private func modelBreakdown(_ models: [ModelTokenUsage]) -> some View {
        let rows = ModelUsageBreakdown.displayRows(models)
        let total = models.reduce(Int64.zero) { $0 + $1.tokens }
        let colors: [Color] = [.blue, .purple, .cyan, .pink, .indigo, .gray]
        return VStack(alignment: .leading, spacing: 7) {
            Text(copy.text("今日模型用量", "Today's model usage"))
                .font(.system(size: 11.5, weight: .semibold))
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Rectangle()
                            .fill(colors[index % colors.count])
                            .frame(width: proxy.size.width * ModelUsageBreakdown.fraction(row, totalTokens: total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 4) {
                    Circle().fill(colors[index % colors.count]).frame(width: 5, height: 5)
                    Text(modelName(row.model))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(fullModelUsageName(row.model == ModelUsageBreakdown.unknownModel ? "" : row.model, language: language))
                    Text(formatDetailTokensInMillions(row.tokens))
                        .frame(width: 50, alignment: .trailing)
                    Text(row.valueUSD != nil || row.partialValueUSD != nil ? costText(row.usage) : "—")
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                        .frame(width: 60, alignment: .trailing)
                    Text(ModelUsageBreakdown.fraction(row, totalTokens: total).formatted(.percent.precision(.fractionLength(0...1))))
                        .frame(width: 36, alignment: .trailing)
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func modelName(_ model: String) -> String {
        compactModelUsageName(model == ModelUsageBreakdown.unknownModel ? "" : model, language: language)
    }

    private var usageHeadline: some View {
        let layout = isOverview
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 7))
        let todayCost = costText(usage.today)
        let todayCostText = Text(todayCost)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.48))
        let headline = isOverview
            ? Text("\(Text(headlineValue)) \(todayCostText)")
            : Text(headlineValue)

        return layout {
            headline
                .font(
                    .system(
                        size: isOverview ? 30 : 26,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .lineLimit(isOverview ? 1 : nil)
                .minimumScaleFactor(isOverview ? 0.75 : 1)
                .contentTransition(.numericText(value: Double(usage.todayRequests?.requests ?? usage.today?.tokens ?? 0)))
                .help(isOverview ? partialCostHelp(usage.today) : "")

            Text(isOverview ? overviewCaption : headlineCaption)
                .help(partialCostHelp(isOverview ? usage.last30Days : usage.today))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.48))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(
                    .numericText(
                        value: isOverview
                            ? Double(usage.last30DaysRequests?.requests ?? usage.last30Days?.tokens ?? 0)
                            : usage.today?.valueUSD ?? 0
                    )
                )
        }
    }

    @ViewBuilder
    private var overviewChart: some View {
        if usage.last30DaysDaily.isEmpty {
            Text(copy.text("暂无 30 天用量", "No 30-day usage yet"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.38))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
        } else {
            DailyUsageBarChart(points: usage.last30DaysDaily, tint: tint)
        }
    }

    @ViewBuilder
    private var serviceIncidentBanner: some View {
        if let status = serviceStatus, status.hasIssue {
            let title = status.title ?? copy.text("暂无事件标题", "No incident title")
            let color: Color = switch status.severity {
            case .minor: .orange
            case .major, .critical: .red
            default: .secondary
            }
            let prefix = switch status.severity {
            case .minor: copy.text("服务部分异常：", "Partial outage:")
            case .major, .critical: copy.text("服务中断：", "Outage:")
            case .maintenance: copy.text("计划维护：", "Scheduled maintenance:")
            default: ""
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(prefix).fixedSize()
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(title)
                if status.severity != .maintenance {
                    Button { NSWorkspace.shared.open(status.pageURL) } label: {
                        Text(copy.text("状态页 ›", "Status ›"))
                            .underline(isStatusLinkHovering)
                    }
                    .buttonStyle(ServiceIncidentLinkStyle())
                    .fixedSize()
                    .pointerStyle(.link)
                    .onHover { isStatusLinkHovering = $0 }
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
        }
    }

    private var headerContent: some View {
        HStack(spacing: 7) {
            ZStack {
                ProviderIconView(provider: descriptor)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(tint)
                    .id(descriptor.id)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.82))
                    )
            }
            .frame(width: 20, height: 20)

            Text(descriptor.name)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .contentTransition(.opacity)

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
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.94))
                    )
            }

            if descriptor.id.rawValue == "codex", let credits = usage.codexResetCredits {
                let now = Date()
                let count = credits.filter { $0.expiresAt.map { $0 > now } ?? true }.count
                HStack(spacing: 3) {
                    Image(systemName: "creditcard")
                    Text("\(count)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(copy.text("重置卡 \(count)", "Resets \(count)"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    AppTheme.primaryText(for: colorScheme).opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }

            HStack(spacing: 6) {
                if isOverview, let openDailyBill {
                    headerButton(
                        symbol: "receipt", title: copy.text("今日 AI 账单", "Today's AI bill"),
                        hovering: $isBillHovering, action: openDailyBill
                    )
                }
                headerButton(
                    symbol: "arrow.clockwise",
                    title: isOverview
                        ? copy.text("立即刷新全部 Provider", "Refresh all providers")
                        : copy.text("立即刷新", "Refresh now"),
                    hovering: $isRefreshHovering, action: refresh
                )
                .disabled(isRefreshing)
                .opacity(isRefreshing ? 0.45 : 1)
            }
        }
    }

    private func headerButton(symbol: String, title: String, hovering: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                .frame(width: 23, height: 22)
                .background(
                    AppTheme.primaryText(for: colorScheme).opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering.wrappedValue ? 1.06 : 1)
        .help(title)
        .accessibilityLabel(title)
        .onHover { value in
            if value { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
            withAnimation(.easeOut(duration: 0.12)) { hovering.wrappedValue = value }
        }
        .onDisappear {
            if hovering.wrappedValue { NSCursor.arrow.set() }
            hovering.wrappedValue = false
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
            if let balance = displayedBalance,
               !usage.details.contains(where: {
                   let label = $0.label.lowercased()
                   return label.contains("balance") || label.contains("余额")
               }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(copy.usageLabel(descriptor.id.rawValue == "codex" ? "Credits" : "Balance"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.42))
                    Spacer(minLength: 8)
                    Text(balance)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            if let cost = usage.providerCost {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(formattedProviderCost(cost))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: cost.used))
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
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(last30DaysValue) · \(last30DaysCostValue)")
                .help(partialCostHelp(usage.last30DaysRequests == nil ? usage.last30Days : nil))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(
                    .numericText(value: Double(usage.last30DaysRequests?.requests ?? usage.last30Days?.tokens ?? 0))
                )

            Spacer(minLength: 12)

            Text("\(weeklyEstimateValue) " + copy.text("每周估算", "Weekly estimate"))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText(value: usage.weeklyEstimate?.valueUSD ?? 0))
                .help(copy.text(
                    "根据本地用量、模型价格和官方已用比例推算的每周金额，不是官方金额额度。",
                    "Estimated weekly amount from local usage, model prices, and the reported usage fraction; not an official monetary allowance."
                ))
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
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

private struct ServiceIncidentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct ProviderDetailPanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var appPreferences = AppPreferences.shared
    @ObservedObject var presentation: ProviderDetailPresentation
    let railSide: UsageRailSide
    var openDailyBill: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ProviderDetailCard(
            descriptor: presentation.descriptor,
            usage: presentation.descriptor.id == ProviderCatalog.overview.id
                ? store.overviewUsage
                : store.usage(for: presentation.descriptor.id),
            transitionDirection: presentation.direction,
            isRefreshing: store.isRefreshing,
            refreshInterval: { store.currentRefreshInterval },
            refresh: {
                let providerID = presentation.descriptor.id
                Task {
                    await store.refresh(
                        providerID: providerID == ProviderCatalog.overview.id
                            ? nil
                            : providerID,
                        allowBrowserCookieImport: true
                    )
                }
            },
            openDailyBill: openDailyBill,
            serviceStatus: store.serviceStatus(for: presentation.descriptor.id)
        )
        .padding(
            railSide == .right ? .trailing : .leading,
            ProviderDetailLayout.arrowWidth
        )
        .background {
            ProviderDetailPanelShape(railSide: railSide)
                .fill(AppTheme.detailBackground(for: colorScheme))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 5)
                .overlay {
                    ProviderDetailPanelShape(railSide: railSide)
                        .stroke(
                            AppTheme.primaryText(for: colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.10),
                            lineWidth: 1
                        )
                }
        }
        .contentShape(Rectangle())
        .padding(ProviderDetailLayout.panelPadding)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: presentation.descriptor.id
        )
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
        .preferredColorScheme(appPreferences.appearance.colorScheme)
    }
}

private struct DailyUsageBarChart: View {
    let points: [DailyTokenUsagePoint]
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var hoveredPointID: Date?

    private let tooltipWidth: CGFloat = 176

    private var maximumTokens: Double {
        max(1, Double(points.map(\.usage.tokens).max() ?? 0))
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2.5
            let availableWidth = proxy.size.width - spacing * CGFloat(max(points.count - 1, 0))
            let barWidth = max(2, availableWidth / CGFloat(max(points.count, 1)))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let fraction = Double(point.usage.tokens) / maximumTokens
                    let isHovered = hoveredPointID == point.id
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(tint.opacity(barOpacity(for: point, isHovered: isHovered)))
                            .frame(height: max(2, proxy.size.height * fraction))
                            .opacity(point.usage.tokens > 0 ? 1 : 0.2)
                            .scaleEffect(
                                x: isHovered ? 1.22 : 1,
                                y: appeared ? 1 : 0.05,
                                anchor: .bottom
                            )
                            .shadow(
                                color: tint.opacity(isHovered ? 0.48 : 0),
                                radius: isHovered ? 4 : 0
                            )
                            .animation(
                                reduceMotion
                                    ? nil
                                    : .spring(response: 0.32, dampingFraction: 0.82)
                                        .delay(Double(index) * 0.006),
                                value: appeared
                            )
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.1),
                                value: isHovered
                            )
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.18),
                                value: point.usage.tokens
                            )
                    }
                    .frame(width: barWidth, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .background {
                        PointingHandCursorRegion()
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredPointID = point.id
                        } else if hoveredPointID == point.id {
                            hoveredPointID = nil
                        }
                    }
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .bottomLeading
            )
            .overlay(alignment: .bottomLeading) {
                if let hoveredPointID,
                   let index = points.firstIndex(where: { $0.id == hoveredPointID }) {
                    let point = points[index]
                    let barCenter = CGFloat(index) * (barWidth + spacing) + barWidth / 2
                    let tooltipX = min(
                        max(0, barCenter - tooltipWidth / 2),
                        max(0, proxy.size.width - tooltipWidth)
                    )
                    VStack(spacing: 6) {
                        DailyUsageTooltip(point: point)
                            .frame(width: tooltipWidth)
                        Color.clear
                            .frame(width: tooltipWidth, height: proxy.size.height)
                    }
                    .offset(x: tooltipX)
                    .allowsHitTesting(false)
                    .zIndex(2)
                }
            }
        }
        .frame(height: 52)
        .onAppear { appeared = true }
        .onChange(of: points.map(\.id)) { _, ids in
            if let hoveredPointID, !ids.contains(hoveredPointID) {
                self.hoveredPointID = nil
            }
        }
    }

    private func barOpacity(for point: DailyTokenUsagePoint, isHovered: Bool) -> Double {
        if isHovered { return 1 }
        return Calendar.current.isDateInToday(point.date) ? 0.9 : 0.58
    }
}

private struct DailyUsageTooltip: View {
    let point: DailyTokenUsagePoint

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    private var dateText: String {
        point.date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .locale(language.locale)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateText)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))

            HStack(spacing: 8) {
                Text(copy.text("总用量", "Total usage"))
                Spacer(minLength: 8)
                Text(formatDetailTokensInMillions(point.usage.tokens))
                    .monospacedDigit()
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))

            ForEach(point.providerBreakdown ?? []) { breakdown in
                HStack(spacing: 6) {
                    if let descriptor = ProviderCatalog.byID[breakdown.providerID] {
                        ProviderIconView(provider: descriptor)
                            .frame(width: 13, height: 13)
                            .foregroundStyle(ProviderBrandColors.color(for: breakdown.providerID))
                    }
                    Text(providerName(for: breakdown.providerID))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(formatDetailTokensInMillions(breakdown.usage.tokens))
                        .monospacedDigit()
                }
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.72))
            }
        }
        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(red: 0.15, green: 0.15, blue: 0.17)
                        : Color.white
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.primaryText(for: colorScheme).opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.24), radius: 8, y: 3)
        }
    }

    private func providerName(for id: ProviderID) -> String {
        ProviderCatalog.byID[id]?.name ?? id.rawValue
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

        let path = Path(
            roundedRect: cardRect,
            cornerRadius: 18,
            style: .continuous
        )
        let cardEdge = railSide == .right ? cardRect.maxX - 1 : cardRect.minX + 1
        let arrowTip = railSide == .right ? rect.maxX : rect.minX
        var arrow = Path()
        arrow.move(to: CGPoint(
            x: cardEdge,
            y: midpoint - ProviderDetailLayout.arrowHalfHeight
        ))
        arrow.addLine(to: CGPoint(x: arrowTip, y: midpoint))
        arrow.addLine(to: CGPoint(
            x: cardEdge,
            y: midpoint + ProviderDetailLayout.arrowHalfHeight
        ))
        arrow.closeSubpath()
        return path.union(arrow)
    }
}

nonisolated enum QuotaStatus: Equatable {
    case ok
    case fast
    case critical

    static func evaluate(remainingFraction: Double, pace: UsagePace?) -> QuotaStatus {
        // 减法会让正好 10%、30% 的余量多出一点浮点误差。
        if remainingFraction <= Double(0.1).nextUp { return .critical }
        if let pace, pace.predictionReady {
            return pace.willLastToReset ? .ok : .fast
        }
        return remainingFraction > Double(0.3).nextUp ? .ok : .fast
    }

    var textColor: Color {
        switch self {
        case .ok: .green
        case .fast: .orange
        case .critical: .red
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let tint: Color
    var usageUpdatedAt: Date? = nil
    var refreshInterval: () -> TimeInterval = { 300 }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: AppCopy { AppCopy(language: language) }

    private var remainingFraction: Double {
        1 - window.clampedFraction
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let pace = UsagePace.evaluate(window: window, now: context.date, updatedAt: usageUpdatedAt, refreshInterval: refreshInterval())
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
                    .contentTransition(.numericText(value: remainingFraction))
                if let resetsAt = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(compactDuration(from: context.date, until: resetsAt, language: language))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.3))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())
                    }
                }
            }

            GeometryReader { proxy in
                let states = SegmentedUsageBar.states(remainingFraction: remainingFraction)
                let width = max(0, (proxy.size.width - SegmentedUsageBar.spacing * Double(SegmentedUsageBar.segmentCount - 1))
                    / Double(SegmentedUsageBar.segmentCount))
                HStack(spacing: SegmentedUsageBar.spacing) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint.opacity(state == .solid ? 1 : 0.12))
                            .frame(width: width, height: 12)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: states)
            }
            .frame(height: 12)
            .accessibilityLabel(copy.text("剩余额度", "Remaining quota"))
            .accessibilityValue("\(Int((remainingFraction * 100).rounded()))%")

            if let pace, pace.predictionReady {
                let status = QuotaStatus.evaluate(remainingFraction: remainingFraction, pace: pace)
                Text(paceText(pace, now: context.date, language: language))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(status == .ok
                        ? AppTheme.primaryText(for: colorScheme).opacity(0.6)
                        : status.textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if let detail = window.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.38))
                    .lineLimit(2)
            }
        }
        }
    }
}

func paceText(_ pace: UsagePace, now: Date, language: AppLanguage) -> String {
    let copy = AppCopy(language: language)
    if pace.actualUsedPercent >= 100 { return copy.text("已用完", "Quota depleted") }
    guard pace.deltaPercent > 0, let eta = pace.etaSeconds else {
        return copy.text("预计撑到重置", "Lasts until reset")
    }
    let delta = pace.deltaPercent.formatted(.number.precision(.fractionLength(0...1)).locale(language.locale))
    if eta < 60 {
        return copy.text("超前 \(delta)% · 预计 1 分钟内用尽", "\(delta)% ahead · runs out in <1 min")
    }
    let duration = compactDuration(from: now, until: now.addingTimeInterval(eta), language: language)
    return copy.text("超前 \(delta)% · 预计 \(duration)后用尽", "\(delta)% ahead · runs out in \(duration)")
}

private func compactDuration(from now: Date, until date: Date, language: AppLanguage) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now)))
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

func cachedUsageStatus(_ usage: ProviderUsage, language: AppLanguage) -> String? {
    guard usage.state == .unavailable || usage.state == .failed,
          UsageStore.hasCacheableData(usage) else { return nil }
    let copy = AppCopy(language: language)
    var status = copy.text("数据未更新", "Data is out of date")
    if let updatedAt = usage.updatedAt {
        let timestamp = updatedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        )
        status += " · " + copy.text("数据时间：", "Last updated: ") + timestamp
    }
    if let message = usage.message, !message.isEmpty {
        status += "\n" + DiagnosticsRedactor.redact(copy.usageMessage(message))
    }
    return status
}

func compactTokenCount(_ value: Int64) -> String {
    guard value >= 1_000 else {
        return value.formatted(.number.grouping(.automatic))
    }
    let units: [(value: Int64, suffix: String)] = [
        (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"),
    ]
    var unitIndex = value >= 1_000_000_000 ? 2 : value >= 1_000_000 ? 1 : 0
    while true {
        let amount = Double(value) / Double(units[unitIndex].value)
        let rounded = amount < 100 ? (amount * 10).rounded() / 10 : amount.rounded()
        if rounded >= 1_000, unitIndex < units.count - 1 {
            unitIndex += 1
            continue
        }
        return String(
            format: rounded < 100 ? "%.1f%@" : "%.0f%@",
            locale: Locale(identifier: "en_US_POSIX"),
            rounded, units[unitIndex].suffix
        )
    }
}

private func compactDollarValue(_ value: Double) -> String {
    if value >= 1_000 {
        return "$" + value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(0))
        )
    }
    return String(format: "$%.2f", value)
}
