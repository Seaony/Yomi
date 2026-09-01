import Foundation

nonisolated struct FireworksUsageSnapshot: Sendable {
    let summary: FireworksUsageSummary
    let accountSlug: String
    let accountSlugWasDiscovered: Bool

    func toProviderUsage(now: Date? = nil) -> ProviderUsage {
        let updatedAt = now ?? summary.updatedAt
        let cost = summary.last30DaysSpend.flatMap { spend in
            summary.currencyCode.map { currency in
                ProviderCostSummary(
                    used: spend,
                    limit: 0,
                    currencyCode: currency,
                    period: "Last 30 days",
                    balance: nil
                )
            }
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "fireworks"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            providerCost: cost,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated struct FireworksUsageSummary: Sendable {
    let last30DaysSpend: Double?
    let currencyCode: String?
    let updatedAt: Date
}

enum FireworksUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidAccountSlug(String)
    case accountNotFound(String)
    case noAccountsFound
    case multipleAccountsFound([String])
    case authenticationRejected
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 Fireworks API Key。请在设置中添加，或设置 FIREWORKS_API_KEY。",
                "Missing Fireworks API key. Add one in Settings or set FIREWORKS_API_KEY."
            )
        case let .invalidAccountSlug(slug):
            AppLocalization.text(
                "Fireworks 账号 slug“\(slug)”无效，请检查设置。",
                "Invalid Fireworks account slug '\(slug)'. Please double-check the account slug in Settings."
            )
        case let .accountNotFound(slug):
            AppLocalization.text(
                "此 API Key 无法访问 Fireworks 账号“\(slug)”。请留空以自动发现账号，或在 Fireworks 账号切换器中确认 slug。",
                "Fireworks account slug '\(slug)' not found for this API key. Leave the slug blank to auto-discover it, choose it in the app.fireworks.ai account switcher, or run 'firectl whoami'."
            )
        case .noAccountsFound:
            AppLocalization.text(
                "此 API Key 看不到任何 Fireworks 账号，请检查密钥。",
                "No Fireworks accounts are visible to this API key. Check the key in app.fireworks.ai or run 'firectl whoami'."
            )
        case let .multipleAccountsFound(slugs):
            AppLocalization.text(
                "此 Fireworks API Key 可访问多个账号：\(slugs.joined(separator: ", "))。请在设置中填写账号 slug。",
                "This Fireworks API key can access multiple accounts: \(slugs.joined(separator: ", ")). Set the account slug in Settings or FIREWORKS_ACCOUNT_SLUG; find it in the app.fireworks.ai account switcher or with 'firectl whoami'."
            )
        case .authenticationRejected:
            AppLocalization.text(
                "Fireworks 拒绝了此 API Key，请创建新密钥并更新设置。",
                "Fireworks rejected the API key. Create a new key at app.fireworks.ai and update Settings."
            )
        case .rateLimited:
            AppLocalization.text(
                "Fireworks 请求已达到速率限制，将在下个刷新周期重试。",
                "Fireworks rate limit exceeded. Usage will refresh on the next cycle."
            )
        case let .apiError(statusCode):
            AppLocalization.text(
                "Fireworks 账单接口返回 HTTP \(statusCode)。",
                "Fireworks billing API returned HTTP \(statusCode)."
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Fireworks 用量：\(message)",
                "Could not parse Fireworks usage: \(message)"
            )
        }
    }
}

