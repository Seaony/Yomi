import Foundation
import SweetCookieKit

nonisolated enum MistralUsageError: LocalizedError, Equatable {
    case missingCookie
    case invalidCookie
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "未找到 Mistral 浏览器会话，请先登录 admin.mistral.ai",
                "No Mistral browser session was found. Sign in to admin.mistral.ai first."
            )
        case .invalidCookie:
            AppLocalization.text(
                "Mistral Cookie 标头无效或缺少 ory_session_* Cookie",
                "The Mistral Cookie header is invalid or missing an ory_session_* cookie."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "Mistral 会话无效或已过期，请重新登录",
                "The Mistral session is invalid or expired. Sign in again."
            )
        case let .apiError(message):
            AppLocalization.text("Mistral 接口错误：\(message)", "Mistral API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Mistral 账单：\(message)", "Failed to parse Mistral billing: \(message)")
        }
    }
}

nonisolated struct MistralDailyUsage: Sendable, Equatable {
    struct Model: Sendable, Equatable {
        let name: String
        let cost: Double
        let inputTokens: Int
        let cachedTokens: Int
        let outputTokens: Int

        var totalTokens: Int { inputTokens + cachedTokens + outputTokens }
    }

    let day: String
    let cost: Double
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
    let models: [Model]

    var totalTokens: Int { inputTokens + cachedTokens + outputTokens }
}

nonisolated struct MistralCredits: Sendable, Equatable {
    let walletAmount: Double
    let creditNotesAmount: Double
    let ongoingUsageBalance: Double
    let currency: String

    var availableAmount: Double {
        let value = walletAmount + creditNotesAmount - ongoingUsageBalance
        return value.isFinite ? max(0, value) : 0
    }
}

nonisolated struct MistralVibeUsage: Sendable, Equatable {
    let usedPercent: Double
    let resetsAt: Date?
}

