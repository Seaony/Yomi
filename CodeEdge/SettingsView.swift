import AppKit
import ColorSelector
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
            AboutSettingsView(updateController: updates)
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
    private static let refreshIntervals = [0.0, 60, 300, 900, 1_800]
    @ObservedObject private var appPreferences = AppPreferences.shared
    @AppStorage("refresh-interval") private var refreshInterval = 0.0
    @AppStorage("show-provider-names") private var showProviderNames = true
    @AppStorage(FullscreenCollapsePolicy.settingKey) private var collapseInFullscreen = FullscreenCollapsePolicy.defaultEnabled
    @AppStorage(ProviderServiceStatusMonitor.settingKey) private var showServiceIncidents = ProviderServiceStatusMonitor.defaultEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @Environment(\.appLanguage) private var language

    private var copy: AppCopy { AppCopy(language: language) }

    var body: some View {
        SettingsScrollablePage {
            CodeEdgeSettingsForm {
                CodeEdgeFormSection(title: copy.text("外观与语言", "Appearance and language")) {
                    CodeEdgeSideRow(copy.text("外观", "Appearance")) {
                        CodeEdgeChoiceButtons(
                            options: AppAppearance.allCases, selection: $appPreferences.appearance,
                            title: appearanceTitle, symbol: appearanceSymbol, iconOnly: true
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(copy.text("外观", "Appearance"))
                    }
                    CodeEdgeSideRow(copy.text("语言", "Language")) {
                        CodeEdgeMenuPicker(
                            title: copy.text("语言", "Language"), selection: $appPreferences.language,
                            options: [(.english, "English"), (.simplifiedChinese, "简体中文")]
                        )
                    }
                }
                CodeEdgeFormSection(title: copy.text("悬浮侧边栏背景", "Floating rail background")) {
                    RailBackgroundRow(scheme: .light, title: copy.text("浅色外观", "Light appearance"))
                    RailBackgroundRow(scheme: .dark, title: copy.text("深色外观", "Dark appearance"))
                }

                CodeEdgeFormSection(title: copy.text("刷新", "Refresh")) {
                    CodeEdgeSideRow {
                        CodeEdgeMenuPicker(
                            title: copy.text("刷新间隔", "Refresh interval"), selection: $refreshInterval,
                            options: Self.refreshIntervals.map { interval in
                                (interval, interval == 0 ? copy.text("自动", "Auto")
                                    : copy.text("\(Int(interval / 60)) 分钟", "\(Int(interval / 60)) min"))
                            }
                        )
                    } label: {
                        CodeEdgeSettingsRowLabel(
                            title: copy.text("刷新间隔", "Refresh interval"),
                            detail: refreshIntervalDescription
                        )
                    }
                }

                CodeEdgeFormSection(title: copy.text("行为", "Behavior")) {
                    Toggle(copy.text("全屏时收起", "Collapse in full screen"), isOn: $collapseInFullscreen)
                    Toggle(copy.text("显示服务故障", "Show service incidents"), isOn: $showServiceIncidents)
                    Toggle(copy.text("登录后自动启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                    Toggle(copy.text("显示 Provider 名称", "Show provider names"), isOn: $showProviderNames)
                } footer: {
                    if let loginError { Text(loginError).foregroundStyle(CodeEdgeSettingsTheme.error) }
                }
            }
        }
    }

    private var refreshIntervalDescription: String {
        if refreshInterval == 0 {
            return copy.text(
                "常看时每 2 分钟刷新，闲置时最长间隔 30 分钟",
                "Every 2 min while you're looking, up to 30 min when idle."
            )
        }
        if let interval = Self.refreshIntervals.first(where: { $0 == refreshInterval }) {
            let minutes = Int(interval / 60)
            return copy.text(
                "每 \(minutes) 分钟更新侧边栏的额度和用量",
                "Updates quota and usage in the sidebar every \(minutes) min."
            )
        }
        return copy.text("定期更新侧边栏的额度和用量", "Updates quota and usage in the sidebar periodically.")
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
        case .system: "display"
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
                    Toggle(isOn: $lowQuotaEnabled) {
                        CodeEdgeSettingsRowLabel(
                            title: copy.text("剩余额度较低", "Low remaining quota"),
                            detail: copy.text("剩余额度降到所选百分比时提醒", "Alerts when remaining quota reaches a selected percentage.")
                        )
                    }
                    Toggle(isOn: $depletedEnabled) {
                        CodeEdgeSettingsRowLabel(
                            title: copy.text("额度用完", "Quota depleted"),
                            detail: copy.text("某个额度窗口的剩余量降到 0% 时提醒", "Alerts when any quota window runs out.")
                        )
                    }
                    Toggle(isOn: $resetEnabled) {
                        CodeEdgeSettingsRowLabel(
                            title: copy.text("额度重置或恢复", "Quota reset or restored"),
                            detail: copy.text("上一周期用量超过 15% 时，新周期开始会提醒", "Alerts when a new cycle starts if you used over 15% last cycle.")
                        )
                    }
                } footer: {
                    if notifications.authorizationDenied {
                        Text(copy.text("通知权限已关闭，请在系统设置 → 通知 → CodeEdge 中允许通知。", "Notifications are disabled. Allow CodeEdge notifications in System Settings → Notifications."))
                            .foregroundStyle(CodeEdgeSettingsTheme.warning)
                    } else if let error = notifications.permissionError {
                        Text(error).foregroundStyle(CodeEdgeSettingsTheme.warning)
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
                    } footer: {
                        Text(copy.text("每个额度周期只提醒一次", "Once per threshold each quota cycle"))
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

/// 一种外观下的侧边栏底色：十六进制输入框加取色器，改过才显示「恢复默认」。
private struct RailBackgroundRow: View {
    let scheme: ColorScheme
    let title: String
    @ObservedObject private var appPreferences = AppPreferences.shared
    @State private var hexDraft: String?
    @State private var showsColorPicker = false
    @FocusState private var hexFocused: Bool
    @Environment(\.appLanguage) private var language
    private var copy: AppCopy { AppCopy(language: language) }

    private var color: Color {
        appPreferences.railBackgroundColor(for: scheme) ?? AppTheme.railBackground(for: scheme)
    }

    private var currentHex: String {
        appPreferences.railBackgroundColorHex[scheme] ?? AppTheme.railBackgroundHex(for: scheme)
    }

    var body: some View {
        CodeEdgeSideRow(title) {
            HStack(spacing: SettingsSpace.sm) {
                if appPreferences.railBackgroundColorHex[scheme] != nil {
                    Button(copy.text("恢复默认", "Reset")) { appPreferences.setRailBackgroundColor(nil, for: scheme) }
                }
                TextField("#RRGGBB", text: Binding(
                    get: { hexDraft ?? currentHex },
                    set: { value in
                        hexDraft = appPreferences.setRailBackgroundColor(hex: value, for: scheme) == nil ? value : nil
                    }
                ))
                    .font(.system(size: 13, design: .monospaced))
                    .focused($hexFocused)
                    .codeEdgeSettingsField(focused: hexFocused)
                    .frame(width: 98)
                    .background {
                        if hexFocused { RailBackgroundFocusDismissal() }
                    }
                    .accessibilityLabel(title + " #RRGGBB")
                    .onSubmit { hexFocused = false }
                Button {
                    hexFocused = false
                    showsColorPicker = true
                } label: {
                    Color.clear.frame(width: 54, height: 28)
                }
                .buttonStyle(RailColorSwatchStyle(color: color))
                .accessibilityLabel(copy.text("\(title)背景颜色", "\(title) background color"))
                .accessibilityValue(currentHex)
                .popover(isPresented: $showsColorPicker) {
                    RailColorPopover(color: color) { appPreferences.setRailBackgroundColor($0, for: scheme) }
                }
            }
        }
        .onChange(of: hexFocused) { _, focused in
            if !focused { hexDraft = nil }
        }
    }
}

private struct RailColorSwatchStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let scale = configuration.isPressed ? 0.94 : hovering ? 1.04 : 1
        let shape = Capsule()
        let highlighted = isEnabled && reduceMotion && (hovering || configuration.isPressed)
        let border = if isFocused {
            CodeEdgeSettingsTheme.focus
        } else if highlighted {
            CodeEdgeSettingsTheme.accent
        } else {
            CodeEdgeSettingsTheme.border
        }
        let borderWidth: CGFloat = !isFocused && highlighted && configuration.isPressed ? 3 : 2
        configuration.label
            .background {
                shape.fill(border)
                    .overlay { shape.fill(color).padding(borderWidth) }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
            .pointerStyle(isEnabled ? .link : nil)
            .scaleEffect(isEnabled && !reduceMotion ? scale : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: scale)
    }
}

private struct RailColorPopover: View {
    @State private var hue: CGFloat
    @State private var saturation: CGFloat
    @State private var brightness: CGFloat
    @Environment(\.swatchColors) private var swatchColors
    @Environment(\.appLanguage) private var language
    let selectColor: (Color) -> Void

    init(color: Color, selectColor: @escaping (Color) -> Void) {
        // 打开时从当前颜色初始化色盘，只有拖动、点击色板或取色才保存。
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        _hue = State(initialValue: rgb.hueComponent)
        _saturation = State(initialValue: rgb.saturationComponent)
        _brightness = State(initialValue: rgb.brightnessComponent)
        self.selectColor = selectColor
    }

    var body: some View {
        let copy = AppCopy(language: language)
        Sketch(hue: $hue, saturation: $saturation, brightness: $brightness, alpha: .constant(1))
            .showsAlpha(false)
            .buttonStyle(.automatic)
            .environment(\.swatchColors, swatchColors.filter { $0.alphaComponent == 1 })
            .frame(width: 180, height: 230)
            .accessibilityRepresentation {
                VStack {
                    Slider(value: $hue, in: 0...1, step: 0.01) { Text(copy.text("色相", "Hue")) }
                    Slider(value: $saturation, in: 0...1, step: 0.01) { Text(copy.text("饱和度", "Saturation")) }
                    Slider(value: $brightness, in: 0...1, step: 0.01) { Text(copy.text("亮度", "Brightness")) }
                }
            }
            .onChange(of: Color(hue: hue, saturation: saturation, brightness: brightness)) { _, color in
                selectColor(color)
            }
    }
}

private struct RailBackgroundFocusDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            guard let window else {
                monitor = nil
                return
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window
            )
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
                // 先结束编辑，再把原点击交给菜单、按钮或下一个输入框。
                if let self, let window, event.window === window,
                   !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            window?.makeFirstResponder(nil)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var updateController: UpdateController
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
                    Text(copy.text("用到极限，心里有数", "Code to the edge."))
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
                    Button {
                        let directory = DiagnosticLog.shared.directoryURL
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(copy.text("打开日志", "Open Logs"))
                        }
                    }
                    Button(role: .destructive) { NSApp.terminate(nil) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "power")
                            Text(copy.text("退出", "Quit"))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsSpace.xl)
            .padding(.vertical, SettingsSpace.section)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return copy.text("版本 \(version)（\(build)）", "Version \(version) (\(build))")
    }
}
