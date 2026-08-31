import SwiftUI

enum UsageRailLayout {
    static let scale: CGFloat = 0.5
    static let panelWidth: CGFloat = scaled(104)
    static let minimumPanelHeight: CGFloat = scaled(140)
    static let transitionHeight: CGFloat = scaled(88)
    static let contentInset: CGFloat = scaled(64)
    static let bottomContentInset: CGFloat = scaled(16)
    static let settingsDiameter: CGFloat = scaled(56)
    static let settingsAreaHeight: CGFloat = scaled(68)
    static let settingsBottomPadding: CGFloat = scaled(6)
    static let settingsArcSize: CGFloat = scaled(64)
    static let settingsArcBottomPadding: CGFloat = scaled(4)

    static func scaled(_ value: CGFloat) -> CGFloat {
        value * scale
    }
}

struct UsageRailView: View {
    @ObservedObject var store: UsageStore
    let openSettings: (ProviderID?) -> Void
    let toggleProviderDetail: (ProviderDescriptor, CGFloat) -> Void
    let contentHeightChanged: (CGFloat) -> Void

    @State private var appeared = false
    @State private var isHovering = false
    @State private var providerAnchorY: [ProviderID: CGFloat] = [:]
    @State private var providerRowHeights: [ProviderID: CGFloat] = [:]
    @AppStorage("show-provider-names") private var showProviderNames = true

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: UsageRailLayout.contentInset)

            ScrollView(.vertical) {
                VStack(spacing: UsageRailLayout.scaled(12)) {
                    ForEach(Array(store.enabledProviders.enumerated()), id: \.element.id) { index, descriptor in
                        Button {
                            let rowHeight = UsageRailLayout.scaled(showProviderNames ? 101 : 84)
                            let fallbackY = UsageRailLayout.contentInset
                                + UsageRailLayout.scaled(6)
                                + UsageRailLayout.scaled(28)
                                + CGFloat(index) * (rowHeight + UsageRailLayout.scaled(12))
                            let anchorY = providerAnchorY[descriptor.id] ?? fallbackY
                            toggleProviderDetail(descriptor, anchorY)
                        } label: {
                            ProviderRailItem(
                                descriptor: descriptor,
                                usage: store.usage(for: descriptor.id),
                                animationDelay: Double(index) * 0.045,
                                showName: showProviderNames
                            )
                        }
                        .buttonStyle(.plain)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProviderAnchorYKey.self,
                                    value: [
                                        descriptor.id: proxy.frame(in: .named("usageRail")).minY
                                            + UsageRailLayout.scaled(28)
                                    ]
                                )
                                .preference(
                                    key: ProviderRowHeightKey.self,
                                    value: [descriptor.id: proxy.size.height]
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, UsageRailLayout.scaled(6))
                .padding(.horizontal, UsageRailLayout.scaled(9))
            }
            .scrollIndicators(.never)

            Color.clear
                .frame(
                    height: UsageRailLayout.bottomContentInset
                        + UsageRailLayout.settingsAreaHeight
                )
        }
        .overlay(alignment: .bottom) {
            SettingsHoverControl(isHovering: isHovering) {
                openSettings(nil)
            }
            .padding(.bottom, UsageRailLayout.settingsBottomPadding)
        }
        .overlay(alignment: .bottom) {
            SettingsQuarterArcShape()
                .trim(
                    from: isHovering ? 0.5 : 0,
                    to: isHovering ? 0.5 : 1
                )
                .stroke(
                    .black,
                    style: StrokeStyle(
                        lineWidth: UsageRailLayout.scaled(5),
                        lineCap: .round
                    )
                )
                .frame(
                    width: UsageRailLayout.settingsArcSize,
                    height: UsageRailLayout.settingsArcSize
                )
                .offset(x: -UsageRailLayout.scaled(16))
                .padding(.bottom, UsageRailLayout.settingsArcBottomPadding)
                .opacity(isHovering ? 0 : 1)
                .animation(
                    .spring(response: 0.34, dampingFraction: 0.78),
                    value: isHovering
                )
        }
        .coordinateSpace(name: "usageRail")
        .background {
            UsageRailShape()
                .fill(.black)
        }
        .contentShape(UsageRailHitShape())
        .scaleEffect(appeared ? 1 : 0.96, anchor: .trailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { appeared = true }
            reportContentHeight(providerRows: providerRowHeights)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .onPreferenceChange(ProviderRowHeightKey.self) { heights in
            providerRowHeights = heights
            reportContentHeight(providerRows: heights)
        }
        .onChange(of: store.enabledProviders.map(\.id)) { _, _ in
            reportContentHeight(providerRows: providerRowHeights)
        }
        .onPreferenceChange(ProviderAnchorYKey.self) { providerAnchorY = $0 }
        .preferredColorScheme(.dark)
    }

    private func reportContentHeight(providerRows: [ProviderID: CGFloat]) {
        let providers = store.enabledProviders
        guard providers.allSatisfy({ providerRows[$0.id] != nil }) else { return }
        let rowsHeight = providers.reduce(CGFloat.zero) { result, provider in
            result + (providerRows[provider.id] ?? 0)
        }
        let spacing = CGFloat(max(providers.count - 1, 0)) * UsageRailLayout.scaled(12)
        let sectionPadding = UsageRailLayout.scaled(12)
        let height = rowsHeight
            + spacing
            + sectionPadding
            + UsageRailLayout.contentInset
            + UsageRailLayout.bottomContentInset
            + UsageRailLayout.settingsAreaHeight
        contentHeightChanged(height)
    }
}

