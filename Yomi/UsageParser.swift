import Foundation

nonisolated enum UsageParser {
    private static let usedKeys = [
        "used", "usage", "consumed", "spent", "current_usage", "used_amount",
        "credits_used", "tokens_used", "requests_used", "current_value", "current",
    ]
    private static let totalKeys = [
        "limit", "quota", "total", "maximum", "max", "budget", "allocation",
        "credits", "total_credits", "token_limit", "request_limit", "included",
    ]
    private static let remainingKeys = [
        "remaining", "balance", "available", "left", "credits_remaining", "remain",
        "remaining_amount", "remaining_quota",
    ]
    private static let percentKeys = [
        "used_percent", "usage_percent", "percent_used", "utilization", "percentage",
    ]
    private static let resetKeys = [
        "reset_at", "resets_at", "reset_time", "renewal_at", "expires_at", "end_time",
    ]

    static func parse(_ data: Data, descriptor: ProviderDescriptor) throws -> ProviderUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageCollectionError.unreadableResponse
        }
        let parsed = switch descriptor.id.rawValue {
        case "codex": parseCodex(object, descriptor: descriptor)
        case "claude": parseClaude(object, descriptor: descriptor)
        case "gemini": parseGemini(object, descriptor: descriptor)
        default: parseJSON(object, descriptor: descriptor)
        }
        guard let parsed else { throw UsageCollectionError.unreadableResponse }
        return parsed
    }

    private static func parseCodex(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        guard let response = root as? [String: Any] else { return nil }
        let rateLimit = response["rate_limit"] as? [String: Any]
        var windows: [UsageWindow] = []
        appendCodexWindow(
            rateLimit?["primary_window"],
            id: "codex-primary",
            fallbackLabel: descriptor.primaryLabel,
            to: &windows
        )
        appendCodexWindow(
            rateLimit?["secondary_window"],
            id: "codex-secondary",
            fallbackLabel: descriptor.secondaryLabel,
            to: &windows
        )
        if let additional = response["additional_rate_limits"] as? [[String: Any]] {
            for (index, item) in additional.enumerated() {
                guard let additionalRateLimit = item["rate_limit"] as? [String: Any] else { continue }
                let name = (item["limit_name"] as? String)
                    ?? (item["metered_feature"] as? String)
                    ?? "Additional limit"
                appendCodexWindow(
                    additionalRateLimit["primary_window"],
                    id: "codex-additional-\(index)-primary",
                    fallbackLabel: name,
                    to: &windows
                )
                appendCodexWindow(
                    additionalRateLimit["secondary_window"],
                    id: "codex-additional-\(index)-secondary",
                    fallbackLabel: "\(name) · Weekly",
                    to: &windows
                )
            }
        }
        guard !windows.isEmpty else { return nil }
        let plan = (response["plan_type"] as? String)
            .flatMap { displayPlan($0, descriptor: descriptor) }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: Array(windows.prefix(3)),
            balance: nil,
            plan: plan,
            updatedAt: Date(),
            message: nil
        )
    }

    private static func appendCodexWindow(
        _ value: Any?,
        id: String,
        fallbackLabel: String,
        to windows: inout [UsageWindow]
    ) {
        guard let object = value as? [String: Any],
              let usedPercent = numericValue(object["used_percent"])
        else { return }
        let seconds = numericValue(object["limit_window_seconds"]).map(Int.init)
        let label: String
        switch seconds {
        case 18_000: label = "Session"
        case 604_800: label = "Weekly"
        default: label = fallbackLabel
        }
        windows.append(UsageWindow(
            id: id,
            label: label,
            usedFraction: usedPercent / 100,
            resetsAt: date(object["reset_at"]),
            detail: nil
        ))
    }

    private static func parseClaude(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        guard let response = root as? [String: Any] else { return nil }
        let candidates: [(String, String)] = [
            ("five_hour", "Session"),
            ("seven_day", "Weekly"),
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_opus", "Opus"),
            ("seven_day_oauth_apps", "OAuth apps"),
        ]
        var windows = candidates.compactMap { key, label -> UsageWindow? in
            guard let object = response[key] as? [String: Any],
                  let utilization = numericValue(object["utilization"])
            else { return nil }
            return UsageWindow(
                id: "claude-\(key)",
                label: label,
                usedFraction: utilization / 100,
                resetsAt: date(object["resets_at"]),
                detail: nil
            )
        }
        if let limits = response["limits"] as? [[String: Any]] {
            for (index, limit) in limits.enumerated() {
                guard (limit["is_active"] as? Bool) != false,
                      let percent = numericValue(limit["percent"])
                else { continue }
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let label = (model?["display_name"] as? String)
                    ?? (limit["kind"] as? String)
                    ?? "Weekly"
                windows.append(UsageWindow(
                    id: "claude-limit-\(index)",
                    label: label,
                    usedFraction: percent / 100,
                    resetsAt: date(limit["resets_at"]),
                    detail: nil
                ))
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: Array(windows.prefix(3)),
            balance: nil,
            plan: nil,
            updatedAt: Date(),
            message: nil
        )
    }

    private static func parseGemini(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        guard let response = root as? [String: Any],
              let buckets = response["buckets"] as? [[String: Any]]
        else { return nil }
        var lowestByTier: [String: (remaining: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String,
                  let remaining = numericValue(bucket["remainingFraction"])
            else { continue }
            let normalized = model.lowercased()
            let tier: String?
            if normalized.contains("flash-lite") {
                tier = "Flash Lite"
            } else if normalized.contains("flash") {
                tier = "Flash"
            } else if normalized.contains("pro") {
                tier = "Pro"
            } else {
                tier = nil
            }
            guard let tier else { continue }
            let candidate = (remaining: remaining, reset: date(bucket["resetTime"]))
            if let current = lowestByTier[tier], current.remaining <= remaining { continue }
            lowestByTier[tier] = candidate
        }
        let order = ["Pro", "Flash", "Flash Lite"]
        let windows = order.compactMap { tier -> UsageWindow? in
            guard let quota = lowestByTier[tier] else { return nil }
            return UsageWindow(
                id: "gemini-\(tier.lowercased().replacingOccurrences(of: " ", with: "-"))",
                label: tier,
                usedFraction: 1 - quota.remaining,
                resetsAt: quota.reset,
                detail: nil
            )
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            balance: nil,
            plan: nil,
            updatedAt: Date(),
            message: nil
        )
    }

    private static func parseJSON(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        var objects: [[String: Any]] = []
        collectObjects(root, depth: 0, into: &objects)

        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for object in objects {
            guard let fraction = fraction(in: object) else { continue }
            let label = label(in: object) ?? (windows.isEmpty ? descriptor.primaryLabel : descriptor.secondaryLabel)
            let fingerprint = "\(label)-\(Int(fraction * 10_000))"
            guard seen.insert(fingerprint).inserted else { continue }
            windows.append(UsageWindow(
                id: fingerprint,
                label: label,
                usedFraction: fraction,
                resetsAt: resetDate(in: object),
                detail: detail(in: object)
            ))
            if windows.count == 3 { break }
        }

        let balance = firstNumber(named: remainingKeys, in: objects)
            .map { formattedNumber($0, metric: descriptor.metricKind) }
        guard !windows.isEmpty || balance != nil else { return nil }

        if windows.isEmpty {
            windows = [UsageWindow(
                id: descriptor.id.rawValue + "-balance",
                label: descriptor.primaryLabel,
                usedFraction: 0,
                resetsAt: nil,
                detail: balance
            )]
        }

        let rawPlan = firstString(named: [
            "plan", "tier", "subscription", "plan_name", "plan_type",
            "subscription_type", "login_method", "rate_limit_tier",
            "organization_rate_limit_tier",
        ], in: objects)

        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            balance: balance,
            plan: rawPlan.flatMap { displayPlan($0, descriptor: descriptor) },
            updatedAt: Date(),
            message: nil
        )
    }

    private static func collectObjects(_ value: Any, depth: Int, into output: inout [[String: Any]]) {
        guard depth <= 6 else { return }
        if let dictionary = value as? [String: Any] {
            output.append(dictionary)
            for child in dictionary.values {
                collectObjects(child, depth: depth + 1, into: &output)
            }
        } else if let array = value as? [Any] {
            for child in array.prefix(100) {
                collectObjects(child, depth: depth + 1, into: &output)
            }
        }
    }

    private static func fraction(in object: [String: Any]) -> Double? {
        let values = normalized(object)
        if let percent = number(for: percentKeys, in: values) {
            return percent > 1 ? percent / 100 : percent
        }
        if let used = number(for: usedKeys, in: values),
           let total = number(for: totalKeys, in: values), total > 0 {
            return used / total
        }
        if let remaining = number(for: remainingKeys, in: values),
           let total = number(for: totalKeys, in: values), total > 0 {
            return 1 - remaining / total
        }
        return nil
    }

    private static func label(in object: [String: Any]) -> String? {
        let values = normalized(object)
        for key in ["label", "name", "model", "window", "period", "type"] {
            if let value = values[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func detail(in object: [String: Any]) -> String? {
        let values = normalized(object)
        guard let used = number(for: usedKeys, in: values),
              let total = number(for: totalKeys, in: values) else { return nil }
        return "\(formattedNumber(used, metric: .quota)) / \(formattedNumber(total, metric: .quota))"
    }

    private static func resetDate(in object: [String: Any]) -> Date? {
        let values = normalized(object)
        for key in resetKeys {
            if let epoch = numericValue(values[key]) {
                return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
            }
            if let text = values[key] as? String {
                if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
                if let epoch = Double(text) {
                    return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
                }
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let epoch = numericValue(value) {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        guard let value = value as? String else { return nil }
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return parsed
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }

    private static func firstNumber(named keys: [String], in objects: [[String: Any]]) -> Double? {
        for object in objects {
            if let result = number(for: keys, in: normalized(object)) { return result }
        }
        return nil
    }

    private static func firstString(named keys: [String], in objects: [[String: Any]]) -> String? {
        for object in objects {
            let values = normalized(object)
            for key in keys {
                if let value = values[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func normalized(_ object: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: object.map {
            ($0.key.lowercased().replacingOccurrences(of: "-", with: "_"), $0.value)
        })
    }

    private static func number(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = numericValue(object[key]) { return value }
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    private static func formattedNumber(_ value: Double, metric: ProviderMetricKind) -> String {
        let digits = value < 10 ? 2 : 0
        let rendered = value.formatted(.number.precision(.fractionLength(0...digits)))
        return metric == .spend || metric == .balance ? "$\(rendered)" : rendered
    }

    static func displayPlan(_ value: String, descriptor: ProviderDescriptor) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        if descriptor.id.rawValue == "claude" {
            if words.contains("max") {
                let multiplier = words.first { word in
                    word.last == "x" && Int(word.dropLast()) != nil
                }
                return multiplier.map { "Max \($0)" } ?? "Max"
            }
            if words.contains("pro") { return "Pro" }
            if words.contains("team") { return "Team" }
            if words.contains("enterprise") { return "Enterprise" }
            if words.contains("ultra") { return "Ultra" }
        }

        let displayWords = words
            .filter { !["default", "account", "plan"].contains($0) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        guard !displayWords.isEmpty else { return nil }
        return displayWords.joined(separator: " ")
    }
}
