import Foundation

nonisolated enum XAIUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingTeamID
    case invalidTeamID
    case unauthorized
    case rateLimited
    case apiFailure(Int)
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: AppLocalization.text("缺少 xAI Management API Key", "Missing xAI Management API key")
        case .missingTeamID: AppLocalization.text("缺少 xAI Team ID", "Missing xAI team ID")
        case .invalidTeamID: AppLocalization.text("xAI Team ID 不能包含路径分隔符", "The xAI team ID cannot contain path separators")
        case .unauthorized: AppLocalization.text("xAI 拒绝了 Management API Key", "xAI rejected the Management API key")
        case .rateLimited: AppLocalization.text("xAI Management API 请求频率受限", "xAI Management API rate limit reached")
        case let .apiFailure(status): AppLocalization.text("xAI 请求失败（HTTP \(status)）", "xAI request failed (HTTP \(status))")
        case let .parseFailure(message): AppLocalization.text("无法解析 xAI 账单：\(message)", "Failed to parse xAI billing: \(message)")
        }
    }
}

nonisolated enum XAIUsageFetcher {
    struct DailySpend: Sendable, Equatable {
        let day: String
        let value: Double
    }

    static let baseURL = URL(string: "https://management-api.x.ai/v1/billing/teams")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        teamID configuredTeamID: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["XAI_MANAGEMENT_API_KEY"]) else {
            throw XAIUsageError.missingCredentials
        }
        guard let teamID = cleaned(configuredTeamID) ?? cleaned(environment["XAI_TEAM_ID"]) else {
            throw XAIUsageError.missingTeamID
        }
        guard teamID != ".", teamID != "..", !teamID.contains("/") else { throw XAIUsageError.invalidTeamID }
        let teamURL = baseURL.appendingPathComponent(teamID)
        let balanceData = try await request(
            teamURL.appendingPathComponent("prepaid/balance"),
            method: "GET",
            apiKey: apiKey,
            body: nil,
            session: session,
            required: true
        )
        let balance = try parseBalance(balanceData)

        let history: (daily: [DailySpend], partial: Bool)?
        do {
            let body = try historyBody(now: now)
            let data = try await request(
                teamURL.appendingPathComponent("usage"),
                method: "POST",
                apiKey: apiKey,
                body: body,
                session: session,
                required: false
            )
            history = try parseHistory(data)
        } catch XAIUsageError.unauthorized {
            throw XAIUsageError.unauthorized
        } catch {
            history = nil
        }
        return providerUsage(balance: balance, history: history, now: now)
    }

    static func parseBalance(_ data: Data) throws -> Double {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["total"] as? [String: Any],
              let raw = total["val"] as? String else {
            throw XAIUsageError.parseFailure("balance total.val is missing")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              let cents = Double(value), cents.isFinite else {
            throw XAIUsageError.parseFailure("balance total.val is not a cent amount")
        }
        return -cents / 100
    }

    static func parseHistory(_ data: Data) throws -> (daily: [DailySpend], partial: Bool) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let series = root["timeSeries"] as? [Any] else {
            throw XAIUsageError.parseFailure("usage history is invalid")
        }
        var totals: [String: Double] = [:]
        for rawSeries in series {
            guard let object = rawSeries as? [String: Any], let points = object["dataPoints"] as? [Any] else {
                throw XAIUsageError.parseFailure("usage history is invalid")
            }
            for rawPoint in points {
                guard let point = rawPoint as? [String: Any],
                      let timestamp = point["timestamp"] as? String,
                      let date = isoDate(timestamp),
                      let values = point["values"] as? [Any],
                      let number = values.first as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue >= 0 else {
                    throw XAIUsageError.parseFailure("usage history is invalid")
                }
                totals[utcDay(date), default: 0] += number.doubleValue
            }
        }
        return (
            totals.keys.sorted().map { DailySpend(day: $0, value: totals[$0] ?? 0) },
            root["limitReached"] as? Bool == true
        )
    }

    static func historyBody(now: Date) throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let startDate = calendar.date(byAdding: .day, value: -29, to: now) else {
            throw XAIUsageError.parseFailure("invalid date range")
        }
        let start = calendar.startOfDay(for: startDate)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try JSONSerialization.data(withJSONObject: [
            "analyticsRequest": [
                "timeRange": [
                    "startTime": formatter.string(from: start),
                    "endTime": formatter.string(from: now),
                    "timezone": "Etc/GMT",
                ],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": [],
                "filters": [],
            ],
        ])
    }

    static func providerUsage(
        balance: Double,
        history: (daily: [DailySpend], partial: Bool)?,
        now: Date
    ) -> ProviderUsage {
        let total = history?.daily.reduce(0) { $0 + $1.value } ?? 0
        var details = [UsageDetail(
            id: "xai-prepaid-balance",
            label: AppLocalization.text("预付余额", "Prepaid balance"),
            value: String(format: "$%.2f", balance)
        )]
        if let history {
            details.append(UsageDetail(
                id: "xai-history",
                label: history.partial
                    ? AppLocalization.text("最近 30 天（部分）", "Last 30 days (partial)")
                    : AppLocalization.text("最近 30 天", "Last 30 days"),
                value: String(format: "$%.2f", total)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "xai"),
            state: .ready,
            windows: [],
            balance: String(format: "$%.2f", balance),
            plan: nil,
            providerCost: ProviderCostSummary(
                used: balance,
                limit: 0,
                currencyCode: "USD",
                period: "Prepaid credits",
                balance: balance
            ),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func request(
        _ url: URL,
        method: String,
        apiKey: String,
        body: Data?,
        session: URLSession,
        required: Bool
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XAIUsageError.apiFailure(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw XAIUsageError.unauthorized }
        if http.statusCode == 429 { throw XAIUsageError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            if required || http.statusCode < 500 { throw XAIUsageError.apiFailure(http.statusCode) }
            throw XAIUsageError.apiFailure(http.statusCode)
        }
        return data
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
    private static func isoDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
