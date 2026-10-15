import Foundation

nonisolated enum TinyApiUsageError: LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case rateLimited
    case providerUnavailable(Int)
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "请登录 tinyapi.rest 并粘贴 Cookie 标头",
                "Sign in to tinyapi.rest and paste a Cookie header."
            )
        case .sessionExpired:
            AppLocalization.text("TinyApi 会话已过期，请重新登录", "The TinyApi session expired. Sign in again.")
        case .rateLimited:
            AppLocalization.text("TinyApi 请求频率受限", "TinyApi rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("TinyApi 服务暂时不可用（HTTP \(status)）", "TinyApi is unavailable (HTTP \(status))")
        case let .requestFailed(status):
            AppLocalization.text("TinyApi 余额请求失败（HTTP \(status)）", "TinyApi credits request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("TinyApi 未返回有效的积分余额", "TinyApi did not return a valid available credit balance")
        }
    }
}

nonisolated enum TinyApiUsageFetcher {
    private struct Envelope: Decodable {
        struct Credits: Decodable {
            let totalAvailable: Double
        }

        let success: Bool
        let data: Credits
    }

    static let creditsURL = URL(string: "https://tinyapi.rest/api/user/credits")!

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .cookie || source == .automatic,
              let cookie = normalizedCookie(credential) else {
            throw TinyApiUsageError.missingSession
        }
        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TinyApiUsageError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw TinyApiUsageError.sessionExpired
        case 429: throw TinyApiUsageError.rateLimited
        case 500...599: throw TinyApiUsageError.providerUnavailable(http.statusCode)
        default: throw TinyApiUsageError.requestFailed(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.success,
              envelope.data.totalAvailable.isFinite,
              envelope.data.totalAvailable >= 0 else {
            throw TinyApiUsageError.invalidResponse
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        let value = envelope.data.totalAvailable
        let amount = formatter.string(from: NSNumber(value: value)) ?? String(value)
        let balance = AppLocalization.text("\(amount) 积分", "\(amount) credits")
        return ProviderUsage(
            id: ProviderID(rawValue: "tinyapi"),
            state: .ready,
            windows: [],
            balance: balance,
            details: [UsageDetail(
                id: "tinyapi-available-credits",
                label: AppLocalization.text("可用积分", "Available credits"),
                value: balance
            )],
            updatedAt: now,
            message: nil
        )
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, value.contains("="), !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }
}
