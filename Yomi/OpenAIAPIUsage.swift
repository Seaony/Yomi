import Foundation

struct OpenAIAPIUsageSnapshot: Codable, Hashable, Sendable {
    struct DailyBucket: Codable, Hashable, Sendable, Identifiable {
        var day: String
        var startTime: Date
        var endTime: Date
        var costUSD: Double
        var requests: Int
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var totalTokens: Int
        var lineItems: [LineItem]
        var models: [Model]

        var id: String { day }
    }

    struct LineItem: Codable, Hashable, Sendable, Identifiable {
        var name: String
        var costUSD: Double

        var id: String { name }
    }

    struct Model: Codable, Hashable, Sendable, Identifiable {
        var name: String
        var requests: Int
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var totalTokens: Int

        var id: String { name }
    }

    struct Summary: Hashable, Sendable {
        var costUSD: Double
        var requests: Int
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var totalTokens: Int
    }

    var daily: [DailyBucket]
    var updatedAt: Date
    var historyDays: Int
    var projectID: String?

    var currentDay: Summary {
        let selected = daily.filter { $0.startTime <= updatedAt && updatedAt < $0.endTime }
        return Self.summary(selected)
    }

    var history: Summary {
        Self.summary(Array(daily.suffix(max(1, historyDays))))
    }

    var topModel: Model? {
        var totals: [String: Model] = [:]
        for bucket in daily {
            for model in bucket.models {
                var total = totals[model.name] ?? Model(
                    name: model.name,
                    requests: 0,
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    totalTokens: 0
                )
                total.requests += model.requests
                total.inputTokens += model.inputTokens
                total.cachedInputTokens += model.cachedInputTokens
                total.outputTokens += model.outputTokens
                total.totalTokens += model.totalTokens
                totals[model.name] = total
            }
        }
        return totals.values.sorted {
            $0.totalTokens == $1.totalTokens ? $0.name < $1.name : $0.totalTokens > $1.totalTokens
        }.first
    }

    private static func summary(_ buckets: [DailyBucket]) -> Summary {
        Summary(
            costUSD: buckets.reduce(0) { $0 + $1.costUSD },
            requests: buckets.reduce(0) { $0 + $1.requests },
            inputTokens: buckets.reduce(0) { $0 + $1.inputTokens },
            cachedInputTokens: buckets.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: buckets.reduce(0) { $0 + $1.outputTokens },
            totalTokens: buckets.reduce(0) { $0 + $1.totalTokens }
        )
    }
}

enum OpenAIAPIUsageError: LocalizedError, Equatable {
    case missingCredential
    case network(String)
    case requestFailed(endpoint: String, status: Int)
    case malformedResponse(endpoint: String)
    case invalidPagination(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            AppLocalization.text("缺少 OpenAI Admin API Key", "Missing OpenAI Admin API key")
        case let .network(message):
            AppLocalization.text("OpenAI 网络错误：\(message)", "OpenAI network error: \(message)")
        case let .requestFailed(endpoint, status):
            AppLocalization.text(
                "OpenAI \(endpoint) 请求失败（HTTP \(status)）",
                "OpenAI \(endpoint) request failed (HTTP \(status))"
            )
        case let .malformedResponse(endpoint):
            AppLocalization.text(
                "无法解析 OpenAI \(endpoint) 返回的数据",
                "Could not parse the OpenAI \(endpoint) response"
            )
        case let .invalidPagination(endpoint):
            AppLocalization.text(
                "OpenAI \(endpoint) 返回了无效的分页游标",
                "OpenAI \(endpoint) returned an invalid pagination cursor"
            )
        }
    }
}

enum OpenAIAPIUsageFetcher {
    private static let costsURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    private static let completionsURL = URL(
        string: "https://api.openai.com/v1/organization/usage/completions"
    )!
    private static let creditsURL = URL(
        string: "https://api.openai.com/v1/dashboard/billing/credit_grants"
    )!
    private static let maximumPageCount = 100

    static func fetch(
        apiKey: String,
        projectID: String?,
        usesAdminKey: Bool,
        session: URLSession,
        now: Date = Date(),
        historyDays: Int = 30
    ) async throws -> ProviderUsage {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIAPIUsageError.missingCredential }
        let project = cleaned(projectID)

