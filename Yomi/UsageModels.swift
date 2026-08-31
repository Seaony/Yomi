import CodexBarCore
import Foundation

struct ProviderDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let sessionLabel: String
    let weeklyLabel: String
    let tertiaryLabel: String
    let accentHex: String

    var defaultsKey: String { "provider.\(id).enabled" }
}

struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?

    var normalizedPercent: Double {
        min(100, max(0, usedPercent))
    }
}

struct ProviderUsage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let definition: ProviderDefinition
    var windows: [UsageWindow]
    var balanceText: String?
    var updatedAt: Date?
    var issue: String?

    var primary: UsageWindow? { windows.first }

    static func loading(_ definition: ProviderDefinition) -> Self {
        Self(
            id: definition.id,
            definition: definition,
            windows: [],
            balanceText: nil,
            updatedAt: nil,
            issue: nil)
    }

    static func unavailable(_ definition: ProviderDefinition, issue: String) -> Self {
        Self(
            id: definition.id,
            definition: definition,
            windows: [],
            balanceText: nil,
            updatedAt: nil,
            issue: issue)
    }
}

enum ProviderDefinitions {
    nonisolated static let all: [ProviderDefinition] = ProviderDescriptorRegistry.all.map { descriptor in
        ProviderDefinition(
            id: descriptor.id.rawValue,
            displayName: descriptor.metadata.displayName,
            sessionLabel: descriptor.metadata.sessionLabel,
            weeklyLabel: descriptor.metadata.weeklyLabel,
            tertiaryLabel: descriptor.metadata.opusLabel ?? "其他配额",
            accentHex: descriptor.branding.color.hexString)
    }
}

enum UsageFormatting {
    static func percentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func resetDescription(_ window: UsageWindow, now: Date = Date()) -> String {
        if let supplied = window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !supplied.isEmpty
        {
            return supplied
        }
        guard let date = window.resetsAt else { return "重置时间未知" }
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "即将重置" }

        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "\(minutes) 分钟后重置"
        }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        if hours < 24 {
            return restMinutes == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(restMinutes) 分钟后重置"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm 重置"
        return formatter.string(from: date)
    }
}
