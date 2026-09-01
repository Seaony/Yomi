import Foundation

nonisolated enum AiAndUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case insufficientCredits
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 ai& API Key", "Missing ai& API key")
        case .unauthorized:
            AppLocalization.text("ai& API Key 无效", "The ai& API key was rejected")
        case .insufficientCredits:
            AppLocalization.text("ai& 组织额度已用尽", "The ai& organization is out of credits")
        case .rateLimited:
            AppLocalization.text("ai& 请求过于频繁", "The ai& rate limit was exceeded")
        case let .apiError(status):
            AppLocalization.text("ai& 接口请求失败（HTTP \(status)）", "The ai& API returned HTTP \(status)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 ai& 用量：\(message)", "Failed to parse ai& usage: \(message)")
        }
    }
}

nonisolated enum AiAndUsageFetcher {
    struct Spend: Sendable, Equatable {
        let amount: Decimal
        let currencyCode: String
    }

    struct Snapshot: Sendable, Equatable {
        let spend: Spend?
        let isComplete: Bool
        let updatedAt: Date

        func toProviderUsage() -> ProviderUsage {
            ProviderUsage(
                id: ProviderID(rawValue: "aiand"),
                state: .ready,
                windows: [],
                providerCost: spend.map {
                    ProviderCostSummary(
                        used: NSDecimalNumber(decimal: $0.amount).doubleValue,
                        limit: 0,
                        currencyCode: $0.currencyCode,
                        period: isComplete ? "Last 30 days" : "Last 30 days (partial)"
                    )
                },
                updatedAt: updatedAt
            )
        }
    }

    private struct LogsEnvelope: Decodable {
        struct Row: Decodable {
            let cost: String?
            let currency: String?
        }

        let data: [Row]
        let hasMore: Bool?
        let nextAfter: String?
        let nextAfterID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case nextAfter = "next_after"
            case nextAfterID = "next_after_id"
        }
    }

    static let logsBaseURL = URL(string: "https://api.aiand.com/logs")!
    static let pageLimit = 100
    static let maxPages = 10

    static func fetch(
        apiKey rawAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(rawAPIKey) ?? cleaned(environment["AIAND_API_KEY"]) else {
            throw AiAndUsageError.missingCredentials
        }
        var rows: [LogsEnvelope.Row] = []
        var after: String?
        var afterID: String?
        var isComplete = false
        for _ in 0..<maxPages {
            let page = try await fetchPage(
                apiKey: apiKey,
                after: after,
                afterID: afterID,
                session: session
            )
            rows.append(contentsOf: page.data)
            if page.hasMore != true {
                isComplete = true
                break
            }
            guard let nextAfter = page.nextAfter, let nextAfterID = page.nextAfterID else { break }
            after = nextAfter
            afterID = nextAfterID
        }
        return summarize(rows: rows, isComplete: isComplete, now: now).toProviderUsage()
    }

    private static func fetchPage(
        apiKey: String,
        after: String?,
        afterID: String?,
        session: URLSession
    ) async throws -> LogsEnvelope {
        var request = URLRequest(url: logsURL(after: after, afterID: afterID))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AiAndUsageError.apiError(0) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw AiAndUsageError.unauthorized
        case 402: throw AiAndUsageError.insufficientCredits
        case 429: throw AiAndUsageError.rateLimited
        default: throw AiAndUsageError.apiError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(LogsEnvelope.self, from: data)
        } catch {
            throw AiAndUsageError.parseFailed(error.localizedDescription)
        }
    }

    static func logsURL(after: String?, afterID: String?) -> URL {
        var components = URLComponents(url: logsBaseURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "range", value: "30days"),
            URLQueryItem(name: "limit", value: String(pageLimit)),
        ]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private static func summarize(
        rows: [LogsEnvelope.Row],
        isComplete: Bool,
        now: Date
    ) -> Snapshot {
        var currency: String?
        var total = Decimal.zero
        for row in rows {
            guard let rawCost = row.cost,
                  let cost = Decimal(string: rawCost, locale: Locale(identifier: "en_US_POSIX")),
                  let rowCurrency = cleaned(row.currency)?.lowercased()
            else { continue }
            if currency == nil { currency = rowCurrency }
            guard currency == rowCurrency else { continue }
            total += cost
        }
        return Snapshot(
            spend: currency.map { Spend(amount: total, currencyCode: $0.uppercased()) },
            isComplete: isComplete,
            updatedAt: now
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
