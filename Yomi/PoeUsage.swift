import Foundation

nonisolated enum PoeUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Poe API Key", "Missing Poe API key")
        case .unauthorized:
            AppLocalization.text("Poe API Key 无效或已过期", "The Poe API key is invalid or expired")
        case let .apiError(status):
            AppLocalization.text("Poe 接口请求失败（HTTP \(status)）", "Poe API request failed (HTTP \(status))")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Poe 用量：\(message)", "Failed to parse Poe usage: \(message)")
        }
    }
}

nonisolated enum PoeUsageFetcher {
    struct Entry: Sendable, Equatable {
        let date: Date
        let points: Double
        let costUSD: Double?
    }

    private struct Summary {
        var points = 0.0
        var requests = 0
        var cost = 0.0
        var hasCost = false
    }

    static let balanceURL = URL(string: "https://api.poe.com/usage/current_balance")!
    static let historyURL = URL(string: "https://api.poe.com/usage/points_history")!

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configured) ?? cleaned(environment["POE_API_KEY"]) else {
            throw PoeUsageError.missingCredentials
        }
        let balanceData = try await responseData(url: balanceURL, apiKey: apiKey, session: session)
        let balance = try parseBalance(balanceData)
        let entries = (try? await fetchHistory(apiKey: apiKey, session: session, now: now)) ?? []
        return providerUsage(balance: balance, entries: entries, now: now)
    }

    static func parseBalance(_ data: Data) throws -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoeUsageError.parseFailed("balance response is not an object")
        }
        return try optionalNumber(root["current_point_balance"], field: "current_point_balance")
    }

    static func parseHistoryPage(_ data: Data, cutoff: Date) throws -> (entries: [Entry], cursor: String?, oldest: Date?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoeUsageError.parseFailed("history response is not an object")
        }
        let rows = (root["data"] as? [Any])
            ?? (root["items"] as? [Any])
            ?? (root["results"] as? [Any])
            ?? []
        var entries: [Entry] = []
        var oldest: Date?
        for case let row as [String: Any] in rows {
            let date = entryDate(row["creation_time"] ?? row["timestamp"] ?? row["created_at"])
            if let date, oldest == nil || date < oldest! { oldest = date }
            guard let date, date >= cutoff else { continue }
            let points = max(0, try optionalNumber(
                row["cost_points"] ?? row["points"] ?? row["point_cost"],
                field: "points"
            ) ?? 0)
            let cost = try optionalNumber(row["cost_usd"] ?? row["usd"], field: "cost_usd")
            entries.append(Entry(date: date, points: points, costUSD: cost))
        }
        let explicitCursor = nonempty(root["next_cursor"] as? String)
        let fallbackCursor: String? = if explicitCursor == nil,
                                        root["has_more"] as? Bool == true,
                                        let last = rows.last as? [String: Any] {
            nonempty(last["query_id"] as? String)
        } else {
            nil
        }
        return (entries, explicitCursor ?? fallbackCursor, oldest)
    }

    static func providerUsage(balance: Double?, entries: [Entry], now: Date) -> ProviderUsage {
        var details: [UsageDetail] = []
        if let balance {
            details.append(UsageDetail(
                id: "poe-current-balance",
                label: "Current balance",
                value: "\(compact(balance)) points"
            ))
        }
        if !entries.isEmpty {
            let calendar = utcCalendar
            let grouped = Dictionary(grouping: entries) { entry in
                calendar.startOfDay(for: entry.date)
            }
            let orderedDays = grouped.keys.sorted()
            let summaries = Dictionary(uniqueKeysWithValues: grouped.map { day, values in
                (day, summarize(values))
            })
            let today = summarize(grouped[calendar.startOfDay(for: now)] ?? [])
            let seven = summarizeDays(Array(orderedDays.suffix(7)), summaries: summaries)
            let thirty = summarizeDays(Array(orderedDays.suffix(30)), summaries: summaries)
            details.append(summaryDetail(id: "poe-today", label: "Today", summary: today))
            details.append(summaryDetail(id: "poe-seven", label: "Last 7 days", summary: seven))
            details.append(summaryDetail(id: "poe-thirty", label: "Last 30 days", summary: thirty))

        }
        return ProviderUsage(
            id: ProviderID(rawValue: "poe"),
            state: .ready,
            windows: [],
            balance: balance.map { "\(compact($0)) points" },
            plan: nil,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func fetchHistory(apiKey: String, session: URLSession, now: Date) async throws -> [Entry] {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        var entries: [Entry] = []
        var cursor: String?
        for _ in 0..<5 {
            var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { items.append(URLQueryItem(name: "starting_after", value: cursor)) }
            components.queryItems = items
            let data = try await responseData(url: components.url!, apiKey: apiKey, session: session)
            let page = try parseHistoryPage(data, cutoff: cutoff)
            entries.append(contentsOf: page.entries)
            cursor = page.cursor
            if cursor == nil || page.oldest.map({ $0 < cutoff }) == true { break }
        }
        return entries
    }

    private static func responseData(url: URL, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PoeUsageError.parseFailed("invalid response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw PoeUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw PoeUsageError.apiError(http.statusCode) }
        return data
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        let number: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            number = nil
        }
        guard let number, number.isFinite else { throw PoeUsageError.parseFailed("\(field) must be numeric") }
        return number
    }

    private static func entryDate(_ value: Any?) -> Date? {
        if let number = try? optionalNumber(value, field: "date") {
            if number > 100_000_000_000_000 { return Date(timeIntervalSince1970: number / 1_000_000) }
            if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1_000) }
            return Date(timeIntervalSince1970: number)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func summarize(_ entries: [Entry]) -> Summary {
        entries.reduce(into: Summary()) { result, entry in
            result.points += entry.points
            result.requests += 1
            if let cost = entry.costUSD {
                result.cost += max(0, cost)
                result.hasCost = true
            }
        }
    }

    private static func summarizeDays(_ days: [Date], summaries: [Date: Summary]) -> Summary {
        days.reduce(into: Summary()) { total, day in
            guard let value = summaries[day] else { return }
            total.points += value.points
            total.requests += value.requests
            if value.hasCost {
                total.cost += value.cost
                total.hasCost = true
            }
        }
    }

    private static func summaryDetail(id: String, label: String, summary: Summary) -> UsageDetail {
        var value = "\(compact(summary.points)) points · \(summary.requests) requests"
        if summary.hasCost { value += String(format: " · $%.2f", summary.cost) }
        return UsageDetail(id: id, label: label, value: value)
    }

    private static func compact(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1_000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func nonempty(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
