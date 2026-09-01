import Foundation
import SweetCookieKit

nonisolated enum DeepSeekUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case missingPlatformSession
    case invalidPlatformSession
    case profileSelectionRequired
    case apiError(String)
    case networkError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text("缺少 DeepSeek API Key", "Missing DeepSeek API key")
        case .missingPlatformSession:
            AppLocalization.text(
                "未找到 DeepSeek Platform 会话，请先在 Chrome 登录 platform.deepseek.com",
                "No DeepSeek Platform session was found. Sign in to platform.deepseek.com in Chrome first."
            )
        case .invalidPlatformSession:
            AppLocalization.text(
                "DeepSeek Platform 会话已失效，请重新登录",
                "The DeepSeek Platform session is missing or expired."
            )
        case .profileSelectionRequired:
            AppLocalization.text(
                "检测到多个 DeepSeek Chrome 会话，请选择一个 Chrome Profile",
                "Multiple DeepSeek Chrome sessions are valid. Select a Chrome profile."
            )
        case let .apiError(message):
            AppLocalization.text("DeepSeek 接口错误：\(message)", "DeepSeek API error: \(message)")
        case let .networkError(message):
            AppLocalization.text("DeepSeek 网络错误：\(message)", "DeepSeek network error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 DeepSeek 数据：\(message)", "Failed to parse DeepSeek response: \(message)")
        }
    }
}

nonisolated enum DeepSeekDetailedUsageState: Sendable, Equatable {
    case notRequested
    case available
    case webSessionRequired
    case profileSelectionRequired
    case unavailable
}

nonisolated enum DeepSeekUsageCategory: String, Sendable, Equatable, CaseIterable {
    case promptCacheHitToken = "PROMPT_CACHE_HIT_TOKEN"
    case promptCacheMissToken = "PROMPT_CACHE_MISS_TOKEN"
    case responseToken = "RESPONSE_TOKEN"
    case request = "REQUEST"

    init?(apiValue: String?) {
        guard let apiValue else { return nil }
        self.init(rawValue: apiValue.uppercased())
    }
}

nonisolated struct DeepSeekCategoryBreakdown: Sendable, Equatable {
    let category: DeepSeekUsageCategory
    let tokens: Int
    let cost: Double?
}

nonisolated struct DeepSeekDailyUsage: Sendable, Equatable {
    let date: String
    let totalTokens: Int
    let cost: Double?
    let requestCount: Int
}

nonisolated struct DeepSeekUsageSummary: Sendable, Equatable {
    let todayTokens: Int
    let currentMonthTokens: Int
    let todayCost: Double?
    let currentMonthCost: Double?
    let requestCount: Int
    let currentMonthRequestCount: Int
    let topModel: String?
    let categoryBreakdown: [DeepSeekCategoryBreakdown]
    let daily: [DeepSeekDailyUsage]
    let currency: String
    let updatedAt: Date
}

nonisolated struct DeepSeekUsageSnapshot: Sendable, Equatable {
    let isAvailable: Bool
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
    let usageSummary: DeepSeekUsageSummary?
    let detailedUsageState: DeepSeekDetailedUsageState
    let updatedAt: Date

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"
        let total = Self.currency(totalBalance, symbol: symbol)
        let details = usageSummary.map { Self.summaryDetails($0, language: language) } ?? []

        let message: String? = if totalBalance <= 0 {
            AppLocalization.text(
                "余额为零，请前往 platform.deepseek.com 充值",
                "Balance is zero. Add credits at platform.deepseek.com.",
                language: language
            )
        } else if !isAvailable {
            AppLocalization.text(
                "当前余额不可用于 API 调用",
                "Balance unavailable for API calls",
                language: language
            )
        } else {
            switch detailedUsageState {
            case .webSessionRequired:
                AppLocalization.text(
                    "登录 DeepSeek Platform 后可显示详细用量",
                    "Sign in to DeepSeek Platform in Chrome for detailed usage.",
                    language: language
                )
            case .profileSelectionRequired:
                AppLocalization.text(
                    "请选择用于详细用量的 DeepSeek Chrome Profile",
                    "Select a DeepSeek Chrome profile for detailed usage.",
                    language: language
                )
            case .unavailable:
                AppLocalization.text("详细用量暂时不可用", "Detailed usage unavailable.", language: language)
            case .notRequested, .available:
                nil
            }
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "deepseek"),
            state: .ready,
            windows: [],
            balance: total,
            plan: nil,
            today: usageSummary.map {
                DailyTokenUsage(tokens: Int64($0.todayTokens), valueUSD: $0.todayCost)
            },
            details: details,
            updatedAt: updatedAt,
            message: message
        )
    }

    private static func summaryDetails(
        _ summary: DeepSeekUsageSummary,
        language: AppLanguage
    ) -> [UsageDetail] {
        let symbol = summary.currency.uppercased() == "CNY" ? "¥" : "$"
        let cost: (Double?) -> String = { value in
            value.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        }
        let tokens: (Int) -> String = { value in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        let tokenWord = AppLocalization.text("Token", "tokens", language: language)
        return [
            UsageDetail(
                id: "deepseek-today",
                label: "Today",
                value: "\(cost(summary.todayCost)) · \(tokens(summary.todayTokens)) \(tokenWord)"
            ),
            UsageDetail(
                id: "deepseek-month",
                label: "This month",
                value: "\(cost(summary.currentMonthCost)) · \(tokens(summary.currentMonthTokens)) \(tokenWord)"
            ),
            UsageDetail(
                id: "deepseek-requests",
                label: "Requests",
                value: tokens(summary.currentMonthRequestCount)
            ),
        ]
    }

    private static func currency(_ value: Double, symbol: String) -> String {
        "\(symbol)\(String(format: "%.2f", value))"
    }
}

