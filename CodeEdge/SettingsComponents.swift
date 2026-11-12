import SwiftUI

enum CodeEdgeSettingsTheme {
    static let background = Color("SettingsBackground")
    static let surface = Color("SettingsSurface")
    static let border = Color("SettingsBorder")
    static let controlFill = Color("SettingsControlFill")
    static let field = Color("SettingsField")
    static let primaryText = Color("SettingsPrimaryText")
    static let secondaryText = Color("SettingsSecondaryText")
    static let tertiaryText = Color("SettingsTertiaryText")
    static let accent = Color("SettingsAccent")
    static let actionText = Color("SettingsActionText")
    static let actionHover = Color("SettingsActionHover")
    static let actionPressed = Color("SettingsActionPressed")
    static let disabledText = Color("SettingsDisabledText")
    static let disabledSurface = Color("SettingsDisabledSurface")
    static let focus = Color("SettingsFocus")
    static let error = Color("SettingsError")
    static let warning = Color("SettingsWarning")
    static let selection = Color("SettingsSelection")
    // 状态色只用于标记，说明文字使用上面的语义文本色。
    static let statusGreen = Color("SettingsStatusGreen")
    static let statusBlue = Color("SettingsStatusBlue")
    static let statusAmber = Color("SettingsStatusAmber")
    static let statusRed = Color("SettingsStatusRed")
}

enum SettingsSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let section: CGFloat = 32
    static let margin = xl
}

struct CodeEdgeFormSection<Content: View, Footer: View>: View {
    var title: String?
    let content: Content
    let footer: Footer

    init(
        title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: SettingsSpace.sm) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                    .padding(.horizontal, SettingsSpace.xs)
            }
            Group(subviews: content) { rows in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        row.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, SettingsSpace.sm)
                        if index < rows.count - 1 {
                            CodeEdgeSeparator().padding(.horizontal, 14)
                        }
                    }
                }
            }
            .background(CodeEdgeSettingsTheme.surface, in: shape)
            .overlay { shape.strokeBorder(CodeEdgeSettingsTheme.border, lineWidth: 0.5) }
            footer.font(.system(size: 12))
                .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsSpace.xs)
        }
    }
}

extension CodeEdgeFormSection where Footer == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, footer: { EmptyView() })
    }
}

struct CodeEdgeSideRow<Label: View, Control: View>: View {
    let label: Label
    let control: Control

    init(@ViewBuilder control: () -> Control, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.control = control()
    }

    var body: some View {
        HStack(spacing: SettingsSpace.md) {
            label.font(.system(size: 13))
                .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
            Spacer(minLength: 0)
            control
        }
    }
}

extension CodeEdgeSideRow where Label == Text {
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.init(control: control) { Text(title) }
    }
}

struct CodeEdgeFormRow<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsSpace.md) {
            label.font(.system(size: 13))
                .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
                .frame(width: 110, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

extension CodeEdgeFormRow where Label == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(label: Text(title), content: content())
    }
}

struct CodeEdgeFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodeEdgeFormRow(label: configuration.label, content: configuration.content)
    }
}

