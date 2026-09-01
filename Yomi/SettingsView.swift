import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsPalette {
    static let panel = adaptive(light: rgb(0xF1F1F4), dark: rgb(0x0A0A0C))
    static let card = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x17171A))
    static let inset = adaptive(light: rgb(0xF4F4F7), dark: rgb(0x101012))
    static let control = adaptive(light: rgb(0xEAEAEF), dark: rgb(0x1C1C1F))
    static let controlHover = adaptive(light: rgb(0xE0E0E6), dark: rgb(0x26262A))
    static let selected = adaptive(light: rgb(0xE4EFFF), dark: rgb(0x202634))
    static let line = adaptive(
        light: rgb(0x000000, alpha: 0.09),
        dark: rgb(0xFFFFFF, alpha: 0.07)
    )
    static let primary = adaptive(light: rgb(0x16161A), dark: rgb(0xFFFFFF))
    static let secondary = adaptive(
        light: rgb(0x000000, alpha: 0.68),
        dark: rgb(0xFFFFFF, alpha: 0.60)
    )
    static let tertiary = adaptive(
        light: rgb(0x000000, alpha: 0.50),
        dark: rgb(0xFFFFFF, alpha: 0.44)
    )
    static let blue = Color(nsColor: rgb(0x0A84FF))
    static let green = adaptive(light: rgb(0x1F9E46), dark: rgb(0x30D158))
    static let orange = Color(nsColor: rgb(0xFF9F0A))
    static let red = Color(nsColor: rgb(0xFF453A))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private struct SettingsPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .pointerStyle(.link)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPalette.secondary)
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsPalette.line, lineWidth: 1)
        }
    }
}

private struct SettingsChoiceButton: View {
    let title: String
    let systemImage: String?
    let selected: Bool
    var expands = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : SettingsPalette.secondary)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                selected
                    ? SettingsPalette.blue
                    : (hovered ? SettingsPalette.controlHover : SettingsPalette.control)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SettingsPressButtonStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primary)
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPalette.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(SettingsPalette.blue)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .pointerStyle(.link)
    }
}

struct SettingsView: View {
    enum Section: Hashable, CaseIterable {
        case general
        case providers
        case about
    }

    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateController
    @ObservedObject private var appPreferences = AppPreferences.shared
    let initialProviderID: ProviderID?

    @State private var selection: Section = .general
    @State private var selectedProviderID: ProviderID?
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: AppCopy { AppCopy(language: appPreferences.language) }

