import Foundation

nonisolated struct NeuralWattBalance: Codable, Sendable, Equatable {
    let creditsRemainingUSD: Double?
    let totalCreditsUSD: Double?
    let creditsUsedUSD: Double?
    let accountingMethod: String?

    private enum CodingKeys: String, CodingKey {
        case creditsRemainingUSD = "credits_remaining_usd"
        case totalCreditsUSD = "total_credits_usd"
        case creditsUsedUSD = "credits_used_usd"
        case accountingMethod = "accounting_method"
    }
}

nonisolated struct NeuralWattUsagePeriod: Codable, Sendable, Equatable {
    let costUSD: Double?
    let requests: Int?
    let tokens: Int?
    let energyKWh: Double?

    private enum CodingKeys: String, CodingKey {
        case costUSD = "cost_usd"
        case requests
        case tokens
        case energyKWh = "energy_kwh"
    }
}

nonisolated struct NeuralWattUsageResponse: Codable, Sendable, Equatable {
    let lifetime: NeuralWattUsagePeriod?
    let currentMonth: NeuralWattUsagePeriod?

    private enum CodingKeys: String, CodingKey {
        case lifetime
        case currentMonth = "current_month"
    }
}

nonisolated struct NeuralWattLimits: Codable, Sendable, Equatable {
    let overageLimitUSD: Double?
    let rateLimitTier: String?

    private enum CodingKeys: String, CodingKey {
        case overageLimitUSD = "overage_limit_usd"
        case rateLimitTier = "rate_limit_tier"
    }
}

nonisolated struct NeuralWattSubscription: Codable, Sendable, Equatable {
    let plan: String?
    let status: String?
    let billingInterval: String?
    let currentPeriodStart: Date?
    let currentPeriodEnd: Date?
    let autoRenew: Bool?
    let kwhIncluded: Double?
    let kwhUsed: Double?
    let kwhRemaining: Double?
    let inOverage: Bool?

    private enum CodingKeys: String, CodingKey {
        case plan
        case status
        case billingInterval = "billing_interval"
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case autoRenew = "auto_renew"
        case kwhIncluded = "kwh_included"
        case kwhUsed = "kwh_used"
        case kwhRemaining = "kwh_remaining"
        case inOverage = "in_overage"
    }
}

nonisolated struct NeuralWattKeyAllowance: Codable, Sendable, Equatable {
    let limitUSD: Double?
    let period: String?
    let spentUSD: Double?
    let remainingUSD: Double?
    let blocked: Bool?

    private enum CodingKeys: String, CodingKey {
        case limitUSD = "limit_usd"
        case period
        case spentUSD = "spent_usd"
        case remainingUSD = "remaining_usd"
        case blocked
    }
}

nonisolated struct NeuralWattKey: Codable, Sendable, Equatable {
    let name: String?
    let allowance: NeuralWattKeyAllowance?
}

nonisolated struct NeuralWattQuotaResponse: Decodable, Sendable {
    let snapshotAt: String?
    let balance: NeuralWattBalance?
    let usage: NeuralWattUsageResponse?
    let limits: NeuralWattLimits?
    let subscription: NeuralWattSubscription?
    let key: NeuralWattKey?

    private enum CodingKeys: String, CodingKey {
        case snapshotAt = "snapshot_at"
        case balance, usage, limits, subscription, key
    }
}

