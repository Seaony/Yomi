import CoreFoundation
import Foundation

nonisolated enum OpenRouterUsageError: LocalizedError, Equatable {
    case missingCredential
    case invalidEndpoint(String)
    case network(String)
    case apiError(endpoint: String, status: Int)
    case parseFailed(endpoint: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            AppLocalization.text("缺少 OpenRouter API Key", "Missing OpenRouter API key")
        case let .invalidEndpoint(value):
            AppLocalization.text(
                "OpenRouter 接口必须使用 HTTPS：\(value)",
                "OpenRouter endpoint must use HTTPS: \(value)"
            )
        case let .network(message):
            AppLocalization.text(
                "OpenRouter 网络错误：\(message)",
                "OpenRouter network error: \(message)"
            )
        case let .apiError(endpoint, status):
            AppLocalization.text(
                "OpenRouter \(endpoint) 请求失败（HTTP \(status)）",
                "OpenRouter \(endpoint) request failed (HTTP \(status))"
            )
        case let .parseFailed(endpoint, reason):
            AppLocalization.text(
                "无法解析 OpenRouter \(endpoint) 返回的数据：\(reason)",
                "Failed to parse OpenRouter \(endpoint) response: \(reason)"
            )
        }
    }
}

nonisolated enum OpenRouterUsageFetcher {
    struct Credits: Sendable, Equatable {
        let total: Double
        let used: Double

        var balance: Double { max(0, total - used) }
    }

    struct RateLimit: Sendable, Equatable {
        let requests: Int
        let interval: String
    }

    struct KeyUsage: Sendable, Equatable {
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?
        let cumulative: Double?
        let daily: Double?
        let weekly: Double?
        let monthly: Double?
        let rateLimit: RateLimit?

        var amountUsedForLimit: Double? {
            guard let limit, limit > 0 else { return nil }
            if let limitRemaining {
                return limit - min(limit, max(0, limitRemaining))
            }
            let periodUsage: Double? = switch limitReset?.lowercased() {
            case "daily": daily
            case "weekly": weekly
            case "monthly": monthly
            default: nil
            }
            return periodUsage ?? cumulative
        }
    }

    struct ActivityEntry: Sendable, Equatable {
        let day: String
        let model: String?
        let inputTokens: Int64
        let outputTokens: Int64
        let reasoningTokens: Int64
        let requests: Int64
        let meteredCost: Double
        let estimatedCost: Double

        var totalTokens: Int64 { inputTokens + outputTokens }
        var totalCost: Double { meteredCost + estimatedCost }
    }

    struct ActivitySummary: Sendable, Equatable {
        let entries: [ActivityEntry]
        let totalTokens: Int64
        let totalRequests: Int64
        let totalCost: Double
        let meteredCost: Double
        let estimatedCost: Double
    }

    struct Snapshot: Sendable, Equatable {
        let credits: Credits
        let keyUsage: KeyUsage?
        let keyDiagnostic: String?
        let activity: ActivitySummary?
        let activityDiagnostic: String?
        let updatedAt: Date
    }

    static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let activityURL = URL(string: "https://openrouter.ai/api/v1/activity")!
    static let apiKeyEnvironmentKey = "OPENROUTER_API_KEY"
    static let managementKeyEnvironmentKey = "OPENROUTER_MANAGEMENT_API_KEY"
    static let endpointEnvironmentKey = "OPENROUTER_API_URL"
    static let refererEnvironmentKey = "OPENROUTER_HTTP_REFERER"
    static let titleEnvironmentKey = "OPENROUTER_X_TITLE"

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        cleaned(configured) ?? cleaned(environment[apiKeyEnvironmentKey])
    }

    static func resolvedManagementKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        cleaned(configured) ?? cleaned(environment[managementKeyEnvironmentKey])
    }

    static func resolvedBaseURL(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let value = cleaned(configured) ?? cleaned(environment[endpointEnvironmentKey]) else {
            return defaultBaseURL
        }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw OpenRouterUsageError.invalidEndpoint(value) }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw OpenRouterUsageError.invalidEndpoint(value) }
        return url
    }

    static func fetch(
        apiKey: String,
        endpoint: String? = nil,
        managementAPIKey: String? = nil,
        httpReferer: String? = nil,
        clientTitle: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        language: AppLanguage = AppLocalization.currentLanguage,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let key = cleaned(apiKey)
        guard let key else { throw OpenRouterUsageError.missingCredential }
        let baseURL = try resolvedBaseURL(configured: endpoint, environment: environment)
        let title = cleaned(clientTitle) ?? cleaned(environment[titleEnvironmentKey]) ?? "Yomi"
        let referer = cleaned(httpReferer) ?? cleaned(environment[refererEnvironmentKey])

        let creditsData = try await request(
            url: baseURL.appendingPathComponent("credits"),
            token: key,
            timeout: 15,
            session: session,
            clientTitle: title,
            referer: referer,
            endpointName: "credits"
        )
        let credits = try parseCredits(creditsData)

        let keyResult = await optionalKeyUsage(
            baseURL: baseURL,
            apiKey: key,
            session: session
        )
        let managementKey = resolvedManagementKey(configured: managementAPIKey, environment: environment)
        let activityResult = await optionalActivity(
            managementAPIKey: managementKey,
            session: session,
            now: now
        )
        let snapshot = Snapshot(
            credits: credits,
            keyUsage: keyResult.value,
            keyDiagnostic: keyResult.diagnostic,
            activity: activityResult.value,
            activityDiagnostic: activityResult.diagnostic,
            updatedAt: now
        )
        return providerUsage(snapshot, language: language)
    }

    static func parseCredits(_ data: Data) throws -> Credits {
        let root = try object(data, endpoint: "credits")
        guard let payload = root["data"] as? [String: Any] else {
            throw OpenRouterUsageError.parseFailed(endpoint: "credits", reason: "data must be an object")
        }
        let total = try requiredFinite(payload["total_credits"], field: "total_credits", endpoint: "credits")
        let used = try requiredFinite(payload["total_usage"], field: "total_usage", endpoint: "credits")
        return Credits(total: total, used: used)
    }

    static func parseKeyUsage(_ data: Data) throws -> KeyUsage {
        let root = try object(data, endpoint: "key")
        guard let payload = root["data"] as? [String: Any] else {
            throw OpenRouterUsageError.parseFailed(endpoint: "key", reason: "data must be an object")
        }
        let limit = try optionalFinite(payload["limit"], field: "limit", endpoint: "key")
        let remaining = try optionalFinite(
            payload["limit_remaining"], field: "limit_remaining", endpoint: "key"
        )
        let cumulative = try optionalFinite(payload["usage"], field: "usage", endpoint: "key")
        let daily = try optionalFinite(payload["usage_daily"], field: "usage_daily", endpoint: "key")
        let weekly = try optionalFinite(payload["usage_weekly"], field: "usage_weekly", endpoint: "key")
        let monthly = try optionalFinite(payload["usage_monthly"], field: "usage_monthly", endpoint: "key")

        let reset: String?
        if payload["limit_reset"] == nil || payload["limit_reset"] is NSNull {
            reset = nil
        } else if let value = payload["limit_reset"] as? String {
            reset = value
        } else {
            throw OpenRouterUsageError.parseFailed(endpoint: "key", reason: "limit_reset must be a string")
        }

        let rateLimit: RateLimit?
        if payload["rate_limit"] == nil || payload["rate_limit"] is NSNull {
            rateLimit = nil
        } else if let value = payload["rate_limit"] as? [String: Any],
                  let requests = try optionalSafeInteger(
                      value["requests"], field: "rate_limit.requests", endpoint: "key"
                  ),
                  let interval = value["interval"] as? String {
            guard requests <= Int64(Int.max) else {
                throw OpenRouterUsageError.parseFailed(
                    endpoint: "key", reason: "rate_limit.requests is out of range"
                )
            }
            rateLimit = RateLimit(requests: Int(requests), interval: interval)
        } else {
            throw OpenRouterUsageError.parseFailed(endpoint: "key", reason: "rate_limit is invalid")
        }

        return KeyUsage(
            limit: limit,
            limitRemaining: remaining,
            limitReset: reset,
            cumulative: cumulative,
            daily: daily,
            weekly: weekly,
            monthly: monthly,
            rateLimit: rateLimit
        )
    }

    static func parseActivity(
        historyData: Data,
        latestCompletedData: Data,
        now: Date
    ) throws -> ActivitySummary {
        let latestCompleted = utcDay(now.addingTimeInterval(-86_400))
        let cutoff = utcDay(now.addingTimeInterval(-30 * 86_400))
        let historyRows = try activityRows(historyData)
        let latestRows = try activityRows(latestCompletedData)
        let rows = historyRows + latestRows
        guard rows.count <= 20_000 else {
            throw OpenRouterUsageError.parseFailed(endpoint: "activity", reason: "data exceeds 20000 rows")
        }

        var signatures: [String: String] = [:]
        var entries: [ActivityEntry] = []
        var totalTokens: Int64 = 0
        var totalRequests: Int64 = 0
        var totalCost = 0.0
        var meteredCost = 0.0
        var estimatedCost = 0.0

        for (index, row) in rows.enumerated() {
            guard let rawDate = row["date"] as? String else {
                throw activityFailure(index, "date must be YYYY-MM-DD or YYYY-MM-DD HH:MM:SS")
            }
            let trimmedDate = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAcceptedActivityDate(trimmedDate) else {
                throw activityFailure(index, "date must be YYYY-MM-DD or YYYY-MM-DD HH:MM:SS")
            }
            let day = String(trimmedDate.prefix(10))
            guard isRealUTCDay(day) else { throw activityFailure(index, "date must be a real calendar date") }
            guard day <= latestCompleted else { throw activityFailure(index, "date must be a completed UTC day") }
            if day < cutoff { continue }

            let rawModel = (row["model_permaslug"] ?? row["model"]) as? String
            let model = cleaned(rawModel)
            if let model, model.count > 64 { throw activityFailure(index, "model exceeds 64 characters") }
            let input = try requiredNonnegativeInteger(row["prompt_tokens"], index, "prompt_tokens")
            let output = try requiredNonnegativeInteger(row["completion_tokens"], index, "completion_tokens")
            let reasoning = try optionalNonnegativeInteger(row["reasoning_tokens"], index, "reasoning_tokens") ?? 0
            let requests = try requiredNonnegativeInteger(row["requests"], index, "requests")
            guard reasoning <= output else {
                throw activityFailure(index, "reasoning_tokens must not exceed completion_tokens")
            }
            let metered = try requiredFinite(row["usage"], field: "usage", endpoint: "activity")
            let estimated = try optionalFinite(
                row["byok_usage_inference"], field: "byok_usage_inference", endpoint: "activity"
            ) ?? 0
            guard metered >= 0, estimated >= 0, (metered + estimated).isFinite else {
                throw activityFailure(index, "spend must be finite and nonnegative")
            }
            let (rowTokens, rowTokenOverflow) = input.addingReportingOverflow(output)
            guard !rowTokenOverflow else { throw activityFailure(index, "token total overflowed") }

            let identity = [
                day,
                model ?? "",
                stringValue(row["endpoint_id"]),
                stringValue(row["provider_name"]),
                stringValue(row["workspace_id"]),
            ].joined(separator: "\u{1F}")
            let signature = "\(input)|\(output)|\(reasoning)|\(requests)|\(metered)|\(estimated)"
            if let previous = signatures[identity] {
                guard previous == signature else { throw activityFailure(index, "duplicate row conflicts") }
                continue
            }
            signatures[identity] = signature

            let (newTokens, tokenOverflow) = totalTokens.addingReportingOverflow(rowTokens)
            let (newRequests, requestOverflow) = totalRequests.addingReportingOverflow(requests)
            guard !tokenOverflow, !requestOverflow else {
                throw activityFailure(index, "aggregate exceeded the integer range")
            }
            totalTokens = newTokens
            totalRequests = newRequests
            meteredCost += metered
            estimatedCost += estimated
            totalCost += metered + estimated
            guard meteredCost.isFinite, estimatedCost.isFinite, totalCost.isFinite else {
                throw activityFailure(index, "spend aggregate overflowed")
            }
            entries.append(ActivityEntry(
                day: day,
                model: model,
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                requests: requests,
                meteredCost: metered,
                estimatedCost: estimated
            ))
            guard entries.count <= 10_000 else {
                throw OpenRouterUsageError.parseFailed(
                    endpoint: "activity", reason: "data exceeds 10000 distinct rows"
                )
            }
        }
        return ActivitySummary(
            entries: entries,
            totalTokens: totalTokens,
            totalRequests: totalRequests,
            totalCost: totalCost,
            meteredCost: meteredCost,
            estimatedCost: estimatedCost
        )
    }

    static func providerUsage(
        _ snapshot: Snapshot,
        language: AppLanguage = AppLocalization.currentLanguage
    ) -> ProviderUsage {
        let currency: (Double) -> String = { String(format: "$%.2f", max(0, $0)) }
        let text: (String, String) -> String = {
            AppLocalization.text($0, $1, language: language)
        }
        var windows: [UsageWindow] = []
        var details = [
            UsageDetail(
                id: "openrouter-credit-remaining", label: "Remaining", value: currency(snapshot.credits.balance)
            ),
            UsageDetail(id: "openrouter-credit-used", label: "Used", value: currency(snapshot.credits.used)),
            UsageDetail(id: "openrouter-credit-total", label: "Total added", value: currency(snapshot.credits.total)),
        ]

        if let key = snapshot.keyUsage {
            if let limit = key.limit, limit > 0 {
                details.append(UsageDetail(
                    id: "openrouter-key-limit",
                    label: "API key limit",
                    value: "\(currency(limit)) · \(text("消费上限，不是余额", "Spending cap, not balance"))"
                ))
                if let used = key.amountUsedForLimit, used >= 0 {
                    let remaining = max(0, limit - used)
                    windows.append(UsageWindow(
                        id: "openrouter-key-limit",
                        label: "API key limit",
                        usedFraction: used / limit,
                        resetsAt: nil,
                        detail: text("剩余 \(currency(remaining))", "\(currency(remaining)) left")
                    ))
                    details.append(UsageDetail(
                        id: "openrouter-key-remaining",
                        label: "API key remaining",
                        value: currency(remaining)
                    ))
                }
                if let value = key.cumulative {
                    details.append(UsageDetail(
                        id: "openrouter-key-used", label: "API key used", value: currency(value)
                    ))
                }
            } else {
                details.append(UsageDetail(
                    id: "openrouter-key-limit",
                    label: "API key limit",
                    value: text("未设置上限", "No limit configured")
                ))
            }
            if let reset = cleaned(key.limitReset) {
                details.append(UsageDetail(id: "openrouter-key-reset", label: "Reset window", value: reset))
            }
            for (id, label, value) in [
                ("daily", "Today", key.daily),
                ("weekly", "This week", key.weekly),
                ("monthly", "This month", key.monthly),
            ] {
                guard let value else { continue }
                details.append(UsageDetail(
                    id: "openrouter-key-\(id)", label: label, value: currency(value)
                ))
            }
            if let rate = key.rateLimit {
                details.append(UsageDetail(
                    id: "openrouter-rate-limit",
                    label: "Rate limit",
                    value: text("\(rate.requests) 次请求 / \(rate.interval)", "\(rate.requests) requests / \(rate.interval)")
                ))
            }
        }

        let providerCost: ProviderCostSummary?
        let last30Days: DailyTokenUsage?
        if let activity = snapshot.activity {
            providerCost = ProviderCostSummary(
                used: activity.totalCost,
                limit: 0,
                currencyCode: "USD",
                period: text("最近 30 天", "Last 30 days"),
                balance: snapshot.credits.balance
            )
            last30Days = DailyTokenUsage(tokens: activity.totalTokens, valueUSD: activity.totalCost)
            details.append(UsageDetail(
                id: "openrouter-history-requests",
                label: "Last 30 days requests",
                value: activity.totalRequests.formatted()
            ))
        } else {
            providerCost = nil
            last30Days = nil
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "openrouter"),
            state: .ready,
            windows: windows,
            additionalWindows: [],
            balance: currency(snapshot.credits.balance),
            plan: nil,
            last30Days: last30Days,
            providerCost: providerCost,
            details: details,
            updatedAt: snapshot.updatedAt,
            message: nil
        )
    }

    private static func optionalKeyUsage(
        baseURL: URL,
        apiKey: String,
        session: URLSession
    ) async -> (value: KeyUsage?, diagnostic: String?) {
        do {
            let data = try await request(
                url: baseURL.appendingPathComponent("key"),
                token: apiKey,
                timeout: 1,
                session: session,
                clientTitle: nil,
                referer: nil,
                endpointName: "key"
            )
            return (try parseKeyUsage(data), nil)
        } catch {
            return (nil, degradation(for: error, management: false))
        }
    }

    private static func optionalActivity(
        managementAPIKey: String?,
        session: URLSession,
        now: Date
    ) async -> (value: ActivitySummary?, diagnostic: String?) {
        guard let managementAPIKey else { return (nil, "Management API key not configured") }
        let latestCompleted = utcDay(now.addingTimeInterval(-86_400))
        var datedComponents = URLComponents(url: activityURL, resolvingAgainstBaseURL: false)!
        datedComponents.queryItems = [URLQueryItem(name: "date", value: latestCompleted)]
        guard let datedURL = datedComponents.url else { return (nil, "Response was invalid") }
        do {
            async let historyData = request(
                url: activityURL,
                token: managementAPIKey,
                timeout: 1,
                session: session,
                clientTitle: nil,
                referer: nil,
                endpointName: "activity"
            )
            async let latestData = request(
                url: datedURL,
                token: managementAPIKey,
                timeout: 1,
                session: session,
                clientTitle: nil,
                referer: nil,
                endpointName: "activity"
            )
            return (try await parseActivity(
                historyData: historyData,
                latestCompletedData: latestData,
                now: now
            ), nil)
        } catch {
            return (nil, degradation(for: error, management: true))
        }
    }

    private static func request(
        url: URL,
        token: String,
        timeout: TimeInterval,
        session: URLSession,
        clientTitle: String?,
        referer: String?,
        endpointName: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientTitle { request.setValue(clientTitle, forHTTPHeaderField: "X-Title") }
        if let referer { request.setValue(referer, forHTTPHeaderField: "HTTP-Referer") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw OpenRouterUsageError.network(error.code == .timedOut ? "Request timed out" : error.code.rawValue.description)
        } catch {
            throw OpenRouterUsageError.network("Request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterUsageError.network("Invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            throw OpenRouterUsageError.apiError(endpoint: endpointName, status: http.statusCode)
        }
        return data
    }

    private static func object(_ data: Data, endpoint: String) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenRouterUsageError.parseFailed(endpoint: endpoint, reason: "root must be an object")
            }
            return object
        } catch let error as OpenRouterUsageError {
            throw error
        } catch {
            throw OpenRouterUsageError.parseFailed(endpoint: endpoint, reason: "response was not valid JSON")
        }
    }

    private static func activityRows(_ data: Data) throws -> [[String: Any]] {
        let root = try object(data, endpoint: "activity")
        guard let rows = root["data"] as? [Any] else {
            throw OpenRouterUsageError.parseFailed(endpoint: "activity", reason: "data must be an array")
        }
        return try rows.enumerated().map { index, value in
            guard let row = value as? [String: Any] else { throw activityFailure(index, "row must be an object") }
            return row
        }
    }

    private static func requiredFinite(
        _ value: Any?, field: String, endpoint: String
    ) throws -> Double {
        guard let result = try optionalFinite(value, field: field, endpoint: endpoint) else {
            throw OpenRouterUsageError.parseFailed(endpoint: endpoint, reason: "\(field) is required")
        }
        return result
    }

    private static func optionalFinite(
        _ value: Any?, field: String, endpoint: String
    ) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            throw OpenRouterUsageError.parseFailed(endpoint: endpoint, reason: "\(field) must be a finite number")
        }
        return number.doubleValue
    }

    private static func optionalSafeInteger(
        _ value: Any?, field: String, endpoint: String
    ) throws -> Int64? {
        guard let number = try optionalFinite(value, field: field, endpoint: endpoint) else { return nil }
        guard number >= 0, number.rounded() == number, number <= 9_007_199_254_740_991 else {
            throw OpenRouterUsageError.parseFailed(
                endpoint: endpoint, reason: "\(field) must be a nonnegative safe integer"
            )
        }
        guard number <= Double(Int64.max) else {
            throw OpenRouterUsageError.parseFailed(endpoint: endpoint, reason: "\(field) is out of range")
        }
        return Int64(number)
    }

    private static func requiredNonnegativeInteger(
        _ value: Any?, _ index: Int, _ field: String
    ) throws -> Int64 {
        do {
            guard let number = try optionalSafeInteger(value, field: field, endpoint: "activity") else {
                throw activityFailure(index, "\(field) is required")
            }
            return number
        } catch let error as OpenRouterUsageError {
            if case let .parseFailed(_, reason) = error { throw activityFailure(index, reason) }
            throw error
        }
    }

    private static func optionalNonnegativeInteger(
        _ value: Any?, _ index: Int, _ field: String
    ) throws -> Int64? {
        do {
            return try optionalSafeInteger(value, field: field, endpoint: "activity")
        } catch let error as OpenRouterUsageError {
            if case let .parseFailed(_, reason) = error { throw activityFailure(index, reason) }
            throw error
        }
    }

    private static func activityFailure(_ index: Int, _ reason: String) -> OpenRouterUsageError {
        .parseFailed(endpoint: "activity", reason: "data[\(index)].\(reason)")
    }

    private static func degradation(for error: Error, management: Bool) -> String {
        switch error {
        case let OpenRouterUsageError.apiError(_, status):
            if management, status == 403 { return "Management API key required" }
            return "Request returned HTTP \(status)"
        case let OpenRouterUsageError.network(message):
            return message == "Request timed out" ? message : "Request failed"
        case OpenRouterUsageError.parseFailed:
            return "Response was invalid"
        default:
            return "Request failed"
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isAcceptedActivityDate(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}:\d{2})?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isRealUTCDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func stringValue(_ value: Any?) -> String {
        value is NSNull ? "" : (value as? String ?? "")
    }
}