struct CodeEdgeFormSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsSpace.lg) {
            configuration.label.font(.system(size: 13))
                .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

struct CodeEdgeSeparator: View {
    var body: some View {
        Rectangle().fill(CodeEdgeSettingsTheme.border)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

struct CodeEdgeChoiceButtons<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String?
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                CodeEdgeChoiceSegment(
                    title: title(option), symbol: symbol(option),
                    selected: option == selection, space: selectionSpace
                ) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        selection = option
                    }
                }
            }
        }
        .padding(3)
        .background(
            CodeEdgeSettingsTheme.controlFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct CodeEdgeChoiceSegment: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(
                !isEnabled ? CodeEdgeSettingsTheme.disabledText
                    : selected ? CodeEdgeSettingsTheme.actionText : CodeEdgeSettingsTheme.primaryText
            )
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background {
                if selected {
                    shape.fill(isEnabled ? CodeEdgeSettingsTheme.accent : CodeEdgeSettingsTheme.disabledSurface)
                        .matchedGeometryEffect(id: "selected", in: space)
                } else if hovering && isEnabled {
                    shape.fill(CodeEdgeSettingsTheme.primaryText.opacity(0.06))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(CodeEdgeChoicePressStyle())
        .pointerStyle(isEnabled ? .link : nil)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CodeEdgeChoicePressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .overlay {
                shape.fill(CodeEdgeSettingsTheme.primaryText.opacity(configuration.isPressed && isEnabled ? 0.12 : 0))
            }
            .overlay {
                shape.strokeBorder(isFocused ? CodeEdgeSettingsTheme.focus : .clear, lineWidth: 2)
            }
            .offset(y: configuration.isPressed && isEnabled && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CodeEdgeFlatButtonStyle: ButtonStyle {
    var prominent = false
    var focusOverride: Bool? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let focused = focusOverride ?? isFocused
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .foregroundStyle(foreground(configuration))
            .background(background(configuration), in: shape)
            .overlay { shape.fill(CodeEdgeSettingsTheme.primaryText.opacity(overlayOpacity(configuration))) }
            .overlay {
                shape.strokeBorder(focused ? CodeEdgeSettingsTheme.focus : .clear, lineWidth: 2)
            }
            .contentShape(shape)
            .pointerStyle(isEnabled ? .link : nil)
            .offset(y: configuration.isPressed && isEnabled && !reduceMotion ? 1 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
    }

    private func background(_ configuration: Configuration) -> Color {
        guard isEnabled else { return CodeEdgeSettingsTheme.disabledSurface }
        guard prominent else { return CodeEdgeSettingsTheme.controlFill }
        return configuration.isPressed ? CodeEdgeSettingsTheme.actionPressed
            : hovering ? CodeEdgeSettingsTheme.actionHover : CodeEdgeSettingsTheme.accent
    }

    private func overlayOpacity(_ configuration: Configuration) -> Double {
        guard isEnabled, !prominent else { return 0 }
        if configuration.isPressed { return 0.12 }
        return hovering ? 0.06 : 0
    }

    private func foreground(_ configuration: Configuration) -> Color {
        if !isEnabled { return CodeEdgeSettingsTheme.disabledText }
        if prominent { return CodeEdgeSettingsTheme.actionText }
        return configuration.role == .destructive ? CodeEdgeSettingsTheme.error : CodeEdgeSettingsTheme.primaryText
    }
}

struct CodeEdgeSettingsForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpace.xl) { content }
            .padding(.horizontal, SettingsSpace.xl)
            .padding(.vertical, SettingsSpace.lg)
            .labeledContentStyle(CodeEdgeFormRowStyle())
            .toggleStyle(CodeEdgeFormSwitchStyle())
            .controlSize(.regular)
            .codeEdgeSettingsPageTop()
            .fixedSize(horizontal: false, vertical: true)
            .background(CodeEdgeSettingsTheme.background)
    }
}

private struct CodeEdgeSettingsFieldModifier: ViewModifier {
    let focused: Bool
    let horizontalPadding: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, horizontalPadding)
            .frame(height: 28)
            .background(CodeEdgeSettingsTheme.field, in: shape)
            .overlay {
                shape.strokeBorder(
                    focused ? CodeEdgeSettingsTheme.focus : CodeEdgeSettingsTheme.border,
                    lineWidth: focused ? 2 : 0.5
                )
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
            // 输入框加高后，把基线放回框内文字的位置。
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

extension View {
    func codeEdgeSettingsPageTop() -> some View {
        scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .overlay(alignment: .top) { CodeEdgeSeparator() }
    }

    func codeEdgeSettingsField(focused: Bool = false, horizontalPadding: CGFloat = 10) -> some View {
        modifier(CodeEdgeSettingsFieldModifier(focused: focused, horizontalPadding: horizontalPadding))
    }
}