        do {
            let snapshot = try await fetchAdminUsage(
                apiKey: key,
                projectID: project,
                session: session,
                now: now,
                historyDays: historyDays
            )
            let history = snapshot.history
            return ProviderUsage(
                id: ProviderID(rawValue: "openai"),
                state: .ready,
                windows: [],
                balance: nil,
                plan: nil,
                today: DailyTokenUsage(
                    tokens: Int64(snapshot.currentDay.totalTokens),
                    valueUSD: snapshot.currentDay.costUSD
                ),
                last30Days: DailyTokenUsage(
                    tokens: Int64(history.totalTokens),
                    valueUSD: history.costUSD
                ),
                providerCost: ProviderCostSummary(
                    used: history.costUSD,
                    limit: 0,
                    currencyCode: "USD",
                    period: AppLocalization.text("最近 30 天", "Last 30 days")
                ),
                details: [
                    UsageDetail(
                        id: "openai-requests",
                        label: AppLocalization.text("请求", "Requests"),
                        value: history.requests.formatted(.number.grouping(.automatic))
                    ),
                    UsageDetail(
                        id: "openai-tokens",
                        label: "Tokens",
                        value: history.totalTokens.formatted(.number.grouping(.automatic))
                    ),
                ],
                updatedAt: now,
                message: nil
            )
        } catch let error as OpenAIAPIUsageError {
            guard project == nil || !usesAdminKey else { throw error }
            do {
                return try await fetchLegacyCredits(apiKey: key, session: session, now: now)
            } catch {
                throw error
            }
        }
    }

    static func parseAdminUsage(
        costsData: Data,
        completionsData: Data,
        now: Date,
        historyDays: Int = 30,
        projectID: String? = nil
    ) throws -> OpenAIAPIUsageSnapshot {
        let costs: CostsResponse
        let completions: CompletionsResponse
        do {
            costs = try JSONDecoder().decode(CostsResponse.self, from: costsData)
        } catch {
            throw OpenAIAPIUsageError.malformedResponse(endpoint: "costs")
        }
        do {
            completions = try JSONDecoder().decode(CompletionsResponse.self, from: completionsData)
        } catch {
            throw OpenAIAPIUsageError.malformedResponse(endpoint: "completions")
        }
        return makeSnapshot(
            costs: costs.data,
            completions: completions.data,
            now: now,
            historyDays: historyDays,
            projectID: cleaned(projectID)
        )
    }

    private static func fetchAdminUsage(
        apiKey: String,
        projectID: String?,
        session: URLSession,
        now: Date,
        historyDays: Int
    ) async throws -> OpenAIAPIUsageSnapshot {
        let ranges = dailyRanges(now: now, historyDays: historyDays)
        var costs: [CostBucket] = []
        var completions: [CompletionBucket] = []

        for range in ranges {
            costs += try await fetchPages(
                endpoint: "costs",
                baseURL: costsURL,
                apiKey: apiKey,
                projectID: projectID,
                range: range,
                groupBy: "line_item",
                session: session,
                response: CostsResponse.self
            ).flatMap(\.data)
            completions += try await fetchPages(
                endpoint: "completions",
                baseURL: completionsURL,
                apiKey: apiKey,
                projectID: projectID,
                range: range,
                groupBy: "model",
                session: session,
                response: CompletionsResponse.self
            ).flatMap(\.data)
        }

        return makeSnapshot(
            costs: costs,
            completions: completions,
            now: now,
            historyDays: historyDays,
            projectID: projectID
        )
    }

    private static func fetchPages<Response: PageResponse>(
        endpoint: String,
        baseURL: URL,
        apiKey: String,
        projectID: String?,
        range: DateRange,
        groupBy: String,
        session: URLSession,
        response: Response.Type
    ) async throws -> [Response] {
        var pages: [Response] = []
        var cursor: String?
        var seen: Set<String> = []

        repeat {
            guard pages.count < maximumPageCount else {
                throw OpenAIAPIUsageError.invalidPagination(endpoint: endpoint)
            }
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "start_time", value: String(range.start)),
                URLQueryItem(name: "end_time", value: String(range.end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: String(range.limit)),
                URLQueryItem(name: "group_by", value: groupBy),
            ]
            if let projectID { query.append(URLQueryItem(name: "project_ids", value: projectID)) }
            if let cursor { query.append(URLQueryItem(name: "page", value: cursor)) }
            components.queryItems = query

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: request)
            } catch {
                throw OpenAIAPIUsageError.network(error.localizedDescription)
            }
            guard let http = urlResponse as? HTTPURLResponse else {
                throw OpenAIAPIUsageError.malformedResponse(endpoint: endpoint)
            }
            guard http.statusCode == 200 else {
                throw OpenAIAPIUsageError.requestFailed(endpoint: endpoint, status: http.statusCode)
            }
            let decoded: Response
            do {
                decoded = try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw OpenAIAPIUsageError.malformedResponse(endpoint: endpoint)
            }
            pages.append(decoded)
            guard decoded.hasMore else {
                cursor = nil
                continue
            }
            guard let next = cleaned(decoded.nextPage), seen.insert(next).inserted else {
                throw OpenAIAPIUsageError.invalidPagination(endpoint: endpoint)
            }
            cursor = next
        } while cursor != nil

        return pages
    }

    private static func fetchLegacyCredits(
        apiKey: String,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIAPIUsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIAPIUsageError.malformedResponse(endpoint: "credit balance")
        }
        guard http.statusCode == 200 else {
            throw OpenAIAPIUsageError.requestFailed(endpoint: "credit balance", status: http.statusCode)
        }
        let credits: CreditsResponse
        do {
            credits = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw OpenAIAPIUsageError.malformedResponse(endpoint: "credit balance")
        }
        let fraction = credits.totalGranted > 0 ? credits.totalUsed / credits.totalGranted : 1
        let expiry = credits.grants?.data.compactMap(\.expiresAt).filter { $0 > now }.min()
        return ProviderUsage(
            id: ProviderID(rawValue: "openai"),
            state: .ready,
            windows: [UsageWindow(
                id: "openai-api-credits",
                label: "API credits",
                usedFraction: fraction,
                resetsAt: expiry,
                detail: String(format: "$%.2f available", max(0, credits.totalAvailable))
            )],
            balance: String(format: "$%.2f", max(0, credits.totalAvailable)),
            plan: nil,
            updatedAt: now,
            message: nil
        )
    }

    private static func makeSnapshot(
        costs: [CostBucket],
        completions: [CompletionBucket],
        now: Date,
        historyDays: Int,
        projectID: String?
    ) -> OpenAIAPIUsageSnapshot {
        var buckets: [Int: Accumulator] = [:]
        for bucket in costs {
            var accumulator = buckets[bucket.startTime] ?? Accumulator(
                startTime: bucket.startTime,
                endTime: bucket.endTime
            )
            for result in bucket.results {
                let amount = result.amount?.value ?? 0
                let name = cleaned(result.lineItem) ?? "API"
                accumulator.costUSD += amount
                accumulator.lineItems[name, default: 0] += amount
            }
            buckets[bucket.startTime] = accumulator
        }
        for bucket in completions {
            var accumulator = buckets[bucket.startTime] ?? Accumulator(
                startTime: bucket.startTime,
                endTime: bucket.endTime
            )
            for result in bucket.results {
                let input = result.inputTokens ?? 0
                let cached = result.inputCachedTokens ?? 0
                let audioInput = result.inputAudioTokens ?? 0
                let output = result.outputTokens ?? 0
                let audioOutput = result.outputAudioTokens ?? 0
                let requests = result.numModelRequests ?? 0
                let total = input + audioInput + output + audioOutput
                let name = cleaned(result.model) ?? "Responses and Chat Completions"
                accumulator.requests += requests
                accumulator.inputTokens += input + audioInput
                accumulator.cachedInputTokens += cached
                accumulator.outputTokens += output + audioOutput
                accumulator.totalTokens += total
                var model = accumulator.models[name] ?? OpenAIAPIUsageSnapshot.Model(
                    name: name,
                    requests: 0,
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    totalTokens: 0
                )
                model.requests += requests
                model.inputTokens += input + audioInput
                model.cachedInputTokens += cached
                model.outputTokens += output + audioOutput
                model.totalTokens += total
                accumulator.models[name] = model
            }
            buckets[bucket.startTime] = accumulator
        }

        let daily = buckets.values
            .filter { Date(timeIntervalSince1970: TimeInterval($0.startTime)) <= now }
            .sorted { $0.startTime < $1.startTime }
            .map(\.bucket)
        return OpenAIAPIUsageSnapshot(
            daily: daily,
            updatedAt: now,
            historyDays: max(1, min(365, historyDays)),
            projectID: projectID
        )
    }

    private static func dailyRanges(now: Date, historyDays: Int) -> [DateRange] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = max(1, min(365, historyDays))
        let today = calendar.startOfDay(for: now)
        var cursor = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        var remaining = days
        var ranges: [DateRange] = []
        while remaining > 0 {
            let count = min(31, remaining)
            let end = calendar.date(byAdding: .day, value: count, to: cursor)!
            ranges.append(DateRange(
                start: Int(cursor.timeIntervalSince1970),
                end: Int(end.timeIntervalSince1970),
                limit: count
            ))
            cursor = end
            remaining -= count
        }
        return ranges
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private protocol PageResponse: Decodable {
    associatedtype Bucket
    var data: [Bucket] { get }
    var hasMore: Bool { get }
    var nextPage: String? { get }
}

