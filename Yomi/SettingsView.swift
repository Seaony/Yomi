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
    let initialProviderID: ProviderID?

    @State private var selection: Section = .general
    @State private var selectedProviderID: ProviderID?
    @State private var searchText = ""

    init(store: UsageStore, initialProviderID: ProviderID? = nil) {
        self.store = store
        self.initialProviderID = initialProviderID
        _selectedProviderID = State(initialValue: initialProviderID)
        _selection = State(initialValue: initialProviderID == nil ? .general : .providers)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("通用", systemImage: "gearshape")
                    .tag(Section.general)
                Label("Providers", systemImage: "square.grid.2x2")
                    .tag(Section.providers)
                Label("关于", systemImage: "info.circle")
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
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("refresh-interval") private var refreshInterval = 300.0
    @AppStorage("show-provider-names") private var showProviderNames = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录后自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                Toggle("在悬浮栏显示 Provider 名称", isOn: $showProviderNames)
            }

            Section("刷新") {
                Picker("自动刷新间隔", selection: $refreshInterval) {
                    Text("1 分钟").tag(60.0)
                    Text("5 分钟").tag(300.0)
                    Text("15 分钟").tag(900.0)
                    Text("30 分钟").tag(1_800.0)
                }
                Button("立即刷新") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }

            Section("数据") {
                LabeledContent("Provider 数量", value: "\(ProviderCatalog.all.count)")
                LabeledContent("已启用", value: "\(store.enabledProviders.count)")
                Text("认证信息保存在系统钥匙串；用量缓存仅保存在本机。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let loginError {
                Text(loginError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
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
            .searchable(text: $searchText, prompt: "搜索 Provider")
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
                        "选择一个 Provider",
                        systemImage: "square.grid.2x2",
                        description: Text("可启用、选择取数方式并配置认证信息。")
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
            return "已更新 · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return usage.message ?? "未读取"
    }
}

private struct ProviderConfigurationView: View {
    @ObservedObject var store: UsageStore
    let descriptor: ProviderDescriptor

    @State private var configuration: ProviderConfiguration
    @State private var secret: String
    @State private var saveMessage: String?

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
                        Text("\(descriptor.primaryLabel) · \(descriptor.secondaryLabel)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用", isOn: $configuration.isEnabled)
                }
            }

            Section("数据来源") {
                Picker("读取方式", selection: $configuration.source) {
                    ForEach(ProviderSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }

                if configuration.source == .endpoint {
                    TextField("接口地址", text: $configuration.endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                if configuration.source == .command {
                    TextField("输出 JSON 或百分比的命令", text: $configuration.command)
                        .textFieldStyle(.roundedBorder)
                }
                if configuration.source == .account {
                    TextField("账号标识（可选）", text: $configuration.account)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("认证") {
                SecureField(secretLabel, text: $secret)
                    .textFieldStyle(.roundedBorder)
                if !descriptor.environmentKeys.isEmpty {
                    Text("自动模式也会读取：\(descriptor.environmentKeys.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("状态") {
                let usage = store.usage(for: descriptor.id)
                LabeledContent("状态", value: stateText(usage.state))
                if let message = usage.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("刷新此 Provider") {
                    save()
                    Task { await store.refresh() }
                }
            }

            HStack {
                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(22)
    }

    private var secretLabel: String {
        configuration.source == .cookie ? "Cookie 内容" : "访问令牌或密钥"
    }

    private func save() {
        do {
            store.preferences.update(configuration)
            try store.preferences.setSecret(secret, for: descriptor.id)
            saveMessage = "已保存"
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func stateText(_ state: ProviderUsage.State) -> String {
        switch state {
        case .ready: "可用"
        case .loading: "读取中"
        case .unavailable: "缓存数据"
        case .failed: "读取失败"
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text("Yomi").font(.largeTitle.weight(.semibold))
            Text("跨 Provider 用量一览")
                .foregroundStyle(.secondary)
            Text("版本 1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("退出 Yomi") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("关于")
    }
}
