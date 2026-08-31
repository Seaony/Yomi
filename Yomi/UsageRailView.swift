import AppKit
import SwiftUI

enum UsageRailSide: String {
    static let storageKey = "panel-side"

    case left
    case right
}

enum UsageRailLayout {
    static let scale: CGFloat = 0.5
    static let panelWidth: CGFloat = scaled(104)
    static let minimumPanelHeight: CGFloat = scaled(140)
    static let screenVerticalMargin: CGFloat = 12
    static let screenEdgeOverlap: CGFloat = 2
    static let leftEdgeInset: CGFloat = scaled(8)
    static let rightEdgeExtension: CGFloat = scaled(24)
    static let transitionHeight: CGFloat = panelWidth - leftEdgeInset
    static let edgeTransition: CGFloat = transitionHeight + rightEdgeExtension
    static let contentInset: CGFloat = scaled(64) + rightEdgeExtension
    static let providerSpacing: CGFloat = scaled(16)
    static let providerSectionVerticalPadding: CGFloat = scaled(6)
    static let providerSectionHorizontalPadding: CGFloat = scaled(9)
    static let providerRingDiameter: CGFloat = scaled(56)
    static let settingsDiameter: CGFloat = providerRingDiameter
    static let settingsBottomPadding: CGFloat = scaled(6)
    static let settingsAreaHeight: CGFloat = settingsDiameter + settingsBottomPadding * 2
    static let bottomExteriorSpace: CGFloat = scaled(4)
    static let bottomContentInset: CGFloat = contentInset
        - settingsAreaHeight
        + bottomExteriorSpace

    static func scaled(_ value: CGFloat) -> CGFloat {
        value * scale
    }
}

struct UsageRailView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var appPreferences = AppPreferences.shared
    let openSettings: (ProviderID?) -> Void
    let toggleProviderDetail: (ProviderDescriptor, CGFloat) -> Void
    let contentHeightChanged: (CGFloat) -> Void

    @State private var appeared = false
    @State private var isHovering = false
    @State private var providerAnchorY: [ProviderID: CGFloat] = [:]
    @State private var providerRowHeights: [ProviderID: CGFloat] = [:]
    @AppStorage(UsageRailSide.storageKey) private var railSideValue = UsageRailSide.right.rawValue
    @AppStorage("show-provider-names") private var showProviderNames = true
    @Environment(\.colorScheme) private var colorScheme

    private var railSide: UsageRailSide {
        UsageRailSide(rawValue: railSideValue) ?? .right
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: UsageRailLayout.contentInset)

            ScrollView(.vertical) {
                VStack(spacing: UsageRailLayout.providerSpacing) {
                    ForEach(Array(store.enabledProviders.enumerated()), id: \.element.id) { index, descriptor in
                        Button {
                            let rowHeight = UsageRailLayout.scaled(showProviderNames ? 101 : 84)
                            let fallbackY = UsageRailLayout.contentInset
                                + UsageRailLayout.providerSectionVerticalPadding
                                + UsageRailLayout.providerRingDiameter / 2
                                + CGFloat(index) * (rowHeight + UsageRailLayout.providerSpacing)
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
                                            + UsageRailLayout.providerRingDiameter / 2
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
                .padding(.vertical, UsageRailLayout.providerSectionVerticalPadding)
                .padding(.horizontal, UsageRailLayout.providerSectionHorizontalPadding)
            }
            .scrollIndicators(.never)

            Color.clear
                .frame(
                    height: UsageRailLayout.bottomContentInset
                        + UsageRailLayout.settingsAreaHeight
                )
        }
        .overlay(alignment: .bottom) {
            SettingsHoverControl(isHovering: isHovering, railSide: railSide) {
                openSettings(nil)
            }
            .padding(.bottom, UsageRailLayout.settingsBottomPadding)
        }
        .coordinateSpace(name: "usageRail")
        .background {
            GeometryReader { proxy in
                UsageRailShape(side: railSide)
                    .fill(AppTheme.railBackground(for: colorScheme))
                    .frame(
                        height: max(
                            0,
                            proxy.size.height - UsageRailLayout.bottomExteriorSpace
                        ),
                        alignment: .top
                    )
            }
        }
        .contentShape(UsageRailHitShape(side: railSide))
        .scaleEffect(
            appeared ? 1 : 0.96,
            anchor: railSide == .right ? .trailing : .leading
        )
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
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
        .preferredColorScheme(appPreferences.appearance.colorScheme)
    }

    private func reportContentHeight(providerRows: [ProviderID: CGFloat]) {
        let providers = store.enabledProviders
        guard providers.allSatisfy({ providerRows[$0.id] != nil }) else { return }
        let rowsHeight = providers.reduce(CGFloat.zero) { result, provider in
            result + (providerRows[provider.id] ?? 0)
        }
        let spacing = CGFloat(max(providers.count - 1, 0)) * UsageRailLayout.providerSpacing
        let sectionPadding = UsageRailLayout.providerSectionVerticalPadding * 2
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
    let railSide: UsageRailSide
    let action: () -> Void

    @State private var isControlHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .trim(from: 0, to: isHovering ? 0 : 0.25)
                    .stroke(
                        AppTheme.railBackground(for: colorScheme),
                        style: StrokeStyle(
                            lineWidth: UsageRailLayout.scaled(5),
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: railSide == .right ? 1 : -1)
                    .opacity(isHovering ? 0 : 1)

                Circle()
                    .fill(AppTheme.railBackground(for: colorScheme))
                    .frame(
                        width: UsageRailLayout.settingsDiameter,
                        height: UsageRailLayout.settingsDiameter
                    )
                    .scaleEffect(isHovering ? 1 : 0.55)
                    .opacity(isHovering ? 1 : 0)

                Image(systemName: "gearshape")
                    .font(.system(size: UsageRailLayout.scaled(26), weight: .medium))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
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
        .help(copy.text("设置", "Settings"))
        .allowsHitTesting(isHovering)
        .accessibilityHidden(!isHovering)
        .scaleEffect(isControlHovering ? 1.08 : 1)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                isControlHovering = hovering
            }
        }
        .onDisappear {
            if isControlHovering { NSCursor.arrow.set() }
        }
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
    let side: UsageRailSide

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let transition = min(UsageRailLayout.edgeTransition, height / 2)
        let curve = UsageRailEdgeCurve(width: width, transition: transition)

        var path = Path()
        path.move(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: height))
        addUsageRailEdgeCurve(to: &path, curve: curve, edge: .bottom, height: height)
        path.addLine(to: curve.point(curve.leftEndpoint, at: .top, height: height))
        addUsageRailEdgeCurve(to: &path, curve: curve, edge: .top, height: height)
        path.closeSubpath()
        guard side == .left else { return path }
        return path.applying(CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: 1,
            tx: rect.minX + rect.maxX,
            ty: 0
        ))
    }
}