    init(
        store: UsageStore,
        updates: UpdateController,
        initialProviderID: ProviderID? = nil
    ) {
        self.store = store
        self.updates = updates
        self.initialProviderID = initialProviderID
        _selectedProviderID = State(initialValue: initialProviderID)
        _selection = State(initialValue: initialProviderID == nil ? .general : .providers)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sidebar

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .providers:
                    ProviderSettingsView(
                        store: store,
                        selectedProviderID: $selectedProviderID,
                        searchText: $searchText
                    )
                case .about:
                    AboutSettingsView(updateController: updates)
                }
            }
            .id(selection)
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .scale(scale: 0.99, anchor: .top))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(minWidth: 920, minHeight: 600)
        .foregroundStyle(SettingsPalette.primary)
        .tint(SettingsPalette.blue)
        .background(SettingsPalette.panel)
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
        .preferredColorScheme(appPreferences.appearance.colorScheme)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9),
            value: selection
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: symbol(for: item))
                            .frame(width: 16)
                        Text(title(for: item))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        selection == item ? SettingsPalette.primary : SettingsPalette.tertiary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(selection == item ? SettingsPalette.control : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(SettingsPressButtonStyle())
            }

            Spacer()
        }
        .frame(width: 184)
    }

    private func title(for section: Section) -> String {
        switch section {
        case .general: copy.text("通用", "General")
        case .providers: "Providers"
        case .about: copy.text("关于", "About")
        }
    }

    private func symbol(for section: Section) -> String {
        switch section {
        case .general: "slider.horizontal.3"
        case .providers: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var appPreferences = AppPreferences.shared
    @AppStorage("refresh-interval") private var refreshInterval = 300.0
    @AppStorage("show-provider-names") private var showProviderNames = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var railBackgroundHex = ""
    @Environment(\.appLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme

    private var copy: AppCopy { AppCopy(language: language) }

    private var railBackgroundColor: Binding<Color> {
        Binding(
            get: {
                appPreferences.railBackgroundColor
                    ?? AppTheme.railBackground(for: colorScheme)
            },
            set: { appPreferences.setRailBackgroundColor($0) }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                SettingsCard(copy.text("语言", "Language")) {
                    HStack(spacing: 7) {
                        SettingsChoiceButton(
                            title: "English",
                            systemImage: "character.book.closed",
                            selected: appPreferences.language == .english,
                            expands: true
                        ) {
                            appPreferences.language = .english
                        }
                        SettingsChoiceButton(
                            title: "简体中文",
                            systemImage: "character.book.closed.zh",
                            selected: appPreferences.language == .simplifiedChinese,
                            expands: true
                        ) {
                            appPreferences.language = .simplifiedChinese
                        }
                    }
                    Text(copy.text(
                        "切换设置、悬浮栏和详情卡片的显示语言。",
                        "Changes the language across settings, the floating rail, and detail cards."
                    ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.tertiary)
                }

                SettingsCard(copy.text("外观", "Appearance")) {
                    HStack(spacing: 7) {
                        SettingsChoiceButton(
                            title: copy.text("系统", "System"),
                            systemImage: "circle.lefthalf.filled",
                            selected: appPreferences.appearance == .system,
                            expands: true
                        ) {
                            appPreferences.appearance = .system
                        }
                        SettingsChoiceButton(
                            title: copy.text("深色", "Dark"),
                            systemImage: "moon.fill",
                            selected: appPreferences.appearance == .dark,
                            expands: true
                        ) {
                            appPreferences.appearance = .dark
                        }
                        SettingsChoiceButton(
                            title: copy.text("浅色", "Light"),
                            systemImage: "sun.max.fill",
                            selected: appPreferences.appearance == .light,
                            expands: true
                        ) {
                            appPreferences.appearance = .light
                        }
                    }
                    Text(copy.text(
                        "系统模式会自动跟随 macOS 的外观设置。",
                        "System mode follows the current macOS appearance."
                    ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.tertiary)

                    Rectangle().fill(SettingsPalette.line).frame(height: 1)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(copy.text("悬浮侧边栏背景", "Floating rail background"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SettingsPalette.primary)
                            Text(copy.text(
                                "自定义悬浮侧边栏的背景颜色",
                                "Customize the floating rail background color"
                            ))
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsPalette.tertiary)
                        }

                        Spacer()

                        if appPreferences.railBackgroundColorHex != nil {
                            Button(copy.text("恢复默认", "Reset")) {
                                appPreferences.setRailBackgroundColor(nil)
                            }
                            .buttonStyle(SettingsPressButtonStyle())
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SettingsPalette.secondary)
                        }

                        TextField("#RRGGBB", text: $railBackgroundHex)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .frame(width: 76)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(SettingsPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .onChange(of: railBackgroundHex) { _, value in
                                guard let normalized = appPreferences.setRailBackgroundColor(hex: value),
                                      normalized != value
                                else { return }
                                railBackgroundHex = normalized
                            }

                        ColorPicker(
                            "",
                            selection: railBackgroundColor,
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .pointerStyle(.link)
                    }
                    .onAppear {
                        railBackgroundHex = appPreferences.railBackgroundColorHex ?? ""
                    }
                    .onChange(of: appPreferences.railBackgroundColorHex) { _, value in
                        railBackgroundHex = value ?? ""
                    }
                }

                SettingsCard(copy.text("刷新间隔", "Refresh interval")) {
                    HStack(spacing: 7) {
                        ForEach(refreshOptions, id: \.0) { interval, chinese, english in
                            SettingsChoiceButton(
                                title: copy.text(chinese, english),
                                systemImage: nil,
                                selected: refreshInterval == interval
                            ) {
                                refreshInterval = interval
                            }
                        }
                    }
                    Text(copy.text(
                        "更短的间隔会更快同步额度变化，但会增加网络请求。",
                        "Shorter intervals update quotas sooner and make more network requests."
                    ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.tertiary)
                }

                SettingsCard(copy.text("行为", "Behavior")) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: copy.text("登录后自动启动", "Launch at login"),
                            hint: copy.text(
                                "登录 macOS 后自动运行 Yomi",
                                "Start Yomi automatically after signing in to macOS"
                            ),
                            isOn: $launchAtLogin
                        )
                        .onChange(of: launchAtLogin) { _, enabled in
                            updateLoginItem(enabled)
                        }

                        Rectangle().fill(SettingsPalette.line).frame(height: 1)

                        SettingsToggleRow(
                            title: copy.text("显示 Provider 名称", "Show provider names"),
                            hint: copy.text(
                                "在悬浮栏圆环下方显示名称",
                                "Show names below provider rings in the floating rail"
                            ),
                            isOn: $showProviderNames
                        )
                    }

                    if let loginError {
                        Text(loginError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsPalette.red)
                    }
                }

            }
            .padding(.bottom, 4)
        }
    }

    private var refreshOptions: [(Double, String, String)] {
        [
            (60, "1 分钟", "1 min"),
            (300, "5 分钟", "5 min"),
            (900, "15 分钟", "15 min"),
            (1_800, "30 分钟", "30 min"),
        ]
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }
}