nonisolated struct NeuralWattUsageSnapshot: Sendable, Equatable {
    let creditsRemainingUSD: Double?
    let totalCreditsUSD: Double?
    let creditsUsedUSD: Double?
    let accountingMethod: String?
    let currentMonthCostUSD: Double?
    let currentMonthEnergyKWh: Double?
    let subscription: NeuralWattSubscription?
    let keyAllowance: NeuralWattKeyAllowance?
    let rateLimitTier: String?
    let updatedAt: Date

    var creditUsedPercent: Double {
        if Self.validNonNegative(creditsRemainingUSD) == 0, effectiveTotalCredits == nil { return 100 }
        guard let used = effectiveUsedCredits, let total = effectiveTotalCredits, total > 0 else { return 0 }
        return min(100, max(0, used / total * 100))
    }

    var effectiveRemainingCredits: Double? {
        if let remaining = Self.validNonNegative(creditsRemainingUSD) { return remaining }
        guard let total = effectiveTotalCredits, let used = effectiveUsedCredits else { return nil }
        return max(0, total - used)
    }

    var effectiveTotalCredits: Double? {
        if let total = Self.validPositive(totalCreditsUSD) { return total }
        guard let remaining = Self.validNonNegative(creditsRemainingUSD),
              let used = Self.validNonNegative(creditsUsedUSD) else { return nil }
        let total = remaining + used
        return total > 0 ? total : nil
    }

    var effectiveUsedCredits: Double? {
        if let used = Self.validNonNegative(creditsUsedUSD) { return used }
        guard let total = Self.validPositive(totalCreditsUSD),
              let remaining = Self.validNonNegative(creditsRemainingUSD) else { return nil }
        return max(0, total - remaining)
    }

    var keyAllowanceUsedPercent: Double? {
        if keyAllowance?.blocked == true { return 100 }
        guard let spent = keyAllowance?.spentUSD,
              spent.isFinite,
              let limit = keyAllowance?.limitUSD,
              limit.isFinite,
              limit > 0 else { return nil }
        return min(100, max(0, spent / limit * 100))
    }

    func providerUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let total = effectiveSubscriptionTotalKWh,
           let used = effectiveSubscriptionUsedKWh {
            windows.append(UsageWindow(
                id: "subscription",
                label: "Subscription",
                usedFraction: min(1, max(0, used / total)),
                resetsAt: subscription?.currentPeriodEnd,
                detail: "\(Self.formatKWh(used)) / \(Self.formatKWh(total)) kWh"
            ))
        }

        var additionalWindows: [UsageWindow] = []
        if let percent = keyAllowanceUsedPercent, let allowance = keyAllowance {
            let period = (allowance.period ?? "allowance").capitalized
            additionalWindows.append(UsageWindow(
                id: "key-allowance",
                label: "Key \(period)",
                usedFraction: percent / 100,
                resetsAt: nil,
                detail: nil
            ))
        }

        let prepaidBalance = effectiveRemainingCredits.map {
            ProviderCostSummary(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Neuralwatt prepaid balance",
                balance: $0
            )
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "neuralwatt"),
            state: .ready,
            windows: windows,
            additionalWindows: additionalWindows,
            balance: nil,
            plan: displayPlan,
            providerCost: prepaidBalance,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private var effectiveSubscriptionTotalKWh: Double? {
        if let included = Self.validPositive(subscription?.kwhIncluded) { return included }
        guard let used = Self.validNonNegative(subscription?.kwhUsed),
              let remaining = Self.validNonNegative(subscription?.kwhRemaining) else { return nil }
        let total = used + remaining
        return total > 0 ? total : nil
    }

    private var effectiveSubscriptionUsedKWh: Double? {
        if let used = Self.validNonNegative(subscription?.kwhUsed) { return used }
        guard let total = effectiveSubscriptionTotalKWh,
              let remaining = Self.validNonNegative(subscription?.kwhRemaining) else { return nil }
        return max(0, total - remaining)
    }

    private var displayPlan: String? {
        if let plan = subscription?.plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return "\(plan.replacingOccurrences(of: "_", with: " ").capitalized) plan"
        }
        return nil
    }

    fileprivate static func validNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    fileprivate static func validPositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func formatKWh(_ value: Double) -> String {
        let digits = value.rounded() == value ? 0 : 2
        return String(format: "%.*f", digits, value)
    }
}

nonisolated enum NeuralWattSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            AppLocalization.text(
                "Neuralwatt 接口覆盖 \(key) 必须使用 HTTPS 或不带协议的主机名",
                "Neuralwatt endpoint override \(key) must use HTTPS or a bare host"
            )
        }
    }
}

nonisolated enum NeuralWattUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Neuralwatt API Key", "Missing Neuralwatt API key")
        case let .networkError(message):
            AppLocalization.text("Neuralwatt 网络错误：\(message)", "Neuralwatt network error: \(message)")
        case let .apiError(message):
            AppLocalization.text("Neuralwatt API 错误：\(message)", "Neuralwatt API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Neuralwatt 返回的数据：\(message)",
                "Failed to parse Neuralwatt response: \(message)"
            )
        }
    }
}

