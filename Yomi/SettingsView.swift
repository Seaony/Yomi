import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Section: Hashable {
        case general
        case providers
        case about
    }

    @ObservedObject var store: UsageStore
    @ObservedObject private var appPreferences = AppPreferences.shared
    let initialProviderID: ProviderID?

    @State private var selection: Section = .general
    @State private var selectedProviderID: ProviderID?
    @State private var searchText = ""

    private var copy: AppCopy { AppCopy(language: appPreferences.language) }

    init(store: UsageStore, initialProviderID: ProviderID? = nil) {
        self.store = store
        self.initialProviderID = initialProviderID
        _selectedProviderID = State(initialValue: initialProviderID)
        _selection = State(initialValue: initialProviderID == nil ? .general : .providers)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(copy.text("通用", "General"), systemImage: "gearshape")
                    .tag(Section.general)
                Label("Providers", systemImage: "square.grid.2x2")
                    .tag(Section.providers)
                Label(copy.text("关于", "About"), systemImage: "info.circle")
                    .tag(Section.about)
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 210)
        } detail: {
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
                AboutSettingsView()
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
        .preferredColorScheme(appPreferences.appearance.colorScheme)
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
        Form {
            Section(copy.text("外观", "Appearance")) {
                Picker(copy.text("显示模式", "Appearance"), selection: $appPreferences.appearance) {
                    Text(copy.text("跟随系统", "System")).tag(AppAppearance.system)
                    Text(copy.text("亮色", "Light")).tag(AppAppearance.light)
                    Text(copy.text("暗色", "Dark")).tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section(copy.text("语言", "Language")) {
                Picker(copy.text("显示语言", "Display language"), selection: $appPreferences.language) {
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)
            }

            Section(copy.text("启动", "Startup")) {
                Toggle(copy.text("登录后自动启动", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                Toggle(
                    copy.text("在悬浮栏显示 Provider 名称", "Show provider names in the floating rail"),
                    isOn: $showProviderNames
                )
            }

            Section(copy.text("刷新", "Refresh")) {
                Picker(copy.text("自动刷新间隔", "Automatic refresh interval"), selection: $refreshInterval) {
                    Text(copy.text("1 分钟", "1 minute")).tag(60.0)
                    Text(copy.text("5 分钟", "5 minutes")).tag(300.0)
                    Text(copy.text("15 分钟", "15 minutes")).tag(900.0)
                    Text(copy.text("30 分钟", "30 minutes")).tag(1_800.0)
                }
                Button(copy.text("立即刷新", "Refresh now")) { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }

            Section(copy.text("数据", "Data")) {
                LabeledContent(copy.text("Provider 数量", "Providers"), value: "\(ProviderCatalog.all.count)")
                LabeledContent(copy.text("已启用", "Enabled"), value: "\(store.enabledProviders.count)")
                Text(copy.text(
                    "认证信息保存在系统钥匙串；用量缓存仅保存在本机。",
                    "Credentials are stored in the system Keychain; usage cache stays on this Mac."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let loginError {
                Text(loginError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(copy.text("通用", "General"))
        .padding(24)
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
        HStack(spacing: 0) {
            List(filtered, selection: $selectedProviderID) { descriptor in
                ProviderSettingsRow(
                    descriptor: descriptor,
                    usage: store.usage(for: descriptor.id),
                    isEnabled: Binding(
                        get: { store.preferences.configuration(for: descriptor.id).isEnabled },
                        set: { store.preferences.setEnabled($0, for: descriptor.id) }
                    )
                )
                .tag(descriptor.id)
            }
            .searchable(text: $searchText, prompt: copy.text("搜索 Provider", "Search providers"))
            .listStyle(.sidebar)
            .frame(width: 270)
            .frame(maxHeight: .infinity)

            Divider()

            Group {
                if let id = selectedProviderID, let descriptor = ProviderCatalog.byID[id] {
                    ProviderConfigurationView(store: store, descriptor: descriptor)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        copy.text("选择一个 Provider", "Select a provider"),
                        systemImage: "square.grid.2x2",
                        description: Text(copy.text(
                            "可启用、选择取数方式并配置认证信息。",
                            "Enable it, choose a data source, and configure credentials."
                        ))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Providers")
    }
}

private struct ProviderSettingsRow: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    @Binding var isEnabled: Bool
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIconView(provider: descriptor)
                .frame(width: 22, height: 22)
                .foregroundStyle(ProviderBrandColors.color(for: descriptor.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.name).lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        if let date = usage.updatedAt, !usage.windows.isEmpty {
            return copy.text("已更新", "Updated")
                + " · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return usage.message.map(copy.usageMessage) ?? copy.text("未读取", "Not loaded")
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
        Form {
            Section {
                HStack(spacing: 14) {
                    ProviderIconView(provider: descriptor)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(ProviderBrandColors.color(for: descriptor.id))
                        .frame(width: 48, height: 48)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(descriptor.name).font(.title2.weight(.semibold))
                        Text(
                            "\(copy.usageLabel(descriptor.primaryLabel)) · "
                                + copy.usageLabel(descriptor.secondaryLabel)
                        )
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(copy.text("启用", "Enabled"), isOn: $configuration.isEnabled)
                }
            }

            Section(copy.text("数据来源", "Data source")) {
                Picker(copy.text("读取方式", "Source"), selection: $configuration.source) {
                    ForEach(ProviderSource.allCases, id: \.self) { source in
                        Text(source.title(language: language)).tag(source)
                    }
                }

                if configuration.source == .endpoint {
                    TextField(copy.text("接口地址", "Endpoint URL"), text: $configuration.endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                if configuration.source == .command {
                    TextField(
                        copy.text("输出 JSON 或百分比的命令", "Command that outputs JSON or percentages"),
                        text: $configuration.command
                    )
                        .textFieldStyle(.roundedBorder)
                }
                if configuration.source == .account {
                    TextField(copy.text("账号标识（可选）", "Account identifier (optional)"), text: $configuration.account)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section(copy.text("认证", "Authentication")) {
                SecureField(secretLabel, text: $secret)
                    .textFieldStyle(.roundedBorder)
                if !descriptor.environmentKeys.isEmpty {
                    Text(copy.text("自动模式也会读取：", "Automatic mode also reads: ")
                        + descriptor.environmentKeys.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section(copy.text("状态", "Status")) {
                let usage = store.usage(for: descriptor.id)
                LabeledContent(copy.text("状态", "Status"), value: stateText(usage.state))
                if let message = usage.message {
                    Text(copy.usageMessage(message)).font(.caption).foregroundStyle(.secondary)
                }
                Button(copy.text("刷新此 Provider", "Refresh this provider")) {
                    save()
                    Task { await store.refresh() }
                }
            }

            HStack {
                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copy.text("保存", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(22)
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
}

private struct AboutSettingsView: View {
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text("Yomi").font(.largeTitle.weight(.semibold))
            Text(copy.text("跨 Provider 用量一览", "Usage across all your providers"))
                .foregroundStyle(.secondary)
            Text(copy.text("版本 1.0", "Version 1.0"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(copy.text("退出 Yomi", "Quit Yomi")) { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(copy.text("关于", "About"))
    }
}