private func addUsageRailEdgeCurve(
    to path: inout Path,
    curve: UsageRailEdgeCurve,
    edge: UsageRailVerticalEdge,
    height: CGFloat
) {
    switch edge {
    case .top:
        path.addCurve(
            to: curve.point(curve.midpoint, at: edge, height: height),
            control1: curve.point(curve.leftControl, at: edge, height: height),
            control2: curve.point(curve.midpointLeftControl, at: edge, height: height)
        )
        path.addCurve(
            to: curve.point(curve.rightEndpoint, at: edge, height: height),
            control1: curve.point(curve.midpointRightControl, at: edge, height: height),
            control2: curve.point(curve.rightControl, at: edge, height: height)
        )
    case .bottom:
        path.addCurve(
            to: curve.point(curve.midpoint, at: edge, height: height),
            control1: curve.point(curve.rightControl, at: edge, height: height),
            control2: curve.point(curve.midpointRightControl, at: edge, height: height)
        )
        path.addCurve(
            to: curve.point(curve.leftEndpoint, at: edge, height: height),
            control1: curve.point(curve.midpointLeftControl, at: edge, height: height),
            control2: curve.point(curve.leftControl, at: edge, height: height)
        )
    }
}

private enum UsageRailVerticalEdge {
    case top
    case bottom
}

private struct UsageRailEdgeCurve {
    let leftEndpoint: CGPoint
    let leftControl: CGPoint
    let midpointLeftControl: CGPoint
    let midpoint: CGPoint
    let midpointRightControl: CGPoint
    let rightControl: CGPoint
    let rightEndpoint: CGPoint

    init(width: CGFloat, transition: CGFloat) {
        let rightRadius = width / 2
        let leftRadius = UsageRailLayout.transitionHeight - rightRadius
        let rightVerticalRadius = transition - leftRadius
        let control = 0.552_284_75

        leftEndpoint = CGPoint(x: UsageRailLayout.leftEdgeInset, y: transition)
        midpoint = CGPoint(x: width - rightRadius, y: rightVerticalRadius)
        rightEndpoint = CGPoint(x: width, y: 0)
        leftControl = CGPoint(
            x: UsageRailLayout.leftEdgeInset,
            y: transition - leftRadius * control
        )
        midpointLeftControl = CGPoint(
            x: midpoint.x - leftRadius * control,
            y: midpoint.y
        )
        midpointRightControl = CGPoint(
            x: midpoint.x + rightRadius * control,
            y: midpoint.y
        )
        rightControl = CGPoint(
            x: width,
            y: rightVerticalRadius * control
        )
    }

    func point(
        _ point: CGPoint,
        at edge: UsageRailVerticalEdge,
        height: CGFloat
    ) -> CGPoint {
        switch edge {
        case .top:
            point
        case .bottom:
            CGPoint(x: point.x, y: height - point.y)
        }
    }
}

private struct UsageRailHitShape: Shape {
    let side: UsageRailSide

