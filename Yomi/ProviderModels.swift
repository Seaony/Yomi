import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    nonisolated init(rawValue: String) {
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

    nonisolated var clampedFraction: Double {
        min(max(usedFraction, 0), 1)
    }
}

struct DailyTokenUsage: Codable, Hashable, Sendable {
    var tokens: Int64
    var valueUSD: Double?
}

struct ProviderCostSummary: Codable, Hashable, Sendable {
    var used: Double
    var limit: Double
    var currencyCode: String
    var period: String?
    var balance: Double?
}

struct UsageDetail: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var value: String
}

struct LocalTokenUsageSummary: Sendable {
    var today: DailyTokenUsage?
    var last30Days: DailyTokenUsage?
    var currentWeek: DailyTokenUsage?
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
    var additionalWindows: [UsageWindow] = []
    var balance: String?
    var plan: String?
    var today: DailyTokenUsage? = nil
    var last30Days: DailyTokenUsage? = nil
    var weeklyEstimate: DailyTokenUsage? = nil
    var providerCost: ProviderCostSummary? = nil
    var details: [UsageDetail] = []
    var commandCodeSubscriptionEnrichmentUnavailable = false
    var commandCodeHasSubscriptionPlan = false
    var commandCodeMonthlyGrantDepleted = false
    var updatedAt: Date?
    var message: String?

    nonisolated init(
        id: ProviderID,
        state: State,
        windows: [UsageWindow],
        additionalWindows: [UsageWindow] = [],
        balance: String? = nil,
        plan: String? = nil,
        today: DailyTokenUsage? = nil,
        last30Days: DailyTokenUsage? = nil,
        weeklyEstimate: DailyTokenUsage? = nil,
        providerCost: ProviderCostSummary? = nil,
        details: [UsageDetail] = [],
        commandCodeSubscriptionEnrichmentUnavailable: Bool = false,
        commandCodeHasSubscriptionPlan: Bool = false,
        commandCodeMonthlyGrantDepleted: Bool = false,
        updatedAt: Date? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.state = state
        self.windows = windows
        self.additionalWindows = additionalWindows
        self.balance = balance
        self.plan = plan
        self.today = today
        self.last30Days = last30Days
        self.weeklyEstimate = weeklyEstimate
        self.providerCost = providerCost
        self.details = details
        self.commandCodeSubscriptionEnrichmentUnavailable = commandCodeSubscriptionEnrichmentUnavailable
        self.commandCodeHasSubscriptionPlan = commandCodeHasSubscriptionPlan
        self.commandCodeMonthlyGrantDepleted = commandCodeMonthlyGrantDepleted
        self.updatedAt = updatedAt
        self.message = message
    }

    var headlineFraction: Double {
        windows.first?.clampedFraction ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, windows, additionalWindows, balance, plan, today, last30Days
        case weeklyEstimate, providerCost, details, updatedAt, message
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ProviderID.self, forKey: .id)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .unavailable
        windows = try values.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        additionalWindows = try values.decodeIfPresent([UsageWindow].self, forKey: .additionalWindows) ?? []
        balance = try values.decodeIfPresent(String.self, forKey: .balance)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        today = try values.decodeIfPresent(DailyTokenUsage.self, forKey: .today)
        last30Days = try values.decodeIfPresent(DailyTokenUsage.self, forKey: .last30Days)
        weeklyEstimate = try values.decodeIfPresent(DailyTokenUsage.self, forKey: .weeklyEstimate)
        providerCost = try values.decodeIfPresent(ProviderCostSummary.self, forKey: .providerCost)
        details = try values.decodeIfPresent([UsageDetail].self, forKey: .details) ?? []
        commandCodeSubscriptionEnrichmentUnavailable = false
        commandCodeHasSubscriptionPlan = false
        commandCodeMonthlyGrantDepleted = false
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        message = try values.decodeIfPresent(String.self, forKey: .message)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(state, forKey: .state)
        try values.encode(windows, forKey: .windows)
        try values.encode(additionalWindows, forKey: .additionalWindows)
        try values.encodeIfPresent(balance, forKey: .balance)
        try values.encodeIfPresent(plan, forKey: .plan)
        try values.encodeIfPresent(today, forKey: .today)
        try values.encodeIfPresent(last30Days, forKey: .last30Days)
        try values.encodeIfPresent(weeklyEstimate, forKey: .weeklyEstimate)
        try values.encodeIfPresent(providerCost, forKey: .providerCost)
        try values.encode(details, forKey: .details)
        try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(message, forKey: .message)
    }
}
