import SwiftUI

struct ProviderDetailCard: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let refresh: () -> Void
    let settings: () -> Void

    private var tint: Color {
        ProviderBrandColors.color(for: descriptor.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                ProviderIconView(provider: descriptor)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(descriptor.name) Usage")
                        .font(.system(size: 17, weight: .semibold))
                    if let plan = usage.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                Button(action: settings) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if usage.windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(usage.state == .loading ? "正在读取用量" : "暂时无法显示用量", systemImage: statusSymbol)
                        .font(.system(size: 13, weight: .medium))
                    if let message = usage.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.48))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            } else {
                ForEach(Array(usage.windows.prefix(3))) { window in
                    UsageWindowRow(window: window, tint: tint)
                }
            }

            HStack {
                if let balance = usage.balance {
                    Text("余额 \(balance)")
                }
                Spacer()
                if let updatedAt = usage.updatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.38))
        }
        .padding(18)
        .frame(width: 360)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
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
    let settings: () -> Void

    var body: some View {
        ProviderDetailCard(
            descriptor: descriptor,
            usage: store.usage(for: descriptor.id),
            refresh: { Task { await store.refresh() } },
            settings: settings
        )
        .padding(.trailing, ProviderDetailPanelShape.arrowWidth)
        .background {
            ProviderDetailPanelShape()
                .fill(.black)
                .shadow(color: .black.opacity(0.38), radius: 24, y: 12)
        }
        .padding(24)
    }
}

private struct ProviderDetailPanelShape: Shape {
    static let arrowWidth: CGFloat = 16

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
            cornerRadius: 24,
            style: .continuous
        )
        path.move(to: CGPoint(x: cardRect.maxX - 1, y: midpoint - 14))
        path.addLine(to: CGPoint(x: rect.maxX, y: midpoint))
        path.addLine(to: CGPoint(x: cardRect.maxX - 1, y: midpoint + 14))
        path.closeSubpath()
        return path
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.44))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, proxy.size.width * window.clampedFraction))
                }
            }
            .frame(height: 7)

            HStack {
                Text("\(Int((window.clampedFraction * 100).rounded()))% Used")
                Spacer()
                if let detail = window.detail { Text(detail) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var resetText: String {
        guard let date = window.resetsAt else { return "" }
        return "Resets \(date.formatted(.relative(presentation: .numeric)))"
    }
}