    func path(in rect: CGRect) -> Path {
        let railRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(0, rect.height - UsageRailLayout.bottomExteriorSpace)
        )
        var path = UsageRailShape(side: side).path(in: railRect)
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

enum ProviderBrandColors {
    private static let values: [String: UInt32] = [
        "abacus": 0x38BDF8,
        "aiand": 0xE25C2B,
        "alibaba": 0xFF6A00,
        "alibabatokenplan": 0xFF6A00,
        "amp": 0xDC2626,
        "antigravity": 0x60BA7E,
        "augment": 0x6366F1,
        "azureopenai": 0x0078D4,
        "bedrock": 0xFF9900,
        "chutes": 0x3184FF,
        "claude": 0xCC7C5E,
        "clawrouter": 0x596EF6,
        "clinepass": 0x61A3FA,
        "codebuff": 0x44FF00,
        "codex": 0x49A3B0,
        "commandcode": 0xA04DFD,
        "copilot": 0xA855F7,
        "crof": 0x2EAB94,
        "cursor": 0x00BFA5,
        "deepgram": 0x6467F2,
        "deepinfra": 0x2A3275,
        "deepseek": 0x527DF0,
        "devin": 0x46B482,
        "doubao": 0x3370FF,
        "elevenlabs": 0xEBEBE6,
        "factory": 0xFF6B35,
        "fireworks": 0xF25B1C,
        "gemini": 0xAB87EA,
        "grok": 0x10A37F,
        "groq": 0xF56844,
        "ibmbob": 0x0E61FA,
        "jetbrains": 0xFF3399,
        "kilo": 0xF27027,
        "kimi": 0xFE603C,
        "kiro": 0xFF9900,
        "litellm": 0x4C89F0,
        "llmproxy": 0x24B47E,
        "longcat": 0xFFD100,
        "manus": 0x34322D,
        "mimo": 0xFF6900,
        "minimax": 0xFE603C,
        "mistral": 0xFF500F,
        "moonshot": 0x205DEB,
        "neuralwatt": 0x38D98C,
        "notion": 0x337EA9,
        "ollama": 0x888888,
        "openai": 0x0F826E,
        "opencode": 0x3B82F6,
        "opencodego": 0x3B82F6,
        "openrouter": 0x6467F2,
        "perplexity": 0x20B2AA,
        "poe": 0x5D5CDE,
        "qoder": 0x10B981,
        "qwencloud": 0x615CED,
        "sakana": 0x2975DB,
        "stepfun": 0x2196F2,
        "sub2api": 0x2DC6D8,
        "synthetic": 0x141414,
        "t3chat": 0xF56647,
        "venice": 0x3399FF,
        "vertexai": 0x4285F4,
        "warp": 0x938BB4,
        "wayfinder": 0x10A37F,
        "windsurf": 0x34E8BB,
        "xai": 0x8E8E93,
        "zai": 0xE85A6A,
        "zed": 0x084EFF,
        "zenmux": 0x6C5CE7,
        "zoommate": 0x0B5CFF,
    ]

    static func color(for id: ProviderID) -> Color {
        let value = values[id.rawValue] ?? 0xFFFFFF
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct ProviderRailItem: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let animationDelay: Double
    let showName: Bool

    @State private var animatedFraction = 0.0
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        ProviderBrandColors.color(for: descriptor.id)
    }

    private var remainingFraction: Double {
        guard !usage.windows.isEmpty else { return 0 }
        return 1 - usage.headlineFraction
    }

    private var percentage: String {
        guard !usage.windows.isEmpty else { return "—" }
        return "\(Int((remainingFraction * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: UsageRailLayout.scaled(5)) {
            ZStack {
                Circle()
                    .stroke(
                        AppTheme.primaryText(for: colorScheme).opacity(0.16),
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
                    .stroke(
                        AppTheme.primaryText(for: colorScheme).opacity(0.08),
                        lineWidth: UsageRailLayout.scaled(1)
                    )
                    .padding(UsageRailLayout.scaled(7))
                ProviderIconView(provider: descriptor)
                    .frame(
                        width: UsageRailLayout.scaled(26),
                        height: UsageRailLayout.scaled(26)
                    )
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: usage.state == .loading)
            }
            .frame(
                width: UsageRailLayout.providerRingDiameter,
                height: UsageRailLayout.providerRingDiameter
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
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            }

            if showName {
                Text(descriptor.shortName)
                    .font(.system(size: UsageRailLayout.scaled(9), weight: .medium))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(hovered ? 1.045 : 1)
        .onHover { value in
            if value { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) { hovered = value }
        }
        .onDisappear {
            if hovered { NSCursor.arrow.set() }
        }
        .onAppear { animate(to: remainingFraction) }
        .onChange(of: remainingFraction) { _, value in animate(to: value) }
    }

    private func animate(to value: Double) {
        withAnimation(.spring(response: 0.72, dampingFraction: 0.84).delay(animationDelay)) {
            animatedFraction = min(max(value, 0), 1)
        }
    }
}
