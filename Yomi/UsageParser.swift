import Foundation

nonisolated enum UsageParser {
    private static let usedKeys = [
        "used", "usage", "consumed", "spent", "current_usage", "used_amount",
        "used_quota", "credits_used", "used_credits", "used_credit", "consumed_credits",
        "tokens_used", "requests_used", "used_value", "consumed_value", "current_value", "current",
    ]
    private static let totalKeys = [
        "limit", "quota", "total", "maximum", "max", "budget", "allocation",
        "entitlement", "total_quota", "quota_limit", "credits", "total_credits", "credits_total",
        "token_limit", "request_limit", "included", "total_value",
    ]
    private static let remainingKeys = [
        "remaining", "balance", "available", "left", "credits_remaining", "remain",
        "remaining_amount", "remaining_quota", "remaining_credits", "credits_left", "left_quota",
    ]
    private static let percentKeys = [
        "used_percent", "usage_percent", "percent_used", "utilization", "percentage",
    ]
    private static let remainingPercentKeys = [
        "percent_remaining", "remaining_percent",
    ]
    private static let resetKeys = [
        "reset_at", "resets_at", "reset_time", "reset_date", "quota_reset_date",
        "renewal_at", "next_billing_date", "expires_at", "end_time", "period_end",
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
        let plan = ((response["plan_type"] as? String) ?? (response["planType"] as? String))
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
        var identityCounts: [String: Int] = [:]
        for object in objects {
            guard let fraction = fraction(in: object) else { continue }
            let label = label(in: object) ?? (windows.isEmpty ? descriptor.primaryLabel : descriptor.secondaryLabel)
            let reset = resetDate(in: object)
            let resetFingerprint = reset.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "none"
            let fingerprint = "\(label)-\(Int(fraction * 10_000))-\(resetFingerprint)"
            guard seen.insert(fingerprint).inserted else { continue }
            let identity = label.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: "-",
                    options: .regularExpression
                )
            let occurrence = identityCounts[identity, default: 0]
            identityCounts[identity] = occurrence + 1
            windows.append(UsageWindow(
                id: "\(descriptor.id.rawValue)-\(identity)-\(occurrence)",
                label: label,
                usedFraction: fraction,
                resetsAt: reset,
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

        var planKeys = [
            "plan", "tier", "subscription", "plan_name", "plan_type", "subscription_type",
            "subscription_tier", "current_tier", "login_method", "rate_limit_tier",
            "organization_rate_limit_tier",
        ]
        switch descriptor.id.rawValue {
        case "alibaba":
            planKeys += ["package_name"]
        case "alibabatokenplan":
            planKeys += [
                "package_name", "commodity_name", "spec_type", "instance_name", "display_name",
                "product_name", "spec_code", "plan_code",
            ]
        case "kilo":
            planKeys += ["tier_name", "pass_name", "subscription_name"]
        case "minimax":
            planKeys += ["package_name"]
        case "qwencloud":
            planKeys += ["spec_code", "plan_code"]
        case "copilot":
            planKeys += ["copilot_plan"]
        case "cursor":
            planKeys += ["membership_type"]
        case "antigravity", "augment", "gemini":
            planKeys += ["account_plan"]
        case "commandcode":
            planKeys += ["plan_id"]
        case "grok":
            planKeys += ["subscription_tier_display", "auth_mode"]
        case "kiro":
            planKeys += ["display_plan_name"]
        case "mimo":
            planKeys += ["plan_code", "plan_label"]
        case "zed":
            planKeys += ["plan_v3"]
        default:
            break
        }
        let rawPlan = planlessProviders.contains(descriptor.id.rawValue)
            ? nil
            : firstString(named: planKeys, in: objects)

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
            for key in dictionary.keys.sorted() {
                collectObjects(dictionary[key] as Any, depth: depth + 1, into: &output)
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
        if let percent = number(for: remainingPercentKeys, in: values) {
            return 1 - (percent > 1 ? percent / 100 : percent)
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
        var values: [String: Any] = [:]
        for key in object.keys.sorted() {
            let normalized = normalizedKey(key)
            if values[normalized] == nil {
                values[normalized] = object[key]
            }
        }
        return values
    }

    private static func normalizedKey(_ key: String) -> String {
        var result = ""
        var previousWasSeparator = true
        var previousWasLowercaseOrDigit = false
        for character in key {
            if character == "-" || character == " " || character == "." {
                if !previousWasSeparator && !result.isEmpty { result.append("_") }
                previousWasSeparator = true
                previousWasLowercaseOrDigit = false
                continue
            }
            if character.isUppercase, previousWasLowercaseOrDigit {
                result.append("_")
            }
            result.append(contentsOf: character.lowercased())
            previousWasSeparator = false
            previousWasLowercaseOrDigit = character.isLowercase || character.isNumber
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func number(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = numericValue(object[key]) { return value }
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        if let string = value as? String {
            guard let value = Double(string.replacingOccurrences(of: ",", with: "")), value.isFinite else {
                return nil
            }
            return value
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

        if let mapped = providerPlanLabels[descriptor.id.rawValue]?[normalized] {
            return mapped
        }

        if descriptor.id.rawValue == "claude" {
            return displayClaudeOAuthPlan(subscriptionType: value, rateLimitTier: value)
                ?? humanizedPlan(words)
        }
        if descriptor.id.rawValue == "zenmux" {
            return "\(normalized.capitalized) plan"
        }

        return humanizedPlan(words)
    }

    private static let providerPlanLabels: [String: [String: String]] = [
        "abacus": ["basic": "Basic", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"],
        "alibaba": [
            "lite": "Lite", "coding plan lite": "Lite", "pro": "Pro", "active pro": "Pro",
            "alibaba coding plan pro": "Pro", "starter": "Starter", "enterprise": "Enterprise",
        ],
        "alibabatokenplan": [
            "token plan": "Token Plan", "token plan pro": "Token Plan Pro",
            "token plan plus": "Token Plan Plus",
        ],
        "antigravity": [
            "free": "Free", "paid": "Paid", "pro": "Pro", "ultra": "Google AI Ultra",
            "google ai ultra": "Google AI Ultra",
        ],
        "augment": [
            "free": "Free", "community": "Community", "indie": "Indie", "pro": "Pro",
            "team": "Team", "enterprise": "Enterprise",
        ],
        "claude": [
            "free": "Free", "claude free": "Free", "pro": "Pro", "claude pro": "Pro",
            "max": "Max", "claude max": "Max", "max 5x": "Max 5x", "claude max 5x": "Max 5x",
            "max 20x": "Max 20x", "claude max 20x": "Max 20x", "team": "Team",
            "claude team": "Team", "claude team standard": "Team Standard",
            "claude team premium": "Team Premium", "enterprise": "Enterprise",
            "claude enterprise": "Enterprise", "ultra": "Ultra", "claude ultra": "Ultra",
        ],
        "codex": [
            "guest": "Guest", "free": "Free", "go": "Go", "plus": "Plus",
            "plus plan": "Plus", "chatgpt plus": "Plus", "pro": "Pro 20x",
            "codex pro": "Pro 20x", "prolite": "Pro 5x", "pro lite": "Pro 5x",
            "codex pro lite": "Pro 5x", "free workspace": "Free Workspace", "team": "Team",
            "business": "Business", "education": "Education", "quorum": "Quorum",
            "k12": "K12", "enterprise": "Enterprise", "edu": "Edu",
        ],
        "commandcode": [
            "individual go": "Go", "individual goat": "GOAT", "individual pro": "Pro",
            "individual pro v1": "Pro", "individual max": "Max", "individual ultra": "Ultra",
        ],
        "copilot": [
            "free": "Free", "individual": "Individual", "pro": "Individual",
            "business": "Business", "enterprise": "Enterprise",
        ],
        "cursor": [
            "free": "Cursor Free", "cursor free": "Cursor Free", "hobby": "Cursor Hobby",
            "cursor hobby": "Cursor Hobby", "pro": "Cursor Pro", "cursor pro": "Cursor Pro",
            "express": "Cursor Start", "free trial": "Cursor Pro Trial",
            "pro student": "Cursor Pro", "pro plus": "Cursor Pro+",
            "team": "Cursor Team", "cursor team": "Cursor Team", "business": "Cursor Business",
            "cursor business": "Cursor Business", "enterprise": "Cursor Enterprise",
            "cursor enterprise": "Cursor Enterprise", "ultra": "Cursor Ultra",
            "cursor ultra": "Cursor Ultra",
        ],
        "devin": [
            "free": "Free", "core": "Core", "pro": "Pro", "team": "Team",
            "enterprise": "Enterprise",
        ],
        "elevenlabs": [
            "free": "Free", "starter": "Starter", "creator": "Creator", "pro": "Pro",
            "scale": "Scale", "business": "Business", "growing business": "Business",
            "enterprise": "Enterprise",
        ],
        "gemini": [
            "free": "Free", "paid": "Paid", "plus": "Plus", "workspace": "Workspace",
            "legacy": "Legacy", "gemini code assist in google one ai pro": "Google One AI Pro",
        ],
        "grok": [
            "supergrokheavy": "SuperGrok Heavy", "supergrok heavy": "SuperGrok Heavy",
            "super grok heavy": "SuperGrok Heavy", "heavy": "SuperGrok Heavy",
            "supergrok": "SuperGrok", "super grok": "SuperGrok",
        ],
        "kilo": ["tier 19": "Starter", "tier 49": "Pro", "tier 199": "Expert"],
        "minimax": [
            "free": "Free", "pro": "Pro", "plus": "Plus", "max": "Max", "ultra": "Ultra",
            "minimax star": "MiniMax Star", "combo star": "Combo Star",
            "coding plan pro": "Coding Plan Pro", "token plan pro": "Token Plan Pro",
            "token plan · tokenplanplus 年度会员": "Token Plan Plus",
            "tokenplanplus 年度会员": "Token Plan Plus",
            "tokenplanmax 年度会员": "Token Plan Max",
            "tokenplanultra 年度会员": "Token Plan Ultra",
        ],
        "notion": ["free": "Free", "plus": "Plus", "business": "Business", "enterprise": "Enterprise"],
        "perplexity": ["pro": "Pro", "max": "Max"],
        "qwencloud": ["lite": "Lite", "standard": "Standard", "pro": "Pro", "max": "Max"],
        "sakana": [
            "standard": "Standard", "standard $20/mo": "Standard", "pro": "Pro",
            "enterprise": "Enterprise",
        ],
        "sub2api": [
            "free": "Free", "pro": "Pro", "team": "Team", "claude team": "Team",
            "enterprise": "Enterprise", "wallet plan": "Wallet",
        ],
        "synthetic": ["starter": "Starter", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"],
        "t3chat": ["free": "Free", "pro": "Pro", "team": "Team"],
        "windsurf": [
            "free": "Free", "pro": "Pro", "team": "Teams", "teams": "Teams",
            "enterprise": "Enterprise", "ultimate": "Ultimate",
        ],
        "zai": ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team"],
        "zed": [
            "zed free": "Zed Free", "zed pro": "Zed Pro", "zed pro trial": "Zed Pro Trial",
            "zed student": "Zed Student", "zed business": "Zed Business",
        ],
    ]

    private static let planlessProviders: Set<String> = [
        "deepinfra", "deepseek", "doubao", "ibmbob", "kimi", "longcat", "qoder", "warp",
    ]

    static func displayClaudeOAuthPlan(
        subscriptionType: String?,
        rateLimitTier: String?
    ) -> String? {
        guard let plan = claudeCompatibilityPlan(subscriptionType) ?? claudeRateLimitPlan(rateLimitTier) else {
            return nil
        }
        return claudePlanLabel(plan, rateLimitTier: rateLimitTier, seatTier: nil)
    }

    static func displayClaudeWebPlan(
        rateLimitTier: String?,
        billingType: String?,
        seatTier: String?
    ) -> String? {
        var plan = claudeRateLimitPlan(rateLimitTier)
        if plan == nil,
           billingType?.lowercased().contains("stripe") == true,
           rateLimitTier?.lowercased().contains("claude") == true {
            plan = "pro"
        }
        if plan == nil {
            switch seatTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "team_standard": return "Team Standard"
            case "team_tier_1": return "Team Premium"
            default: return nil
            }
        }
        guard let plan else { return nil }
        return claudePlanLabel(plan, rateLimitTier: rateLimitTier, seatTier: seatTier)
    }

    private static func claudeCompatibilityPlan(_ value: String?) -> String? {
        let words = value?
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init) ?? []
        for plan in ["max", "pro", "team", "enterprise", "ultra"] where words.contains(plan) {
            return plan
        }
        return nil
    }

    private static func claudeRateLimitPlan(_ value: String?) -> String? {
        let tier = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        for plan in ["max", "pro", "team", "enterprise"] where tier.contains(plan) {
            return plan
        }
        return nil
    }

    private static func claudePlanLabel(
        _ plan: String,
        rateLimitTier: String?,
        seatTier: String?
    ) -> String {
        if plan == "max" {
            let words = rateLimitTier?
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init) ?? []
            if let maxIndex = words.firstIndex(of: "max"), words.indices.contains(maxIndex + 1) {
                let multiplier = words[maxIndex + 1]
                if multiplier.last == "x", Int(multiplier.dropLast()) != nil {
                    return "Max \(multiplier)"
                }
            }
            return "Max"
        }
        if plan == "team" {
            switch seatTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "team_standard": return "Team Standard"
            case "team_tier_1": return "Team Premium"
            default: return "Team"
            }
        }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    private static func humanizedPlan(_ words: [String]) -> String? {
        let displayWords = words
            .filter { !["default", "account", "plan"].contains($0) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        guard !displayWords.isEmpty else { return nil }
        return displayWords.joined(separator: " ")
    }
}
