import Foundation

nonisolated enum CopilotUsageFetcher {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }

    struct Quota: Decodable, Equatable {
        var entitlement: Double
        var remaining: Double
        var creditsUsed: Double?
        var percentRemaining: Double
        var quotaID: String
        var hasPercentRemaining: Bool
        var unlimited: Bool
        private var decodedEntitlement: Bool
        private var decodedRemaining: Bool

        var usedFraction: Double { max(0, 1 - percentRemaining / 100) }
        var placeholder: Bool {
            if unlimited { return false }
            if entitlement == 0, remaining == 0, percentRemaining == 0, !hasPercentRemaining { return true }
            return decodedEntitlement && decodedRemaining && entitlement == 0 && remaining == 0
        }
        var usable: Bool { !unlimited && !placeholder && hasPercentRemaining }

        enum CodingKeys: String, CodingKey {
            case entitlement, remaining, unlimited
            case creditsUsed = "credits_used"
            case percentRemaining = "percent_remaining"
            case quotaID = "quota_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let entitlement = Self.number(values, .entitlement)
            let remaining = Self.number(values, .remaining)
            self.entitlement = entitlement ?? 0
            self.remaining = remaining ?? 0
            decodedEntitlement = entitlement != nil
            decodedRemaining = remaining != nil
            creditsUsed = Self.number(values, .creditsUsed)
            unlimited = (try? values.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? false
            quotaID = (try? values.decodeIfPresent(String.self, forKey: .quotaID)) ?? ""
            if unlimited {
                percentRemaining = 100
                hasPercentRemaining = true
            } else if let percent = Self.number(values, .percentRemaining) {
                percentRemaining = percent
                hasPercentRemaining = true
            } else if let entitlement, entitlement > 0, let remaining {
                percentRemaining = remaining / entitlement * 100
                hasPercentRemaining = true
            } else {
                percentRemaining = 0
                hasPercentRemaining = false
            }
        }

        init(
            entitlement: Double, remaining: Double, creditsUsed: Double? = nil,
            percentRemaining: Double, quotaID: String
        ) {
            self.entitlement = entitlement
            self.remaining = remaining
            self.creditsUsed = creditsUsed
            self.percentRemaining = percentRemaining
            self.quotaID = quotaID
            hasPercentRemaining = true
            unlimited = false
            decodedEntitlement = true
            decodedRemaining = true
        }

        func withCredits(_ value: Double?) -> Quota {
            var copy = self
            copy.creditsUsed = value
            return copy
        }

        private static func number(
            _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Double? {
            if let value = try? values.decodeIfPresent(Double.self, forKey: key) { return value }
            if let value = try? values.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
            if let value = try? values.decodeIfPresent(String.self, forKey: key) { return Double(value) }
            return nil
        }
    }

    struct Quotas: Decodable, Equatable {
        var premium: Quota?
        var chat: Quota?

        enum CodingKeys: String, CodingKey {
            case premium = "premium_interactions"
            case chat
        }

        init(premium: Quota?, chat: Quota?) {
            self.premium = premium
            self.chat = chat
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var premium = try values.decodeIfPresent(Quota.self, forKey: .premium)
            var chat = try values.decodeIfPresent(Quota.self, forKey: .chat)
            if premium?.placeholder == true, premium?.creditsUsed == nil { premium = nil }
            if chat?.placeholder == true, chat?.creditsUsed == nil { chat = nil }
            if premium == nil || chat == nil {
                let dynamic = try decoder.container(keyedBy: AnyKey.self)
                var fallbackPremium: Quota?
                var fallbackChat: Quota?
                var first: Quota?
                for key in dynamic.allKeys {
                    guard let quota = try? dynamic.decode(Quota.self, forKey: key),
                          !quota.placeholder || quota.creditsUsed != nil else { continue }
                    if first == nil { first = quota }
                    let name = key.stringValue.lowercased()
                    if fallbackChat == nil, name.contains("chat") { fallbackChat = quota; continue }
                    if fallbackPremium == nil,
                       name.contains("premium") || name.contains("completion") || name.contains("code") {
                        fallbackPremium = quota
                    }
                }
                if premium == nil { premium = fallbackPremium }
                if chat == nil { chat = fallbackChat }
                if premium == nil, chat == nil { chat = first }
            }
            self.premium = premium
            self.chat = chat
        }
    }

    private struct Counts: Decodable {
        var chat: Double?
        var completions: Double?

        enum CodingKeys: String, CodingKey { case chat, completions }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            chat = Self.number(values, .chat)
            completions = Self.number(values, .completions)
        }
        private static func number(
            _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Double? {
            if let value = try? values.decodeIfPresent(Double.self, forKey: key) { return value }
            if let value = try? values.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
            if let value = try? values.decodeIfPresent(String.self, forKey: key) { return Double(value) }
            return nil
        }
    }

    struct Response: Decodable {
        var quotas: Quotas
        var plan: String
        var tokenBasedBilling: Bool
        var reset: String?

        enum CodingKeys: String, CodingKey {
            case quotas = "quota_snapshots"
            case plan = "copilot_plan"
            case tokenBasedBilling = "token_based_billing"
            case reset = "quota_reset_date"
            case monthly = "monthly_quotas"
            case limited = "limited_user_quotas"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let direct = try values.decodeIfPresent(Quotas.self, forKey: .quotas)
            let monthly = try values.decodeIfPresent(Counts.self, forKey: .monthly)
            let limited = try values.decodeIfPresent(Counts.self, forKey: .limited)
            let fallback = Quotas(
                premium: Self.quota(total: monthly?.completions, remaining: limited?.completions, id: "completions"),
                chat: Self.quota(total: monthly?.chat, remaining: limited?.chat, id: "chat")
            )
            quotas = Quotas(
                premium: Self.preferred(direct?.premium, fallback.premium),
                chat: Self.preferred(direct?.chat, fallback.chat)
            )
            plan = (try values.decodeIfPresent(String.self, forKey: .plan)) ?? "unknown"
            tokenBasedBilling = (try values.decodeIfPresent(Bool.self, forKey: .tokenBasedBilling)) ?? false
            reset = try values.decodeIfPresent(String.self, forKey: .reset)
        }

        private static func quota(total: Double?, remaining: Double?, id: String) -> Quota? {
            guard let total, total > 0, let remaining else { return nil }
            let normalized = max(0, remaining)
            return Quota(
                entitlement: total, remaining: normalized,
                percentRemaining: max(0, min(100, normalized / total * 100)), quotaID: id
            )
        }

        private static func preferred(_ direct: Quota?, _ fallback: Quota?) -> Quota? {
            if direct?.unlimited == true, let fallback, fallback.usable {
                return fallback.withCredits(direct?.creditsUsed)
            }
            if let direct, direct.usable { return direct }
            guard let fallback, fallback.usable else {
                return direct?.unlimited == true || direct?.creditsUsed != nil ? direct : nil
            }
            return direct?.creditsUsed == nil ? fallback : fallback.withCredits(direct?.creditsUsed)
        }
    }

    static func fetch(
        token rawToken: String,
        enterpriseHost: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let token = cleanToken(rawToken)
        guard !token.isEmpty else { throw UsageCollectionError.missingCredential }
        guard let url = usageURL(enterpriseHost: enterpriseHost) else { throw UsageCollectionError.missingEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return try parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw UsageCollectionError.unreadableResponse
        }
        let reset = resetDate(response.reset)
        var windows: [UsageWindow] = []
        if let premium = response.quotas.premium, premium.usable {
            windows.append(window(id: "copilot-premium", label: "Premium", quota: premium, reset: reset))
        }
        if let chat = response.quotas.chat, chat.usable {
            windows.append(window(id: "copilot-chat", label: "Chat", quota: chat, reset: reset))
        }
        let hasUnlimited = response.quotas.premium?.unlimited == true || response.quotas.chat?.unlimited == true
        guard !windows.isEmpty || response.tokenBasedBilling || hasUnlimited else {
            throw UsageCollectionError.unreadableResponse
        }
        var details: [UsageDetail] = []
        if let credits = response.quotas.premium?.creditsUsed ?? response.quotas.chat?.creditsUsed {
            details.append(UsageDetail(
                id: "credits-used", label: "Credits used",
                value: credits.formatted(.number.precision(.fractionLength(0...2)))
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "copilot"), state: .ready, windows: windows,
            balance: nil, plan: response.plan.capitalized,
            details: details, updatedAt: now, message: nil
        )
    }

    static func usageURL(enterpriseHost: String?) -> URL? {
        let host = normalizedHost(enterpriseHost)
        let apiHost = host == "github.com" ? "api.github.com" : host.hasPrefix("api.") ? host : "api.\(host)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/copilot_internal/user"
        return components.url
    }

    static func normalizedHost(_ raw: String?) -> String {
        var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value.isEmpty { return "github.com" }
        if let url = URL(string: value.contains("://") ? value : "https://\(value)"), let host = url.host {
            value = host
        }
        return value
    }

    static func cleanToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["token ", "bearer "] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func resetDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func window(
        id: String, label: String, quota: Quota, reset: Date?
    ) -> UsageWindow {
        let overage = quota.usedFraction > 1
            ? String(format: "%.0f%% used", quota.usedFraction * 100)
            : nil
        return UsageWindow(
            id: id, label: label, usedFraction: quota.usedFraction,
            resetsAt: reset, detail: overage
        )
    }
}
