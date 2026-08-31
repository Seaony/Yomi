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
                    GeneralSettingsView(store: store)
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

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Yomi \(appVersion)")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(copy.text(
                        "已启用 \(store.enabledProviders.count) 个 Provider",
                        "\(store.enabledProviders.count) providers enabled"
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.tertiary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(SettingsPalette.line, lineWidth: 1)
            }
        }
        .frame(width: 184)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
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
    @ObservedObject var store: UsageStore
    @ObservedObject private var appPreferences = AppPreferences.shared
    @AppStorage("refresh-interval") private var refreshInterval = 300.0
    @AppStorage("show-provider-names") private var showProviderNames = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

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

                SettingsCard(copy.text("本机数据", "Local data")) {
                    HStack(spacing: 10) {
                        SettingsMetric(
                            title: copy.text("Provider 总数", "Providers"),
                            value: "\(ProviderCatalog.all.count)"
                        )
                        SettingsMetric(
                            title: copy.text("已启用", "Enabled"),
                            value: "\(store.enabledProviders.count)"
                        )
                        Spacer(minLength: 10)
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label(
                                copy.text("立即刷新", "Refresh now"),
                                systemImage: "arrow.clockwise"
                            )
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(SettingsPalette.control)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(SettingsPressButtonStyle())
                        .disabled(store.isRefreshing)
                    }
                    Text(copy.text(
                        "认证信息保存在系统钥匙串；用量缓存仅保存在本机。",
                        "Credentials are stored in the system Keychain; usage cache stays on this Mac."
                    ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.tertiary)
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

private struct SettingsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SettingsPalette.tertiary)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minWidth: 94, alignment: .leading)
        .background(SettingsPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        if let date = usage.updatedAt, !usage.windows.isEmpty {
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
    @State private var saveMessage: String?
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    init(store: UsageStore, descriptor: ProviderDescriptor) {
        self.store = store
        self.descriptor = descriptor
        _configuration = State(initialValue: store.preferences.configuration(for: descriptor.id))
        _secret = State(initialValue: store.preferences.secret(for: descriptor.id))
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
                            ForEach(ProviderSource.allCases, id: \.self) { source in
                                Text(source.title(language: language)).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    if configuration.source == .endpoint {
                        SettingsTextField(
                            title: copy.text("接口地址", "Endpoint URL"),
                            text: $configuration.endpoint
                        )
                    }
                    if configuration.source == .command {
                        SettingsTextField(
                            title: copy.text(
                                "输出 JSON 或百分比的命令",
                                "Command that outputs JSON or percentages"
                            ),
                            text: $configuration.command
                        )
                    }
                    if configuration.source == .account {
                        SettingsTextField(
                            title: copy.text("账号标识（可选）", "Account identifier (optional)"),
                            text: $configuration.account
                        )
                    }
                }

                SettingsCard(copy.text("认证", "Authentication")) {
                    SecureField(secretLabel, text: $secret)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(SettingsPalette.inset)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if !descriptor.environmentKeys.isEmpty {
                        Text(copy.text("自动模式也会读取：", "Automatic mode also reads: ")
                            + descriptor.environmentKeys.joined(separator: ", "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsPalette.tertiary)
                            .textSelection(.enabled)
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
                            Task { await store.refresh() }
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
        configuration.source == .cookie
            ? copy.text("Cookie 内容", "Cookie contents")
            : copy.text("访问令牌或密钥", "Access token or key")
    }

    private func save() {
        do {
            store.preferences.update(configuration)
            try store.preferences.setSecret(secret, for: descriptor.id)
            saveMessage = copy.text("已保存", "Saved")
        } catch {
            saveMessage = error.localizedDescription
        }
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
