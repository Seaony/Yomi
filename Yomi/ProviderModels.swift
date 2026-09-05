import Foundation

nonisolated struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    nonisolated init(rawValue: String) {
        self.rawValue = rawValue
    }
}

nonisolated enum ProviderSource: String, Codable, CaseIterable, Sendable {
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

nonisolated enum ProviderMetricKind: String, Codable, Sendable {
    case quota
    case balance
    case spend
    case requests
    case tokens
    case credits
}

nonisolated struct ProviderDescriptor: Identifiable, Hashable, Sendable {
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

nonisolated struct ProviderConfiguration: Codable, Hashable, Sendable, Identifiable {
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

nonisolated struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var usedFraction: Double
    var resetsAt: Date?
    var detail: String?

    nonisolated var clampedFraction: Double {
        min(max(usedFraction, 0), 1)
    }
}

nonisolated struct DailyTokenUsage: Codable, Hashable, Sendable {
    var tokens: Int64
    var valueUSD: Double?
}

nonisolated struct DailyRequestUsage: Codable, Hashable, Sendable {
    var requests: Int64
    var valueUSD: Double
}

nonisolated struct ProviderTokenUsageBreakdown: Codable, Hashable, Sendable, Identifiable {
    var providerID: ProviderID
    var usage: DailyTokenUsage

    var id: ProviderID { providerID }
}

nonisolated struct DailyTokenUsagePoint: Codable, Hashable, Sendable, Identifiable {
    var date: Date
    var usage: DailyTokenUsage
    var providerBreakdown: [ProviderTokenUsageBreakdown]? = nil

    var id: Date { date }
}

nonisolated struct ProviderCostSummary: Codable, Hashable, Sendable {
    var used: Double
    var limit: Double
    var currencyCode: String
    var period: String?
    var balance: Double?
}

nonisolated struct UsageDetail: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var value: String
}

nonisolated struct LocalTokenUsageSummary: Sendable {
    var today: DailyTokenUsage?
    var last30Days: DailyTokenUsage?
    var currentWeek: DailyTokenUsage?
    var last30DaysDaily: [DailyTokenUsagePoint]
}

nonisolated struct ProviderUsage: Codable, Hashable, Sendable, Identifiable {
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
    var todayDate: Date? = nil
    var todayRequests: DailyRequestUsage? = nil
    var last30DaysRequests: DailyRequestUsage? = nil
    var last30Days: DailyTokenUsage? = nil
    var last30DaysDaily: [DailyTokenUsagePoint] = []
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
        todayDate: Date? = nil,
        todayRequests: DailyRequestUsage? = nil,
        last30DaysRequests: DailyRequestUsage? = nil,
        last30Days: DailyTokenUsage? = nil,
        last30DaysDaily: [DailyTokenUsagePoint] = [],
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
        self.todayDate = todayDate ?? updatedAt
        self.todayRequests = todayRequests
        self.last30DaysRequests = last30DaysRequests
        self.last30Days = last30Days
        self.last30DaysDaily = last30DaysDaily
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
        case last30DaysDaily
        case todayDate, todayRequests, last30DaysRequests
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
        last30DaysDaily = try values.decodeIfPresent(
            [DailyTokenUsagePoint].self,
            forKey: .last30DaysDaily
        ) ?? []
        weeklyEstimate = try values.decodeIfPresent(DailyTokenUsage.self, forKey: .weeklyEstimate)
        providerCost = try values.decodeIfPresent(ProviderCostSummary.self, forKey: .providerCost)
        details = try values.decodeIfPresent([UsageDetail].self, forKey: .details) ?? []
        commandCodeSubscriptionEnrichmentUnavailable = false
        commandCodeHasSubscriptionPlan = false
        commandCodeMonthlyGrantDepleted = false
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        todayDate = try values.decodeIfPresent(Date.self, forKey: .todayDate) ?? updatedAt
        todayRequests = try values.decodeIfPresent(DailyRequestUsage.self, forKey: .todayRequests)
        last30DaysRequests = try values.decodeIfPresent(DailyRequestUsage.self, forKey: .last30DaysRequests)
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
        try values.encodeIfPresent(todayDate, forKey: .todayDate)
        try values.encodeIfPresent(todayRequests, forKey: .todayRequests)
        try values.encodeIfPresent(last30DaysRequests, forKey: .last30DaysRequests)
        try values.encodeIfPresent(last30Days, forKey: .last30Days)
        try values.encode(last30DaysDaily, forKey: .last30DaysDaily)
        try values.encodeIfPresent(weeklyEstimate, forKey: .weeklyEstimate)
        try values.encodeIfPresent(providerCost, forKey: .providerCost)
        try values.encode(details, forKey: .details)
        try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(message, forKey: .message)
    }
}