nonisolated struct MistralUsageSnapshot: Sendable, Equatable {
    let totalCost: Double
    let currency: String
    let currencySymbol: String
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCachedTokens: Int
    let modelCount: Int
    let daily: [MistralDailyUsage]
    let credits: MistralCredits?
    let vibeUsage: MistralVibeUsage?
    let startDate: Date?
    let endDate: Date?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let todayKey = MistralUsageFetcher.utcDayFormatter.string(from: updatedAt)
        let todayBucket = daily.first { $0.day == todayKey }
        let totalTokens = totalInputTokens + totalCachedTokens + totalOutputTokens
        var windows: [UsageWindow] = []
        if let vibeUsage {
            windows.append(UsageWindow(
                id: "mistral-monthly-plan",
                label: AppLocalization.text("月度套餐", "Monthly Plan"),
                usedFraction: vibeUsage.usedPercent / 100,
                resetsAt: vibeUsage.resetsAt,
                detail: nil
            ))
        }

        var details = [UsageDetail(
            id: "mistral-api-spend",
            label: AppLocalization.text("API 支出", "API spend"),
            value: AppLocalization.text(
                "\(currencySymbol)\(String(format: "%.4f", max(0, totalCost)))（本月）",
                "\(currencySymbol)\(String(format: "%.4f", max(0, totalCost))) this month"
            )
        )]
        if let credits {
            details.insert(UsageDetail(
                id: "mistral-balance",
                label: AppLocalization.text("余额", "Balance"),
                value: MistralUsageFetcher.currency(credits.availableAmount, code: credits.currency)
            ), at: 0)
        }
        details.append(UsageDetail(
            id: "mistral-monthly-tokens",
            label: AppLocalization.text("月度 Token", "Monthly tokens"),
            value: totalTokens.formatted(.number.grouping(.automatic))
        ))

        return ProviderUsage(
            id: ProviderID(rawValue: "mistral"),
            state: .ready,
            windows: windows,
            balance: credits.map { MistralUsageFetcher.currency($0.availableAmount, code: $0.currency) },
            plan: nil,
            today: DailyTokenUsage(
                tokens: Int64(todayBucket?.totalTokens ?? 0),
                valueUSD: currency == "USD" ? todayBucket?.cost : nil
            ),
            last30Days: DailyTokenUsage(
                tokens: Int64(totalTokens),
                valueUSD: currency == "USD" ? max(0, totalCost) : nil
            ),
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum MistralUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    struct CookieSession: Sendable, Equatable {
        let cookieHeader: String
        let sourceLabel: String?

        var csrfToken: String? {
            cookiePairs(cookieHeader).first { $0.name == "csrftoken" }?.value
        }
    }

    static let usageURL = URL(string: "https://admin.mistral.ai/api/billing/v2/usage")!
    static let creditsURL = URL(string: "https://admin.mistral.ai/api/billing/credits")!
    static let vibeURL = URL(string:
        "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input="
            + "%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D"
    )!
    static let cookieDomains = ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "console.mistral.ai"]
    static let browserOrder: [Browser] = [.chrome, .firefox, .safari]
    static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        now: Date = Date(),
        timeout: TimeInterval = 15
    ) async throws -> ProviderUsage {
        let candidates: [CookieSession]
        switch source {
        case .cookie, .token:
            guard let normalized = normalizedCookie(credential) else { throw MistralUsageError.invalidCookie }
            candidates = [CookieSession(cookieHeader: normalized, sourceLabel: nil)]
        case .automatic, .account:
            var automatic: [CookieSession] = []
            if let cached = normalizedCookie(cachedCookieHeader) {
                automatic.append(CookieSession(cookieHeader: cached, sourceLabel: "cache"))
            }
            automatic.append(contentsOf: automaticCookieSessions())
            candidates = deduplicated(automatic)
        case .command, .endpoint:
            throw MistralUsageError.missingCookie
        }

        guard !candidates.isEmpty else { throw MistralUsageError.missingCookie }
        return try await fetchFromSessions(
            candidates,
            session: session,
            cacheUpdate: cacheUpdate,
            shouldUpdateCache: source == .automatic || source == .account,
            now: now,
            timeout: timeout
        )
    }

    static func fetchFromSessions(
        _ candidates: [CookieSession],
        session: URLSession,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        shouldUpdateCache: Bool = true,
        now: Date = Date(),
        timeout: TimeInterval = 15
    ) async throws -> ProviderUsage {
        var lastError: MistralUsageError = .invalidCredentials
        for candidate in candidates {
            do {
                let snapshot = try await fetchSnapshot(
                    cookieHeader: candidate.cookieHeader,
                    session: session,
                    now: now,
                    timeout: timeout
                )
                if shouldUpdateCache { await cacheUpdate(candidate.cookieHeader) }
                return snapshot.toProviderUsage()
            } catch MistralUsageError.invalidCredentials {
                lastError = .invalidCredentials
                if shouldUpdateCache, candidate.sourceLabel == "cache" { await cacheUpdate(nil) }
            } catch let error as MistralUsageError {
                lastError = error
                break
            }
        }
        throw lastError
    }

    static func fetchSnapshot(
        cookieHeader: String,
        session: URLSession,
        now: Date = Date(),
        timeout: TimeInterval = 15
    ) async throws -> MistralUsageSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        let csrf = cookiePairs(cookieHeader).first { $0.name == "csrftoken" }?.value
        let primary = try await fetchUsage(
            cookieHeader: cookieHeader,
            csrfToken: csrf,
            session: session,
            now: now,
            timeout: timeout
        )
        let vibe: MistralVibeUsage?
        var remaining = deadline.timeIntervalSinceNow
        if let csrf, remaining > 0 {
            vibe = try await fetchOptionalVibeUsage(
                csrfToken: csrf,
                cookieHeader: cookieHeader,
                session: session,
                timeout: min(remaining, 4)
            )
        } else {
            vibe = nil
        }
        remaining = deadline.timeIntervalSinceNow
        let credits = remaining > 0
            ? try await fetchOptionalCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrf,
                session: session,
                timeout: min(remaining, 4)
            )
            : nil
        return MistralUsageSnapshot(
            totalCost: primary.totalCost,
            currency: primary.currency,
            currencySymbol: primary.currencySymbol,
            totalInputTokens: primary.totalInputTokens,
            totalOutputTokens: primary.totalOutputTokens,
            totalCachedTokens: primary.totalCachedTokens,
            modelCount: primary.modelCount,
            daily: primary.daily,
            credits: credits,
            vibeUsage: vibe,
            startDate: primary.startDate,
            endDate: primary.endDate,
            updatedAt: primary.updatedAt
        )
    }

    static func fetchUsage(
        cookieHeader: String,
        csrfToken: String?,
        session: URLSession,
        now: Date = Date(),
        timeout: TimeInterval = 15
    ) async throws -> MistralUsageSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: String(calendar.component(.month, from: now))),
            URLQueryItem(name: "year", value: String(calendar.component(.year, from: now))),
        ]
        guard let url = components.url else { throw MistralUsageError.apiError("Invalid usage URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken { request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN") }
        let data = try await responseData(for: request, session: session)
        return try parseUsage(data: data, updatedAt: now)
    }

    static func fetchCredits(
        cookieHeader: String,
        csrfToken: String?,
        session: URLSession,
        timeout: TimeInterval = 4
    ) async throws -> MistralCredits {
        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/billing", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken { request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN") }
        let data = try await responseData(for: request, session: session)
        return try parseCredits(data: data)
    }

    static func fetchVibeUsage(
        csrfToken: String,
        cookieHeader: String?,
        session: URLSession,
        timeout: TimeInterval = 4
    ) async throws -> MistralVibeUsage {
        let csrf = try validatedCSRFToken(csrfToken)
        var request = URLRequest(url: vibeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(consoleCookieHeader(csrfToken: csrf, adminCookieHeader: cookieHeader), forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        let data = try await responseData(for: request, session: session)
        return try parseVibeUsage(data: data)
    }

    static func fetchOptionalCredits(
        cookieHeader: String,
        csrfToken: String?,
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> MistralCredits? {
        do {
            return try await fetchCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                session: session,
                timeout: timeout
            )
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    static func fetchOptionalVibeUsage(
        csrfToken: String,
        cookieHeader: String?,
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> MistralVibeUsage? {
        do {
            return try await fetchVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                session: session,
                timeout: timeout
            )
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    static func parseUsage(data: Data, updatedAt: Date) throws -> MistralUsageSnapshot {
        let response: BillingResponse
        do {
            response = try JSONDecoder().decode(BillingResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        let prices = priceIndex(response.prices ?? [])
        var totalCost = 0.0
        var input = 0
        var output = 0
        var cached = 0
        var modelCount = 0
        var daily: [String: DailyAccumulator] = [:]

        if let models = response.completion?.models {
            for (name, usage) in models {
                modelCount += 1
                let aggregate = aggregate(usage, prices: prices)
                input = safeAdd(input, aggregate.input)
                output = safeAdd(output, aggregate.output)
                cached = safeAdd(cached, aggregate.cached)
                addFinite(aggregate.cost, to: &totalCost)
                addDaily(name: name, usage: usage, prices: prices, countsTokens: true, daily: &daily)
            }
        }
        for category in [response.ocr, response.connectors, response.audio] {
            for (name, usage) in category?.models ?? [:] {
                let aggregate = aggregate(usage, prices: prices)
                addFinite(aggregate.cost, to: &totalCost)
                addDaily(name: name, usage: usage, prices: prices, countsTokens: false, daily: &daily)
            }
        }
        for (name, usage) in response.librariesAPI?.pages?.models ?? [:] {
            let aggregate = aggregate(usage, prices: prices)
            addFinite(aggregate.cost, to: &totalCost)
            addDaily(name: name, usage: usage, prices: prices, countsTokens: false, daily: &daily)
        }
        for (name, usage) in response.librariesAPI?.tokens?.models ?? [:] {
            let aggregate = aggregate(usage, prices: prices)
            input = safeAdd(input, aggregate.input)
            output = safeAdd(output, aggregate.output)
            cached = safeAdd(cached, aggregate.cached)
            addFinite(aggregate.cost, to: &totalCost)
            addDaily(name: name, usage: usage, prices: prices, countsTokens: true, daily: &daily)
        }
        for models in [response.fineTuning?.training, response.fineTuning?.storage] {
            for (name, usage) in models ?? [:] {
                let aggregate = aggregate(usage, prices: prices)
                addFinite(aggregate.cost, to: &totalCost)
                addDaily(name: name, usage: usage, prices: prices, countsTokens: false, daily: &daily)
            }
        }

        let rawCurrency = response.currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currency = rawCurrency.isEmpty ? "XXX" : rawCurrency.uppercased()
        let rawSymbol = response.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultSymbol = currency == "EUR" ? "€" : (currency == "XXX" ? "¤" : currency)
        return MistralUsageSnapshot(
            totalCost: totalCost,
            currency: currency,
            currencySymbol: rawSymbol.isEmpty ? defaultSymbol : rawSymbol,
            totalInputTokens: input,
            totalOutputTokens: output,
            totalCachedTokens: cached,
            modelCount: modelCount,
            daily: daily.values.map { $0.snapshot() }.sorted { $0.day < $1.day },
            credits: nil,
            vibeUsage: nil,
            startDate: response.startDate.flatMap(parseDate),
            endDate: response.endDate.flatMap(parseDate),
            updatedAt: updatedAt
        )
    }

    static func parseCredits(data: Data) throws -> MistralCredits {
        let response: CreditsResponse
        do {
            response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        let credits = MistralCredits(
            walletAmount: response.walletAmount,
            creditNotesAmount: response.creditNotesAmount ?? 0,
            ongoingUsageBalance: response.ongoingUsageBalance ?? 0,
            currency: response.currency
        )
        let amounts = [credits.walletAmount, credits.creditNotesAmount, credits.ongoingUsageBalance]
        let available = credits.walletAmount + credits.creditNotesAmount - credits.ongoingUsageBalance
        guard amounts.allSatisfy(\.isFinite), available.isFinite else {
            throw MistralUsageError.parseFailed("Invalid credit amount")
        }
        return credits
    }

    static func parseVibeUsage(data: Data) throws -> MistralVibeUsage {
        let response: [VibeResponse]
        do {
            response = try JSONDecoder().decode([VibeResponse].self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        guard let json = response.first?.result.data.json else {
            throw MistralUsageError.parseFailed("Empty response array")
        }
        guard json.usagePercentage.isFinite, (0...100).contains(json.usagePercentage) else {
            throw MistralUsageError.parseFailed("Invalid usage percentage")
        }
        return MistralVibeUsage(
            usedPercent: json.usagePercentage,
            resetsAt: json.resetAt.flatMap(parseDate)
        )
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let patterns = [#"(?i)-H\s*'Cookie:\s*([^']+)'"#, #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#]
        if value.lowercased().hasPrefix("curl ") {
            guard let extracted = patterns.lazy.compactMap({ capture($0, in: value) }).first else { return nil }
            value = extracted
        } else if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        guard value.rangeOfCharacter(from: .newlines) == nil,
              cookiePairs(value).contains(where: { $0.name.hasPrefix("ory_session_") })
        else { return nil }
        return value
    }

    static func consoleCookieHeader(csrfToken: String, adminCookieHeader: String?) -> String {
        var values = ["csrftoken=\(csrfToken)"]
        values += cookiePairs(adminCookieHeader ?? "")
            .filter { $0.name.hasPrefix("ory_session_") }
            .map { "\($0.name)=\($0.value)" }
        return values.joined(separator: "; ")
    }

    static func automaticCookieSessions() -> [CookieSession] {
        let query = BrowserCookieQuery(
            domains: cookieDomains,
            domainMatch: .exact,
            includeExpired: false
        )
        let client = BrowserCookieClient()
        var sessions: [CookieSession] = []
        for browser in browserOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources where !source.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard cookies.contains(where: { $0.name.hasPrefix("ory_session_") }) else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                sessions.append(CookieSession(
                    cookieHeader: header,
                    sourceLabel: "\(browser.displayName):\(source.store.profile.name)"
                ))
            }
        }
        return deduplicated(sessions)
    }

    static func currency(_ amount: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code.uppercased()
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(code.uppercased()) \(String(format: "%.2f", amount))"
    }

    private static func responseData(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MistralUsageError.apiError("Invalid response")
        }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw MistralUsageError.invalidCredentials
        default: throw MistralUsageError.apiError("HTTP \(http.statusCode)")
        }
    }

    private static func validatedCSRFToken(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: ";,\r\n")
        guard !value.isEmpty, value.rangeOfCharacter(from: forbidden) == nil else {
            throw MistralUsageError.invalidCredentials
        }
        return value
    }

    private static func deduplicated(_ values: [CookieSession]) -> [CookieSession] {
        var headers = Set<String>()
        return values.filter { headers.insert($0.cookieHeader).inserted }
    }

    private static func cookiePairs(_ value: String) -> [(name: String, value: String)] {
        value.split(separator: ";").compactMap { raw in
            let pair = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || value.isEmpty ? nil : (name, value)
        }
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func priceIndex(_ prices: [Price]) -> [String: Double] {
        var result: [String: Double] = [:]
        for price in prices {
            guard let metric = price.billingMetric,
                  let group = price.billingGroup,
                  let raw = price.price,
                  let value = Double(raw), value.isFinite
            else { continue }
            result["\(metric)::\(group)"] = value
        }
        return result
    }

    private static func aggregate(
        _ usage: ModelUsage,
        prices: [String: Double]
    ) -> (input: Int, output: Int, cached: Int, cost: Double) {
        var input = 0
        var output = 0
        var cached = 0
        var cost = 0.0
        for entry in usage.input ?? [] {
            let value = entry.valuePaid ?? entry.value ?? 0
            input = safeAdd(input, value)
            addFinite(entryCost(entry, units: value, prices: prices), to: &cost)
        }
        for entry in usage.output ?? [] {
            let value = entry.valuePaid ?? entry.value ?? 0
            output = safeAdd(output, value)
            addFinite(entryCost(entry, units: value, prices: prices), to: &cost)
        }
        for entry in usage.cached ?? [] {
            let value = entry.valuePaid ?? entry.value ?? 0
            cached = safeAdd(cached, value)
            addFinite(entryCost(entry, units: value, prices: prices), to: &cost)
        }
        return (input, output, cached, cost)
    }

    private static func addDaily(
        name: String,
        usage: ModelUsage,
        prices: [String: Double],
        countsTokens: Bool,
        daily: inout [String: DailyAccumulator]
    ) {
        for (entries, kind) in [(usage.input ?? [], TokenKind.input),
                                (usage.output ?? [], TokenKind.output),
                                (usage.cached ?? [], TokenKind.cached)] {
            for entry in entries {
                guard let timestamp = entry.timestamp, timestamp.count >= 10 else { continue }
                let day = String(timestamp.prefix(10))
                let units = entry.valuePaid ?? entry.value ?? 0
                var accumulator = daily[day] ?? DailyAccumulator(day: day)
                accumulator.add(
                    modelName: displayName(name, entry: entry),
                    kind: kind,
                    units: units,
                    cost: entryCost(entry, units: units, prices: prices),
                    countsTokens: countsTokens
                )
                daily[day] = accumulator
            }
        }
    }

    private static func displayName(_ raw: String, entry: Entry) -> String {
        if let display = entry.billingDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        return raw.split(separator: "::").first.map(String.init) ?? raw
    }

    private static func entryCost(_ entry: Entry, units: Int, prices: [String: Double]) -> Double {
        guard let metric = entry.billingMetric, let group = entry.billingGroup else { return 0 }
        let result = Double(units) * (prices["\(metric)::\(group)"] ?? 0)
        return result.isFinite ? result : 0
    }

    private static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? lhs : result.partialValue
    }

    private static func addFinite(_ value: Double, to total: inout Double) {
        guard value.isFinite else { return }
        let result = total + value
        if result.isFinite { total = result }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private enum TokenKind { case input, output, cached }

    private struct DailyAccumulator {
        let day: String
        var cost = 0.0
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        var models: [String: ModelAccumulator] = [:]

        mutating func add(modelName: String, kind: TokenKind, units: Int, cost: Double, countsTokens: Bool) {
            addFinite(cost, to: &self.cost)
            var model = models[modelName] ?? ModelAccumulator(name: modelName)
            addFinite(cost, to: &model.cost)
            if countsTokens {
                switch kind {
                case .input:
                    inputTokens = safeAdd(inputTokens, units)
                    model.inputTokens = safeAdd(model.inputTokens, units)
                case .cached:
                    cachedTokens = safeAdd(cachedTokens, units)
                    model.cachedTokens = safeAdd(model.cachedTokens, units)
                case .output:
                    outputTokens = safeAdd(outputTokens, units)
                    model.outputTokens = safeAdd(model.outputTokens, units)
                }
            }
            models[modelName] = model
        }

        func snapshot() -> MistralDailyUsage {
            MistralDailyUsage(
                day: day,
                cost: cost,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                outputTokens: outputTokens,
                models: models.values.map { $0.snapshot() }.sorted {
                    $0.totalTokens == $1.totalTokens ? $0.name < $1.name : $0.totalTokens > $1.totalTokens
                }
            )
        }
    }

    private struct ModelAccumulator {
        let name: String
        var cost = 0.0
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0

        func snapshot() -> MistralDailyUsage.Model {
            .init(
                name: name,
                cost: cost,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                outputTokens: outputTokens
            )
        }
    }

    private struct BillingResponse: Decodable {
        let completion: Category?
        let ocr: Category?
        let connectors: Category?
        let librariesAPI: Libraries?
        let fineTuning: FineTuning?
        let audio: Category?
        let currency: String?
        let currencySymbol: String?
        let prices: [Price]?
        let startDate: String?
        let endDate: String?

        enum CodingKeys: String, CodingKey {
            case completion, ocr, connectors, audio, currency, prices
            case librariesAPI = "libraries_api"
            case fineTuning = "fine_tuning"
            case currencySymbol = "currency_symbol"
            case startDate = "start_date"
            case endDate = "end_date"
        }
    }

    private struct Category: Decodable { let models: [String: ModelUsage]? }
    private struct Libraries: Decodable { let pages: Category?; let tokens: Category? }
    private struct FineTuning: Decodable { let training: [String: ModelUsage]?; let storage: [String: ModelUsage]? }
    private struct ModelUsage: Decodable { let input: [Entry]?; let output: [Entry]?; let cached: [Entry]? }
    private struct Entry: Decodable {
        let billingMetric: String?
        let billingDisplayName: String?
        let billingGroup: String?
        let timestamp: String?
        let value: Int?
        let valuePaid: Int?

        enum CodingKeys: String, CodingKey {
            case timestamp, value
            case billingMetric = "billing_metric"
            case billingDisplayName = "billing_display_name"
            case billingGroup = "billing_group"
            case valuePaid = "value_paid"
        }
    }
    private struct Price: Decodable {
        let billingMetric: String?
        let billingGroup: String?
        let price: String?

        enum CodingKeys: String, CodingKey {
            case price
            case billingMetric = "billing_metric"
            case billingGroup = "billing_group"
        }
    }
    private struct CreditsResponse: Decodable {
        let walletAmount: Double
        let creditNotesAmount: Double?
        let ongoingUsageBalance: Double?
        let currency: String

        enum CodingKeys: String, CodingKey {
            case currency
            case walletAmount = "wallet_amount"
            case creditNotesAmount = "credit_notes_amount"
            case ongoingUsageBalance = "ongoing_usage_balance"
        }
    }
    private struct VibeResponse: Decodable {
        let result: Result
        struct Result: Decodable {
            let data: DataEnvelope
            struct DataEnvelope: Decodable {
                let json: JSON
                struct JSON: Decodable {
                    let usagePercentage: Double
                    let resetAt: String?
                    enum CodingKeys: String, CodingKey {
                        case usagePercentage = "usage_percentage"
                        case resetAt = "reset_at"
                    }
                }
            }
        }
    }
}
