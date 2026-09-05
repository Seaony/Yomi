import Foundation

nonisolated enum UsageParser {
    static func parse(_ data: Data, descriptor: ProviderDescriptor, claudeWeb: Bool = false) throws -> ProviderUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageCollectionError.unreadableResponse
        }
        let parsed: ProviderUsage? = switch descriptor.id.rawValue {
        case "codex": parseCodex(object, descriptor: descriptor)
        case "claude": parseClaude(object, descriptor: descriptor, isWeb: claudeWeb)
        case "clinepass": parseClinePass(object, descriptor: descriptor)
        case "gemini": parseGemini(object, descriptor: descriptor)
        default: nil
        }
        guard let parsed else { throw UsageCollectionError.unreadableResponse }
        return parsed
    }

    private static func parseCodex(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        guard let response = root as? [String: Any] else { return nil }
        let rateLimit = response["rate_limit"] as? [String: Any]
        let primary = codexWindow(
            rateLimit?["primary_window"],
            id: "codex-primary",
            fallbackLabel: descriptor.primaryLabel
        )
        let secondary = codexWindow(
            rateLimit?["secondary_window"],
            id: "codex-secondary",
            fallbackLabel: descriptor.secondaryLabel
        )
        let windows = normalizedCodexWindows(primary: primary, secondary: secondary)
        guard !windows.isEmpty else { return nil }
        let plan = ((response["plan_type"] as? String) ?? (response["planType"] as? String))
            .flatMap { displayPlan($0, descriptor: descriptor) }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            balance: nil,
            plan: plan,
            updatedAt: Date(),
            message: nil
        )
    }

    private static func codexWindow(
        _ value: Any?,
        id: String,
        fallbackLabel: String
    ) -> CodexWindow? {
        guard let object = value as? [String: Any],
              let usedPercent = numericValue(object["used_percent"])
        else { return nil }
        let seconds = numericValue(object["limit_window_seconds"]).flatMap(integerValue)
        let role: CodexWindowRole
        let label: String
        switch seconds {
        case 18_000:
            role = .session
            label = "Session"
        case 604_800:
            role = .weekly
            label = "Weekly"
        default:
            role = .unknown
            label = fallbackLabel
        }
        return CodexWindow(
            usage: UsageWindow(
                id: id,
                label: label,
                usedFraction: usedPercent / 100,
                resetsAt: date(object["reset_at"]),
                detail: nil
            ),
            role: role
        )
    }

    private static func normalizedCodexWindows(
        primary: CodexWindow?,
        secondary: CodexWindow?
    ) -> [UsageWindow] {
        [primary, secondary]
            .compactMap { $0 }
            .first { $0.role == .weekly }
            .map { [$0.usage] } ?? []
    }

    private struct CodexWindow {
        let usage: UsageWindow
        let role: CodexWindowRole
    }

    private enum CodexWindowRole: Equatable {
        case session
        case weekly
        case unknown
    }

    private static func parseClaude(_ root: Any, descriptor: ProviderDescriptor, isWeb: Bool) -> ProviderUsage? {
        guard let response = root as? [String: Any] else { return nil }
        func window(_ key: String, label: String) -> UsageWindow? {
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

        let fiveHour = window("five_hour", label: "Session")
        let sevenDay = window("seven_day", label: "Weekly")
        let oauthApps = window("seven_day_oauth_apps", label: "OAuth apps")
        let sonnet = window("seven_day_sonnet", label: "Sonnet")
        let opus = window("seven_day_opus", label: "Opus")
        var windows: [UsageWindow] = []
        if let primary = fiveHour ?? sevenDay ?? oauthApps ?? sonnet ?? opus {
            windows.append(primary)
        }
        if let sevenDay, sevenDay.id != windows.first?.id {
            windows.append(sevenDay)
        }
        if let modelSpecific = sonnet ?? opus, !windows.contains(where: { $0.id == modelSpecific.id }) {
            windows.append(modelSpecific)
        }

        var additional: [UsageWindow] = []
        let routineKeys = [
            "seven_day_routines", "seven_day_claude_routines", "claude_routines",
            "routines", "routine", "seven_day_cowork", "cowork",
        ]
        if let routine = routineKeys.lazy.compactMap({ window($0, label: "Daily Routines") }).first {
            additional.append(routine)
        }
        if let limits = response["limits"] as? [[String: Any]] {
            var seen = Set<String>()
            for limit in limits {
                guard limit["group"] as? String == "weekly",
                      limit["kind"] as? String == "weekly_scoped",
                      let percent = numericValue(limit["percent"]),
                      percent.isFinite
                else { continue }
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                guard let label = (model?["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !label.isEmpty
                else { continue }
                let modelID = (model?["id"] as? String) ?? label
                let slug = modelID.lowercased()
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                guard !slug.isEmpty,
                      slug != "all-models",
                      !slug.hasSuffix("-all-models"),
                      seen.insert(slug).inserted
                else { continue }
                additional.append(UsageWindow(
                    id: "claude-weekly-scoped-\(slug)",
                    label: label,
                    usedFraction: percent / 100,
                    resetsAt: date(limit["resets_at"]),
                    detail: nil
                ))
            }
        }

        let providerCost: ProviderCostSummary? = {
            guard let extra = response["extra_usage"] as? [String: Any],
                  isWeb || (extra["is_enabled"] as? Bool) == true,
                  let used = numericValue(extra["used_credits"]),
                  let limit = numericValue(extra["monthly_limit"] ?? extra["monthly_credit_limit"])
            else { return nil }
            let currency = ((extra["currency"] as? String) ?? "USD")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderCostSummary(
                used: used / 100,
                limit: limit / 100,
                currencyCode: currency.isEmpty ? "USD" : currency,
                period: "Monthly cap",
                balance: nil
            )
        }()
        if windows.isEmpty, let providerCost, providerCost.limit > 0 {
            windows = [UsageWindow(
                id: "claude-spend-limit",
                label: "Spend limit",
                usedFraction: providerCost.used / providerCost.limit,
                resetsAt: nil,
                detail: String(format: "$%.2f / $%.2f", providerCost.used, providerCost.limit)
            )]
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: nil,
            plan: nil,
            providerCost: providerCost,
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

    private static func parseClinePass(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        guard let response = root as? [String: Any],
              let data = response["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]]
        else { return nil }
        let definitions: [String: (label: String, order: Int)] = [
            "five_hour": ("5-hour", 0),
            "weekly": ("Weekly", 1),
            "monthly": ("Monthly", 2),
        ]
        let windows = limits.compactMap { limit -> (Int, UsageWindow)? in
            guard let type = limit["type"] as? String,
                  let definition = definitions[type],
                  let percent = numericValue(limit["percentUsed"]),
                  percent.isFinite
            else { return nil }
            return (
                definition.order,
                UsageWindow(
                    id: "clinepass-\(type)",
                    label: definition.label,
                    usedFraction: percent / 100,
                    resetsAt: date(limit["resetsAt"]),
                    detail: nil
                )
            )
        }.sorted { $0.0 < $1.0 }.map(\.1)
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

    private static func integerValue(_ value: Double) -> Int? {
        guard value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
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
