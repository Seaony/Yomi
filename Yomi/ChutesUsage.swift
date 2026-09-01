import Foundation

nonisolated enum ChutesUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidEndpoint
    case unauthorized
    case apiError(Int)
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Chutes API Key", "Missing Chutes API key")
        case .invalidEndpoint:
            AppLocalization.text("Chutes API URL 必须是 HTTPS 或裸主机名", "Chutes API URL must use HTTPS or a bare host")
        case .unauthorized:
            AppLocalization.text("Chutes API Key 无效", "The Chutes API key is invalid")
        case let .apiError(status):
            AppLocalization.text("Chutes 接口请求失败（HTTP \(status)）", "Chutes API request failed (HTTP \(status))")
        case let .parseFailure(message):
            AppLocalization.text("无法解析 Chutes 用量：\(message)", "Failed to parse Chutes usage: \(message)")
        }
    }
}

nonisolated struct ChutesQuotaWindow: Sendable, Equatable {
    let label: String?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
    let unit: String?

    var usagePercent: Double? {
        if let usedPercent { return max(0, min(usedPercent, 100)) }
        var used = used
        var limit = limit
        let remaining = remaining
        if limit == nil, let used, let remaining { limit = used + remaining }
        if used == nil, let limit, let remaining { used = limit - remaining }
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, min(used / limit * 100, 100))
    }

    func providerWindow(id: String, defaultLabel: String, defaultWindowMinutes: Int?) -> UsageWindow? {
        guard let percent = usagePercent else { return nil }
        return UsageWindow(
            id: id,
            label: label ?? defaultLabel,
            usedFraction: percent / 100,
            resetsAt: resetsAt,
            detail: usageDescription
        )
    }

    private var usageDescription: String? {
        guard let limit, limit > 0 else { return nil }
        let displayedUsed: Double
        if let used {
            displayedUsed = used
        } else if let remaining {
            displayedUsed = max(0, limit - remaining)
        } else {
            return nil
        }
        let suffix = cleaned(unit).map { " \($0)" } ?? ""
        return "\(Self.amount(displayedUsed))/\(Self.amount(limit))\(suffix)"
    }

    private static func amount(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0001 { return String(Int(rounded)) }
        var text = String(format: "%.2f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

nonisolated struct ChutesUsageSnapshot: Sendable, Equatable {
    enum SubscriptionState: Sendable, Equatable {
        case active
        case inactive
        case unknown
    }

    static let rollingMinutes = 4 * 60
    static let monthlyMinutes = 30 * 24 * 60

    let rolling: ChutesQuotaWindow?
    let monthly: ChutesQuotaWindow?
    let fallback: [ChutesQuotaWindow]
    let subscriptionState: SubscriptionState
    let planName: String?
    let subscriptionRenewsAt: Date?
    let updatedAt: Date

    var hasUsage: Bool {
        rolling?.usagePercent != nil || monthly?.usagePercent != nil || fallback.contains { $0.usagePercent != nil }
    }

    func mergingQuotaFallback(_ quota: ChutesUsageSnapshot) -> ChutesUsageSnapshot {
        ChutesUsageSnapshot(
            rolling: rolling ?? quota.rolling,
            monthly: monthly ?? quota.monthly,
            fallback: quota.fallback + fallback,
            subscriptionState: subscriptionState,
            planName: planName,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: updatedAt
        )
    }

    func toProviderUsage() -> ProviderUsage {
        let rollingWindow = rolling?.providerWindow(
            id: "chutes-rolling",
            defaultLabel: "4-hour quota",
            defaultWindowMinutes: Self.rollingMinutes
        )
        let monthlyWindow = monthly?.providerWindow(
            id: "chutes-monthly",
            defaultLabel: "Monthly quota",
            defaultWindowMinutes: Self.monthlyMinutes
        )
        let fallbackWindows = fallback.enumerated().compactMap { index, quota in
            quota.providerWindow(
                id: "chutes-quota-\(index)",
                defaultLabel: "Quota",
                defaultWindowMinutes: quota.windowMinutes
            )
        }

        var windows: [UsageWindow] = []
        if let rollingWindow {
            windows.append(rollingWindow)
            if let monthlyWindow {
                windows.append(monthlyWindow)
            } else if let first = fallbackWindows.first {
                windows.append(first)
            }
        } else if let monthlyWindow {
            windows.append(monthlyWindow)
        } else {
            windows.append(contentsOf: fallbackWindows.prefix(2))
        }

        let plan = cleaned(planName)
        return ProviderUsage(
            id: ProviderID(rawValue: "chutes"),
            state: .ready,
            windows: windows,
            plan: plan,
            details: [],
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum ChutesUsageFetcher {
    static let defaultAPIURL = URL(string: "https://api.chutes.ai")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        endpointOverride configuredEndpoint: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["CHUTES_API_KEY"]) else {
            throw ChutesUsageError.missingCredentials
        }
        let baseURL = try resolvedAPIURL(configured: configuredEndpoint, environment: environment)
        let subscription = try await fetchSnapshot(
            path: ["users", "me", "subscription_usage"],
            apiKey: apiKey,
            baseURL: baseURL,
            session: session,
            now: now
        )
        guard subscription.rolling == nil || subscription.monthly == nil else {
            return subscription.toProviderUsage()
        }
        do {
            let quotas = try await fetchQuotaSnapshot(
                apiKey: apiKey,
                baseURL: baseURL,
                session: session,
                now: now
            )
            return subscription.mergingQuotaFallback(quotas.hasUsage ? quotas : ChutesUsageSnapshot(
                rolling: nil,
                monthly: nil,
                fallback: [],
                subscriptionState: .unknown,
                planName: nil,
                subscriptionRenewsAt: nil,
                updatedAt: now
            )).toProviderUsage()
        } catch ChutesUsageError.unauthorized {
            throw ChutesUsageError.unauthorized
        } catch {
            return subscription.toProviderUsage()
        }
    }

    static func resolvedAPIURL(configured: String?, environment: [String: String]) throws -> URL {
        guard let raw = cleaned(configured) ?? cleaned(environment["CHUTES_API_URL"]) else {
            return defaultAPIURL
        }
        var candidate = raw
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw ChutesUsageError.invalidEndpoint
        }
        components.scheme = "https"
        guard let url = components.url else { throw ChutesUsageError.invalidEndpoint }
        return url
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ChutesUsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChutesUsageError.parseFailure(error.localizedDescription)
        }
        return ChutesUsageParser.parse(object, now: now)
    }

    private static func fetchSnapshot(
        path: [String],
        apiKey: String,
        baseURL: URL,
        session: URLSession,
        now: Date
    ) async throws -> ChutesUsageSnapshot {
        try parse(try await fetchData(path: path, apiKey: apiKey, baseURL: baseURL, session: session), now: now)
    }

    private static func fetchQuotaSnapshot(
        apiKey: String,
        baseURL: URL,
        session: URLSession,
        now: Date
    ) async throws -> ChutesUsageSnapshot {
        let data = try await fetchData(path: ["users", "me", "quotas"], apiKey: apiKey, baseURL: baseURL, session: session)
        let fallback = try parse(data, now: now)
        let definitions = try quotaDefinitions(data)
        guard !definitions.isEmpty else { return fallback }
        var enriched: [[String: Any]] = []
        for definition in definitions {
            guard let identifier = quotaIdentifier(definition) else {
                enriched.append(definition)
                continue
            }
            do {
                let usageData = try await fetchData(
                    path: ["users", "me", "quota_usage", identifier],
                    apiKey: apiKey,
                    baseURL: baseURL,
                    session: session
                )
                let object = try JSONSerialization.jsonObject(with: usageData) as? [String: Any]
                let usage = (object?["data"] as? [String: Any]) ?? (object?["result"] as? [String: Any]) ?? object
                enriched.append(definition.merging(usage ?? [:]) { _, usageValue in usageValue })
            } catch ChutesUsageError.unauthorized {
                throw ChutesUsageError.unauthorized
            } catch {
                enriched.append(definition)
            }
        }
        let enrichedData = try JSONSerialization.data(withJSONObject: ["quotas": enriched])
        let snapshot = try parse(enrichedData, now: now)
        return snapshot.hasUsage ? snapshot : fallback
    }

    private static func fetchData(path: [String], apiKey: String, baseURL: URL, session: URLSession) async throws -> Data {
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard url.scheme?.lowercased() == "https" else { throw ChutesUsageError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChutesUsageError.parseFailure("invalid response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw ChutesUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ChutesUsageError.apiError(http.statusCode) }
        return data
    }

    private static func quotaDefinitions(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let values = object as? [Any] { return values.compactMap { $0 as? [String: Any] } }
        guard let root = object as? [String: Any] else { return [] }
        if let values = root["quotas"] as? [Any] { return values.compactMap { $0 as? [String: Any] } }
        if let values = root["data"] as? [Any] { return values.compactMap { $0 as? [String: Any] } }
        if let data = root["data"] as? [String: Any], let values = data["quotas"] as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func quotaIdentifier(_ definition: [String: Any]) -> String? {
        for key in ["chute_id", "chuteId", "id"] {
            if let value = cleaned(definition[key] as? String) { return value }
            if let value = definition[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }
}

private nonisolated enum ChutesUsageParser {
    enum WindowKind { case rolling, monthly }

    static func parse(_ object: Any, now: Date) -> ChutesUsageSnapshot {
        let root: [String: Any]
        if let object = object as? [String: Any] { root = object }
        else if let object = object as? [Any] { root = ["quotas": object] }
        else { root = [:] }
        let dataRoot = dictionary(value(root, keys: ["data", "result"])) ?? root
        let subscription = firstDictionary(root, dataRoot, keys: [
            "subscription", "subscription_usage", "subscriptionUsage", "current_subscription",
            "currentSubscription", "plan",
        ])
        let explicitRolling = firstDictionary(root, dataRoot, keys: rollingPayloadKeys).flatMap {
            quota($0, defaultLabel: "4-hour quota", defaultWindowMinutes: ChutesUsageSnapshot.rollingMinutes)
        }
        let explicitMonthly = firstDictionary(root, dataRoot, keys: monthlyPayloadKeys).flatMap {
            quota($0, defaultLabel: "Monthly quota", defaultWindowMinutes: ChutesUsageSnapshot.monthlyMinutes)
        }
        let quotas = fallbackQuotaObjects(root, dataRoot).compactMap { quota($0, defaultLabel: nil, defaultWindowMinutes: nil) }
        let rolling = explicitRolling ?? quotas.first { kind($0) == .rolling }
        let monthly = explicitMonthly ?? quotas.first { kind($0) == .monthly }
        let fallback = quotas.filter { Optional.some($0) != rolling && Optional.some($0) != monthly }
        return ChutesUsageSnapshot(
            rolling: rolling,
            monthly: monthly,
            fallback: fallback,
            subscriptionState: subscriptionState(root, dataRoot, subscription),
            planName: firstString(root, planKeys) ?? firstString(dataRoot, planKeys) ?? subscription.flatMap { firstString($0, planKeys) },
            subscriptionRenewsAt: firstDate(root, resetKeys) ?? firstDate(dataRoot, resetKeys) ?? subscription.flatMap { firstDate($0, resetKeys) },
            updatedAt: now
        )
    }

    private static func quota(_ payload: [String: Any], defaultLabel: String?, defaultWindowMinutes: Int?) -> ChutesQuotaWindow? {
        var usedPercent = normalizedPercent(firstDouble(payload, percentUsedKeys))
        if usedPercent == nil, let remaining = normalizedPercent(firstDouble(payload, percentRemainingKeys)) {
            usedPercent = 100 - remaining
        }
        let result = ChutesQuotaWindow(
            label: firstString(payload, labelKeys) ?? defaultLabel,
            used: firstDouble(payload, usedKeys),
            limit: firstDouble(payload, limitKeys),
            remaining: firstDouble(payload, remainingKeys),
            usedPercent: usedPercent,
            windowMinutes: windowMinutes(payload) ?? defaultWindowMinutes,
            resetsAt: firstDate(payload, resetKeys),
            unit: firstString(payload, unitKeys) ?? "credits"
        )
        return result.usagePercent == nil ? nil : result
    }

    private static func subscriptionState(
        _ root: [String: Any],
        _ dataRoot: [String: Any],
        _ subscription: [String: Any]?
    ) -> ChutesUsageSnapshot.SubscriptionState {
        if let active = firstBool(root, activeKeys) ?? firstBool(dataRoot, activeKeys) ?? subscription.flatMap({ firstBool($0, activeKeys) }) {
            return active ? .active : .inactive
        }
        let status = firstString(root, statusKeys) ?? firstString(dataRoot, statusKeys) ?? subscription.flatMap { firstString($0, statusKeys) }
        guard let status = status?.lowercased() else { return .unknown }
        if status.contains("active"), !status.contains("inactive") { return .active }
        if ["free", "inactive", "cancel", "none", "expired"].contains(where: status.contains) { return .inactive }
        return .unknown
    }

    private static func fallbackQuotaObjects(_ root: [String: Any], _ dataRoot: [String: Any]) -> [[String: Any]] {
        let candidates = [value(root, keys: quotaContainerKeys), value(dataRoot, keys: quotaContainerKeys), dataRoot, root]
        var found = candidates.flatMap(extractQuotaObjects)
        var seen = Set<Data>()
        found = found.filter { object in
            guard let key = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return true }
            return seen.insert(key).inserted
        }
        return found
    }

    private static func extractQuotaObjects(_ candidate: Any?) -> [[String: Any]] {
        if let values = candidate as? [Any] { return values.flatMap(extractQuotaObjects) }
        guard let object = dictionary(candidate) else { return [] }
        var results = isQuotaPayload(object) ? [object] : []
        for child in object.values { results.append(contentsOf: extractQuotaObjects(child)) }
        return results
    }

    private static func isQuotaPayload(_ object: [String: Any]) -> Bool {
        firstDouble(object, limitKeys) != nil || firstDouble(object, usedKeys) != nil
            || firstDouble(object, remainingKeys) != nil || firstDouble(object, percentUsedKeys) != nil
            || firstDouble(object, percentRemainingKeys) != nil
    }

    private static func kind(_ window: ChutesQuotaWindow) -> WindowKind? {
        let label = [window.label, window.unit].compactMap { $0?.lowercased() }.joined(separator: " ")
        if ["rolling", "4h", "4 h", "4-hour", "four hour", "four-hour"].contains(where: label.contains)
            || window.windowMinutes == ChutesUsageSnapshot.rollingMinutes { return .rolling }
        if ["month", "billing", "subscription"].contains(where: label.contains)
            || (window.windowMinutes ?? 0) >= 28 * 24 * 60 { return .monthly }
        return nil
    }

    private static func windowMinutes(_ object: [String: Any]) -> Int? {
        if let value = firstDouble(object, windowMinuteKeys) { return Int(value.rounded()) }
        if let value = firstDouble(object, windowHourKeys) { return Int((value * 60).rounded()) }
        if let value = firstDouble(object, windowDayKeys) { return Int((value * 1440).rounded()) }
        if let value = firstDouble(object, windowSecondKeys) { return Int((value / 60).rounded()) }
        guard let raw = firstString(object, windowStringKeys) else { return nil }
        let compact = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let scanner = Scanner(string: compact)
        guard let value = scanner.scanDouble(), value > 0 else { return nil }
        let suffix = String(compact[scanner.currentIndex...])
        if suffix.hasPrefix("min") || suffix == "m" { return Int(value.rounded()) }
        if suffix.hasPrefix("hour") || suffix.hasPrefix("hr") || suffix == "h" { return Int((value * 60).rounded()) }
        if suffix.hasPrefix("day") || suffix == "d" { return Int((value * 1440).rounded()) }
        if suffix.hasPrefix("month") || suffix == "mo" { return Int((value * 43200).rounded()) }
        return nil
    }

    private static func firstDictionary(_ root: [String: Any], _ data: [String: Any], keys: [String]) -> [String: Any]? {
        dictionary(value(root, keys: keys)) ?? dictionary(value(data, keys: keys))
    }
    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        let raw = value(object, keys: keys)
        if let raw = raw as? String { return cleaned(raw) }
        if let raw = raw as? NSNumber { return raw.stringValue }
        return nil
    }
    private static func firstBool(_ object: [String: Any], _ keys: [String]) -> Bool? {
        let raw = value(object, keys: keys)
        if let raw = raw as? Bool { return raw }
        if let raw = raw as? NSNumber { return raw.boolValue }
        guard let raw = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if ["true", "1", "yes", "active"].contains(raw) { return true }
        if ["false", "0", "no", "inactive", "none"].contains(raw) { return false }
        return nil
    }
    private static func firstDouble(_ object: [String: Any], _ keys: [String]) -> Double? { double(value(object, keys: keys)) }
    private static func firstDate(_ object: [String: Any], _ keys: [String]) -> Date? { date(value(object, keys: keys)) }
    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, min(abs(value) < 1 ? value * 100 : value, 100))
    }
    private static func value(_ object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            let normalized = normalize(key)
            if let found = object.first(where: { normalize($0.key) == normalized }) { return found.value }
        }
        return nil
    }
    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func double(_ raw: Any?) -> Double? {
        if let raw = raw as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { return raw.doubleValue.isFinite ? raw.doubleValue : nil }
        if let raw = raw as? String {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "%", with: "")
            if let value = Double(text), value.isFinite { return value }
        }
        return nil
    }
    private static func date(_ raw: Any?) -> Date? {
        if let value = double(raw), value > 0 {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        guard let text = cleaned(raw as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: text) { return value }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
    private static func normalize(_ key: String) -> String { key.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static let rollingPayloadKeys = ["rolling", "rolling_window", "rollingWindow", "rolling_4h", "rolling4h", "four_hour", "fourHour", "four_hour_usage", "fourHourUsage", "window_4h", "window4h"]
    private static let monthlyPayloadKeys = ["monthly", "monthly_usage", "monthlyUsage", "subscription", "subscription_usage", "subscriptionUsage", "billing_period", "billingPeriod"]
    private static let quotaContainerKeys = ["quotas", "quota", "quota_usage", "quotaUsage", "limits", "usage", "entries", "subscription_usage", "subscriptionUsage"]
    private static let labelKeys = ["label", "name", "title", "type", "quota_type", "quotaType", "period", "window", "window_name", "windowName", "chute_id", "chuteId"]
    private static let limitKeys = ["limit", "cap", "max", "maximum", "quota", "quota_limit", "quotaLimit", "monthly_cap", "monthlyCap", "monthly_limit", "monthlyLimit", "request_limit", "requestLimit", "token_limit", "tokenLimit", "hard_limit", "hardLimit", "total"]
    private static let usedKeys = ["used", "usage", "used_amount", "usedAmount", "consumed", "consumed_amount", "consumedAmount", "current", "current_usage", "currentUsage", "requests", "request_count", "requestCount", "tokens", "token_usage", "tokenUsage", "monthly_usage", "monthlyUsage"]
    private static let remainingKeys = ["remaining", "available", "balance", "left", "remaining_amount", "remainingAmount", "available_amount", "availableAmount"]
    private static let percentUsedKeys = ["percent_used", "percentUsed", "usage_percent", "usagePercent", "used_percent", "usedPercent", "utilization", "utilization_percent", "utilizationPercent"]
    private static let percentRemainingKeys = ["percent_remaining", "percentRemaining", "remaining_percent", "remainingPercent"]
    private static let resetKeys = ["reset_at", "resetAt", "resets_at", "resetsAt", "reset_time", "resetTime", "next_reset_at", "nextResetAt", "renews_at", "renewsAt", "renewal_at", "renewalAt", "period_end", "periodEnd", "current_period_end", "currentPeriodEnd", "expires_at", "expiresAt", "window_end", "windowEnd", "end_time", "endTime"]
    private static let unitKeys = ["unit", "units", "currency", "quota_unit", "quotaUnit"]
    private static let activeKeys = ["active", "is_active", "isActive", "subscription_active", "subscriptionActive", "has_subscription", "hasSubscription"]
    private static let statusKeys = ["status", "state", "subscription_status", "subscriptionStatus"]
    private static let planKeys = ["plan_name", "planName", "plan", "tier", "subscription_plan", "subscriptionPlan", "subscription_tier", "subscriptionTier"]
    private static let windowMinuteKeys = ["window_minutes", "windowMinutes", "period_minutes", "periodMinutes", "duration_minutes", "durationMinutes"]
    private static let windowHourKeys = ["window_hours", "windowHours", "period_hours", "periodHours", "duration_hours", "durationHours"]
    private static let windowDayKeys = ["window_days", "windowDays", "period_days", "periodDays", "duration_days", "durationDays"]
    private static let windowSecondKeys = ["window_seconds", "windowSeconds", "period_seconds", "periodSeconds", "duration_seconds", "durationSeconds"]
    private static let windowStringKeys = ["window", "period", "interval", "duration"]
}

private nonisolated func cleaned(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.count >= 2,
       value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.isEmpty ? nil : value
}
