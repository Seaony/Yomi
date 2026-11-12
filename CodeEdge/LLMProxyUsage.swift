import Foundation

nonisolated enum LLMProxyUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingBaseURL
    case invalidBaseURL
    case apiError(Int, String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 LLM Proxy API Key", "Missing LLM Proxy API key")
        case .missingBaseURL:
            AppLocalization.text("缺少 LLM Proxy Base URL", "Missing LLM Proxy base URL")
        case .invalidBaseURL:
            AppLocalization.text("LLM Proxy Base URL 无效", "Invalid LLM Proxy base URL")
        case let .apiError(status, message):
            AppLocalization.text("LLM Proxy 接口错误（HTTP \(status)）：\(message)", "LLM Proxy API error (HTTP \(status)): \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 LLM Proxy 用量：\(message)", "Failed to parse LLM Proxy usage: \(message)")
        }
    }
}

nonisolated enum LLMProxyUsageFetcher {
    private struct Response: Decodable {
        struct Provider: Decodable {
            struct Tokens: Decodable {
                let inputCached: Int?
                let inputUncached: Int?
                let output: Int?
                enum CodingKeys: String, CodingKey {
                    case inputCached = "input_cached"
                    case inputUncached = "input_uncached"
                    case output
                }
            }
            struct Quota: Decodable {
                let remainingPercent: Double?
                let resetTime: String?
                enum CodingKeys: String, CodingKey {
                    case remainingPercent = "remaining_percent"
                    case resetTime = "reset_time"
                }
            }
            let credentialCount: Int?
            let activeCount: Int?
            let exhaustedCount: Int?
            let totalRequests: Int?
            let tokens: Tokens?
            let approximateCost: Double?
            let quotaGroups: [Quota]?
            enum CodingKeys: String, CodingKey {
                case credentialCount = "credential_count"
                case activeCount = "active_count"
                case exhaustedCount = "exhausted_count"
                case totalRequests = "total_requests"
                case tokens
                case approximateCost = "approx_cost"
                case quotaGroups = "quota_groups"
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                credentialCount = try values.decodeIfPresent(Int.self, forKey: .credentialCount)
                activeCount = try values.decodeIfPresent(Int.self, forKey: .activeCount)
                exhaustedCount = try values.decodeIfPresent(Int.self, forKey: .exhaustedCount)
                totalRequests = try values.decodeIfPresent(Int.self, forKey: .totalRequests)
                tokens = try values.decodeIfPresent(Tokens.self, forKey: .tokens)
                approximateCost = try values.decodeIfPresent(Double.self, forKey: .approximateCost)
                if let array = try? values.decodeIfPresent([Quota].self, forKey: .quotaGroups) {
                    quotaGroups = array
                } else {
                    quotaGroups = try? values.decodeIfPresent([String: Quota].self, forKey: .quotaGroups)?.values.map { $0 }
                }
            }
        }
        struct Summary: Decodable {
            let totalRequests: Int?
            let approximateCost: Double?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case totalRequests = "total_requests"
                case approximateCost = "approx_cost"
                case totalTokens = "total_tokens"
            }
        }
        let providers: [String: Provider]
        let summary: Summary?
    }

    struct ProviderSummary: Sendable, Equatable {
        let requests: Int
        let tokens: Int
        let cost: Double?
    }

    static func fetch(
        apiKey configuredKey: String?,
        endpointOverride configuredBaseURL: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let key = cleaned(configuredKey) ?? cleaned(environment["LLM_PROXY_API_KEY"]) else {
            throw LLMProxyUsageError.missingCredentials
        }
        guard let rawBaseURL = cleaned(configuredBaseURL) ?? cleaned(environment["LLM_PROXY_BASE_URL"]) else {
            throw LLMProxyUsageError.missingBaseURL
        }
        guard let baseURL = ProviderEndpointValidator.privateNetworkURL(rawBaseURL) else {
            throw LLMProxyUsageError.invalidBaseURL
        }
        var request = URLRequest(url: quotaStatsURL(baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMProxyUsageError.apiError(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            let summary = String(data: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LLMProxyUsageError.apiError(http.statusCode, summary)
        }
        return try parse(data, now: now)
    }

    static func quotaStatsURL(_ baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versioned = path.split(separator: "/").last == "v1"
            ? baseURL
            : baseURL.appendingPathComponent("v1")
        return versioned.appendingPathComponent("quota-stats")
    }

    static func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw LLMProxyUsageError.parseFailed(error.localizedDescription) }
        var summaries: [ProviderSummary] = []
        for provider in decoded.providers.values {
            let inputCached = provider.tokens?.inputCached ?? 0
            let inputUncached = provider.tokens?.inputUncached ?? 0
            let output = provider.tokens?.output ?? 0
            summaries.append(ProviderSummary(
                requests: provider.totalRequests ?? 0,
                tokens: inputCached + inputUncached + output,
                cost: provider.approximateCost
            ))
        }
        let requests = decoded.summary?.totalRequests ?? summaries.reduce(0) { $0 + $1.requests }
        let tokens = decoded.summary?.totalTokens ?? summaries.reduce(0) { $0 + $1.tokens }
        let fallbackCost = summaries.compactMap { $0.cost }.reduce(0.0, +)
        let cost = decoded.summary?.approximateCost ?? (fallbackCost > 0 ? fallbackCost : nil)
        let quotas = decoded.providers.values.flatMap { $0.quotaGroups ?? [] }
        let minimumRemaining = quotas.compactMap { $0.remainingPercent }.min()
        let reset = quotas.compactMap { date($0.resetTime) }.filter { $0 > now }.min()
        var windows: [UsageWindow] = []
        if let minimumRemaining {
            windows.append(UsageWindow(
                id: "llmproxy-quota",
                label: "Quota",
                usedFraction: min(max((100 - minimumRemaining) / 100, 0), 1),
                resetsAt: reset,
                detail: nil
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "llmproxy"),
            state: .ready,
            windows: windows,
            providerCost: cost.map {
                ProviderCostSummary(used: $0, limit: 0, currencyCode: "USD", period: "Approx. spend")
            },
            details: [
                UsageDetail(id: "llmproxy-requests", label: "Requests", value: formatted(requests)),
                UsageDetail(id: "llmproxy-tokens", label: "Tokens", value: formatted(tokens)),
            ],
            updatedAt: now
        )
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
