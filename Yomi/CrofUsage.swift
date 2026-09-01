import Foundation

nonisolated enum CrofUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case invalidResponse
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Crof API Key", "Missing Crof API key")
        case .unauthorized:
            AppLocalization.text("Crof API Key 无效", "The Crof API key is invalid")
        case let .apiError(status):
            AppLocalization.text("Crof 接口请求失败（HTTP \(status)）", "Crof API request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("Crof 返回内容不是对象", "The Crof response is not an object")
        case let .invalidField(field):
            AppLocalization.text("Crof 字段无效：\(field)", "Invalid Crof field: \(field)")
        }
    }
}

nonisolated struct CrofUsageSnapshot: Sendable, Equatable {
    let credits: Double
    let requestsPlan: Double?
    let usableRequests: Double?
    let requestsResetAt: Date?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let flooredCredits = floor(max(0, credits) * 100) / 100
        let creditsWindow = UsageWindow(
            id: "crof-credits",
            label: "Credits",
            usedFraction: flooredCredits > 0 ? 0 : 1,
            resetsAt: nil,
            detail: String(format: "$%.2f", flooredCredits)
        )
        guard let requestsPlan, let usableRequests else {
            return ProviderUsage(
                id: ProviderID(rawValue: "crof"),
                state: .ready,
                windows: [creditsWindow],
                plan: nil,
                details: [],
                updatedAt: updatedAt,
                message: nil
            )
        }

        let remaining = max(0, min(requestsPlan, usableRequests))
        let remainingPercent = requestsPlan > 0
            ? floor(min(100, max(0, remaining / requestsPlan * 100)))
            : 0
        let displayedRequests = max(0, usableRequests)
        let requestText = displayedRequests.rounded(.towardZero) == displayedRequests
            ? String(format: "%.0f", displayedRequests)
            : String(format: "%.2f", displayedRequests)
        let requestWindow = UsageWindow(
            id: "crof-requests",
            label: "Requests",
            usedFraction: (100 - remainingPercent) / 100,
            resetsAt: requestsResetAt,
            detail: "\(requestText) requests left"
        )
        return ProviderUsage(
            id: ProviderID(rawValue: "crof"),
            state: .ready,
            windows: [requestWindow, creditsWindow],
            plan: nil,
            details: [],
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum CrofUsageFetcher {
    static let endpoint = URL(string: "https://crof.ai/usage_api/")!
    static let environmentKeys = ["CROF_API_KEY", "CROFAI_API_KEY"]

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in environmentKeys.compactMap({ environment[$0] }) + [configured].compactMap({ $0 }) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(
        apiKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configured, environment: environment) else {
            throw CrofUsageError.missingCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CrofUsageError.invalidResponse }
        switch http.statusCode {
        case 200:
            return try parse(data, now: now).toProviderUsage()
        case 401, 403:
            throw CrofUsageError.unauthorized
        default:
            throw CrofUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> CrofUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CrofUsageError.invalidResponse
        }
        guard let credits = strictNumber(root["credits"]) else {
            throw CrofUsageError.invalidField("credits")
        }
        let requestsPlan = try optionalNumber(root["requests_plan"], field: "requests_plan")
        let usableRequests = try optionalNumber(root["usable_requests"], field: "usable_requests")
        let reset = requestsPlan != nil && usableRequests != nil ? nextChicagoMidnight(after: now) : nil
        return CrofUsageSnapshot(
            credits: credits,
            requestsPlan: requestsPlan,
            usableRequests: usableRequests,
            requestsResetAt: reset,
            updatedAt: now
        )
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        guard let number = strictNumber(value) else { throw CrofUsageError.invalidField(field) }
        return number
    }

    private static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func nextChicagoMidnight(after now: Date) -> Date? {
        guard let zone = TimeZone(identifier: "America/Chicago") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }
}
