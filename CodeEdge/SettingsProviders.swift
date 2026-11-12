import AppKit
import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var store: UsageStore
    @Binding var selectedProviderID: ProviderID?
    @Binding var searchText: String
    @Environment(\.appLanguage) private var language
    @FocusState private var searchFocused: Bool

    private var copy: AppCopy { AppCopy(language: language) }

    private var filtered: [ProviderDescriptor] {
        guard !searchText.isEmpty else { return ProviderCatalog.all }
        return ProviderCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            providerList
                .padding(.leading, SettingsSpace.xl)
                .padding(.vertical, SettingsSpace.lg)
                .frame(width: 260)
            Group {
                if let id = selectedProviderID,
                    let descriptor = ProviderCatalog.byID[id]
                {
                    ProviderConfigurationView(store: store, descriptor: descriptor)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        copy.text("选择一个 Provider", "Select a provider"),
                        systemImage: "square.grid.2x2"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CodeEdgeSettingsTheme.background)
        .codeEdgeSettingsPageTop()
        .buttonStyle(CodeEdgeFlatButtonStyle())
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: SettingsSpace.xl) {
            HStack(spacing: SettingsSpace.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                    .accessibilityHidden(true)
                TextField(copy.text("搜索 Provider", "Search providers"), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .codeEdgeSettingsField(focused: searchFocused)

            ScrollView(.vertical) {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    CodeEdgeFormSection {
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
                                    set: { enabled in
                                        store.preferences.setEnabled(enabled, for: descriptor.id)
                                        guard enabled else { return }
                                        Task { await store.refresh(providerID: descriptor.id, isManual: true) }
                                    }
                                )
                            )
                        }
                    }
                }
            }
            .scrollEdgeEffectHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProviderSettingsRow: View {
    let descriptor: ProviderDescriptor
    let usage: ProviderUsage
    let selected: Bool
    let select: () -> Void
    @Binding var isEnabled: Bool
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        HStack(spacing: SettingsSpace.sm) {
            Button(action: select) {
                HStack(spacing: SettingsSpace.sm) {
                    ProviderIconView(provider: descriptor)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(
                            isEnabled
                                ? ProviderBrandColors.color(for: descriptor.id)
                                : CodeEdgeSettingsTheme.tertiaryText
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                isEnabled ? CodeEdgeSettingsTheme.primaryText : CodeEdgeSettingsTheme.secondaryText
                            )
                            .lineLimit(1)
                            .help(descriptor.name)
                        HStack(spacing: SettingsSpace.xs) {
                            Circle()
                                .fill(isEnabled ? statusColor : CodeEdgeSettingsTheme.tertiaryText)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(statusText)
                                .font(.system(size: 12))
                                .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                                .lineLimit(1)
                                .help(statusText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ProviderSelectionButtonStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])

            Toggle(descriptor.name, isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(CodeEdgeSettingsTheme.accent)
                .pointerStyle(.link)
                .help(copy.text("启用", "Enabled") + " · " + descriptor.name)
        }
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
        case .ready: CodeEdgeSettingsTheme.statusGreen
        case .loading: CodeEdgeSettingsTheme.statusBlue
        case .unavailable: CodeEdgeSettingsTheme.statusAmber
        case .failed: CodeEdgeSettingsTheme.statusRed
        }
    }
}

private struct ProviderSelectionButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .padding(SettingsSpace.xs)
            .background(selected ? CodeEdgeSettingsTheme.selection : .clear, in: shape)
            .overlay {
                shape.fill(
                    CodeEdgeSettingsTheme.primaryText.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
            }
            .overlay { shape.strokeBorder(focused ? CodeEdgeSettingsTheme.focus : .clear, lineWidth: 2) }
            .contentShape(shape)
            .pointerStyle(.link)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
    }
}

private struct ProviderQuotaMuteToggle: View {
    @ObservedObject var notifications: QuotaNotificationController
    let providerID: ProviderID
    @Environment(\.appLanguage) private var language

