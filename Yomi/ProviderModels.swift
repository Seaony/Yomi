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

    var title: String {
        switch self {
        case .automatic: "自动检测"
        case .account: "本机账号"
        case .token: "访问令牌"
        case .cookie: "浏览器会话"
        case .command: "命令行工具"
        case .endpoint: "自定义接口"
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
