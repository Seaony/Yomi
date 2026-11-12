import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsView.Section = .general
    @Published var selectedProviderID: ProviderID?
    @Published var searchText = ""

    func show(providerID: ProviderID?) {
        guard let providerID else { return }
        selectedProviderID = providerID
        searchText = ""
        selection = .providers
    }
}

struct SettingsView: View {
    enum Section: Hashable, CaseIterable {
        case general, notifications, providers, about
    }

    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateController
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var appPreferences = AppPreferences.shared

    private var copy: AppCopy { AppCopy(language: appPreferences.language) }

    var body: some View {
        TabView(selection: $navigation.selection) {
            GeneralSettingsView()
                .tabItem { Label(copy.text("通用", "General"), systemImage: "gearshape") }
                .tag(Section.general)
            QuotaNotificationSettingsView(notifications: store.notifications)
                .tabItem { Label(copy.text("提醒", "Notifications"), systemImage: "bell") }
                .tag(Section.notifications)
            ProviderSettingsView(
                store: store,
                selectedProviderID: $navigation.selectedProviderID,
                searchText: $navigation.searchText
            )
            .frame(height: 640)
            .tabItem { Label("Providers", systemImage: "square.grid.2x2") }
            .tag(Section.providers)
            AboutSettingsView(updateController: updates, store: store)
                .tabItem { Label(copy.text("关于", "About"), systemImage: "info.circle") }
                .tag(Section.about)
        }
        .frame(width: navigation.selection == .providers ? 900 : 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(CodeEdgeSettingsTheme.background)
        .buttonStyle(CodeEdgeFlatButtonStyle())
        .toggleStyle(CodeEdgeFormSwitchStyle())
        .controlSize(.small)
        .tint(CodeEdgeSettingsTheme.accent)
        .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
        .environment(\.appLanguage, appPreferences.language)
        .environment(\.locale, appPreferences.language.locale)
    }
}

// 短页按内容收缩，长页限制高度；滚动内容不进入工具栏。
private struct SettingsScrollablePage<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 640

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(640, contentHeight))
        .clipped()
        .scrollBounceBehavior(.basedOnSize)
        .codeEdgeSettingsPageTop()
        .background(CodeEdgeSettingsTheme.background)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var appPreferences = AppPreferences.shared
    @AppStorage("refresh-interval") private var refreshInterval = 300.0
    @AppStorage("show-provider-names") private var showProviderNames = true
    @AppStorage(FullscreenCollapsePolicy.settingKey) private var collapseInFullscreen = FullscreenCollapsePolicy.defaultEnabled
    @AppStorage(ProviderServiceStatusMonitor.settingKey) private var showServiceIncidents = ProviderServiceStatusMonitor.defaultEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var railBackgroundHex = ""
    @FocusState private var hexFocused: Bool
    @Environment(\.appLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme

    private var copy: AppCopy { AppCopy(language: language) }
    private var railBackgroundColor: Binding<Color> {
        Binding(
            get: { appPreferences.railBackgroundColor ?? AppTheme.railBackground(for: colorScheme) },
            set: { appPreferences.setRailBackgroundColor($0) }
        )
    }

    var body: some View {
        SettingsScrollablePage {
            CodeEdgeSettingsForm {
                CodeEdgeFormSection(title: copy.text("外观与语言", "Appearance and language")) {
                    CodeEdgeSideRow(copy.text("外观", "Appearance")) {
                        CodeEdgeChoiceButtons(
                            options: AppAppearance.allCases, selection: $appPreferences.appearance,
                            title: appearanceTitle, symbol: appearanceSymbol
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(copy.text("外观", "Appearance"))
                    }
                    CodeEdgeSideRow(copy.text("语言", "Language")) {
                        CodeEdgeChoiceButtons(
                            options: [AppLanguage.english, .simplifiedChinese], selection: $appPreferences.language,
                            title: { $0 == .english ? "English" : "简体中文" },
                            symbol: { $0 == .english ? "character.book.closed" : "character.book.closed.zh" }
                        )
                        .environment(\.locale, Locale(identifier: "en"))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(copy.text("语言", "Language"))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                        Text(copy.text("系统模式会自动跟随 macOS 的外观设置。", "System mode follows the current macOS appearance."))
                        Text(copy.text("切换设置、悬浮栏和详情卡片的显示语言。", "Changes the language across settings, the floating rail, and detail cards."))
                    }
                }
                CodeEdgeFormSection(title: copy.text("悬浮侧边栏背景", "Floating rail background")) {
                    CodeEdgeSideRow(copy.text("背景颜色", "Background color")) {
                        HStack(spacing: SettingsSpace.sm) {
                            if appPreferences.railBackgroundColorHex != nil {
                                Button(copy.text("恢复默认", "Reset")) { appPreferences.setRailBackgroundColor(nil) }
                            }
                            TextField("#RRGGBB", text: $railBackgroundHex)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($hexFocused)
                                .codeEdgeSettingsField(focused: hexFocused)
                                .frame(width: 98)
                                .accessibilityLabel(copy.text("悬浮侧边栏背景 #RRGGBB", "Floating rail background #RRGGBB"))
                                .onChange(of: railBackgroundHex) { _, value in
                                    guard let normalized = appPreferences.setRailBackgroundColor(hex: value), normalized != value else { return }
                                    railBackgroundHex = normalized
                                }
                            ColorPicker(copy.text("悬浮侧边栏背景", "Floating rail background"), selection: railBackgroundColor, supportsOpacity: false)
                                .labelsHidden()
                                .pointerStyle(.link)
                        }
                    }
                } footer: {
                    Text(copy.text("自定义悬浮侧边栏的背景颜色", "Customize the floating rail background color"))
                }
                .onAppear { railBackgroundHex = appPreferences.railBackgroundColorHex ?? "" }
                .onChange(of: appPreferences.railBackgroundColorHex) { _, value in railBackgroundHex = value ?? "" }

                CodeEdgeFormSection(title: copy.text("刷新", "Refresh")) {
                    CodeEdgeSideRow(copy.text("刷新间隔", "Refresh interval")) {
                        CodeEdgeChoiceButtons(
                            options: [60.0, 300, 900, 1_800], selection: $refreshInterval,
                            title: { interval in
                                let minutes = Int(interval / 60)
                                return copy.text("\(minutes) 分钟", "\(minutes) min")
                            }, symbol: { _ in "clock" }
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(copy.text("刷新间隔", "Refresh interval"))
                    }
                } footer: {
                    Text(copy.text("更短的间隔会更快同步额度变化，但会增加网络请求。", "Shorter intervals update quotas sooner and make more network requests."))
                }

                CodeEdgeFormSection(title: copy.text("行为", "Behavior")) {
                    Toggle(copy.text("全屏时收起", "Collapse in full screen"), isOn: $collapseInFullscreen)
                    Toggle(copy.text("显示服务故障", "Show service incidents"), isOn: $showServiceIncidents)
                    Toggle(copy.text("登录后自动启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                    Toggle(copy.text("显示 Provider 名称", "Show provider names"), isOn: $showProviderNames)
                } footer: {
                    VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                        Text(copy.text("全屏时收成细条，鼠标移到细条上即可展开", "Collapses to a thin bar in full screen. Hover it to expand."))
                        Text(copy.text("在圆环和详情卡中显示服务商故障", "Show provider incidents in rings and detail cards"))
                        Text(copy.text("登录 macOS 后自动运行 CodeEdge", "Start CodeEdge automatically after signing in to macOS"))
                        Text(copy.text("在悬浮栏圆环下方显示名称", "Show names below provider rings in the floating rail"))
                        if let loginError { Text(loginError).foregroundStyle(CodeEdgeSettingsTheme.error) }
                    }
                }
            }
        }
    }

    private func appearanceTitle(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: copy.text("系统", "System")
        case .light: copy.text("浅色", "Light")
        case .dark: copy.text("深色", "Dark")
        }
    }

    private func appearanceSymbol(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
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

private struct QuotaNotificationSettingsView: View {
    @ObservedObject var notifications: QuotaNotificationController
    @AppStorage(QuotaNotificationController.Keys.lowQuotaEnabled) private var lowQuotaEnabled = false
    @AppStorage(QuotaNotificationController.Keys.depletedEnabled) private var depletedEnabled = false
    @AppStorage(QuotaNotificationController.Keys.resetEnabled) private var resetEnabled = false
    @Environment(\.appLanguage) private var language
    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        SettingsScrollablePage {
            CodeEdgeSettingsForm {
                CodeEdgeFormSection(title: copy.text("额度提醒", "Quota notifications")) {
                    Toggle(copy.text("剩余额度较低", "Low remaining quota"), isOn: $lowQuotaEnabled)
                    Toggle(copy.text("额度用完", "Quota depleted"), isOn: $depletedEnabled)
                    Toggle(copy.text("额度重置或恢复", "Quota reset or restored"), isOn: $resetEnabled)
                } footer: {
                    VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                        Text(copy.text("跨过所选档位时提醒，每个周期一次", "Notify once per threshold in each quota cycle"))
                        Text(copy.text("额度耗尽时提醒", "Notify when a quota is exhausted"))
                        Text(copy.text("确认新周期开始后提醒", "Notify when a new quota cycle is confirmed"))
                        if notifications.authorizationDenied {
                            Text(copy.text("通知权限已关闭，请在系统设置 → 通知 → CodeEdge 中允许通知。", "Notifications are disabled. Allow CodeEdge notifications in System Settings → Notifications."))
                                .foregroundStyle(CodeEdgeSettingsTheme.warning)
                        } else if let error = notifications.permissionError {
                            Text(error).foregroundStyle(CodeEdgeSettingsTheme.warning)
                        }
                    }
                }
                if lowQuotaEnabled {
                    CodeEdgeFormSection(title: copy.text("剩余提醒阈值", "Remaining thresholds")) {
                        HStack(spacing: SettingsSpace.lg) {
                            ForEach(QuotaNotificationController.thresholdChoices, id: \.self) { threshold in
                                Toggle("\(threshold)%", isOn: Binding(
                                    get: { notifications.selectedThresholds.contains(threshold) },
                                    set: { enabled in
                                        var values = notifications.selectedThresholds
                                        if enabled { values.append(threshold) }
                                        else { values.removeAll { $0 == threshold } }
                                        if !values.isEmpty { notifications.setThresholds(values) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                // 复选框不使用表单的固定标题列。
                                .labeledContentStyle(.automatic)
                                .fixedSize()
                                .pointerStyle(.link)
                            }
                        }
                    }
                }
            }
        }
        .task { await notifications.refreshAuthorizationStatus() }
        .onChange(of: [lowQuotaEnabled, depletedEnabled, resetEnabled]) { old, new in
            if zip(old, new).contains(where: { !$0 && $1 }) {
                Task { await notifications.requestAuthorizationIfNeeded() }
            }
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updateController: UpdateController
    @ObservedObject var store: UsageStore
    @State private var copied = false
    @Environment(\.appLanguage) private var language
    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        SettingsScrollablePage {
            VStack(spacing: SettingsSpace.lg) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(spacing: SettingsSpace.xs) {
                    Text("CodeEdge").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CodeEdgeSettingsTheme.primaryText)
                    Text(copy.text("跨 Provider 用量一览", "Usage across all your providers"))
                    Text(versionText).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(CodeEdgeSettingsTheme.secondaryText)
                .multilineTextAlignment(.center)
                HStack(spacing: SettingsSpace.sm) {
                    Button { updateController.checkForUpdates() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(copy.text("检查更新", "Check for Updates"))
                        }
                    }
                    .disabled(!updateController.canCheckForUpdates)
                    Button(role: .destructive) { NSApp.terminate(nil) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "power")
                            Text(copy.text("退出 CodeEdge", "Quit CodeEdge"))
                        }
                    }
                }
                CodeEdgeFormSection(title: copy.text("诊断", "Diagnostics")) {
                    ForEach(store.enabledProviders) { descriptor in
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let backoff = store.backoffDescription(for: descriptor.id, now: context.date, language: language)
                            Group {
                                if let result = DiagnosticLog.shared.latestResult(for: descriptor.id) {
                                    Text(diagnosticLine(provider: descriptor.name, result: result, now: context.date))
                                        .foregroundStyle(result.outcome == .success && backoff == nil ? CodeEdgeSettingsTheme.secondaryText : CodeEdgeSettingsTheme.warning)
                                        .help(diagnosticLine(provider: descriptor.name, result: result, now: context.date))
                                } else {
                                    Text(descriptor.name + " · " + (backoff ?? copy.text("等待首次刷新", "Waiting for the first refresh")))
                                        .foregroundStyle(backoff == nil ? CodeEdgeSettingsTheme.tertiaryText : CodeEdgeSettingsTheme.warning)
                                }
                            }
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SettingsSpace.sm) { diagnosticActions }
                        VStack(alignment: .leading, spacing: SettingsSpace.sm) { diagnosticActions }
                    }
                } footer: {
                    Text(copy.text("仅包含应用、系统、刷新状态和脱敏日志。", "Includes app, system, refresh status and redacted logs only."))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsSpace.xl)
            .padding(.vertical, SettingsSpace.section)
        }
    }

    @ViewBuilder private var diagnosticActions: some View {
        Button {
            NSPasteboard.general.clearContents()
            let limits = store.enabledProviders.compactMap { provider in
                store.backoffDescription(for: provider.id, language: language).map { provider.name + ": " + $0 }
            }
            let report = DiagnosticLog.shared.report(enabledProviders: store.enabledProviders)
                + (limits.isEmpty ? "" : "\n" + limits.joined(separator: "\n"))
            copied = NSPasteboard.general.setString(DiagnosticsRedactor.redact(report), forType: .string)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text(copied ? copy.text("已复制", "Copied") : copy.text("复制诊断信息", "Copy diagnostics"))
            }
        }
        Button {
            let directory = DiagnosticLog.shared.directoryURL
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(copy.text("打开日志文件夹", "Open log folder"))
            }
        }
    }
    private func diagnosticLine(provider: String, result: ProviderDiagnosticResult, now: Date) -> String {
        let outcome = result.outcome == .success ? copy.text("成功", "Success") : copy.text("失败", "Failed")
        let time = result.date.formatted(.dateTime.hour().minute().locale(language.locale))
        let status = store.backoffDescription(for: result.providerID, now: now, language: language) ?? outcome
        var parts = [provider, status, result.source, time]
        if result.outcome == .failed {
            if let error = result.errorKind { parts.append(error) }
            if let status = result.httpStatus { parts.append("HTTP \(status)") }
        }
        if result.usedCache { parts.append(copy.text("已回退缓存", "Using cached data")) }
        return DiagnosticsRedactor.redact(parts.joined(separator: " · "))
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return copy.text("版本 \(version)（\(build)）", "Version \(version) (\(build))")
    }
}