nonisolated enum DeepSeekUsageFetcher {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    static let platformBalanceURL = URL(
        string: "https://platform.deepseek.com/api/v0/users/get_user_summary"
    )!
    static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    static let apiKeyEnvironmentKeys = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]
    static let platformTokenEnvironmentKeys = ["DEEPSEEK_PLATFORM_TOKEN", "DEEPSEEK_USER_TOKEN"]
    private static let timeout: TimeInterval = 15

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        resolvedValue(configured: configured, keys: apiKeyEnvironmentKeys, environment: environment)
    }

    static func resolvedPlatformToken(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        resolvedValue(configured: configured, keys: platformTokenEnvironmentKeys, environment: environment)
    }

    static func fetch(
        source: ProviderSource,
        apiKey configuredAPIKey: String?,
        platformToken configuredPlatformToken: String? = nil,
        selectedProfileID: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories(),
        includeOptionalUsage: Bool = true,
        now: Date = Date(),
        language: AppLanguage = AppLocalization.currentLanguage
    ) async throws -> ProviderUsage {
        do {
            switch source {
            case .cookie:
                let token = try await platformToken(
                    explicit: resolvedPlatformToken(configured: configuredPlatformToken ?? configuredAPIKey,
                                                    environment: environment),
                    selectedProfileID: selectedProfileID,
                    requiresExplicitSelection: false,
                    session: session,
                    homeDirectories: homeDirectories
                )
                return try await fetchPlatform(
                    platformToken: token,
                    session: session,
                    includeOptionalUsage: includeOptionalUsage,
                    now: now
                ).toProviderUsage(language: language)
            case .automatic, .token:
                if let apiKey = resolvedAPIKey(configured: configuredAPIKey, environment: environment) {
                    let explicitPlatform = cleaned(configuredPlatformToken)
                    let platform: String?
                    let missingState: DeepSeekDetailedUsageState
                    if !includeOptionalUsage {
                        platform = nil
                        missingState = .notRequested
                    } else if let explicitPlatform {
                        platform = explicitPlatform
                        missingState = .unavailable
                    } else if let selectedProfileID {
                        platform = try? await platformToken(
                            explicit: nil,
                            selectedProfileID: selectedProfileID,
                            requiresExplicitSelection: true,
                            session: session,
                            homeDirectories: homeDirectories
                        )
                        missingState = platform == nil ? .unavailable : .available
                    } else {
                        platform = nil
                        let profiles = DeepSeekPlatformTokenImporter.importTokens(homeDirectories: homeDirectories)
                        missingState = profiles.isEmpty ? .webSessionRequired : .profileSelectionRequired
                    }
                    let snapshot = try await fetchAPI(
                        apiKey: apiKey,
                        platformToken: platform,
                        session: session,
                        includeOptionalUsage: includeOptionalUsage,
                        missingDetailedUsageState: missingState,
                        now: now
                    )
                    return snapshot.toProviderUsage(language: language)
                }
                guard source == .automatic else { throw DeepSeekUsageError.missingAPIKey }
                let token = try await platformToken(
                    explicit: resolvedPlatformToken(configured: configuredPlatformToken, environment: environment),
                    selectedProfileID: selectedProfileID,
                    requiresExplicitSelection: false,
                    session: session,
                    homeDirectories: homeDirectories
                )
                return try await fetchPlatform(
                    platformToken: token,
                    session: session,
                    includeOptionalUsage: includeOptionalUsage,
                    now: now
                ).toProviderUsage(language: language)
            case .account:
                let token = try await platformToken(
                    explicit: resolvedPlatformToken(configured: configuredPlatformToken ?? configuredAPIKey,
                                                    environment: environment),
                    selectedProfileID: selectedProfileID,
                    requiresExplicitSelection: false,
                    session: session,
                    homeDirectories: homeDirectories
                )
                return try await fetchPlatform(
                    platformToken: token,
                    session: session,
                    includeOptionalUsage: includeOptionalUsage,
                    now: now
                ).toProviderUsage(language: language)
            case .command, .endpoint:
                throw DeepSeekUsageError.missingAPIKey
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeepSeekUsageError {
            throw error
        } catch {
            throw DeepSeekUsageError.networkError(error.localizedDescription)
        }
    }

    static func fetchAPI(
        apiKey rawAPIKey: String,
        platformToken rawPlatformToken: String?,
        session: URLSession,
        includeOptionalUsage: Bool = true,
        missingDetailedUsageState: DeepSeekDetailedUsageState = .webSessionRequired,
        optionalJoinGrace: TimeInterval = 5,
        now: Date = Date()
    ) async throws -> DeepSeekUsageSnapshot {
        guard let apiKey = cleaned(rawAPIKey) else { throw DeepSeekUsageError.missingAPIKey }
        let platformToken = cleaned(rawPlatformToken)
        let optionalResult = DeepSeekOptionalSummaryResult()
        let optionalTask: Task<Void, Never>? = includeOptionalUsage && platformToken != nil ? Task {
            do {
                let summary = try await fetchUsageSummary(
                    platformToken: platformToken!, session: session, now: now
                )
                optionalResult.complete(.success(summary))
            } catch {
                optionalResult.complete(.failure(error))
            }
        } : nil
        do {
            let data = try await response(url: balanceURL, bearer: apiKey, session: session)
            var snapshot = try parseAPIBalance(data, now: now)
            let completion = await optionalCompletion(
                result: optionalResult,
                task: optionalTask,
                grace: optionalJoinGrace
            )
            let state: DeepSeekDetailedUsageState
            let summary: DeepSeekUsageSummary?
            switch completion {
            case let .success(value):
                summary = value
                state = .available
            case let .failure(error):
                summary = nil
                state = error as? DeepSeekUsageError == .invalidPlatformSession
                    ? .webSessionRequired
                    : .unavailable
            case nil:
                summary = nil
                state = includeOptionalUsage
                    ? (platformToken == nil ? missingDetailedUsageState : .unavailable)
                    : .notRequested
            }
            snapshot = snapshot.replacing(summary: summary, state: state)
            return snapshot
        } catch {
            optionalTask?.cancel()
            throw error
        }
    }

    static func fetchPlatform(
        platformToken rawToken: String,
        session: URLSession,
        includeOptionalUsage: Bool = true,
        optionalJoinGrace: TimeInterval = 5,
        now: Date = Date()
    ) async throws -> DeepSeekUsageSnapshot {
        guard let token = cleaned(rawToken) else { throw DeepSeekUsageError.invalidPlatformSession }
        let optionalResult = DeepSeekOptionalSummaryResult()
        let optionalTask: Task<Void, Never>? = includeOptionalUsage ? Task {
            do {
                let summary = try await fetchUsageSummary(platformToken: token, session: session, now: now)
                optionalResult.complete(.success(summary))
            } catch {
                optionalResult.complete(.failure(error))
            }
        } : nil
        do {
            let data = try await response(url: platformBalanceURL, bearer: token, session: session)
            var snapshot = try parsePlatformBalance(data, now: now)
            let completion = await optionalCompletion(
                result: optionalResult,
                task: optionalTask,
                grace: optionalJoinGrace
            )
            let state: DeepSeekDetailedUsageState
            let summary: DeepSeekUsageSummary?
            switch completion {
            case let .success(value):
                summary = value
                state = .available
            case let .failure(error):
                summary = nil
                state = error as? DeepSeekUsageError == .invalidPlatformSession
                    ? .webSessionRequired
                    : .unavailable
            case nil:
                summary = nil
                state = includeOptionalUsage ? .unavailable : .notRequested
            }
            snapshot = snapshot.replacing(summary: summary, state: state)
            return snapshot
        } catch {
            optionalTask?.cancel()
            throw error
        }
    }

    static func fetchUsageSummary(
        platformToken: String,
        session: URLSession,
        now: Date = Date(),
        calendar: Calendar? = nil
    ) async throws -> DeepSeekUsageSummary {
        let calendar = calendar ?? apiCalendar
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let month = components.month, let year = components.year else {
            throw DeepSeekUsageError.parseFailed("Could not determine current month/year")
        }
        async let amount = response(
            url: usageURL(base: usageAmountURL, month: month, year: year),
            bearer: platformToken,
            session: session
        )
        async let cost = response(
            url: usageURL(base: usageCostURL, month: month, year: year),
            bearer: platformToken,
            session: session
        )
        let (amountData, costData) = try await (amount, cost)
        return try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
            now: now,
            calendar: calendar
        )
    }

    static func parseAPIBalance(_ data: Data, now: Date = Date()) throws -> DeepSeekUsageSnapshot {
        let payload: APIBalanceResponse
        do {
            payload = try JSONDecoder().decode(APIBalanceResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
        let parsed = try payload.balanceInfos.map { info -> ParsedBalance in
            guard let total = Double(info.totalBalance),
                  let granted = Double(info.grantedBalance),
                  let toppedUp = Double(info.toppedUpBalance)
            else { throw DeepSeekUsageError.parseFailed("Non-numeric balance value in response.") }
            return ParsedBalance(
                currency: info.currency,
                total: total,
                granted: granted,
                toppedUp: toppedUp
            )
        }
        guard !parsed.isEmpty else {
            return DeepSeekUsageSnapshot(
                isAvailable: false,
                currency: "USD",
                totalBalance: 0,
                grantedBalance: 0,
                toppedUpBalance: 0,
                usageSummary: nil,
                detailedUsageState: .notRequested,
                updatedAt: now
            )
        }
        let selected = parsed.first { $0.currency == "USD" && $0.total > 0 }
            ?? parsed.first { $0.total > 0 }
            ?? parsed.first { $0.currency == "USD" }
            ?? parsed[0]
        return DeepSeekUsageSnapshot(
            isAvailable: payload.isAvailable,
            currency: selected.currency,
            totalBalance: selected.total,
            grantedBalance: selected.granted,
            toppedUpBalance: selected.toppedUp,
            usageSummary: nil,
            detailedUsageState: .notRequested,
            updatedAt: now
        )
    }

    static func parsePlatformBalance(_ data: Data, now: Date = Date()) throws -> DeepSeekUsageSnapshot {
        let payload: PlatformSummaryResponse
        do {
            payload = try JSONDecoder().decode(PlatformSummaryResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }
        try validateEnvelope(code: payload.code, label: "user summary code")
        try validateEnvelope(code: payload.data?.bizCode, label: "user summary biz_code")
        guard let summary = payload.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing user summary biz_data")
        }
        let paid = Dictionary(grouping: summary.normalWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let granted = Dictionary(grouping: summary.bonusWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let currencies = Set(paid.keys).union(granted.keys).sorted()
        guard !currencies.isEmpty else {
            return DeepSeekUsageSnapshot(
                isAvailable: false,
                currency: "USD",
                totalBalance: 0,
                grantedBalance: 0,
                toppedUpBalance: 0,
                usageSummary: nil,
                detailedUsageState: .notRequested,
                updatedAt: now
            )
        }
        let selected = currencies.first { $0 == "USD" && paid[$0, default: 0] + granted[$0, default: 0] > 0 }
            ?? currencies.first { paid[$0, default: 0] + granted[$0, default: 0] > 0 }
            ?? currencies.first(where: { $0 == "USD" })
            ?? currencies[0]
        let toppedUpBalance = paid[selected, default: 0]
        let grantedBalance = granted[selected, default: 0]
        let total = toppedUpBalance + grantedBalance
        return DeepSeekUsageSnapshot(
            isAvailable: total > 0,
            currency: selected,
            totalBalance: total,
            grantedBalance: grantedBalance,
            toppedUpBalance: toppedUpBalance,
            usageSummary: nil,
            detailedUsageState: .notRequested,
            updatedAt: now
        )
    }

    private static func platformToken(
        explicit: String?,
        selectedProfileID: String?,
        requiresExplicitSelection: Bool,
        session: URLSession,
        homeDirectories: [URL]
    ) async throws -> String {
        if let explicit = cleaned(explicit) { return explicit }
        let candidates = DeepSeekPlatformTokenImporter.importTokens(homeDirectories: homeDirectories)
        guard !candidates.isEmpty else { throw DeepSeekUsageError.missingPlatformSession }
        if let selectedProfileID {
            guard let selected = candidates.first(where: { $0.id == selectedProfileID }) else {
                throw DeepSeekUsageError.profileSelectionRequired
            }
            _ = try await fetchPlatform(
                platformToken: selected.token,
                session: session,
                includeOptionalUsage: false
            )
            return selected.token
        }
        if requiresExplicitSelection { throw DeepSeekUsageError.profileSelectionRequired }
        var valid: [DeepSeekPlatformTokenImporter.TokenInfo] = []
        var sawUnavailable = false
        for candidate in candidates {
            do {
                _ = try await fetchPlatform(
                    platformToken: candidate.token,
                    session: session,
                    includeOptionalUsage: false
                )
                valid.append(candidate)
            } catch DeepSeekUsageError.invalidPlatformSession {
                continue
            } catch {
                sawUnavailable = true
            }
        }
        if valid.count == 1 { return valid[0].token }
        if valid.count > 1 { throw DeepSeekUsageError.profileSelectionRequired }
        if sawUnavailable { throw DeepSeekUsageError.networkError("Chrome session resolution unavailable") }
        throw DeepSeekUsageError.missingPlatformSession
    }

    private static func response(url: URL, bearer: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekUsageError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                if url.host == "platform.deepseek.com" { throw DeepSeekUsageError.invalidPlatformSession }
            }
            throw DeepSeekUsageError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func optionalCompletion(
        result: DeepSeekOptionalSummaryResult,
        task: Task<Void, Never>?,
        grace: TimeInterval
    ) async -> Result<DeepSeekUsageSummary, Error>? {
        guard let task else { return nil }
        let deadline = Date().addingTimeInterval(max(0, grace))
        while !result.isCompleted, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let value = result.value { return value }
        task.cancel()
        return nil
    }

    private static func usageURL(base: URL, month: Int, year: Int) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        return components.url!
    }

    private static func validateEnvelope(code: Int?, label: String) throws {
        guard let code, code != 0 else { return }
        if code == 40002 || code == 40003 { throw DeepSeekUsageError.invalidPlatformSession }
        throw DeepSeekUsageError.apiError("\(label) \(code)")
    }

    private static func resolvedValue(
        configured: String?, keys: [String], environment: [String: String]
    ) -> String? {
        if let configured = cleaned(configured) { return configured }
        for key in keys {
            if let value = cleaned(environment[key]) { return value }
        }
        return nil
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private struct ParsedBalance {
        let currency: String
        let total: Double
        let granted: Double
        let toppedUp: Double
    }

    private struct APIBalanceResponse: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        private enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        private enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    private struct PlatformSummaryResponse: Decodable {
        let code: Int?
        let data: PlatformSummaryData?

        private enum CodingKeys: String, CodingKey { case code, data }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decodeIfPresent(Int.self, forKey: .code)
            data = code.map { $0 != 0 } == true
                ? try? values.decodeIfPresent(PlatformSummaryData.self, forKey: .data)
                : try values.decodeIfPresent(PlatformSummaryData.self, forKey: .data)
        }
    }

    private struct PlatformSummaryData: Decodable {
        let bizCode: Int?
        let bizData: PlatformWalletSummary?

        private enum CodingKeys: String, CodingKey {
            case bizCode = "biz_code"
            case bizData = "biz_data"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            bizCode = try values.decodeIfPresent(Int.self, forKey: .bizCode)
            bizData = bizCode.map { $0 != 0 } == true
                ? try? values.decodeIfPresent(PlatformWalletSummary.self, forKey: .bizData)
                : try values.decodeIfPresent(PlatformWalletSummary.self, forKey: .bizData)
        }
    }

    private struct PlatformWalletSummary: Decodable {
        let normalWallets: [PlatformWallet]
        let bonusWallets: [PlatformWallet]

        private enum CodingKeys: String, CodingKey {
            case normalWallets = "normal_wallets"
            case bonusWallets = "bonus_wallets"
        }
    }

    private struct PlatformWallet: Decodable {
        let balance: Double
        let currency: String

        private enum CodingKeys: String, CodingKey { case balance, currency }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            currency = try values.decode(String.self, forKey: .currency)
            if let number = try? values.decode(Double.self, forKey: .balance) {
                balance = number
            } else {
                let raw = try values.decode(String.self, forKey: .balance)
                guard let number = Double(raw) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .balance,
                        in: values,
                        debugDescription: "Expected a numeric wallet balance"
                    )
                }
                balance = number
            }
        }
    }
}