    var body: some View {
        let copy = AppCopy(language: language)
        Toggle(copy.text("关闭此 Provider 的额度提醒", "Turn off quota alerts for this provider"), isOn: Binding(
            get: { notifications.isMuted(providerID) },
            set: { notifications.setMuted($0, for: providerID) }
        ))
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
    @State private var credentialReadError: String?
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    init(store: UsageStore, descriptor: ProviderDescriptor) {
        self.store = store
        self.descriptor = descriptor
        let providerID = descriptor.id.rawValue
        var configuration = store.preferences.configuration(for: descriptor.id)
        var readError: String?
        func readSecret(_ key: String? = nil) -> String {
            do {
                return try store.preferences.editableSecret(for: descriptor.id, key: key)
            } catch {
                readError = error.localizedDescription
                return ""
            }
        }
        let secret = readSecret()
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
        _managementSecret = State(initialValue: providerID == "openrouter"
            ? readSecret("management-api-key")
            : "")
        _secondarySecret = State(initialValue: providerID == "doubao" || providerID == "bedrock"
            ? readSecret("secret-access-key")
            : providerID == "futureagi" ? readSecret("secret-key") : "")
        let storedBedrockAuthMode = providerID == "bedrock"
            ? readSecret("aws-auth-mode")
            : ""
        let initialBedrockAuthMode: String
        if providerID != "bedrock" {
            initialBedrockAuthMode = BedrockAuthMode.keys.rawValue
        } else if storedBedrockAuthMode.isEmpty {
            initialBedrockAuthMode = BedrockCredentialResolver.inferredAuthMode(
                configured: nil,
                environment: ProcessInfo.processInfo.environment
            ).rawValue
        } else {
            initialBedrockAuthMode = storedBedrockAuthMode
        }
        _bedrockAuthMode = State(initialValue: initialBedrockAuthMode)
        _bedrockProfile = State(initialValue: providerID == "bedrock"
            ? readSecret("aws-profile")
            : "")
        _bedrockRegion = State(initialValue: providerID == "bedrock"
            ? readSecret("aws-region")
            : "")
        let storedStepFunManualToken = providerID == "stepfun"
            ? readSecret("manual-token")
            : ""
        _stepFunManualToken = State(initialValue: providerID == "stepfun"
            && configuration.source == .token
            && storedStepFunManualToken.isEmpty
            ? secret
            : storedStepFunManualToken)
        _deepSeekProfiles = State(initialValue: [])
        _credentialReadError = State(initialValue: readError)
        _saveMessage = State(initialValue: readError)
    }

    var body: some View {
        ScrollView(.vertical) {
            CodeEdgeSettingsForm {
                overviewSection
                notificationSection
                dataSourceSection
                if showsAuthenticationCard { authenticationSection }
                statusSection
                saveRow
            }
        }
        .clipped()
        .task(id: descriptor.id) {
            guard descriptor.id.rawValue == "deepseek" else { return }
            let profiles = await Task.detached(priority: .utility) {
                DeepSeekPlatformTokenImporter.importTokens()
            }.value
            guard !Task.isCancelled else { return }
            deepSeekProfiles = profiles
        }
    }

    private var overviewSection: some View {
        CodeEdgeFormSection(title: copy.text("概览", "Overview")) {
            CodeEdgeSideRow {
                Toggle(copy.text("启用", "Enabled"), isOn: $configuration.isEnabled)
                    .toggleStyle(.switch)
                    .labeledContentStyle(.automatic)
                    .controlSize(.small)
                    .tint(CodeEdgeSettingsTheme.accent)
                    .pointerStyle(.link)
                    .fixedSize()
            } label: {
                HStack(spacing: SettingsSpace.sm) {
                    ProviderIconView(provider: descriptor)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(ProviderBrandColors.color(for: descriptor.id))
                    VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                        Text(descriptor.name).fontWeight(.medium)
                        Text(
                            "\(copy.usageLabel(descriptor.primaryLabel)) · "
                                + copy.usageLabel(descriptor.secondaryLabel)
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var notificationSection: some View {
        CodeEdgeFormSection(title: copy.text("额度提醒", "Quota notifications")) {
            ProviderQuotaMuteToggle(notifications: store.notifications, providerID: descriptor.id)
        }
    }

    private var dataSourceSection: some View {
        CodeEdgeFormSection(title: copy.text("数据来源", "Data source")) {
            ProviderSettingsLabeledRow(title: copy.text("读取方式", "Source")) {
                Picker("", selection: $configuration.source) {
                    ForEach(availableSources, id: \.self) { source in
                        Text(sourceTitle(source)).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if configuration.source == .endpoint
                || descriptor.id.rawValue == "azureopenai"
                || descriptor.id.rawValue == "deepgram"
                || descriptor.id.rawValue == "chutes"
                || descriptor.id.rawValue == "siliconflow"
                || descriptor.id.rawValue == "clawrouter"
                || descriptor.id.rawValue == "sub2api"
                || descriptor.id.rawValue == "wayfinder"
                || descriptor.id.rawValue == "llmman"
                || descriptor.id.rawValue == "aixy"
                || descriptor.id.rawValue == "bifrost"
                || descriptor.id.rawValue == "llmproxy"
                || descriptor.id.rawValue == "litellm"
            {
                ProviderSettingsTextField(
                    title: descriptor.id.rawValue == "azureopenai"
                        ? copy.text("Azure Endpoint", "Azure endpoint")
                        : descriptor.id.rawValue == "deepgram"
                            ? copy.text("Deepgram API URL（可选）", "Deepgram API URL (optional)")
                            : descriptor.id.rawValue == "chutes"
                                ? copy.text("Chutes API URL（可选）", "Chutes API URL (optional)")
                                : descriptor.id.rawValue == "siliconflow"
                                    ? copy.text("SiliconFlow API URL（可选）", "SiliconFlow API URL (optional)")
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
                                                        : descriptor.id.rawValue == "llmman"
                                                            ? copy.text("llmman 地址（可选）", "llmman address (optional)")
                                                            : descriptor.id.rawValue == "aixy"
                                                                ? copy.text(
                                                                    "Aixy Base URL（可选）", "Aixy Base URL (optional)")
                                                                : descriptor.id.rawValue == "bifrost"
                                                                    ? copy.text(
                                                                        "Bifrost Base URL（或 BIFROST_BASE_URL）",
                                                                        "Bifrost Base URL (or BIFROST_BASE_URL)")
                                                                    : copy.text("接口地址", "Endpoint URL"),
                    text: $configuration.endpoint
                )

            }
            if configuration.source == .command {
                ProviderSettingsTextField(
                    title: descriptor.id.rawValue == "doubao"
                        ? copy.text("arkcli 可执行文件路径（可选）", "arkcli executable path (optional)")
                        : descriptor.id.rawValue == "codex"
                            ? copy.text("Codex CLI 可执行文件路径（可选）", "Codex CLI executable path (optional)")
                            : descriptor.id.rawValue == "claude"
                                ? copy.text("Claude CLI 可执行文件路径（可选）", "Claude CLI executable path (optional)")
                                : descriptor.id.rawValue == "coderabbit"
                                    ? copy.text(
                                        "CodeRabbit CLI 可执行文件路径（可选）", "CodeRabbit CLI executable path (optional)")
                                    : copy.text(
                                        "输出 JSON 或百分比的命令",
                                        "Command that outputs JSON or percentages"
                                    ),
                    text: $configuration.command
                )
            }
            if descriptor.id.rawValue == "doubao" {
                ProviderSettingsTextField(
                    title: copy.text("Region（默认 cn-beijing）", "Region (default: cn-beijing)"),
                    text: $configuration.account
                )
            }
            if descriptor.id.rawValue == "moonshot" {
                ProviderSettingsLabeledRow(title: copy.text("API 区域", "API region")) {
                    Picker("", selection: $configuration.account) {
                        Text(copy.text("国际", "International"))
                            .tag(MoonshotUsageRegion.international.rawValue)
                        Text(copy.text("中国大陆", "China"))
                            .tag(MoonshotUsageRegion.china.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: configuration.account) { _, newRegion in
                        guard !configuration.endpoint.isEmpty,
                            configuration.endpoint != newRegion
                        else { return }
                        secret = ""
                    }
                }

            }
            if descriptor.id.rawValue == "notion" {
                ProviderSettingsTextField(
                    title: copy.text("Workspace ID（可选）", "Workspace ID (optional)"),
                    text: $configuration.account
                )

            }
            if descriptor.id.rawValue == "workbuddy" {
                ProviderSettingsTextField(
                    title: copy.text("User-Agent（可选）", "User-Agent (optional)"),
                    text: $configuration.account
                )

            }
            if descriptor.id.rawValue == "windsurf", configuration.source != .account {
                ProviderSettingsLabeledRow(title: copy.text("会话来源", "Session source")) {
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
                }
            }
            if descriptor.id.rawValue == "deepseek", deepSeekProfiles.count > 1 {
                ProviderSettingsLabeledRow(title: copy.text("Chrome Profile", "Chrome profile")) {
                    Picker("", selection: $configuration.account) {
                        Text(copy.text("未选择", "Not selected")).tag("")
                        ForEach(deepSeekProfiles, id: \.id) { profile in
                            Text(profile.sourceLabel).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            if configuration.source == .account
                && descriptor.id.rawValue != "antigravity"
                && descriptor.id.rawValue != "augment"
                && descriptor.id.rawValue != "codex"
                && descriptor.id.rawValue != "t3chat"
                && descriptor.id.rawValue != "zed"
                && descriptor.id.rawValue != "windsurf"
                && descriptor.id.rawValue != "muse"
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
                || descriptor.id.rawValue == "kimi"
                || descriptor.id.rawValue == "zai"
                || descriptor.id.rawValue == "minimax"
                || descriptor.id.rawValue == "jetbrains"
                || descriptor.id.rawValue == "deepgram"
                || descriptor.id.rawValue == "xai"
                || descriptor.id.rawValue == "exa"
                || descriptor.id.rawValue == "cosmic"
                || descriptor.id.rawValue == "flora"
                || descriptor.id.rawValue == "v0"
                || descriptor.id.rawValue == "gitkraken"
                || descriptor.id.rawValue == "claudeplatform"
                || descriptor.id.rawValue == "helmcode" && configuration.source == .cookie
                || descriptor.id.rawValue == "stepfun" && configuration.source != .token
                || descriptor.id.rawValue == "claude" && configuration.source == .cookie
            {
                ProviderSettingsTextField(
                    title: configurationAccountLabel,
                    text: $configuration.account
                )
            }
        } footer: {
            VStack(alignment: .leading, spacing: SettingsSpace.sm) {
                if descriptor.id.rawValue == "siliconflow" {
                    Text(
                        copy.text(
                            "默认中国区 https://api.siliconflow.cn（人民币）；国际账号填 https://api.siliconflow.com（美元）。留空时也会读取 SILICONFLOW_BASE_URL。",
                            "China https://api.siliconflow.cn (CNY) is the default. International accounts use https://api.siliconflow.com (USD). When blank, SILICONFLOW_BASE_URL is also read."
                        ))

                }
                if descriptor.id.rawValue == "moonshot" {
                    Text(
                        copy.text(
                            "切换区域后需要输入该区域对应的 API Key。自动模式也会读取 MOONSHOT_REGION。",
                            "Switching regions requires that region's API key. Automatic mode also reads MOONSHOT_REGION."
                        ))

                }
                if descriptor.id.rawValue == "notion" {
                    Text(
                        copy.text(
                            "留空时优先选择首个 Business 或 Enterprise workspace。",
                            "When left blank, the first Business or Enterprise workspace is preferred."
                        ))

                }
                if descriptor.id.rawValue == "workbuddy" {
                    Text(
                        copy.text(
                            "粘贴与 Cookie 来自同一请求的 User-Agent 值。",
                            "Paste the User-Agent value from the same request as the Cookie."
                        ))

                }
            }
        }
    }

    private var authenticationSection: some View {
        CodeEdgeFormSection(title: copy.text("认证", "Authentication")) {
            if descriptor.id.rawValue == "bedrock" {
                ProviderSettingsLabeledRow(title: copy.text("认证方式", "Authentication")) {
                    Picker("", selection: $bedrockAuthMode) {
                        Text(copy.text("Access keys", "Access keys"))
                            .tag(BedrockAuthMode.keys.rawValue)
                        Text(copy.text("AWS Profile", "AWS profile"))
                            .tag(BedrockAuthMode.profile.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if bedrockAuthMode == BedrockAuthMode.profile.rawValue {
                    ProviderSettingsTextField(
                        title: copy.text("Profile 名称", "Profile name"),
                        text: $bedrockProfile
                    )
                } else {
                    ProviderSettingsSecretField(title: "Access Key ID", text: $secret)
                    ProviderSettingsSecretField(title: "Secret Access Key", text: $secondarySecret)
                }
                ProviderSettingsTextField(
                    title: copy.text("Region（可选）", "Region (optional)"),
                    text: $bedrockRegion
                )
            } else {
                ProviderSettingsSecretField(title: secretLabel, text: authenticationSecret)
            }
            if descriptor.id.rawValue == "openrouter" {
                ProviderSettingsSecretField(
                    title: copy.text("管理 API Key（可选）", "Management API key (optional)"),
                    text: $managementSecret
                )
            }
            if descriptor.id.rawValue == "doubao" {
                ProviderSettingsSecretField(
                    title: copy.text("Secret Access Key（可选）", "Secret Access Key (optional)"),
                    text: $secondarySecret
                )
            }
            if descriptor.id.rawValue == "futureagi" {
                ProviderSettingsSecretField(
                    title: copy.text("Secret Key（或 FI_SECRET_KEY）", "Secret key (or FI_SECRET_KEY)"),
                    text: $secondarySecret
                )
            }
        } footer: {
            VStack(alignment: .leading, spacing: SettingsSpace.sm) {
                if !descriptor.environmentKeys.isEmpty {
                    Text(
                        copy.text("自动模式也会读取：", "Automatic mode also reads: ")
                            + descriptor.environmentKeys.joined(separator: ", ")
                    )
                    .textSelection(.enabled)
                }
                if descriptor.id.rawValue == "groq" {
                    Text(
                        copy.text(
                            "用量与支出会自动读取 console.groq.com 浏览器会话；API Key 为可选，仅用于补充 Enterprise Prometheus 指标。",
                            "Usage and spend come from the console.groq.com browser session automatically; the optional API key only adds Enterprise Prometheus metrics."
                        ))
                }
                if descriptor.id.rawValue == "openrouter" {
                    Text(
                        copy.text(
                            "上方 API Key 必填，可使用普通或管理密钥。官方接口上的管理密钥会读取最近 30 个完整 UTC 日活动；这里的可选管理密钥只用于单独指定活动凭据，也可设置 OPENROUTER_MANAGEMENT_API_KEY。",
                            "The API key above is required and accepts a regular or Management key. Management keys on the official API load the last 30 completed UTC days of Activity. This optional key only selects a separate Activity credential; OPENROUTER_MANAGEMENT_API_KEY is also supported."
                        ))
                }
            }
        }
    }

    private var statusSection: some View {
        CodeEdgeFormSection(title: copy.text("状态", "Status")) {
            let usage = store.usage(for: descriptor.id)
            CodeEdgeSideRow {
                Button(copy.text("刷新此 Provider", "Refresh provider")) {
                    saveAndRefresh(allowBrowserCookieImport: true)
                }
            } label: {
                HStack(spacing: SettingsSpace.sm) {
                    Circle().fill(statusColor(usage.state))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(stateText(usage.state))
                }
            }
        } footer: {
            if let message = store.usage(for: descriptor.id).message {
                Text(copy.usageMessage(message))
                    .foregroundStyle(
                        store.usage(for: descriptor.id).state == .failed
                            ? CodeEdgeSettingsTheme.error : CodeEdgeSettingsTheme.secondaryText
                    )
            }
        }
    }

    private var saveRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsSpace.md) {
            if let saveMessage {
                Text(saveMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        credentialReadError == nil ? CodeEdgeSettingsTheme.secondaryText : CodeEdgeSettingsTheme.error
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(copy.text("保存", "Save")) { saveAndRefresh() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SettingsSpace.xs)
    }

    private var secretLabel: String {
        if descriptor.id.rawValue == "langdock" {
            return copy.text("Cookie 标头（包含 auth_token）", "Cookie header (including auth_token)")
        }
        if descriptor.id.rawValue == "xapi" {
            return copy.text("Cookie 标头（包含 auth_token 和 ct0）", "Cookie header (including auth_token and ct0)")
        }
        if descriptor.id.rawValue == "raycast" {
            return copy.text("Cookie 标头（包含 __raycast_session）", "Cookie header (including __raycast_session)")
        }
        if ["museai", "tinyapi", "lithosai", "workbuddy", "parallel", "replicate", "typesafe", "helmcode"].contains(
            descriptor.id.rawValue)
        {
            return copy.text("Cookie 标头", "Cookie header")
        }
        if descriptor.id.rawValue == "opendesign" {
            return copy.text("Cookie 标头（amr-api.open-design.ai，可选）", "Cookie header (amr-api.open-design.ai, optional)")
        }
        if descriptor.id.rawValue == "traecn" {
            return copy.text("Cookie 标头（api.trae.cn，可选）", "Cookie header (api.trae.cn, optional)")
        }
        if descriptor.id.rawValue == "abliteration" {
            return "abliteration.ai API Key"
        }
        if descriptor.id.rawValue == "siliconflow" {
            return "SiliconFlow API Key"
        }
        if descriptor.id.rawValue == "tripo" {
            return "Tripo API Key"
        }
        if descriptor.id.rawValue == "chatbox" {
            return "Chatbox AI License Key"
        }
        if descriptor.id.rawValue == "futureagi" {
            return copy.text("API Key（或 FI_API_KEY）", "API key (or FI_API_KEY)")
        }
        if descriptor.id.rawValue == "munito" {
            return copy.text("Munito 管理 API Key（需读取账户数据权限）", "Munito admin API key (Read account data permission)")
        }
        if descriptor.id.rawValue == "soniox" {
            return copy.text("Soniox 组织 API Key", "Soniox organization API key")
        }
        if descriptor.id.rawValue == "claudeplatform" {
            return copy.text("Cookie 标头（包含 sessionKey）", "Cookie header (including sessionKey)")
        }
        if descriptor.id.rawValue == "bifrost" {
            return copy.text("Bifrost 虚拟 Key", "Bifrost virtual key")
        }
        if descriptor.id.rawValue == "nous" {
            return copy.text("Portal 访问令牌（可选）", "Portal access token (optional)")
        }
        if descriptor.id.rawValue == "muse" {
            return configuration.source == .token
                ? copy.text("Muse 登录令牌（dca:）", "Muse login token (dca:)")
                : copy.text("Muse 登录令牌（dca:，可选）", "Muse login token (dca:, optional)")
        }
        if descriptor.id.rawValue == "hyper" {
            return configuration.source == .cookie
                ? copy.text("Cookie 标头", "Cookie header")
                : "Hyper API Key"
        }
        if descriptor.id.rawValue == "aerostack" {
            return copy.text("Aerostack 账户 JWT", "Aerostack account JWT")
        }
        if descriptor.id.rawValue == "exa" {
            return copy.text("Exa 服务密钥", "Exa service key")
        }
        if descriptor.id.rawValue == "cosmic" {
            return copy.text("个人访问令牌", "Personal Access Token")
        }
        if descriptor.id.rawValue == "fal" {
            return "fal API Key (billing:usage:read)"
        }
        if descriptor.id.rawValue == "llmman" {
            return copy.text("API Key（可选）", "API key (optional)")
        }
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
            return copy.text("OpenRouter API Key（必填）", "OpenRouter API key (required)")
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
            default:
                copy.text(
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
        if ["langdock", "xapi", "museai", "tinyapi", "raycast", "lithosai", "workbuddy", "parallel", "claudeplatform"]
            .contains(descriptor.id.rawValue)
        {
            return source == .automatic
                ? copy.text("自动（使用已填 Cookie）", "Auto (configured Cookie)")
                : copy.text("手动 Cookie", "Manual Cookie")
        }
        if descriptor.id.rawValue == "muse" {
            return switch source {
            case .account: copy.text("本地 auth.json", "Local auth.json")
            case .token: copy.text("登录令牌", "Login token")
            default: source.title(language: language)
            }
        }
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
        if descriptor.id.rawValue == "gemini" {
            return switch source {
            case .account: "Gemini CLI"
            case .cookie: copy.text("Gemini 应用（浏览器会话）", "Gemini app (browser session)")
            default: source.title(language: language)
            }
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
            case .automatic:
                copy.text(
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
        if descriptor.id.rawValue == "coderabbit" { return false }
        if descriptor.id.rawValue == "pi" { return false }
        if descriptor.id.rawValue == "helmcode" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "zed" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "gemini" { return configuration.source == .cookie }
        if descriptor.id.rawValue == "codex" {
            return configuration.source == .automatic
                || configuration.source == .token
                || configuration.source == .cookie
        }
        if descriptor.id.rawValue == "claude" {
            return configuration.source != .account && configuration.source != .command
        }
        if descriptor.id.rawValue == "amp", configuration.source == .account { return false }
        if descriptor.id.rawValue == "muse", configuration.source == .account { return false }
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
        case "alibabatokenplan":
            copy.text(
                "区域（intl、cn、intl-personal 或 cn-personal）",
                "Region (intl, cn, intl-personal, or cn-personal)"
            )
        case "fireworks": copy.text("账号 slug（可选）", "Account slug (optional)")
        case "copilot": copy.text("企业主机（可选）", "Enterprise host (optional)")
        case "devin": copy.text("组织 slug 或 URL（可选）", "Organization slug or URL (optional)")
        case "kilo": copy.text("Organization ID（可选）", "Organization ID (optional)")
        case "kimi": copy.text("区域（china 或 international）", "Region (china or international)")
        case "zai": copy.text("API 区域（global 或 bigmodel-cn）", "API region (global or bigmodel-cn)")
        case "minimax": copy.text("MiniMax 区域（global 或 cn）", "MiniMax region (global or cn)")
        case "jetbrains": copy.text("IDE 配置目录（可选）", "IDE configuration directory (optional)")
        case "deepgram": copy.text("Project ID（可选；留空汇总全部项目）", "Project ID (optional; blank aggregates all projects)")
        case "xai": copy.text("Team ID", "Team ID")
        case "exa": copy.text("API Key ID（或 EXA_API_KEY_ID）", "API key ID (or EXA_API_KEY_ID)")
        case "cosmic": copy.text("Project ID（或 COSMIC_PROJECT_ID）", "Project ID (or COSMIC_PROJECT_ID)")
        case "flora": copy.text("Workspace ID（或 FLORA_WORKSPACE_ID）", "Workspace ID (or FLORA_WORKSPACE_ID)")
        case "v0": copy.text("项目范围（可选）", "Scope (optional)")
        case "gitkraken": copy.text("API 组织 ID（可选）", "API organization ID (optional)")
        case "claudeplatform": copy.text("Organization ID（可选）", "Organization ID (optional)")
        case "helmcode":
            copy.text(
                "Cookie 租户（nanBuilders；留空使用 Helmcode Cloud）", "Cookie tenant (nanBuilders; blank for Helmcode Cloud)")
        case "stepfun": copy.text("用户名", "Username")
        default: copy.text("账号标识（可选）", "Account identifier (optional)")
        }
    }

    private func saveAndRefresh(allowBrowserCookieImport: Bool = false) {
        guard save() else { return }
        Task {
            await store.refresh(
                providerID: descriptor.id, allowBrowserCookieImport: allowBrowserCookieImport, isManual: true)
        }
    }

    @discardableResult
    private func save() -> Bool {
        if let credentialReadError {
            saveMessage = copy.text(
                "凭据读取失败，请重新打开此 Provider 设置后再保存：\(credentialReadError)",
                "Credentials could not be read. Reopen this provider's settings before saving: \(credentialReadError)"
            )
            return false
        }
        do {
            try store.preferences.validateConfiguration()
            if descriptor.id.rawValue == "moonshot" {
                configuration.endpoint = secret.isEmpty ? "" : configuration.account
            }
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
            if descriptor.id.rawValue == "futureagi" {
                try store.preferences.setAuxiliarySecret(
                    secondarySecret,
                    for: descriptor.id,
                    key: "secret-key"
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
            store.preferences.update(configuration)
            saveMessage = copy.text("已保存", "Saved")
            return true
        } catch {
            saveMessage = error.localizedDescription
            return false
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
        case .ready: CodeEdgeSettingsTheme.statusGreen
        case .loading: CodeEdgeSettingsTheme.statusBlue
        case .unavailable: CodeEdgeSettingsTheme.statusAmber
        case .failed: CodeEdgeSettingsTheme.statusRed
        }
    }
}

private struct ProviderSettingsLabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CodeEdgeFormRow(label: Text(title).fixedSize(horizontal: false, vertical: true), content: content)
    }
}

private struct ProviderSettingsTextField: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ProviderSettingsLabeledRow(title: title) {
            TextField("", text: $text)
                .focused($focused)
                .codeEdgeSettingsField(focused: focused)
                .accessibilityLabel(title)
        }
    }
}

private struct ProviderSettingsSecretField: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ProviderSettingsLabeledRow(title: title) {
            SecureField("", text: $text)
                .focused($focused)
                .codeEdgeSettingsField(focused: focused)
                .accessibilityLabel(title)
        }
    }
}