private struct ProviderSettingsView: View {
    @ObservedObject var store: UsageStore
    @Binding var selectedProviderID: ProviderID?
    @Binding var searchText: String
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    private var filtered: [ProviderDescriptor] {
        guard !searchText.isEmpty else { return ProviderCatalog.all }
        return ProviderCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                providerList

                Group {
                    if let id = selectedProviderID,
                       let descriptor = ProviderCatalog.byID[id] {
                        ProviderConfigurationView(store: store, descriptor: descriptor)
                            .id(id)
                    } else {
                        ContentUnavailableView(
                            copy.text("选择一个 Provider", "Select a provider"),
                            systemImage: "square.grid.2x2",
                            description: Text(copy.text(
                                "可以在这里启用并配置数据来源。",
                                "Enable it and configure its data source here."
                            ))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SettingsPalette.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(SettingsPalette.line, lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var providerList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SettingsPalette.tertiary)
                TextField(copy.text("搜索 Provider", "Search providers"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(SettingsPalette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { descriptor in
                        ProviderSettingsRow(
                            descriptor: descriptor,
                            usage: store.usage(for: descriptor.id),
                            selected: selectedProviderID == descriptor.id,
                            select: { selectedProviderID = descriptor.id },
                            isEnabled: Binding(
                                get: {
                                    store.preferences.configuration(for: descriptor.id).isEnabled
                                },
                                set: {
                                    store.preferences.setEnabled($0, for: descriptor.id)
                                }
                            )
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 252)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsPalette.line, lineWidth: 1)
        }
    }
}

private struct ProviderSettingsRow: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let selected: Bool
    let select: () -> Void
    @Binding var isEnabled: Bool
    @Environment(\.appLanguage) private var language

    @State private var hovered = false

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 9) {
                    ProviderIconView(provider: descriptor)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(
                            isEnabled
                                ? ProviderBrandColors.color(for: descriptor.id)
                                : SettingsPalette.tertiary
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(isEnabled ? SettingsPalette.primary : SettingsPalette.secondary)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isEnabled ? statusColor : SettingsPalette.tertiary)
                                .frame(width: 5, height: 5)
                            Text(statusText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(
                                    SettingsPalette.tertiary.opacity(isEnabled ? 1 : 0.72)
                                )
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(SettingsPalette.blue)
                .pointerStyle(.link)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            selected
                ? SettingsPalette.selected
                : (hovered ? SettingsPalette.inset : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var statusText: String {
        if let date = usage.updatedAt, usage.state == .ready {
            return copy.text("已更新", "Updated")
                + " · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return usage.message.map(copy.usageMessage) ?? copy.text("未读取", "Not loaded")
    }

    private var statusColor: Color {
        switch usage.state {
        case .ready: SettingsPalette.green
        case .loading: SettingsPalette.blue
        case .unavailable: SettingsPalette.orange
        case .failed: SettingsPalette.red
        }
    }
}

private struct ProviderConfigurationView: View {
    @ObservedObject var store: UsageStore
    let descriptor: ProviderDescriptor

    @State private var configuration: ProviderConfiguration
    @State private var secret: String
    @State private var managementSecret: String
    @State private var secondarySecret: String
    @State private var stepFunManualToken: String
    @State private var bedrockAuthMode: String
    @State private var bedrockProfile: String
    @State private var bedrockRegion: String
    @State private var deepSeekProfiles: [DeepSeekPlatformTokenImporter.TokenInfo]
    @State private var saveMessage: String?
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    init(store: UsageStore, descriptor: ProviderDescriptor) {
        self.store = store
        self.descriptor = descriptor
        var configuration = store.preferences.configuration(for: descriptor.id)
        let secret = store.preferences.secret(for: descriptor.id)
        if descriptor.id.rawValue == "moonshot" {
            if !secret.isEmpty, configuration.endpoint.isEmpty {
                configuration.endpoint = MoonshotUsageRegion.china.rawValue
            }
            if configuration.account.isEmpty {
                configuration.account = MoonshotUsageFetcher.resolvedRegion(
                    configured: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                    environment: ProcessInfo.processInfo.environment
                ).rawValue
            }
        }
        if descriptor.id.rawValue == "windsurf", configuration.account.isEmpty {
            configuration.account = WindsurfSessionSource.automatic.rawValue
        }
        if (descriptor.id.rawValue == "longcat"
            || descriptor.id.rawValue == "zoommate"
            || descriptor.id.rawValue == "notion"),
           configuration.source == .account || configuration.source == .token {
            configuration.source = .automatic
        }
        _configuration = State(initialValue: configuration)
        _secret = State(initialValue: secret)
        _managementSecret = State(initialValue: store.preferences.auxiliarySecret(
            for: descriptor.id,
            key: "management-api-key"
        ))
        _secondarySecret = State(initialValue: store.preferences.auxiliarySecret(
            for: descriptor.id,
            key: "secret-access-key"
        ))
        let storedBedrockAuthMode = store.preferences.auxiliarySecret(for: descriptor.id, key: "aws-auth-mode")
        _bedrockAuthMode = State(initialValue: storedBedrockAuthMode.isEmpty
            ? BedrockCredentialResolver.inferredAuthMode(
                configured: nil,
                environment: ProcessInfo.processInfo.environment
            ).rawValue
            : storedBedrockAuthMode)
        _bedrockProfile = State(initialValue: store.preferences.auxiliarySecret(
            for: descriptor.id,
            key: "aws-profile"
        ))
        _bedrockRegion = State(initialValue: store.preferences.auxiliarySecret(
            for: descriptor.id,
            key: "aws-region"
        ))
        let storedStepFunManualToken = store.preferences.auxiliarySecret(
            for: descriptor.id,
            key: "manual-token"
        )
        _stepFunManualToken = State(initialValue: descriptor.id.rawValue == "stepfun"
            && configuration.source == .token
            && storedStepFunManualToken.isEmpty
            ? secret
            : storedStepFunManualToken)
        _deepSeekProfiles = State(initialValue: descriptor.id.rawValue == "deepseek"
            ? DeepSeekPlatformTokenImporter.importTokens()
            : [])
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                SettingsCard(copy.text("概览", "Overview")) {
                    HStack(spacing: 12) {
                        ProviderIconView(provider: descriptor)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(ProviderBrandColors.color(for: descriptor.id))
                            .frame(width: 48, height: 48)
                            .background(SettingsPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(descriptor.name)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(
                                "\(copy.usageLabel(descriptor.primaryLabel)) · "
                                    + copy.usageLabel(descriptor.secondaryLabel)
                            )
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsPalette.tertiary)
                        }
                        Spacer()
                        Toggle(copy.text("启用", "Enabled"), isOn: $configuration.isEnabled)
                            .toggleStyle(.switch)
                            .tint(SettingsPalette.blue)
                            .pointerStyle(.link)
                    }
                }

                SettingsCard(copy.text("数据来源", "Data source")) {
                    SettingsLabeledRow(title: copy.text("读取方式", "Source")) {
                        Picker("", selection: $configuration.source) {
                            ForEach(availableSources, id: \.self) { source in
                                Text(sourceTitle(source)).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    if configuration.source == .endpoint
                        || descriptor.id.rawValue == "azureopenai"
                        || descriptor.id.rawValue == "deepgram"
                        || descriptor.id.rawValue == "chutes"
                        || descriptor.id.rawValue == "clawrouter"
                        || descriptor.id.rawValue == "sub2api"
                        || descriptor.id.rawValue == "wayfinder"
                        || descriptor.id.rawValue == "llmproxy"
                        || descriptor.id.rawValue == "litellm" {
                        SettingsTextField(
                            title: descriptor.id.rawValue == "azureopenai"
                                ? copy.text("Azure Endpoint", "Azure endpoint")
                                : descriptor.id.rawValue == "deepgram"
                                ? copy.text("Deepgram API URL（可选）", "Deepgram API URL (optional)")
                                : descriptor.id.rawValue == "chutes"
                                ? copy.text("Chutes API URL（可选）", "Chutes API URL (optional)")
                                : descriptor.id.rawValue == "clawrouter"
                                ? copy.text("ClawRouter Base URL（可选）", "ClawRouter Base URL (optional)")
                                : descriptor.id.rawValue == "sub2api"
                                ? "sub2api Base URL"
                                : descriptor.id.rawValue == "wayfinder"
                                ? copy.text(
                                    "Gateway URL（默认 http://127.0.0.1:8088）",
                                    "Gateway URL (default: http://127.0.0.1:8088)"
                                )
                                : descriptor.id.rawValue == "llmproxy"
                                ? "LLM Proxy Base URL"
                                : descriptor.id.rawValue == "litellm"
                                ? "LiteLLM Base URL"
                                : copy.text("接口地址", "Endpoint URL"),
                            text: $configuration.endpoint
                        )
                    }
                    if configuration.source == .command {
                        SettingsTextField(
                            title: descriptor.id.rawValue == "doubao"
                                ? copy.text("arkcli 可执行文件路径（可选）", "arkcli executable path (optional)")
                                : descriptor.id.rawValue == "codex"
                                ? copy.text("Codex CLI 可执行文件路径（可选）", "Codex CLI executable path (optional)")
                                : descriptor.id.rawValue == "claude"
                                ? copy.text("Claude CLI 可执行文件路径（可选）", "Claude CLI executable path (optional)")
                                : copy.text(
                                    "输出 JSON 或百分比的命令",
                                    "Command that outputs JSON or percentages"
                                ),
                            text: $configuration.command
                        )
                    }
                    if descriptor.id.rawValue == "doubao" {
                        SettingsTextField(
                            title: copy.text("Region（默认 cn-beijing）", "Region (default: cn-beijing)"),
                            text: $configuration.account
                        )
                    }
                    if descriptor.id.rawValue == "moonshot" {
                        SettingsLabeledRow(title: copy.text("API 区域", "API region")) {
                            Picker("", selection: $configuration.account) {
                                Text(copy.text("国际", "International"))
                                    .tag(MoonshotUsageRegion.international.rawValue)
                                Text(copy.text("中国大陆", "China"))
                                    .tag(MoonshotUsageRegion.china.rawValue)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                            .onChange(of: configuration.account) { _, newRegion in
                                guard !configuration.endpoint.isEmpty,
                                      configuration.endpoint != newRegion
                                else { return }
                                secret = ""
                            }
                        }
                        Text(copy.text(
                            "切换区域后需要输入该区域对应的 API Key。自动模式也会读取 MOONSHOT_REGION。",
                            "Switching regions requires that region's API key. Automatic mode also reads MOONSHOT_REGION."
                        ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                    }
                    if descriptor.id.rawValue == "notion" {
                        SettingsTextField(
                            title: copy.text("Workspace ID（可选）", "Workspace ID (optional)"),
                            text: $configuration.account
                        )
                        Text(copy.text(
                            "留空时优先选择首个 Business 或 Enterprise workspace。",
                            "When left blank, the first Business or Enterprise workspace is preferred."
                        ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                    }
                    if descriptor.id.rawValue == "windsurf", configuration.source != .account {
                        SettingsLabeledRow(title: copy.text("会话来源", "Session source")) {
                            Picker("", selection: $configuration.account) {
                                Text(copy.text("自动", "Automatic"))
                                    .tag(WindsurfSessionSource.automatic.rawValue)
                                Text(copy.text("手动", "Manual"))
                                    .tag(WindsurfSessionSource.manual.rawValue)
                                Text(copy.text("关闭", "Off"))
                                    .tag(WindsurfSessionSource.off.rawValue)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                    }
                    if descriptor.id.rawValue == "deepseek", deepSeekProfiles.count > 1 {
                        SettingsLabeledRow(title: copy.text("Chrome Profile", "Chrome profile")) {
                            Picker("", selection: $configuration.account) {
                                Text(copy.text("未选择", "Not selected")).tag("")
                                ForEach(deepSeekProfiles, id: \.id) { profile in
                                    Text(profile.sourceLabel).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                    }
                    if configuration.source == .account
                        && descriptor.id.rawValue != "antigravity"
                        && descriptor.id.rawValue != "augment"
                        && descriptor.id.rawValue != "codex"
                        && descriptor.id.rawValue != "t3chat"
                        && descriptor.id.rawValue != "zed"
                        && descriptor.id.rawValue != "windsurf"
                        || descriptor.id.rawValue == "openai"
                        || descriptor.id.rawValue == "azureopenai"
                        || descriptor.id.rawValue == "opencode"
                        || descriptor.id.rawValue == "opencodego"
                        || descriptor.id.rawValue == "alibaba"
                        || descriptor.id.rawValue == "alibabatokenplan"
                        || descriptor.id.rawValue == "fireworks"
                        || descriptor.id.rawValue == "copilot"
                        || descriptor.id.rawValue == "devin"
                        || descriptor.id.rawValue == "kilo"
                        || descriptor.id.rawValue == "zai"
                        || descriptor.id.rawValue == "minimax"
                        || descriptor.id.rawValue == "jetbrains"
                        || descriptor.id.rawValue == "deepgram"
                        || descriptor.id.rawValue == "xai"
                        || descriptor.id.rawValue == "stepfun" && configuration.source != .token
                        || descriptor.id.rawValue == "claude" && configuration.source == .cookie {
                        SettingsTextField(
                            title: configurationAccountLabel,
                            text: $configuration.account
                        )
                    }
                }

                if showsAuthenticationCard {
                    SettingsCard(copy.text("认证", "Authentication")) {
                        if descriptor.id.rawValue == "bedrock" {
                            SettingsLabeledRow(title: copy.text("认证方式", "Authentication")) {
                                Picker("", selection: $bedrockAuthMode) {
                                    Text(copy.text("Access keys", "Access keys"))
                                        .tag(BedrockAuthMode.keys.rawValue)
                                    Text(copy.text("AWS Profile", "AWS profile"))
                                        .tag(BedrockAuthMode.profile.rawValue)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 180)
                            }
                            if bedrockAuthMode == BedrockAuthMode.profile.rawValue {
                                SettingsTextField(
                                    title: copy.text("Profile 名称", "Profile name"),
                                    text: $bedrockProfile
                                )
                            } else {
                                SecureField("Access Key ID", text: $secret)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .background(SettingsPalette.inset)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                SecureField("Secret Access Key", text: $secondarySecret)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .background(SettingsPalette.inset)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            SettingsTextField(
                                title: copy.text("Region（可选）", "Region (optional)"),
                                text: $bedrockRegion
                            )
                        } else {
                            SecureField(secretLabel, text: authenticationSecret)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .background(SettingsPalette.inset)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if !descriptor.environmentKeys.isEmpty {
                            Text(copy.text("自动模式也会读取：", "Automatic mode also reads: ")
                                + descriptor.environmentKeys.joined(separator: ", "))
                                .font(.system(size: 10.5))
                                .foregroundStyle(SettingsPalette.tertiary)
                                .textSelection(.enabled)
                        }
                        if descriptor.id.rawValue == "groq" {
                            Text(copy.text(
                                "用量与支出会自动读取 console.groq.com 浏览器会话；API Key 为可选，仅用于补充 Enterprise Prometheus 指标。",
                                "Usage and spend come from the console.groq.com browser session automatically; the optional API key only adds Enterprise Prometheus metrics."
                            ))
                                .font(.system(size: 10.5))
                                .foregroundStyle(SettingsPalette.tertiary)
                        }
                        if descriptor.id.rawValue == "openrouter" {
                            SecureField(
                                copy.text("管理 API Key（可选）", "Management API key (optional)"),
                                text: $managementSecret
                            )
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(SettingsPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Text(copy.text(
                                "管理 API Key 用于读取最近 30 天活动；也可设置 OPENROUTER_MANAGEMENT_API_KEY。",
                                "The management API key enables 30-day activity; OPENROUTER_MANAGEMENT_API_KEY is also supported."
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                        }
                        if descriptor.id.rawValue == "doubao" {
                            SecureField(
                                copy.text("Secret Access Key（可选）", "Secret Access Key (optional)"),
                                text: $secondarySecret
                            )
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(SettingsPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                SettingsCard(copy.text("状态", "Status")) {
                    let usage = store.usage(for: descriptor.id)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(usage.state))
                            .frame(width: 7, height: 7)
                        Text(stateText(usage.state))
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Button(copy.text("刷新此 Provider", "Refresh provider")) {
                            save()
                            Task { await store.refresh(providerID: descriptor.id) }
                        }
                        .buttonStyle(SettingsPressButtonStyle())
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SettingsPalette.blue)
                    }
                    if let message = usage.message {
                        Text(copy.usageMessage(message))
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                    }
                }

                HStack {
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                    }
                    Spacer()
                    Button(copy.text("保存", "Save")) { save() }
                        .buttonStyle(SettingsPressButtonStyle())
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(SettingsPalette.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 2)
            }
            .padding(.bottom, 4)
        }
    }

    private var secretLabel: String {
        if descriptor.id.rawValue == "codex" {
            return switch configuration.source {
            case .token: "Codex PAT"
            case .cookie: copy.text("ChatGPT Cookie", "ChatGPT Cookie")
            default: copy.text("Codex PAT（可选）", "Codex PAT (optional)")
            }
        }
        if descriptor.id.rawValue == "antigravity" {
            return copy.text("OAuth 凭证 JSON（可选）", "OAuth credentials JSON (optional)")
        }
        if descriptor.id.rawValue == "t3chat", configuration.source == .cookie {
            return copy.text("Cookie 或完整 cURL", "Cookie or full cURL")
        }
        if descriptor.id.rawValue == "ollama", configuration.source == .cookie {
            return copy.text("Cookie 标头或会话值", "Cookie header or session value")
        }
        if descriptor.id.rawValue == "ollama", configuration.source == .token {
            return copy.text("Ollama API Key", "Ollama API key")
        }
        if descriptor.id.rawValue == "ollama", configuration.source == .automatic {
            return copy.text("API Key 或 Cookie（可选）", "API key or Cookie (optional)")
        }
        if descriptor.id.rawValue == "openrouter" {
            return "OpenRouter API Key"
        }
        if descriptor.id.rawValue == "elevenlabs" {
            return "API Key (xi-...)"
        }
        if descriptor.id.rawValue == "warp" {
            return "Warp API Key"
        }
        if descriptor.id.rawValue == "windsurf" {
            return copy.text("Windsurf 会话 JSON 包", "Windsurf session JSON bundle")
        }
        if descriptor.id.rawValue == "perplexity" {
            return copy.text("Cookie 标头或会话值", "Cookie header or session value")
        }
        if descriptor.id.rawValue == "sakana" {
            return copy.text("Cookie 标头", "Cookie header")
        }
        if descriptor.id.rawValue == "abacus" {
            return copy.text("Cookie 标头或 cURL", "Cookie header or cURL")
        }
        if descriptor.id.rawValue == "mimo" {
            return copy.text("Cookie 标头或完整 cURL", "Cookie header or full cURL")
        }
        if descriptor.id.rawValue == "deepinfra" {
            return "DeepInfra API Key"
        }
        if descriptor.id.rawValue == "crof" {
            return "Crof API Key"
        }
        if descriptor.id.rawValue == "venice" {
            return "Venice API Key"
        }
        if descriptor.id.rawValue == "deepgram" {
            return "Deepgram API Key"
        }
        if descriptor.id.rawValue == "poe" {
            return "Poe API Key"
        }
        if descriptor.id.rawValue == "mistral" {
            return copy.text("Cookie 标头或完整 cURL", "Cookie header or full cURL")
        }
        if descriptor.id.rawValue == "qoder" {
            return copy.text("Cookie 标头或完整 cURL", "Cookie header or full cURL")
        }
        if descriptor.id.rawValue == "longcat" {
            return copy.text("Cookie 标头", "Cookie header")
        }
        if descriptor.id.rawValue == "zoommate", configuration.source == .cookie {
            return copy.text("ZoomMate 完整 cURL", "Full ZoomMate cURL")
        }
        if descriptor.id.rawValue == "notion", configuration.source == .cookie {
            return copy.text(
                "token_v2、Cookie 标头或完整 cURL",
                "token_v2, Cookie header, or full cURL"
            )
        }
        if descriptor.id.rawValue == "stepfun" {
            return configuration.source == .token
                ? "Oasis-Token"
                : copy.text("密码", "Password")
        }
        if descriptor.id.rawValue == "deepseek" {
            return switch configuration.source {
            case .cookie: "DeepSeek Platform userToken"
            case .automatic: copy.text("DeepSeek API Key（可选）", "DeepSeek API key (optional)")
            default: "DeepSeek API Key"
            }
        }
        if descriptor.id.rawValue == "chutes" {
            return "Chutes API Key"
        }
        if descriptor.id.rawValue == "neuralwatt" {
            return "Neuralwatt API Key"
        }
        if descriptor.id.rawValue == "xai" {
            return "xAI Management API Key"
        }
        if descriptor.id.rawValue == "aiand" {
            return "ai& API Key"
        }
        if descriptor.id.rawValue == "zenmux" {
            return "ZenMux Management API Key"
        }
        if descriptor.id.rawValue == "sub2api" {
            return copy.text("备用 API Key", "Fallback API key")
        }
        if descriptor.id.rawValue == "llmproxy" {
            return "LLM Proxy API Key"
        }
        if descriptor.id.rawValue == "litellm" {
            return "LiteLLM API Key"
        }
        if descriptor.id.rawValue == "ibmbob" {
            return "IBM Bob API Key"
        }
        if descriptor.id.rawValue == "grok" {
            return switch configuration.source {
            case .token: copy.text("SuperGrok Bearer 令牌", "SuperGrok bearer token")
            case .cookie: copy.text("grok.com Cookie 标头", "grok.com Cookie header")
            default: copy.text(
                "SuperGrok Bearer 令牌或 grok.com Cookie（可选）",
                "SuperGrok bearer token or grok.com Cookie (optional)"
            )
            }
        }
        if descriptor.id.rawValue == "groq" {
            return "Groq API Key (gsk_...)"
        }
        if descriptor.id.rawValue == "doubao" {
            return "API Key / Access Key ID"
        }
        return configuration.source == .cookie
            ? copy.text("Cookie 内容", "Cookie contents")
            : copy.text("访问令牌或密钥", "Access token or key")
    }

    private var availableSources: [ProviderSource] {
        [.automatic] + descriptor.preferredSources
    }

    private func sourceTitle(_ source: ProviderSource) -> String {
        if descriptor.id.rawValue == "codex" {
            return switch source {
            case .automatic: copy.text("自动", "Auto")
            case .cookie: "Web"
            case .command: "CLI"
            case .account: "OAuth"
            case .token: "API"
            case .endpoint: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "claude" {
            return switch source {
            case .automatic: copy.text("自动", "Auto")
            case .account: "OAuth API"
            case .token: copy.text("API（Admin Key）", "API (Admin key)")
            case .cookie: copy.text("网页 API（Cookie）", "Web API (cookies)")
            case .command: "CLI (PTY)"
            case .endpoint: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "windsurf" {
            return switch source {
            case .automatic: copy.text("自动", "Auto")
            case .cookie: copy.text("网页接口（IndexedDB）", "Web API (IndexedDB)")
            case .account: copy.text("本地（SQLite 缓存）", "Local (SQLite cache)")
            default: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "abacus" {
            return configuration.source == .automatic
                ? copy.text("自动导入浏览器 Cookie", "Automatic browser cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "mimo" {
            return configuration.source == .automatic
                ? copy.text("自动导入浏览器 Cookie", "Automatic browser cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "mistral" {
            return source == .automatic
                ? copy.text("自动导入浏览器 Cookie", "Automatic browser cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "qoder" {
            return source == .automatic
                ? copy.text("自动导入浏览器 Cookie", "Automatic browser cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "longcat" {
            return source == .automatic
                ? copy.text("自动导入浏览器 Cookie", "Automatic browser cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "zoommate" {
            return source == .automatic
                ? copy.text("自动导入 Chrome 会话", "Automatic Chrome session")
                : copy.text("手动 cURL", "Manual cURL")
        }
        if descriptor.id.rawValue == "notion" {
            return source == .automatic
                ? copy.text("自动导入 Chrome Cookie", "Automatic Chrome cookies")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "deepseek" {
            return switch source {
            case .automatic: copy.text("自动", "Auto")
            case .token: "API"
            case .cookie: "Web"
            default: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "doubao" {
            return switch source {
            case .command: "arkcli"
            case .token: copy.text("API 凭据", "API credentials")
            default: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "ibmbob", source == .token {
            return "API Key"
        }
        if descriptor.id.rawValue == "grok" {
            return switch source {
            case .automatic: copy.text("自动", "Auto")
            case .account: "Grok CLI"
            case .token: "SuperGrok OAuth"
            case .cookie: copy.text("grok.com 浏览器会话", "grok.com browser session")
            default: source.title(language: language)
            }
        }
        if descriptor.id.rawValue == "groq" {
            return switch source {
            case .automatic: copy.text(
                "自动（Console，失败时 Enterprise 指标）",
                "Auto (Console, then Enterprise metrics)"
            )
            case .cookie: copy.text("Console（浏览器会话）", "Console (browser session)")
            case .token: "Enterprise Prometheus"
            default: source.title(language: language)
            }
        }
        guard descriptor.id.rawValue == "amp" else { return source.title(language: language) }
        return switch source {
        case .account: copy.text("Amp 命令行工具", "Amp CLI")
        case .token: copy.text("访问令牌", "Access token")
        case .cookie: copy.text("浏览器会话", "Browser session")
        default: source.title(language: language)
        }
    }

    private var showsAuthenticationCard: Bool {
        if descriptor.id.rawValue == "zed" { return false }
        if descriptor.id.rawValue == "codex" {
            return configuration.source == .automatic
                || configuration.source == .token
                || configuration.source == .cookie
        }
        if descriptor.id.rawValue == "claude" {
            return configuration.source != .account && configuration.source != .command
        }
        if descriptor.id.rawValue == "amp", configuration.source == .account { return false }
        if descriptor.id.rawValue == "windsurf" {
            return configuration.source != .account
                && configuration.account == WindsurfSessionSource.manual.rawValue
        }
        if descriptor.id.rawValue == "abacus" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "mimo" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "mistral" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "qoder" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "longcat" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "zoommate" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "notion" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "wayfinder" { return false }
        if descriptor.id.rawValue == "doubao" { return configuration.source != .command }
        if descriptor.id.rawValue == "grok" { return configuration.source != .account }
        return true
    }

    private var configurationAccountLabel: String {
        switch descriptor.id.rawValue {
        case "openai": copy.text("Project ID（可选）", "Project ID (optional)")
        case "azureopenai": copy.text("Deployment 名称", "Deployment name")
        case "claude": copy.text("Organization ID（可选）", "Organization ID (optional)")
        case "opencode": copy.text("Workspace ID（可选）", "Workspace ID (optional)")
        case "opencodego": copy.text("Workspace ID（可选）", "Workspace ID (optional)")
        case "alibaba": copy.text("区域（intl 或 cn）", "Region (intl or cn)")
        case "alibabatokenplan": copy.text(
            "区域（intl、cn、intl-personal 或 cn-personal）",
            "Region (intl, cn, intl-personal, or cn-personal)"
        )
        case "fireworks": copy.text("账号 slug（可选）", "Account slug (optional)")
        case "copilot": copy.text("企业主机（可选）", "Enterprise host (optional)")
        case "devin": copy.text("组织 slug 或 URL（可选）", "Organization slug or URL (optional)")
        case "kilo": copy.text("Organization ID（可选）", "Organization ID (optional)")
        case "zai": copy.text("API 区域（global 或 bigmodel-cn）", "API region (global or bigmodel-cn)")
        case "minimax": copy.text("MiniMax 区域（global 或 cn）", "MiniMax region (global or cn)")
        case "jetbrains": copy.text("IDE 配置目录（可选）", "IDE configuration directory (optional)")
        case "deepgram": copy.text("Project ID（可选；留空汇总全部项目）", "Project ID (optional; blank aggregates all projects)")
        case "xai": copy.text("Team ID", "Team ID")
        case "stepfun": copy.text("用户名", "Username")
        default: copy.text("账号标识（可选）", "Account identifier (optional)")
        }
    }

    private func save() {
        do {
            if descriptor.id.rawValue == "moonshot" {
                configuration.endpoint = secret.isEmpty ? "" : configuration.account
            }
            store.preferences.update(configuration)
            try store.preferences.setSecret(secret, for: descriptor.id)
            if descriptor.id.rawValue == "openrouter" {
                try store.preferences.setAuxiliarySecret(
                    managementSecret,
                    for: descriptor.id,
                    key: "management-api-key"
                )
            }
            if descriptor.id.rawValue == "doubao" {
                try store.preferences.setAuxiliarySecret(
                    secondarySecret,
                    for: descriptor.id,
                    key: "secret-access-key"
                )
            }
            if descriptor.id.rawValue == "bedrock" {
                try store.preferences.setAuxiliarySecret(
                    secondarySecret,
                    for: descriptor.id,
                    key: "secret-access-key"
                )
                try store.preferences.setAuxiliarySecret(
                    bedrockProfile,
                    for: descriptor.id,
                    key: "aws-profile"
                )
                try store.preferences.setAuxiliarySecret(
                    bedrockRegion,
                    for: descriptor.id,
                    key: "aws-region"
                )
                try store.preferences.setAuxiliarySecret(
                    bedrockAuthMode,
                    for: descriptor.id,
                    key: "aws-auth-mode"
                )
            }
            if descriptor.id.rawValue == "stepfun" {
                try store.preferences.setAuxiliarySecret(
                    stepFunManualToken,
                    for: descriptor.id,
                    key: "manual-token"
                )
            }
            saveMessage = copy.text("已保存", "Saved")
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private var authenticationSecret: Binding<String> {
        descriptor.id.rawValue == "stepfun" && configuration.source == .token
            ? $stepFunManualToken
            : $secret
    }

    private func stateText(_ state: ProviderUsage.State) -> String {
        switch state {
        case .ready: copy.text("可用", "Available")
        case .loading: copy.text("读取中", "Loading")
        case .unavailable: copy.text("缓存数据", "Cached data")
        case .failed: copy.text("读取失败", "Failed")
        }
    }

    private func statusColor(_ state: ProviderUsage.State) -> Color {
        switch state {
        case .ready: SettingsPalette.green
        case .loading: SettingsPalette.blue
        case .unavailable: SettingsPalette.orange
        case .failed: SettingsPalette.red
        }
    }
}

private struct SettingsLabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            content
        }
    }
}

private struct SettingsTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(SettingsPalette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updateController: UpdateController
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 88, height: 88)

            VStack(spacing: 5) {
                Text("Yomi")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(copy.text("跨 Provider 用量一览", "Usage across all your providers"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsPalette.tertiary)
                Text(versionText)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.tertiary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label(copy.text("检查更新", "Check for Updates"), systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SettingsPalette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SettingsPressButtonStyle())
                .disabled(!updateController.canCheckForUpdates)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label(copy.text("退出 Yomi", "Quit Yomi"), systemImage: "power")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SettingsPalette.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SettingsPalette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SettingsPressButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return copy.text("版本 \(version)（\(build)）", "Version \(version) (\(build))")
    }
}
