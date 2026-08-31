import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum ProviderSource: String, Codable, CaseIterable, Sendable {
    case automatic
    case account
    case token
    case cookie
    case command
    case endpoint

    func title(language: AppLanguage) -> String {
        let copy = AppCopy(language: language)
        return switch self {
        case .automatic: copy.text("自动检测", "Automatic")
        case .account: copy.text("本机账号", "Local account")
        case .token: copy.text("访问令牌", "Access token")
        case .cookie: copy.text("浏览器会话", "Browser session")
        case .command: copy.text("命令行工具", "Command line")
        case .endpoint: copy.text("自定义接口", "Custom endpoint")
        }
    }
}

enum ProviderMetricKind: String, Codable, Sendable {
    case quota
    case balance
    case spend
    case requests
    case tokens
    case credits
}

struct ProviderDescriptor: Identifiable, Hashable, Sendable {
    let id: ProviderID
    let name: String
    let shortName: String
    let primaryLabel: String
    let secondaryLabel: String
    let metricKind: ProviderMetricKind
    let preferredSources: [ProviderSource]
    let environmentKeys: [String]
    let defaultEndpoint: String?
    let symbol: String
    let hue: Double
    let defaultEnabled: Bool
}

struct ProviderConfiguration: Codable, Hashable, Sendable, Identifiable {
    var id: ProviderID
    var isEnabled: Bool
    var source: ProviderSource
    var endpoint: String
    var command: String
    var account: String

    init(descriptor: ProviderDescriptor) {
        id = descriptor.id
        isEnabled = descriptor.defaultEnabled
        source = .automatic
        endpoint = descriptor.defaultEndpoint ?? ""
        command = ""
        account = ""
    }
}

struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var usedFraction: Double
    var resetsAt: Date?
    var detail: String?

    var clampedFraction: Double {
        min(max(usedFraction, 0), 1)
    }
}

struct DailyTokenUsage: Codable, Hashable, Sendable {
    var tokens: Int64
    var valueUSD: Double?
}

struct ProviderUsage: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case ready
        case loading
        case unavailable
        case failed
    }

    var id: ProviderID
    var state: State
    var windows: [UsageWindow]
    var balance: String?
    var plan: String?
    var today: DailyTokenUsage? = nil
    var updatedAt: Date?
    var message: String?

    var headlineFraction: Double {
        windows.first?.clampedFraction ?? 0
    }
}
