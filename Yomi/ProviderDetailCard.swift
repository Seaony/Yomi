import SwiftUI

struct ProviderDetailCard: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage

    private var tint: Color {
        ProviderBrandColors.color(for: descriptor.id)
    }

    private var headlineValue: String {
        guard let tokens = usage.today?.tokens else { return "—" }
        return compactTokenCount(tokens)
    }

    private var headlineCaption: String {
        let value = usage.today?.valueUSD.map { String(format: "$%.2f", $0) } ?? "$—"
        return "今日 Token · \(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if usage.windows.isEmpty {
                emptyState
            } else {
                headline

                VStack(spacing: 11) {
                    ForEach(Array(usage.windows.prefix(3))) { window in
                        UsageWindowRow(window: window, tint: tint)
                    }
                }

                footer
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(descriptor.name)
                .font(.system(size: 15, weight: .bold, design: .rounded))

            Spacer()

            if let plan = usage.plan {
                Text(plan)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                usage.state == .loading ? "正在读取用量" : "暂时无法显示用量",
                systemImage: statusSymbol
            )
            .font(.system(size: 12, weight: .semibold))

            if let message = usage.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let reset = usage.windows.compactMap(\.resetsAt).min() {
                Text("\(compactDuration(until: reset)) 后重置")
            } else if let updatedAt = usage.updatedAt {
                Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
            }

            Spacer()

            if let balance = usage.balance {
                Text("余额 \(balance)")
            } else {
                Text("\(usage.windows.count) 个额度窗口")
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let descriptor: ProviderDescriptor

    var body: some View {
        ProviderDetailCard(
            descriptor: descriptor,
            usage: store.usage(for: descriptor.id)
        )
        .padding(.trailing, ProviderDetailPanelShape.arrowWidth)
        .background {
            ProviderDetailPanelShape()
                .fill(Color(red: 0.075, green: 0.075, blue: 0.085))
        }
        .padding(16)
    }
}

private struct ProviderDetailPanelShape: Shape {
    static let arrowWidth: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let cardRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width - Self.arrowWidth,
            height: rect.height
        )
        let midpoint = rect.midY

        var path = Path(
            roundedRect: cardRect,
            cornerRadius: 18,
            style: .continuous
        )
        path.move(to: CGPoint(x: cardRect.maxX - 1, y: midpoint - 10))
        path.addLine(to: CGPoint(x: rect.maxX, y: midpoint))
        path.addLine(to: CGPoint(x: cardRect.maxX - 1, y: midpoint + 10))
        path.closeSubpath()
        return path
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let tint: Color

    private var remainingFraction: Double {
        1 - window.clampedFraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Text("\(Int((remainingFraction * 100).rounded()))% left")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                if !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * remainingFraction))
                }
            }
            .frame(height: 5)

            if let detail = window.detail {
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
    }

    private var resetText: String {
        guard let date = window.resetsAt else { return "" }
        return compactDuration(until: date)
    }
}

private func compactDuration(until date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60

    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func compactTokenCount(_ value: Int64) -> String {
    if value >= 100_000_000 {
        return String(format: "%.1f亿", Double(value) / 100_000_000)
    }
    if value >= 10_000 {
        return String(format: "%.1f万", Double(value) / 10_000)
    }
    return value.formatted(.number.grouping(.automatic))
}