private struct CostsResponse: PageResponse {
    var data: [CostBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct CostBucket: Decodable {
    var startTime: Int
    var endTime: Int
    var results: [CostResult]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct CostResult: Decodable {
    struct Amount: Decodable {
        var value: Double?

        enum CodingKeys: CodingKey { case value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decode(Double.self, forKey: .value) {
                value = number
            } else if let text = try? container.decode(String.self, forKey: .value) {
                value = Double(text)
            } else {
                value = nil
            }
        }
    }

    var amount: Amount?
    var lineItem: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case lineItem = "line_item"
    }
}

private struct CompletionsResponse: PageResponse {
    var data: [CompletionBucket]
    var hasMore: Bool
    var nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct CompletionBucket: Decodable {
    var startTime: Int
    var endTime: Int
    var results: [CompletionResult]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct CompletionResult: Decodable {
    var inputTokens: Int?
    var inputCachedTokens: Int?
    var inputAudioTokens: Int?
    var outputTokens: Int?
    var outputAudioTokens: Int?
    var numModelRequests: Int?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputTokens = "output_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case model
    }
}

private struct CreditsResponse: Decodable {
    struct Grants: Decodable {
        struct Grant: Decodable {
            var expiresAt: Date?

            enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let seconds = try container.decodeIfPresent(Double.self, forKey: .expiresAt) {
                    expiresAt = Date(timeIntervalSince1970: seconds)
                } else {
                    expiresAt = nil
                }
            }
        }

        var data: [Grant]
    }

    var totalGranted: Double
    var totalUsed: Double
    var totalAvailable: Double
    var grants: Grants?

    enum CodingKeys: String, CodingKey {
        case totalGranted = "total_granted"
        case totalUsed = "total_used"
        case totalAvailable = "total_available"
        case grants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalGranted = try container.decode(Double.self, forKey: .totalGranted)
        totalUsed = try container.decode(Double.self, forKey: .totalUsed)
        totalAvailable = try container.decode(Double.self, forKey: .totalAvailable)
        if container.contains(.grants) {
            grants = try container.decodeIfPresent(Grants.self, forKey: .grants)
        } else {
            grants = nil
        }
    }
}

private struct DateRange {
    var start: Int
    var end: Int
    var limit: Int
}

private struct Accumulator {
    var startTime: Int
    var endTime: Int
    var costUSD = 0.0
    var requests = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var lineItems: [String: Double] = [:]
    var models: [String: OpenAIAPIUsageSnapshot.Model] = [:]

    var bucket: OpenAIAPIUsageSnapshot.DailyBucket {
        OpenAIAPIUsageSnapshot.DailyBucket(
            day: Self.day(Date(timeIntervalSince1970: TimeInterval(startTime))),
            startTime: Date(timeIntervalSince1970: TimeInterval(startTime)),
            endTime: Date(timeIntervalSince1970: TimeInterval(endTime)),
            costUSD: costUSD,
            requests: requests,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            lineItems: lineItems.map { .init(name: $0.key, costUSD: $0.value) }.sorted {
                $0.costUSD == $1.costUSD ? $0.name < $1.name : $0.costUSD > $1.costUSD
            },
            models: models.values.sorted {
                $0.totalTokens == $1.totalTokens ? $0.name < $1.name : $0.totalTokens > $1.totalTokens
            }
        )
    }

    private static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
