import Foundation

nonisolated enum SyntheticUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case requestFailed(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Synthetic API Key", "Missing Synthetic API key")
        case .invalidCredentials:
            AppLocalization.text("Synthetic API 凭据无效", "Invalid Synthetic API credentials")
        case let .requestFailed(status):
            AppLocalization.text("Synthetic API 请求失败（HTTP \(status)）", "Synthetic API error: HTTP \(status)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Synthetic 返回的数据：\(message)", "Failed to parse Synthetic response: \(message)")
        }
    }
}

nonisolated enum SyntheticUsageFetcher {
    struct Quota: Sendable, Equatable {
        let label: String?
        let usedFraction: Double
        let windowMinutes: Int?
        let resetsAt: Date?
        let nextRegenFraction: Double?
        let cost: Cost?
    }

    struct Cost: Sendable, Equatable {
        let used: Double
        let limit: Double
        let remaining: Double?
        let resetsAt: Date?
        let nextRegenAmount: Double?
    }

    struct Snapshot: Sendable, Equatable {
        let slots: [Quota?]
        let usesKnownSlots: Bool
        let plan: String?
        let updatedAt: Date

        func toProviderUsage() -> ProviderUsage {
            let knownLabels = ["Five-hour quota", "Weekly tokens", "Search hourly"]
            let windows = slots.prefix(3).enumerated().compactMap { index, quota -> UsageWindow? in
                guard let quota else { return nil }
                let label = usesKnownSlots
                    ? knownLabels[index]
                    : knownLabels[min(index, knownLabels.count - 1)]
                var details: [String] = []
                if quota.resetsAt == nil, let minutes = quota.windowMinutes, minutes > 0 {
                    details.append(SyntheticUsageFetcher.windowDescription(minutes))
                }
                if let fraction = quota.nextRegenFraction {
                    let percent = Int((fraction * 100).rounded())
                    details.append(AppLocalization.text("下次恢复 \(percent)%", "\(percent)% after next regen"))
                }
                if let amount = quota.cost?.nextRegenAmount {
                    details.append(AppLocalization.text(
                        "下次恢复 $\(SyntheticUsageFetcher.number(amount))",
                        "$\(SyntheticUsageFetcher.number(amount)) after next regen"
                    ))
                }
                return UsageWindow(
                    id: "synthetic-\(index)",
                    label: label,
                    usedFraction: quota.usedFraction,
                    resetsAt: quota.resetsAt,
                    detail: details.isEmpty ? nil : details.joined(separator: " · ")
                )
            }
            let cost = slots.compactMap { $0?.cost }.first
            return ProviderUsage(
                id: ProviderID(rawValue: "synthetic"),
                state: .ready,
                windows: windows,
                balance: cost?.remaining.map { "$\(SyntheticUsageFetcher.number($0))" },
                plan: plan,
                providerCost: cost.map {
                    ProviderCostSummary(
                        used: $0.used,
                        limit: $0.limit,
                        currencyCode: "USD",
                        period: "Weekly",
                        balance: $0.remaining
                    )
                },
                updatedAt: updatedAt,
                message: nil
            )
        }
    }

    private static let endpoint = URL(string: "https://api.synthetic.new/v2/quotas")!
    private static let labelKeys = ["name", "label", "type", "period", "scope", "title", "id"]
    private static let percentUsedKeys = [
        "percentUsed", "usedPercent", "usagePercent", "usage_percent", "used_percent", "percent_used", "percent",
    ]
    private static let percentRemainingKeys = [
        "percentRemaining", "remainingPercent", "remaining_percent", "percent_remaining",
    ]
    private static let limitKeys = [
        "limit", "messageLimit", "message_limit", "messages", "maxRequests", "max_requests",
        "requestLimit", "request_limit", "quota", "max", "total", "capacity", "allowance",
    ]
    private static let usedKeys = [
        "used", "usage", "usedMessages", "used_messages", "messagesUsed", "messages_used",
        "requests", "requestCount", "request_count", "consumed", "spent",
    ]
    private static let remainingKeys = ["remaining", "left", "available", "balance"]
    private static let resetKeys = [
        "resetAt", "reset_at", "resetsAt", "resets_at", "renewAt", "renew_at", "renewsAt", "renews_at",
        "nextTickAt", "next_tick_at", "nextRegenAt", "next_regen_at", "periodEnd", "period_end",
        "expiresAt", "expires_at", "endAt", "end_at",
    ]
    private static let planKeys = [
        "plan", "planName", "plan_name", "subscription", "subscriptionPlan", "tier", "package", "packageName",
    ]

    static func fetch(
        apiKey rawAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = clean(rawAPIKey) ?? cleanQuoted(environment["SYNTHETIC_API_KEY"]) else {
            throw SyntheticUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyntheticUsageError.parseFailed("Response was not HTTP.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SyntheticUsageError.invalidCredentials
        }
        guard http.statusCode == 200 else { throw SyntheticUsageError.requestFailed(http.statusCode) }
        return try parse(data, now: now).toProviderUsage()
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Snapshot {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw SyntheticUsageError.parseFailed("Expected an object or array.") }
        let root: [String: Any]
        if let array = object as? [Any] {
            root = ["quotas": array]
        } else if let dictionary = object as? [String: Any] {
            root = dictionary
        } else {
            throw SyntheticUsageError.parseFailed("Expected an object or array.")
        }
        let dataObject = root["data"] as? [String: Any]
        let known: [[String: Any]?] = [
            root["rollingFiveHourLimit"] as? [String: Any]
                ?? dataObject?["rollingFiveHourLimit"] as? [String: Any],
            root["weeklyTokenLimit"] as? [String: Any]
                ?? dataObject?["weeklyTokenLimit"] as? [String: Any],
            (root["search"] as? [String: Any])?["hourly"] as? [String: Any]
                ?? (dataObject?["search"] as? [String: Any])?["hourly"] as? [String: Any],
        ]
        let usesKnownSlots = known.contains { candidate in candidate.map(isQuota) == true }
        let slots: [Quota?]
        if usesKnownSlots {
            slots = known.enumerated().map { index, candidate in
                guard let candidate, isQuota(candidate) else { return nil }
                let label = ["Rolling five-hour limit", "Weekly token limit", "Search hourly"][index]
                return parseQuota(candidate, fallbackLabel: label)
            }
        } else {
            let candidates: [Any?] = [
                root["quotas"], root["quota"], root["limits"], root["usage"], root["entries"], root["subscription"],
                root["data"], dataObject?["quotas"], dataObject?["quota"], dataObject?["limits"],
                dataObject?["usage"], dataObject?["entries"], dataObject?["subscription"],
            ]
            var values: [[String: Any]] = []
            for candidate in candidates {
                values = collect(candidate)
                if !values.isEmpty { break }
            }
            slots = values.compactMap { parseQuota($0, fallbackLabel: nil) }.map(Optional.some)
        }
        guard slots.contains(where: { $0 != nil }) else {
            throw SyntheticUsageError.parseFailed("Missing quota data.")
        }
        return Snapshot(
            slots: slots,
            usesKnownSlots: usesKnownSlots,
            plan: firstString(root, keys: planKeys) ?? dataObject.flatMap { firstString($0, keys: planKeys) },
            updatedAt: now
        )
    }

    private static func parseQuota(_ object: [String: Any], fallbackLabel: String?) -> Quota? {
        var usedPercent = firstNumber(object, keys: percentUsedKeys).map(normalizedPercent)
        if usedPercent == nil, let remaining = firstNumber(object, keys: percentRemainingKeys) {
            usedPercent = 100 - normalizedPercent(remaining)
        }
        if usedPercent == nil {
            var limit = firstNumber(object, keys: limitKeys)
            var used = firstNumber(object, keys: usedKeys)
            var remaining = firstNumber(object, keys: remainingKeys)
            if limit == nil, let used, let remaining { limit = used + remaining }
            if used == nil, let limit, let remaining { used = limit - remaining }
            if remaining == nil, let limit, let used { remaining = max(0, limit - used) }
            if let limit, let used, limit > 0 { usedPercent = used / limit * 100 }
        }
        guard let usedPercent else { return nil }
        let fraction = min(1, max(0, usedPercent / 100))
        let minutes = windowMinutes(object)
        let reset = firstDate(object, keys: resetKeys)
        let regenFraction = firstNumber(
            object,
            keys: ["tickPercent", "tick_percent", "nextTickPercent", "next_tick_percent"]
        ).map { normalizedPercent($0) / 100 }
        let maximumCredits = firstCurrency(object, keys: ["maxCredits", "max_credits"])
        let cost: Cost?
        if let maximumCredits {
            let remaining = firstCurrency(object, keys: ["remainingCredits", "remaining_credits"])
            let explicitUsed = firstCurrency(object, keys: ["usedCredits", "used_credits"])
            let used = explicitUsed ?? remaining.map { max(0, maximumCredits - $0) } ?? fraction * maximumCredits
            cost = Cost(
                used: used,
                limit: maximumCredits,
                remaining: remaining,
                resetsAt: reset,
                nextRegenAmount: firstCurrency(object, keys: ["nextRegenCredits", "next_regen_credits"])
            )
        } else {
            cost = nil
        }
        return Quota(
            label: firstString(object, keys: labelKeys) ?? fallbackLabel,
            usedFraction: fraction,
            windowMinutes: minutes,
            resetsAt: reset,
            nextRegenFraction: regenFraction,
            cost: cost
        )
    }

    private static func collect(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] { return array.flatMap(collect) }
        guard let dictionary = value as? [String: Any] else { return [] }
        if isQuota(dictionary) { return [dictionary] }
        return dictionary.keys.sorted().flatMap { collect(dictionary[$0]) }
    }

    private static func isQuota(_ value: [String: Any]) -> Bool {
        [limitKeys, usedKeys, remainingKeys, percentUsedKeys, percentRemainingKeys]
            .contains { firstNumber(value, keys: $0) != nil }
    }

    private static func windowMinutes(_ value: [String: Any]) -> Int? {
        if let minutes = firstNumber(value, keys: ["windowMinutes", "window_minutes", "periodMinutes", "period_minutes"]) {
            return Int(minutes.rounded())
        }
        if let hours = firstNumber(value, keys: ["windowHours", "window_hours", "periodHours", "period_hours"]) {
            return Int((hours * 60).rounded())
        }
        if let days = firstNumber(value, keys: ["windowDays", "window_days", "periodDays", "period_days"]) {
            return Int((days * 1_440).rounded())
        }
        if let seconds = firstNumber(value, keys: ["windowSeconds", "window_seconds", "periodSeconds", "period_seconds"]) {
            return Int((seconds / 60).rounded())
        }
        guard let text = firstString(
            value,
            keys: ["window", "windowLabel", "window_label", "period", "periodLabel", "period_label"]
        )?.lowercased().replacingOccurrences(of: " ", with: ""),
              let expression = try? NSRegularExpression(pattern: #"^([0-9]*\.?[0-9]+)(minutes?|mins?|m|hours?|hrs?|hr|h|days?|d)$"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Double(text[numberRange])
        else { return nil }
        let unit = String(text[unitRange])
        let multiplier: Double = unit.hasPrefix("d") ? 1_440 : (unit.hasPrefix("h") ? 60 : 1)
        return Int((amount * multiplier).rounded())
    }

    private static func firstString(_ value: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = clean(value[key] as? String) { return text }
        }
        return nil
    }

    private static func firstNumber(_ value: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = number(value[key]) { return number }
        }
        return nil
    }

    private static func firstCurrency(_ value: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let raw = value[key] as? String {
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "$", with: "")
                    .replacingOccurrences(of: ",", with: "")
                if let result = Double(cleaned) { return result }
            } else if let result = number(value[key]) {
                return result
            }
        }
        return nil
    }

    private static func firstDate(_ value: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let raw = value[key] else { continue }
            if let timestamp = number(raw) {
                if timestamp > 1_000_000_000_000 { return Date(timeIntervalSince1970: timestamp / 1_000) }
                if timestamp > 1_000_000_000 { return Date(timeIntervalSince1970: timestamp) }
            }
            if let text = raw as? String {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return number.isFinite ? number : nil
        }
        return nil
    }

    private static func normalizedPercent(_ value: Double) -> Double { value <= 1 ? value * 100 : value }

    private static func windowDescription(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return "\(days) day\(days == 1 ? "" : "s") window"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s") window"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") window"
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func cleanQuoted(_ value: String?) -> String? {
        guard var value = clean(value) else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return clean(value)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
