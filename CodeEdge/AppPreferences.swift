import AppKit
import Combine
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

nonisolated enum AppLocalization {
    static let languageKey = "app-language"

    static var currentLanguage: AppLanguage {
        AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: languageKey) ?? ""
        ) ?? .simplifiedChinese
    }

    static func text(
        _ chinese: String,
        _ english: String,
        language: AppLanguage = currentLanguage
    ) -> String {
        language == .simplifiedChinese ? chinese : english
    }
}

nonisolated struct AppCopy {
    let language: AppLanguage

    func text(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english, language: language)
    }

    func usageLabel(_ label: String) -> String {
        guard language == .simplifiedChinese else { return label }
        let basePrefix = "Base - "
        if label.hasPrefix(basePrefix) {
            return "\(Self.usageLabels["Base"] ?? "Base") - \(label.dropFirst(basePrefix.count))"
        }
        let workspacePrefix = "Workspace "
        if label.hasPrefix(workspacePrefix) {
            return "工作区 \(label.dropFirst(workspacePrefix.count))"
        }
        return Self.usageLabels[label] ?? label
    }

    // 通知只能展示这份固定词表，不能把接口传来的账号文字带出去。
    func knownUsageLabel(_ label: String) -> String? {
        if let chinese = Self.usageLabels[label] {
            return text(chinese, label)
        }
        if let pair = Self.usageLabels.first(where: { $0.value == label }) {
            return text(pair.value, pair.key)
        }
        return nil
    }

    func usageMessage(_ message: String) -> String {
        let pairs = [
            ("未找到可用的认证信息", "No available credentials found"),
            ("尚未配置用量接口", "Usage endpoint is not configured"),
            ("无法识别返回的用量数据", "The returned usage data could not be read"),
            ("未找到本机用量记录", "No local usage records found"),
            ("未配置命令", "Command is not configured"),
        ]
        // 旧缓存里可能还存着以前的占位文案。
        if message == "等待首次刷新" || message == "Waiting for the first refresh" {
            return text("还没有数据", "No data yet")
        }
        for pair in pairs where message == pair.0 || message == pair.1 {
            return text(pair.0, pair.1)
        }

        let requestPrefixes = ("请求失败（HTTP ", "Request failed (HTTP ")
        if message.hasPrefix(requestPrefixes.0) || message.hasPrefix(requestPrefixes.1) {
            let status = message.filter(\.isNumber)
            return text("请求失败（HTTP \(status)）", "Request failed (HTTP \(status))")
        }

        let commandPrefixes = ("命令执行失败：", "Command failed: ")
        if message.hasPrefix(commandPrefixes.0) {
            let detail = String(message.dropFirst(commandPrefixes.0.count))
            return text(message, commandPrefixes.1 + localizedCommandDetail(detail))
        }
        if message.hasPrefix(commandPrefixes.1) {
            let detail = String(message.dropFirst(commandPrefixes.1.count))
            return text(commandPrefixes.0 + localizedCommandDetail(detail), message)
        }
        return message
    }

    private func localizedCommandDetail(_ detail: String) -> String {
        let chinesePrefix = "退出码 "
        let englishPrefix = "Exit code "
        if detail.hasPrefix(chinesePrefix) || detail.hasPrefix(englishPrefix) {
            let code = detail.filter(\.isNumber)
            return text(chinesePrefix + code, englishPrefix + code)
        }
        return detail
    }

    private static let usageLabels: [String: String] = [
        "Session": "会话",
        "Weekly": "每周",
        "30-day": "30 天",
        "Spend": "支出",
        "Requests": "请求",
        "Status": "状态",
        "Deployment": "部署",
        "5-hour": "5 小时",
        "Total": "总计",
        "Cursor": "Cursor",
        "Third Party": "第三方",
        "Grok Bot": "Grok Bot",
        "Request quota": "请求额度",
        "Claude and GPT models": "Claude 与 GPT 模型",
        "Claude and GPT-OSS models": "Claude 与 GPT-OSS 模型",
        "Credits": "Credits",
        "Usage": "用量",
        "Standard": "标准",
        "Premium": "高级",
        "Daily": "每日",
        "Prompts": "提示词",
        "Window": "窗口",
        "Monthly credits": "每月 Credits",
        "Daily refresh": "每日刷新",
        "7-day usage": "7 天用量",
        "5-hour usage": "5 小时用量",
        "Bonus": "赠送",
        "Tokens": "Token",
        "Current": "当前",
        "Refill": "补充",
        "Balance": "余额",
        "Amp Free": "Amp 免费额度",
        "Other usage": "其他用量",
        "Orb usage": "Orb 用量",
        "Agent usage": "Agent 用量",
        "Monthly agent allowance": "每月 Agent 额度",
        "Monthly Orb allowance": "每月 Orb 额度",
        "Individual credits": "个人 Credits",
        "Base": "基础",
        "Overage": "超额",
        "Five-hour quota": "5 小时额度",
        "Weekly tokens": "每周 Token",
        "Voices": "语音",
        "Voice slots": "语音槽位",
        "Professional voices": "专业语音",
        "Remaining": "剩余",
        "Used": "已用",
        "Total added": "累计充值",
        "API key limit": "API Key 限额",
        "API key remaining": "API Key 剩余",
        "API key used": "API Key 已用",
        "Reset window": "重置周期",
        "Today": "今天",
        "This week": "本周",
        "This month": "本月",
        "Rate limit": "速率限制",
        "Last 30 days": "最近 30 天",
        "Last 30 days requests": "最近 30 天请求",
        "Add-on credits": "附加 Credits",
        "Edit predictions": "编辑预测",
        "Billing cycle": "计费周期",
        "Bonus credits": "赠送 Credits",
        "Purchased": "已购买 Credits",
        "Budget": "预算",
        "Cost": "费用",
        "Personal budget": "个人预算",
        "Team budget": "团队预算",
        "Points": "点数",
        "4-hour quota": "4 小时额度",
        "Monthly quota": "每月额度",
        "Subscription": "订阅",
        "Key allowance": "密钥额度",
        "Monthly budget": "每月预算",
        "Quota": "额度",
        "Fuel Pack": "燃料包",
        "Weekly quota": "每周额度",
        "Savings": "节省",
        "Rolling": "滚动周期",
        "Monthly": "每月",
        "Monthly Bobcoins": "每月 Bobcoins",
        "Gemini Models": "Gemini 模型",
        "Total usage": "总用量",
        "Code 7-day": "Code 7 天",
        "Kilo Pass": "Kilo Pass",
        "MCP": "MCP",
        "Account balance": "账户余额",
        "Model memory": "模型内存",
        "Models": "模型",
        "Daily free tokens": "每日免费 Token",
        "Plan": "套餐",
        "Plan credits": "套餐 Credits",
        "AI credits": "AI Credits",
        "Gateway requests": "Gateway 请求",
        "Top-up credits": "加油包 Credits",
        "Premium weekly": "Premium 周额度",
        "Secondary budget": "次要预算",
        "API key": "API Key",
        "Monthly tokens": "每月 Token",
        "Input tokens": "输入 Token",
        "Output tokens": "输出 Token",
        "Model quota": "模型额度",
        "Total usable": "可用总额度",
        "Reviews": "审查次数",
        "Billing": "计费",
        "Inference": "推理",
        "Personal": "个人额度",
        "Shared pool": "共享额度",
        "API credit": "API Credits",
        "Purchased credit": "购买 Credits",
        "Credit balance": "Credits 余额",
        "Monthly credits used": "本月已用 Credits",
        "Next refill": "下次补充",
    ]
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.simplifiedChinese
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: appearanceKey) }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: AppLocalization.languageKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    /// 浅色和深色外观各自的侧边栏底色，没设置时用默认色。
    @Published private(set) var railBackgroundColorHex: [ColorScheme: String] = [:]

    func railBackgroundColor(for scheme: ColorScheme) -> Color? {
        railBackgroundColorHex[scheme].flatMap(Self.color(from:))
    }

    private let defaults: UserDefaults
    private let appearanceKey = "app-appearance"
    /// 旧版只有一个底色，两种外观共用。
    private static let legacyRailBackgroundColorKey = "rail-background-color"

    private static func railBackgroundColorKey(for scheme: ColorScheme) -> String {
        scheme == .dark ? "rail-background-color.dark" : "rail-background-color.light"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: appearanceKey) ?? ""
        ) ?? .system
        language = AppLanguage(
            rawValue: defaults.string(forKey: AppLocalization.languageKey) ?? ""
        ) ?? .simplifiedChinese
        // 旧版的单一底色拆给浅色和深色各一份，两种外观下看到的颜色不变。
        if let legacy = defaults.string(forKey: Self.legacyRailBackgroundColorKey) {
            for scheme in [ColorScheme.light, .dark] where defaults.string(forKey: Self.railBackgroundColorKey(for: scheme)) == nil {
                defaults.set(legacy, forKey: Self.railBackgroundColorKey(for: scheme))
            }
            defaults.removeObject(forKey: Self.legacyRailBackgroundColorKey)
        }
        for scheme in [ColorScheme.light, .dark] {
            if let hex = defaults.string(forKey: Self.railBackgroundColorKey(for: scheme)) {
                setRailBackgroundColor(hex: hex, for: scheme)
            }
        }
    }

    func setRailBackgroundColor(_ color: Color?, for scheme: ColorScheme) {
        guard let color, let hex = Self.hexString(from: color) else {
            railBackgroundColorHex[scheme] = nil
            defaults.removeObject(forKey: Self.railBackgroundColorKey(for: scheme))
            return
        }
        setRailBackgroundColor(hex: hex, for: scheme)
    }

    @discardableResult
    func setRailBackgroundColor(hex: String, for scheme: ColorScheme) -> String? {
        guard let normalized = Self.normalizedHex(hex) else { return nil }
        if normalized == AppTheme.railBackgroundHex(for: scheme) {
            setRailBackgroundColor(nil, for: scheme)
        } else {
            railBackgroundColorHex[scheme] = normalized
            defaults.set(normalized, forKey: Self.railBackgroundColorKey(for: scheme))
        }
        return normalized
    }

    private static func normalizedHex(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return String(format: "#%06X", rgb)
    }

    private static func color(from hex: String) -> Color? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    private static func hexString(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

enum AppTheme {
    // 细条覆盖任意窗口，固定蓝色避免随强调色变灰。
    static let revealStrip = Color(red: 10 / 255.0, green: 132 / 255.0, blue: 1)

    static func railBackground(for colorScheme: ColorScheme) -> Color {
        Color(white: Double(railBackgroundShade(for: colorScheme)) / 255)
    }

    static func railBackgroundHex(for colorScheme: ColorScheme) -> String {
        let shade = railBackgroundShade(for: colorScheme)
        return String(format: "#%02X%02X%02X", shade, shade, shade)
    }

    private static func railBackgroundShade(for colorScheme: ColorScheme) -> Int {
        colorScheme == .dark ? 0 : 0xF7
    }

    static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static func detailBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.075, blue: 0.085)
            : Color(red: 0.965, green: 0.965, blue: 0.975)
    }
}