private struct SettingsHoverControl: View {
    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.black)
                    .frame(
                        width: UsageRailLayout.settingsDiameter,
                        height: UsageRailLayout.settingsDiameter
                    )
                    .scaleEffect(isHovering ? 1 : 0.55)
                    .opacity(isHovering ? 1 : 0)

                Image(systemName: "gearshape")
                    .font(.system(size: UsageRailLayout.scaled(26), weight: .medium))
                    .foregroundStyle(.white)
                    .scaleEffect(isHovering ? 1 : 0.55)
                    .rotationEffect(.degrees(isHovering ? 0 : -35))
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(
                width: UsageRailLayout.settingsDiameter,
                height: UsageRailLayout.settingsDiameter
            )
        }
        .buttonStyle(.plain)
        .help("设置")
        .allowsHitTesting(isHovering)
        .accessibilityHidden(!isHovering)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isHovering)
    }
}

private struct ProviderAnchorYKey: PreferenceKey {
    nonisolated static let defaultValue: [ProviderID: CGFloat] = [:]

    nonisolated static func reduce(
        value: inout [ProviderID: CGFloat],
        nextValue: () -> [ProviderID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ProviderRowHeightKey: PreferenceKey {
    nonisolated static let defaultValue: [ProviderID: CGFloat] = [:]

    nonisolated static func reduce(
        value: inout [ProviderID: CGFloat],
        nextValue: () -> [ProviderID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct UsageRailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let topTransition = min(UsageRailLayout.transitionHeight, height / 2)
        let bottomTransition = min(
            UsageRailLayout.transitionHeight + UsageRailLayout.bottomContentInset,
            height - topTransition
        )

        var path = Path()
        path.move(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height))
        addUsageRailBottomCurve(to: &path, in: rect, transition: bottomTransition)
        path.addLine(to: CGPoint(x: 0, y: topTransition))
        path.addCurve(
            to: CGPoint(x: width * 0.52, y: topTransition * 0.52),
            control1: CGPoint(x: 0, y: topTransition * 0.68),
            control2: CGPoint(x: width * 0.18, y: topTransition * 0.54)
        )
        path.addCurve(
            to: CGPoint(x: width, y: 0),
            control1: CGPoint(x: width * 0.86, y: topTransition * 0.5),
            control2: CGPoint(x: width, y: topTransition * 0.32)
        )
        path.closeSubpath()
        return path
    }
}

private struct SettingsQuarterArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height)
        let control = radius * 0.552_284_75
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            control1: CGPoint(x: rect.minX + control, y: rect.minY),
            control2: CGPoint(
                x: rect.minX + radius,
                y: rect.minY + radius - control
            )
        )
        return path
    }
}

private func addUsageRailBottomCurve(
    to path: inout Path,
    in rect: CGRect,
    transition: CGFloat
) {
    let width = rect.width
    let height = rect.height
    let horizontalRadius = width / 2
    let verticalRadius = transition / 2
    let control = 0.552_284_75
    let midpoint = CGPoint(
        x: horizontalRadius,
        y: height - verticalRadius
    )
    path.addCurve(
        to: midpoint,
        control1: CGPoint(
            x: width,
            y: height - verticalRadius * control
        ),
        control2: CGPoint(
            x: horizontalRadius + horizontalRadius * control,
            y: midpoint.y
        )
    )
    path.addCurve(
        to: CGPoint(x: 0, y: height - transition),
        control1: CGPoint(
            x: horizontalRadius - horizontalRadius * control,
            y: midpoint.y
        ),
        control2: CGPoint(
            x: 0,
            y: height - transition + verticalRadius * control
        )
    )
}

private struct UsageRailHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = UsageRailShape().path(in: rect)
        path.addEllipse(
            in: CGRect(
                x: rect.midX - UsageRailLayout.settingsDiameter / 2,
                y: rect.maxY
                    - UsageRailLayout.settingsBottomPadding
                    - UsageRailLayout.settingsDiameter,
                width: UsageRailLayout.settingsDiameter,
                height: UsageRailLayout.settingsDiameter
            )
        )
        return path
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
        VStack(spacing: UsageRailLayout.scaled(5)) {
            ZStack {
                Circle()
                    .stroke(
                        .white.opacity(0.16),
                        style: StrokeStyle(
                            lineWidth: UsageRailLayout.scaled(6),
                            lineCap: .round
                        )
                    )
                Circle()
                    .trim(from: 0, to: animatedFraction)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: UsageRailLayout.scaled(4),
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: UsageRailLayout.scaled(1))
                    .padding(UsageRailLayout.scaled(7))
                ProviderIconView(provider: descriptor)
                    .frame(
                        width: UsageRailLayout.scaled(26),
                        height: UsageRailLayout.scaled(26)
                    )
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: usage.state == .loading)
            }
            .frame(
                width: UsageRailLayout.scaled(56),
                height: UsageRailLayout.scaled(56)
            )
            .shadow(
                color: tint.opacity(hovered ? 0.35 : 0),
                radius: UsageRailLayout.scaled(12)
            )

            if !usage.windows.isEmpty {
                Text(percentage)
                    .font(
                        .system(
                            size: UsageRailLayout.scaled(19),
                            weight: .regular,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            if showName {
                Text(descriptor.shortName)
                    .font(.system(size: UsageRailLayout.scaled(9), weight: .medium))
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