private nonisolated extension DeepSeekUsageSnapshot {
    func replacing(
        summary: DeepSeekUsageSummary?,
        state: DeepSeekDetailedUsageState
    ) -> DeepSeekUsageSnapshot {
        DeepSeekUsageSnapshot(
            isAvailable: isAvailable,
            currency: currency,
            totalBalance: totalBalance,
            grantedBalance: grantedBalance,
            toppedUpBalance: toppedUpBalance,
            usageSummary: summary,
            detailedUsageState: state,
            updatedAt: updatedAt
        )
    }
}

private nonisolated final class DeepSeekOptionalSummaryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<DeepSeekUsageSummary, Error>?

    var isCompleted: Bool { lock.withLock { storage != nil } }
    var value: Result<DeepSeekUsageSummary, Error>? { lock.withLock { storage } }

    func complete(_ value: Result<DeepSeekUsageSummary, Error>) {
        lock.withLock {
            if storage == nil { storage = value }
        }
    }
}

nonisolated enum DeepSeekPlatformTokenImporter {
    struct TokenInfo: Sendable, Equatable {
        let id: String
        let token: String
        let sourceLabel: String
    }

    static func importTokens(
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [TokenInfo] {
        let roots = ChromiumProfileLocator.roots(for: [.chrome], homeDirectories: homeDirectories)
        var results: [TokenInfo] = []
        for root in roots {
            guard let profiles = try? FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = profile.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }
                let directory = profile.appendingPathComponent("Local Storage/leveldb")
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let entries = ChromiumLocalStorageReader.readEntries(
                    for: "https://platform.deepseek.com",
                    in: directory
                )
                guard let raw = entries.first(where: { $0.key == "userToken" })?.value,
                      let token = extractUserToken(raw)
                else { continue }
                let id = "chrome:\(name)"
                if !results.contains(where: { $0.id == id && $0.token == token }) {
                    results.append(TokenInfo(
                        id: id,
                        token: token,
                        sourceLabel: "\(root.labelPrefix) \(name)"
                    ))
                }
            }
        }
        return results
    }

    static func extractUserToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let token = token(from: object) {
            return token
        }
        let unquoted: String
        if trimmed.count >= 2,
           trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
            || trimmed.hasPrefix("'") && trimmed.hasSuffix("'") {
            unquoted = String(trimmed.dropFirst().dropLast())
        } else {
            unquoted = trimmed
        }
        return plausible(unquoted) ? unquoted : nil
    }

    private static func token(from value: Any) -> String? {
        if let string = value as? String { return plausible(string) ? string : nil }
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in ["value", "token", "access_token", "accessToken", "userToken"] {
            if let token = dictionary[key] as? String, plausible(token) { return token }
        }
        return nil
    }

    private static func plausible(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 20 && !value.contains(where: \.isWhitespace)
    }
}

