import CoreFoundation
import Foundation

nonisolated enum XAPIUsageError: LocalizedError, Equatable {
    case missingCookie
    case sessionExpired
    case permissionDenied
    case rateLimited
    case unavailable
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "缺少 X API Cookie 标头，需要包含 auth_token 和 ct0。",
                "Missing X API Cookie header containing auth_token and ct0."
            )
        case .sessionExpired:
            AppLocalization.text(
                "X API 会话已过期，请重新登录 console.x.com。",
                "X API session expired. Sign in to console.x.com again."
            )
        case .permissionDenied:
            AppLocalization.text("无法访问 X 开发者控制台。", "X developer console access was denied.")
        case .rateLimited:
            AppLocalization.text("X API 控制台请求频率受限，请稍后刷新。", "X API console is rate limited. Wait before refreshing.")
        case .unavailable:
            AppLocalization.text("X 开发者控制台暂时不可用。", "X developer console is unavailable.")
        case let .apiError(status):
            AppLocalization.text("X API 控制台请求失败（HTTP \(status)）。", "X API console request failed (HTTP \(status)).")
        case .parseFailed:
            AppLocalization.text("无法识别 X API 账号或美元余额。", "X API returned an unrecognized account or dollar balance.")
        }
    }
}

nonisolated enum XAPIUsageFetcher {
    struct Credits: Sendable, Equatable {
        let purchased: Double
        let free: Double

        var balance: Double { purchased + free }
    }

    static let baseURL = URL(string: "https://console.x.com")!

    static func fetch(
        cookie rawCookie: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let context = cookieContext(rawCookie) else { throw XAPIUsageError.missingCookie }
        let accountData = try await request(
            path: "/api/me", cookie: context.header, csrfToken: context.csrf, session: session
        )
        let account = try parseAccount(accountData)
        let creditsData = try await request(
            path: "/api/accounts/\(account)/credits",
            cookie: context.header,
            csrfToken: context.csrf,
            session: session
        )
        let credits = try parseCredits(creditsData)
        return ProviderUsage(
            id: ProviderID(rawValue: "xapi"),
            state: .ready,
            windows: [],
            balance: currency(credits.balance),
            plan: nil,
            details: [
                UsageDetail(id: "xapi-balance", label: AppLocalization.text("余额", "Balance"), value: currency(credits.balance)),
                UsageDetail(id: "xapi-purchased", label: AppLocalization.text("购买额度", "Purchased credits"), value: currency(credits.purchased)),
                UsageDetail(id: "xapi-free", label: AppLocalization.text("免费额度", "Free credits"), value: currency(credits.free)),
            ],
            updatedAt: now,
            message: nil
        )
    }

    static func parseAccount(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any] else { throw XAPIUsageError.parseFailed }
        if let id = account["id"] as? String,
           id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil {
            return id
        }
        if let id = finiteNumber(account["id"]), id >= 0, id <= 9_007_199_254_740_991,
           id.rounded(.towardZero) == id {
            return String(format: "%.0f", id)
        }
        throw XAPIUsageError.parseFailed
    }

    static func parseCredits(_ data: Data) throws -> Credits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paid = root["credits"] as? [String: Any],
              let purchased = finiteNumber(paid["balance"]) else { throw XAPIUsageError.parseFailed }
        var free = 0.0
        if root["freeCredits"] != nil {
            guard let credits = root["freeCredits"] as? [String: Any],
                  let balance = finiteNumber(credits["balance"]) else { throw XAPIUsageError.parseFailed }
            free = balance
        }
        guard (purchased + free).isFinite else { throw XAPIUsageError.parseFailed }
        return Credits(purchased: purchased, free: free)
    }

    private static func request(
        path: String,
        cookie: String,
        csrfToken: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XAPIUsageError.apiError(0) }
        switch http.statusCode {
        case 200: return data
        case 401: throw XAPIUsageError.sessionExpired
        case 403: throw XAPIUsageError.permissionDenied
        case 429: throw XAPIUsageError.rateLimited
        case 500...599: throw XAPIUsageError.unavailable
        case 400:
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let errors = root?["errors"] as? [[String: Any]],
               errors.contains(where: { finiteNumber($0["code"]) == 215 }) {
                throw XAPIUsageError.sessionExpired
            }
            throw XAPIUsageError.apiError(http.statusCode)
        default: throw XAPIUsageError.apiError(http.statusCode)
        }
    }

    private static func cookieContext(_ raw: String?) -> (header: String, csrf: String)? {
        guard var header = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return nil }
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if header.count >= 2,
           (header.hasPrefix("\"") && header.hasSuffix("\"")) || (header.hasPrefix("'") && header.hasSuffix("'")) {
            header = String(header.dropFirst().dropLast())
        }
        guard header.rangeOfCharacter(from: .newlines) == nil else { return nil }
        var values: [String: String] = [:]
        for rawPair in header.split(separator: ";") {
            let pair = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            values[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let auth = values["auth_token"], !auth.isEmpty,
              let csrf = values["ct0"], !csrf.isEmpty else { return nil }
        return (header, csrf)
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func currency(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}
