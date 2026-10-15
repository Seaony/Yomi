import Foundation

nonisolated enum ExaUsageError: LocalizedError, Equatable {
    case missingServiceKey
    case missingAPIKeyID
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingServiceKey:
            AppLocalization.text(
                "缺少 Exa 团队管理服务密钥。请在设置中添加，或设置 EXA_SERVICE_KEY。普通搜索 API Key 不适用。",
                "Missing Exa Team Management service key. Add one in Settings or set EXA_SERVICE_KEY. Ordinary search API keys are not supported."
            )
        case .missingAPIKeyID:
            AppLocalization.text(
                "请填写要查看的 Exa API key ID，或设置 EXA_API_KEY_ID；此处需要标识符，不是密钥。",
                "Enter the Exa API key ID to monitor or set EXA_API_KEY_ID; this must be the identifier, not the secret key."
            )
        case .authenticationExpired:
            AppLocalization.text(
                "Exa 拒绝了此服务密钥。普通搜索 API Key 不适用。",
                "Exa rejected the service key. Ordinary search API keys are not supported."
            )
        case .permissionDenied:
            AppLocalization.text(
                "Exa 需要开通 Team Management，服务密钥和 API key ID 必须属于同一团队。",
                "Exa Team Management must be enabled, and the service key and API key ID must belong to the same team."
            )
        case .rateLimited:
            AppLocalization.text("Exa 请求频率受限", "Exa rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("Exa 服务暂时不可用（HTTP \(status)）", "Exa is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Exa 接口请求失败（HTTP \(status)）", "Exa API request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("无法识别 Exa 返回的 API key 用量", "Exa returned an unrecognized API key usage response")
        }
    }
}

nonisolated enum ExaUsageFetcher {
    static func fetch(
        serviceKey configuredServiceKey: String?,
        apiKeyID configuredAPIKeyID: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let serviceKey = cleaned(configuredServiceKey) ?? cleaned(environment["EXA_SERVICE_KEY"]) else {
            throw ExaUsageError.missingServiceKey
        }
        guard let apiKeyID = cleaned(configuredAPIKeyID) ?? cleaned(environment["EXA_API_KEY_ID"]),
              apiKeyID != ".", apiKeyID != "..",
              let encodedID = apiKeyID.addingPercentEncoding(withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()"
              )) else {
            throw ExaUsageError.missingAPIKeyID
        }

        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: end)!.start
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var components = URLComponents(string: "https://admin-api.exa.ai")!
        components.percentEncodedPath = "/team-management/api-keys/\(encodedID)/usage"
        components.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: start)),
            URLQueryItem(name: "end_date", value: formatter.string(from: end)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(serviceKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ExaUsageError.parseFailure }
        switch response.statusCode {
        case 200: break
        case 401: throw ExaUsageError.authenticationExpired
        case 403: throw ExaUsageError.permissionDenied
        case 429: throw ExaUsageError.rateLimited
        case 500...599: throw ExaUsageError.providerUnavailable(response.statusCode)
        default: throw ExaUsageError.apiFailure(response.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.totalCostUSD.isFinite, payload.totalCostUSD >= 0,
              date(payload.period.start) == start,
              date(payload.period.end) == end else {
            throw ExaUsageError.parseFailure
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "exa"),
            state: .ready,
            windows: [],
            details: [UsageDetail(
                id: "exa-month-spend",
                label: AppLocalization.text("此 API key 本月花费（UTC）", "API key this month (UTC)"),
                value: String(format: "$%.2f", payload.totalCostUSD)
            )],
            updatedAt: now
        )
    }

    private struct Payload: Decodable {
        struct Period: Decodable {
            let start: String
            let end: String
        }

        let totalCostUSD: Double
        let period: Period

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case period
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
