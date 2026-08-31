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

struct AppCopy {
    let language: AppLanguage

    func text(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english, language: language)
    }

    func usageLabel(_ label: String) -> String {
        guard language == .simplifiedChinese else { return label }
        return Self.usageLabels[label] ?? label
    }

    func usageMessage(_ message: String) -> String {
        let pairs = [
            ("未找到可用的认证信息", "No available credentials found"),
            ("尚未配置用量接口", "Usage endpoint is not configured"),
            ("无法识别返回的用量数据", "The returned usage data could not be read"),
            ("未找到本机用量记录", "No local usage records found"),
            ("未配置命令", "Command is not configured"),
            ("等待首次刷新", "Waiting for the first refresh"),
        ]
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
        "Spend": "支出",
        "Requests": "请求",
        "Status": "状态",
        "Deployment": "部署",
        "5-hour": "5 小时",
        "Total": "总计",
        "Credits": "点数",
        "Usage": "用量",
        "Standard": "标准",
        "Premium": "高级",
        "Daily": "每日",
        "Prompts": "提示词",
        "Window": "窗口",
        "Monthly credits": "每月点数",
        "Daily refresh": "每日刷新",
        "7-day usage": "7 天用量",
        "5-hour usage": "5 小时用量",
        "Bonus": "赠送",
        "Tokens": "Token",
        "Current": "当前",
        "Refill": "补充",
        "Balance": "余额",
        "Base": "基础",
        "Overage": "超额",
        "Five-hour quota": "5 小时额度",
        "Weekly tokens": "每周 Token",
        "Voices": "语音",
        "Add-on credits": "附加点数",
        "Edit predictions": "编辑预测",
        "Billing cycle": "计费周期",
        "Bonus credits": "赠送点数",
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

    private let defaults: UserDefaults
    private let appearanceKey = "app-appearance"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: appearanceKey) ?? ""
        ) ?? .system
        language = AppLanguage(
            rawValue: defaults.string(forKey: AppLocalization.languageKey) ?? ""
        ) ?? .simplifiedChinese
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

enum AppTheme {
    static func railBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : Color(white: 0.97)
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