nonisolated enum FireworksUsageFetcher {
    private static let timeoutSeconds: TimeInterval = 15
    private static let lookbackDays = 30
    private static let accountSlugAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func fetch(
        apiKey: String,
        accountSlug: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> FireworksUsageSnapshot {
        let cleanedKey = clean(apiKey)
        guard !cleanedKey.isEmpty else { throw FireworksUsageError.missingCredentials }

        let configuredSlug = clean(accountSlug ?? "")
        if !configuredSlug.isEmpty {
            return try await fetchConfiguredAccount(
                apiKey: cleanedKey,
                accountSlug: configuredSlug,
                session: session,
                now: now
            )
        }

        let slugs = try await listAccountSlugs(apiKey: cleanedKey, session: session)
        let discoveredSlug = try singleDiscoveredAccount(from: slugs)
        let summary = try await fetchSummary(
            apiKey: cleanedKey,
            accountSlug: discoveredSlug,
            session: session,
            now: now
        )
        return FireworksUsageSnapshot(
            summary: summary,
            accountSlug: discoveredSlug,
            accountSlugWasDiscovered: true
        )
    }

    static func resolvedAccountSlug(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let configured = clean(configured ?? "")
        if !configured.isEmpty { return configured }
        return cleanedEnvironmentValue("FIREWORKS_ACCOUNT_SLUG", environment: environment)
    }

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let configured = clean(configured ?? "")
        if !configured.isEmpty { return configured }
        for key in ["FIREWORKS_API_KEY", "FIREWORKS_KEY"] {
            if let value = cleanedEnvironmentValue(key, environment: environment) {
                return value
            }
        }
        return nil
    }

    @MainActor
    static func persistDiscoveredAccountSlug(_ accountSlug: String) {
        var configuration = ProviderPreferences.shared.configuration(
            for: ProviderID(rawValue: "fireworks")
        )
        guard configuration.account != accountSlug else { return }
        configuration.account = accountSlug
        ProviderPreferences.shared.update(configuration)
    }

    static func resolveAccountsURL(pageToken: String? = nil) -> URL {
        var components = URLComponents(string: "https://api.fireworks.ai/v1/accounts")!
        if let pageToken {
            components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
        }
        return components.url!
    }

    static func resolveSummaryURL(
        accountSlug: String,
        startTime: Date? = nil,
        endTime: Date? = nil
    ) throws -> URL {
        guard accountSlug.rangeOfCharacter(from: accountSlugAllowedCharacters.inverted) == nil,
              var components = URLComponents(
                string: "https://api.fireworks.ai/v1/accounts/\(accountSlug)/billing/summary"
              )
        else { throw FireworksUsageError.invalidAccountSlug(accountSlug) }

        var query: [URLQueryItem] = []
        if let startTime {
            query.append(URLQueryItem(name: "startTime", value: isoString(startTime)))
        }
        if let endTime {
            query.append(URLQueryItem(name: "endTime", value: isoString(endTime)))
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw FireworksUsageError.invalidAccountSlug(accountSlug) }
        return url
    }

    static func parseSummary(data: Data, now: Date = Date()) throws -> FireworksUsageSummary {
        let response: FireworksBillingSummaryResponse
        do {
            response = try JSONDecoder().decode(FireworksBillingSummaryResponse.self, from: data)
        } catch {
            throw FireworksUsageError.parseFailed(error.localizedDescription)
        }

        var currency: String?
        var total = 0.0
        for item in response.lineItems ?? [] {
            guard let cost = item.totalCost,
                  let units = cost.units.flatMap(Double.init),
                  let nanos = cost.nanos,
                  let code = cost.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !code.isEmpty
            else { continue }
            if currency == nil { currency = code }
            guard code == currency else { continue }
            total += units + Double(nanos) / 1_000_000_000
        }

        return FireworksUsageSummary(
            last30DaysSpend: currency.map { _ in total },
            currencyCode: currency,
            updatedAt: now
        )
    }

    private static func fetchConfiguredAccount(
        apiKey: String,
        accountSlug: String,
        session: URLSession,
        now: Date
    ) async throws -> FireworksUsageSnapshot {
        do {
            let summary = try await fetchSummary(
                apiKey: apiKey,
                accountSlug: accountSlug,
                session: session,
                now: now
            )
            if summary.last30DaysSpend == nil {
                let slugs = try await listAccountSlugs(apiKey: apiKey, session: session)
                guard slugs.contains(accountSlug) else {
                    throw FireworksUsageError.accountNotFound(accountSlug)
                }
            }
            return FireworksUsageSnapshot(
                summary: summary,
                accountSlug: accountSlug,
                accountSlugWasDiscovered: false
            )
        } catch FireworksUsageError.apiError(404) {
            let slugs = try await listAccountSlugs(apiKey: apiKey, session: session)
            guard slugs.count == 1, let discoveredSlug = slugs.first else {
                if slugs.isEmpty { throw FireworksUsageError.accountNotFound(accountSlug) }
                throw FireworksUsageError.multipleAccountsFound(slugs)
            }
            let summary = try await fetchSummary(
                apiKey: apiKey,
                accountSlug: discoveredSlug,
                session: session,
                now: now
            )
            return FireworksUsageSnapshot(
                summary: summary,
                accountSlug: discoveredSlug,
                accountSlugWasDiscovered: discoveredSlug != accountSlug
            )
        }
    }

    private static func fetchSummary(
        apiKey: String,
        accountSlug: String,
        session: URLSession,
        now: Date
    ) async throws -> FireworksUsageSummary {
        let startTime = now.addingTimeInterval(-TimeInterval(lookbackDays * 24 * 60 * 60))
        var request = URLRequest(url: try resolveSummaryURL(
            accountSlug: accountSlug,
            startTime: startTime,
            endTime: now
        ))
        authorize(&request, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FireworksUsageError.parseFailed("Invalid HTTP response")
        }
        switch response.statusCode {
        case 200:
            return try parseSummary(data: data, now: now)
        case 401, 403:
            throw FireworksUsageError.authenticationRejected
        case 429:
            throw FireworksUsageError.rateLimited
        default:
            throw FireworksUsageError.apiError(response.statusCode)
        }
    }

    private static func listAccountSlugs(
        apiKey: String,
        session: URLSession
    ) async throws -> [String] {
        var slugs: Set<String> = []
        var pageToken: String?
        repeat {
            var request = URLRequest(url: resolveAccountsURL(pageToken: pageToken))
            authorize(&request, apiKey: apiKey)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw FireworksUsageError.parseFailed("Invalid HTTP response")
            }
            switch response.statusCode {
            case 200:
                break
            case 401, 403:
                throw FireworksUsageError.authenticationRejected
            case 429:
                throw FireworksUsageError.rateLimited
            default:
                throw FireworksUsageError.apiError(response.statusCode)
            }

            let page: FireworksAccountsResponse
            do {
                page = try JSONDecoder().decode(FireworksAccountsResponse.self, from: data)
            } catch {
                throw FireworksUsageError.parseFailed(error.localizedDescription)
            }
            for account in page.accounts ?? [] {
                if let slug = account.slug, isValidAccountSlug(slug) {
                    slugs.insert(slug)
                }
            }
            pageToken = page.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if pageToken?.isEmpty == true { pageToken = nil }
        } while pageToken != nil
        return slugs.sorted()
    }

    private static func singleDiscoveredAccount(from slugs: [String]) throws -> String {
        guard !slugs.isEmpty else { throw FireworksUsageError.noAccountsFound }
        guard slugs.count == 1, let slug = slugs.first else {
            throw FireworksUsageError.multipleAccountsFound(slugs)
        }
        return slug
    }

    private static func authorize(_ request: inout URLRequest, apiKey: String) {
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private static func isValidAccountSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.rangeOfCharacter(from: accountSlugAllowedCharacters.inverted) == nil
    }

    private static func cleanedEnvironmentValue(
        _ key: String,
        environment: [String: String]
    ) -> String? {
        let value = clean(environment[key] ?? "")
        return value.isEmpty ? nil : value
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

nonisolated private struct FireworksBillingSummaryResponse: Decodable {
    let lineItems: [FireworksLineItem]?
    let usageBuckets: [FireworksUsageBucket]?
}

nonisolated private struct FireworksAccountsResponse: Decodable {
    let accounts: [FireworksAccount]?
    let nextPageToken: String?
}

nonisolated private struct FireworksAccount: Decodable {
    let name: String?
    let accountId: String?
    let id: String?

    var slug: String? {
        for value in [accountId, id, name] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            return value.split(separator: "/").last.map(String.init)
        }
        return nil
    }
}

nonisolated private struct FireworksLineItem: Decodable {
    let category: String?
    let groupingKey: String?
    let groupingValue: String?
    let quantity: Double?
    let series: String?
    let totalCost: FireworksMoney?
    let unitAmount: FireworksMoney?
}

nonisolated private struct FireworksMoney: Decodable {
    let currencyCode: String?
    let nanos: Int?
    let units: String?
}

nonisolated private struct FireworksUsageBucket: Decodable {
    let bucketStartTime: String?
    let lineItems: [FireworksLineItem]?
}
