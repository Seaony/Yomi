import SwiftUI

enum UsageRailLayout {
    static let transitionHeight: CGFloat = 88
}

struct UsageRailView: View {
    @ObservedObject var store: UsageStore
    let openSettings: (ProviderID?) -> Void
    let contentHeightChanged: (CGFloat) -> Void

    @State private var selectedProvider: ProviderID?
    @State private var appeared = false
    @State private var isHovering = false
    @State private var providerSectionHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @AppStorage("show-provider-names") private var showProviderNames = true

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: UsageRailLayout.transitionHeight)

            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(Array(store.enabledProviders.enumerated()), id: \.element.id) { index, descriptor in
                        ProviderRailItem(
                            descriptor: descriptor,
                            usage: store.usage(for: descriptor.id),
                            animationDelay: Double(index) * 0.045,
                            showName: showProviderNames
                        )
                        .onTapGesture {
                            selectedProvider = selectedProvider == descriptor.id ? nil : descriptor.id
                        }
                        .popover(
                            isPresented: Binding(
                                get: { selectedProvider == descriptor.id },
                                set: { if !$0 { selectedProvider = nil } }
                            ),
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .leading
                        ) {
                            ProviderDetailCard(
                                descriptor: descriptor,
                                usage: store.usage(for: descriptor.id),
                                refresh: { Task { await store.refresh() } },
                                settings: { openSettings(descriptor.id) }
                            )
                            .presentationBackground(.clear)
                        }
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ProviderSectionHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .scrollIndicators(.never)

            VStack(spacing: 0) {
                Divider()
                    .overlay(.white.opacity(0.08))
                    .padding(.horizontal, 16)

                Button {
                    openSettings(nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("设置")
                .foregroundStyle(.white)
                .padding(.vertical, 10)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FooterHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }

            Color.clear
                .frame(height: UsageRailLayout.transitionHeight)
        }
        .background {
            UsageRailShape()
                .fill(.black.opacity(isHovering ? 0.96 : 0.92))
                .overlay {
                    UsageRailShape()
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                }
        }
        .contentShape(UsageRailShape())
        .scaleEffect(appeared ? 1 : 0.96, anchor: .trailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { appeared = true }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .onPreferenceChange(ProviderSectionHeightKey.self) { height in
            providerSectionHeight = height
            reportContentHeight(providerSection: height, footer: footerHeight)
        }
        .onPreferenceChange(FooterHeightKey.self) { height in
            footerHeight = height
            reportContentHeight(providerSection: providerSectionHeight, footer: height)
        }
        .preferredColorScheme(.dark)
    }

    private func reportContentHeight(providerSection: CGFloat, footer: CGFloat) {
        guard providerSection > 0, footer > 0 else { return }
        contentHeightChanged(
            providerSection + footer + UsageRailLayout.transitionHeight * 2
        )
    }
}

private struct UsageRailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let transition = min(UsageRailLayout.transitionHeight, height / 3)

        var path = Path()
        path.move(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height))
        path.addCurve(
            to: CGPoint(x: width * 0.52, y: height - transition * 0.52),
            control1: CGPoint(x: width, y: height - transition * 0.32),
            control2: CGPoint(x: width * 0.86, y: height - transition * 0.5)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: height - transition),
            control1: CGPoint(x: width * 0.18, y: height - transition * 0.54),
            control2: CGPoint(x: 0, y: height - transition * 0.68)
        )
        path.addLine(to: CGPoint(x: 0, y: transition))
        path.addCurve(
            to: CGPoint(x: width * 0.52, y: transition * 0.52),
            control1: CGPoint(x: 0, y: transition * 0.68),
            control2: CGPoint(x: width * 0.18, y: transition * 0.54)
        )
        path.addCurve(
            to: CGPoint(x: width, y: 0),
            control1: CGPoint(x: width * 0.86, y: transition * 0.5),
            control2: CGPoint(x: width, y: transition * 0.32)
        )
        path.closeSubpath()
        return path
    }
}

private struct ProviderSectionHeightKey: PreferenceKey {
    nonisolated static let defaultValue: CGFloat = 0

    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FooterHeightKey: PreferenceKey {
    nonisolated static let defaultValue: CGFloat = 0

    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ProviderRailItem: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let animationDelay: Double
    let showName: Bool

    @State private var animatedFraction = 0.0
    @State private var hovered = false

    private var tint: Color {
        Color(hue: descriptor.hue, saturation: 0.92, brightness: 1)
    }

    private var percentage: String {
        guard !usage.windows.isEmpty else { return "—" }
        return "\(Int((usage.headlineFraction * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Circle()
                    .trim(from: 0, to: animatedFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                    .padding(7)
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: usage.state == .loading)
            }
            .frame(width: 56, height: 56)
            .shadow(color: tint.opacity(hovered ? 0.35 : 0), radius: 12)

            Text(percentage)
                .font(.system(size: 19, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            if showName {
                Text(descriptor.shortName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(hovered ? 1.045 : 1)
        .onHover { value in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) { hovered = value }
        }
        .onAppear { animate(to: usage.headlineFraction) }
        .onChange(of: usage.headlineFraction) { _, value in animate(to: value) }
    }

    private func animate(to value: Double) {
        withAnimation(.spring(response: 0.72, dampingFraction: 0.84).delay(animationDelay)) {
            animatedFraction = min(max(value, 0), 1)
        }
    }
}