private nonisolated struct DeepSeekAmountPayload: Decodable {
    let code: Int?
    let data: DeepSeekAmountData?
    private enum CodingKeys: String, CodingKey { case code, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decodeIfPresent(Int.self, forKey: .code)
        data = code.map { $0 != 0 } == true
            ? try? values.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
            : try values.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
    }
}

private nonisolated struct DeepSeekAmountData: Decodable {
    let bizCode: Int?
    let bizData: DeepSeekAmountBizData?
    private enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bizCode = try values.decodeIfPresent(Int.self, forKey: .bizCode)
        bizData = bizCode.map { $0 != 0 } == true
            ? try? values.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
            : try values.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
    }
}

private nonisolated struct DeepSeekAmountBizData: Decodable {
    let total: [DeepSeekModelUsage]?
    let days: [DeepSeekDayUsage]?
}

private nonisolated struct DeepSeekCostPayload: Decodable {
    let code: Int?
    let data: DeepSeekCostData?
    private enum CodingKeys: String, CodingKey { case code, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decodeIfPresent(Int.self, forKey: .code)
        data = code.map { $0 != 0 } == true
            ? try? values.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
            : try values.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
    }
}

private nonisolated struct DeepSeekCostData: Decodable {
    let bizCode: Int?
    let bizData: [DeepSeekCostBizData]?
    private enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bizCode = try values.decodeIfPresent(Int.self, forKey: .bizCode)
        bizData = bizCode.map { $0 != 0 } == true
            ? try? values.decodeIfPresent([DeepSeekCostBizData].self, forKey: .bizData)
            : try values.decodeIfPresent([DeepSeekCostBizData].self, forKey: .bizData)
    }
}