nonisolated enum NeuralWattUsageFetcher {
    static let apiKeyEnvironmentKey = "NEURALWATT_API_KEY"
    static let apiURLEnvironmentKey = "NEURALWATT_API_URL"
    static let defaultAPIURL = URL(string: "https://api.neuralwatt.com")!
    static let minimumAccountRefreshInterval: TimeInterval = 1
    private static let timeout: TimeInterval = 15
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        cleaned(configured) ?? cleaned(environment[apiKeyEnvironmentKey])
    }

    static func resolvedAPIURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let raw = cleaned(environment[apiURLEnvironmentKey]) else { return defaultAPIURL }
        guard let url = normalizedHTTPSURL(raw) else {
            throw NeuralWattSettingsError.invalidEndpointOverride(apiURLEnvironmentKey)
        }
        return url
    }

    static func quotaURL(baseURL: URL) -> URL {
        var url = baseURL
        if url.path.split(separator: "/").last == "v1" {
            url.append(path: "quota")
        } else {
            url.append(path: "v1/quota")
        }
        return url
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = Self.sleep
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configuredAPIKey, environment: environment) else {
            throw NeuralWattUsageError.missingCredentials
        }
        let baseURL = try resolvedAPIURL(environment: environment)
        var request = URLRequest(url: quotaURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await response(for: request, session: session, sleeper: sleeper)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as NeuralWattUsageError {
            throw error
        } catch {
            throw NeuralWattUsageError.networkError(error.localizedDescription)
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseSnapshot(data, updatedAt: now).providerUsage()
        case 401, 403:
            throw NeuralWattUsageError.missingCredentials
        default:
            throw NeuralWattUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    static func parseSnapshot(_ data: Data, updatedAt: Date) throws -> NeuralWattUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeISO8601Date)
        let decoded: NeuralWattQuotaResponse
        do {
            decoded = try decoder.decode(NeuralWattQuotaResponse.self, from: data)
        } catch {
            throw NeuralWattUsageError.parseFailed(error.localizedDescription)
        }
        guard let balance = decoded.balance else {
            throw NeuralWattUsageError.parseFailed("Missing Neuralwatt balance object")
        }
        guard NeuralWattUsageSnapshot.validNonNegative(balance.creditsRemainingUSD) != nil
            || NeuralWattUsageSnapshot.validNonNegative(balance.creditsUsedUSD) != nil
            || NeuralWattUsageSnapshot.validPositive(balance.totalCreditsUSD) != nil else {
            throw NeuralWattUsageError.parseFailed("Missing Neuralwatt credit balance fields")
        }
        return NeuralWattUsageSnapshot(
            creditsRemainingUSD: balance.creditsRemainingUSD,
            totalCreditsUSD: balance.totalCreditsUSD,
            creditsUsedUSD: balance.creditsUsedUSD,
            accountingMethod: balance.accountingMethod,
            currentMonthCostUSD: decoded.usage?.currentMonth?.costUSD,
            currentMonthEnergyKWh: decoded.usage?.currentMonth?.energyKWh,
            subscription: decoded.subscription,
            keyAllowance: decoded.key?.allowance,
            rateLimitTier: decoded.limits?.rateLimitTier,
            updatedAt: updatedAt
        )
    }

    private static func response(
        for request: URLRequest,
        session: URLSession,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, rawResponse) = try await session.data(for: request)
                guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if attempt < 1, retryableStatusCodes.contains(response.statusCode) {
                    try await sleeper(retryDelay(response: response, attempt: attempt))
                    attempt += 1
                    continue
                }
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if attempt < 1, retryableURLErrorCodes.contains(error.code) {
                    try await sleeper(retryDelay(response: nil, attempt: attempt))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    private static func retryDelay(response: HTTPURLResponse?, attempt: Int) -> TimeInterval {
        if let raw = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds >= 0 {
            return min(seconds, 10)
        }
        return min(pow(2, Double(max(0, attempt))), 10)
    }

    private static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedHTTPSURL(_ raw: String) -> URL? {
        let candidate = hasExplicitScheme(raw) ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url) else { return nil }
        return url
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }),
           colon > authorityEnd { return false }
        let afterColon = raw.index(after: colon)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { ["/", "?", "#"].contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0)
        }
    }

    private static func hostHasNoEncodedDelimiters(
        _ encodedHost: String,
        decodedHost: String,
        url: URL
    ) -> Bool {
        if decodedHost.contains(":") {
            guard encodedHost == decodedHost,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["),
                  componentHost.hasSuffix("]") else { return false }
            let address = componentHost.dropFirst().dropLast()
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let decodedDelimiters = CharacterSet(charactersIn: "/\\?#@:")
        guard decodedHost.rangeOfCharacter(from: decodedDelimiters) == nil else { return false }
        let encodedDelimiters = ["%2f", "%5c", "%3f", "%23", "%40", "%3a"]
        return !encodedDelimiters.contains { encodedHost.contains($0) }
    }
}
