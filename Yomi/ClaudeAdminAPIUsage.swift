import Foundation

enum ClaudeAdminAPIUsageError: LocalizedError, Equatable {
    case missingCredential
    case network(String)
    case requestFailed(endpoint: String, status: Int)
    case malformedResponse(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return AppLocalization.text(
                "缺少 Anthropic Admin API Key",
                "Missing Anthropic Admin API key"
            )
        case let .network(message):
            return AppLocalization.text(
                "Claude Admin API 网络错误：\(message)",
                "Claude Admin API network error: \(message)"
            )
        case let .requestFailed(endpoint, status):
            return AppLocalization.text(
                "Claude \(endpoint) 请求失败（HTTP \(status)）",
                "Claude \(endpoint) request failed (HTTP \(status))"
            )
        case let .malformedResponse(endpoint):
            return AppLocalization.text(
                "无法解析 Claude \(endpoint) 返回的数据",
                "Could not parse the Claude \(endpoint) response"
            )
        }
    }
}

enum ClaudeAdminAPIUsageFetcher {
    private static let costURL = URL(
        string: "https://api.anthropic.com/v1/organizations/cost_report"
    )!
    private static let messagesURL = URL(
        string: "https://api.anthropic.com/v1/organizations/usage_report/messages"
    )!

    static func fetch(
        apiKey: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeAdminAPIUsageError.missingCredential }
        let range = dailyRange(now: now)
        async let costsData = request(
            url: reportURL(base: costURL, range: range, groupBy: "description"),
            apiKey: key,
            endpoint: "cost_report",
            session: session
        )
        async let messagesData = request(
            url: reportURL(base: messagesURL, range: range, groupBy: "model"),
            apiKey: key,
            endpoint: "messages",
            session: session
        )
        let (resolvedCosts, resolvedMessages) = try await (costsData, messagesData)
        return try parse(costsData: resolvedCosts, messagesData: resolvedMessages, now: now)
    }

    static func parse(
        costsData: Data,
        messagesData: Data,
        now: Date
    ) throws -> ProviderUsage {
        let costs: CostReportResponse
        let messages: MessagesUsageResponse
        do {
            costs = try JSONDecoder().decode(CostReportResponse.self, from: costsData)
        } catch {
            throw ClaudeAdminAPIUsageError.malformedResponse(endpoint: "cost_report")
        }
        do {
            messages = try JSONDecoder().decode(MessagesUsageResponse.self, from: messagesData)
        } catch {
            throw ClaudeAdminAPIUsageError.malformedResponse(endpoint: "messages")
        }

        var days: [String: DayAccumulator] = [:]
        for bucket in costs.data {
            guard let start = date(bucket.startingAt), let end = date(bucket.endingAt) else { continue }
            var day = days[bucket.startingAt] ?? DayAccumulator(start: start, end: end)
            for result in bucket.results {
                day.costUSD += (Double(result.amount) ?? 0) / 100
            }
            days[bucket.startingAt] = day
        }
        for bucket in messages.data {
            guard let start = date(bucket.startingAt), let end = date(bucket.endingAt) else { continue }
            var day = days[bucket.startingAt] ?? DayAccumulator(start: start, end: end)
            for result in bucket.results {
                let input = result.uncachedInputTokens ?? 0
                let creation = (result.cacheCreation?.ephemeral1HInputTokens ?? 0)
                    + (result.cacheCreation?.ephemeral5MInputTokens ?? 0)
                let read = result.cacheReadInputTokens ?? 0
                let output = result.outputTokens ?? 0
                let total = input + creation + read + output
                day.inputTokens += input
                day.cacheCreationTokens += creation
                day.cacheReadTokens += read
                day.outputTokens += output
                day.totalTokens += total
                let model = cleaned(result.model) ?? "Claude API"
                day.models[model, default: 0] += total
            }
            days[bucket.startingAt] = day
        }

        let sorted = days.values.filter { $0.start <= now }.sorted { $0.start < $1.start }
        let current = summary(sorted.filter { $0.start <= now && now < $0.end })
        let seven = summary(Array(sorted.suffix(7)))
        let thirty = summary(Array(sorted.suffix(30)))
        let details = [
            UsageDetail(id: "claude-admin-today-spend", label: "Today spend", value: usd(current.cost)),
            UsageDetail(id: "claude-admin-7d-spend", label: "7d spend", value: usd(seven.cost)),
            UsageDetail(id: "claude-admin-30d-spend", label: "30d spend", value: usd(thirty.cost)),
            UsageDetail(
                id: "claude-admin-today-tokens",
                label: "Today tokens",
                value: current.tokens.formatted(.number.grouping(.automatic))
            ),
            UsageDetail(
                id: "claude-admin-30d-tokens",
                label: "30d tokens",
                value: thirty.tokens.formatted(.number.grouping(.automatic))
            ),
        ]
        return ProviderUsage(
            id: ProviderID(rawValue: "claude"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            today: DailyTokenUsage(tokens: Int64(current.tokens), valueUSD: current.cost),
            last30Days: DailyTokenUsage(tokens: Int64(thirty.tokens), valueUSD: thirty.cost),
            providerCost: ProviderCostSummary(
                used: thirty.cost,
                limit: 0,
                currencyCode: "USD",
                period: "Last 30 days",
                balance: nil
            ),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    static func reportURL(base: URL, range: (start: Date, end: Date), groupBy: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: dateString(range.start)),
            URLQueryItem(name: "ending_at", value: dateString(range.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
            URLQueryItem(name: "group_by[]", value: groupBy),
        ]
        return components.url!
    }

    private static func request(
        url: URL,
        apiKey: String,
        endpoint: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi/1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeAdminAPIUsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAdminAPIUsageError.malformedResponse(endpoint: endpoint)
        }
        guard http.statusCode == 200 else {
            throw ClaudeAdminAPIUsageError.requestFailed(endpoint: endpoint, status: http.statusCode)
        }
        return data
    }

    private static func dailyRange(now: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        return (
            calendar.date(byAdding: .day, value: -30, to: today)!,
            calendar.date(byAdding: .day, value: 1, to: today)!
        )
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(_ days: [DayAccumulator]) -> (cost: Double, tokens: Int, cacheRead: Int) {
        (
            days.reduce(0) { $0 + $1.costUSD },
            days.reduce(0) { $0 + $1.totalTokens },
            days.reduce(0) { $0 + $1.cacheReadTokens }
        )
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

private struct CostReportResponse: Decodable {
    var data: [CostBucket]
}

private struct CostBucket: Decodable {
    var startingAt: String
    var endingAt: String
    var results: [CostResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct CostResult: Decodable {
    var amount: String
}

private struct MessagesUsageResponse: Decodable {
    var data: [MessagesBucket]
}

private struct MessagesBucket: Decodable {
    var startingAt: String
    var endingAt: String
    var results: [MessagesResult]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct MessagesResult: Decodable {
    struct CacheCreation: Decodable {
        var ephemeral1HInputTokens: Int?
        var ephemeral5MInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral1HInputTokens = "ephemeral_1h_input_tokens"
            case ephemeral5MInputTokens = "ephemeral_5m_input_tokens"
        }
    }

    var uncachedInputTokens: Int?
    var cacheCreation: CacheCreation?
    var cacheReadInputTokens: Int?
    var outputTokens: Int?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreation = "cache_creation"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}

private struct DayAccumulator {
    var start: Date
    var end: Date
    var costUSD = 0.0
    var inputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var models: [String: Int] = [:]
}