private nonisolated struct DeepSeekCostBizData: Decodable {
    let total: [DeepSeekCostModelUsage]?
    let days: [DeepSeekCostDayUsage]?
    let currency: String?
}

private nonisolated struct DeepSeekModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekUsageItem]?
}

private nonisolated struct DeepSeekDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekModelUsage]?
}

private nonisolated struct DeepSeekUsageItem: Decodable {
    let type: String?
    let amount: String?
}

private nonisolated struct DeepSeekCostModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekCostItem]?
}

private nonisolated struct DeepSeekCostDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekCostModelUsage]?
}

private nonisolated struct DeepSeekCostItem: Decodable {
    let type: String?
    let amount: String?
}

nonisolated enum DeepSeekUsageCostParser {
    static func parse(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DeepSeekUsageSummary {
        let amount: DeepSeekAmountPayload
        let cost: DeepSeekCostPayload
        do { amount = try JSONDecoder().decode(DeepSeekAmountPayload.self, from: amountData) }
        catch { throw DeepSeekUsageError.parseFailed("amount: \(String(describing: error))") }
        do { cost = try JSONDecoder().decode(DeepSeekCostPayload.self, from: costData) }
        catch { throw DeepSeekUsageError.parseFailed("cost: \(String(describing: error))") }
        try validate(code: amount.code, label: "amount code")
        try validate(code: amount.data?.bizCode, label: "amount biz_code")
        try validate(code: cost.code, label: "cost code")
        try validate(code: cost.data?.bizCode, label: "cost biz_code")
        guard let amountBizData = amount.data?.bizData else {
            throw DeepSeekUsageError.parseFailed("Missing amount biz_data")
        }
        return aggregate(
            totalAmounts: amountBizData.total ?? [],
            totalCosts: cost.data?.bizData?.first?.total ?? [],
            dailyAmounts: amountBizData.days ?? [],
            dailyCosts: cost.data?.bizData?.first?.days ?? [],
            currency: cost.data?.bizData?.first?.currency ?? "CNY",
            now: now,
            calendar: calendar
        )
    }

    private static func aggregate(
        totalAmounts: [DeepSeekModelUsage],
        totalCosts: [DeepSeekCostModelUsage],
        dailyAmounts: [DeepSeekDayUsage],
        dailyCosts: [DeepSeekCostDayUsage],
        currency: String,
        now: Date,
        calendar: Calendar
    ) -> DeepSeekUsageSummary {
        let today = dayString(now, calendar: calendar)
        var monthComponents = calendar.dateComponents([.year, .month], from: now)
        monthComponents.day = 1
        let monthStart = calendar.date(from: monthComponents) ?? now
        let amountMap = buildAmountMap(dailyAmounts)
        let costMap = buildCostMap(dailyCosts)
        let dates = Set(amountMap.keys).union(costMap.keys)

        let todayUsage = aggregateDay(today, amountMap: amountMap, costMap: costMap)
        var monthTokens = 0
        var monthCost: Double?
        var monthRequests = 0
        var daily: [DeepSeekDailyUsage] = []
        for date in dates.sorted() {
            guard let parsed = parseDate(date, calendar: calendar), parsed >= monthStart, parsed <= now else { continue }
            let value = aggregateDay(date, amountMap: amountMap, costMap: costMap)
            monthTokens += value.tokens
            monthRequests += value.requests
            if let cost = value.cost { monthCost = (monthCost ?? 0) + cost }
            daily.append(DeepSeekDailyUsage(
                date: date,
                totalTokens: value.tokens,
                cost: value.cost,
                requestCount: value.requests
            ))
        }

        var modelTokens: [String: Int] = [:]
        var categoryTokens: [DeepSeekUsageCategory: Int] = [:]
        var categoryCosts: [DeepSeekUsageCategory: Double] = [:]
        for model in totalAmounts {
            guard let name = model.model else { continue }
            var total = 0
            for item in model.usage ?? [] {
                guard let category = DeepSeekUsageCategory(apiValue: item.type), category != .request else { continue }
                let amount = token(item.amount)
                total += amount
                categoryTokens[category, default: 0] += amount
            }
            modelTokens[name] = total
        }
        for model in totalCosts where model.model != nil {
            for item in model.usage ?? [] {
                guard let category = DeepSeekUsageCategory(apiValue: item.type), category != .request else { continue }
                categoryCosts[category, default: 0] += decimal(item.amount)
            }
        }
        let topModel = modelTokens.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key
        let breakdown = [
            DeepSeekUsageCategory.promptCacheHitToken,
            .promptCacheMissToken,
            .responseToken,
        ].map {
            DeepSeekCategoryBreakdown(
                category: $0,
                tokens: categoryTokens[$0] ?? 0,
                cost: categoryCosts[$0]
            )
        }
        return DeepSeekUsageSummary(
            todayTokens: todayUsage.tokens,
            currentMonthTokens: monthTokens,
            todayCost: todayUsage.cost,
            currentMonthCost: monthCost,
            requestCount: todayUsage.requests,
            currentMonthRequestCount: monthRequests,
            topModel: topModel,
            categoryBreakdown: breakdown,
            daily: daily,
            currency: currency,
            updatedAt: now
        )
    }

    private static func aggregateDay(
        _ date: String,
        amountMap: [String: [String: [DeepSeekUsageItem]]],
        costMap: [String: [String: [DeepSeekCostItem]]]
    ) -> (tokens: Int, cost: Double?, requests: Int) {
        var tokens = 0
        var cost: Double?
        var requests = 0
        for items in amountMap[date]?.values ?? Dictionary<String, [DeepSeekUsageItem]>().values {
            for item in items {
                guard let category = DeepSeekUsageCategory(apiValue: item.type) else { continue }
                if category == .request { requests += token(item.amount) }
                else { tokens += token(item.amount) }
            }
        }
        for items in costMap[date]?.values ?? Dictionary<String, [DeepSeekCostItem]>().values {
            for item in items {
                guard let category = DeepSeekUsageCategory(apiValue: item.type), category != .request else { continue }
                cost = (cost ?? 0) + decimal(item.amount)
            }
        }
        return (tokens, cost, requests)
    }

    private static func buildAmountMap(
        _ days: [DeepSeekDayUsage]
    ) -> [String: [String: [DeepSeekUsageItem]]] {
        var result: [String: [String: [DeepSeekUsageItem]]] = [:]
        for day in days {
            guard let date = day.date else { continue }
            var models: [String: [DeepSeekUsageItem]] = [:]
            for model in day.data ?? [] {
                guard let name = model.model, let usage = model.usage, !usage.isEmpty else { continue }
                models[name] = usage
            }
            if !models.isEmpty { result[date] = models }
        }
        return result
    }

    private static func buildCostMap(
        _ days: [DeepSeekCostDayUsage]
    ) -> [String: [String: [DeepSeekCostItem]]] {
        var result: [String: [String: [DeepSeekCostItem]]] = [:]
        for day in days {
            guard let date = day.date else { continue }
            var models: [String: [DeepSeekCostItem]] = [:]
            for model in day.data ?? [] {
                guard let name = model.model, let usage = model.usage, !usage.isEmpty else { continue }
                models[name] = usage
            }
            if !models.isEmpty { result[date] = models }
        }
        return result
    }

    private static func validate(code: Int?, label: String) throws {
        guard let code, code != 0 else { return }
        if code == 40002 || code == 40003 { throw DeepSeekUsageError.invalidPlatformSession }
        throw DeepSeekUsageError.apiError("\(label) \(code)")
    }

    private static func token(_ raw: String?) -> Int {
        guard let raw, let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return Int(value)
    }

    private static func decimal(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year, let month = values.month, let day = values.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parseDate(_ raw: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
