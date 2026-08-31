import SwiftUI

struct UsageRailView: View {
    @ObservedObject var store: UsageStore
    let openSettings: (ProviderID?) -> Void

    @State private var selectedProvider: ProviderID?
    @State private var appeared = false
    @State private var isHovering = false
    @AppStorage("show-provider-names") private var showProviderNames = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 15) {
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
                .padding(.top, 25)
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            Divider()
                .overlay(.white.opacity(0.08))
                .padding(.horizontal, 22)

            HStack(spacing: 10) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: Circle())
                        .symbolEffect(.rotate, isActive: store.isRefreshing)
                }
                .buttonStyle(.plain)
                .help("刷新用量")

                Button {
                    openSettings(nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .foregroundStyle(.white)
            .padding(.vertical, 13)
        }
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 42,
                bottomLeadingRadius: 42,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black.opacity(isHovering ? 0.96 : 0.92))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [.white.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 1)
            }
        }
        .scaleEffect(appeared ? 1 : 0.96, anchor: .trailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { appeared = true }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .preferredColorScheme(.dark)
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
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                Circle()
                    .trim(from: 0, to: animatedFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                    .padding(8)
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: usage.state == .loading)
            }
            .frame(width: 62, height: 62)
            .shadow(color: tint.opacity(hovered ? 0.35 : 0), radius: 12)

            Text(percentage)
                .font(.system(size: 21, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            if showName {
                Text(descriptor.shortName)
                    .font(.system(size: 9.5, weight: .medium))
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
