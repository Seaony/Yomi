import Foundation
import SweetCookieKit

nonisolated enum AbacusUsageError: LocalizedError, Equatable {
    case noSessionCookie
    case sessionExpired
    case networkError(String)
    case parseFailed(String)
    case unauthorized

    var shouldTryNextImportedSession: Bool {
        switch self {
        case .unauthorized, .sessionExpired, .networkError, .parseFailed: true
        case .noSessionCookie: false
        }
    }

    var shouldClearCachedCookie: Bool {
        switch self {
        case .unauthorized, .sessionExpired, .parseFailed: true
        case .networkError, .noSessionCookie: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            AppLocalization.text(
                "未找到 Abacus 会话，请先登录 apps.abacus.ai 或手动粘贴 Cookie 标头",
                "No Abacus session was found. Sign in to apps.abacus.ai or paste a Cookie header."
            )
        case .sessionExpired:
            AppLocalization.text("Abacus 会话已过期，请重新登录", "The Abacus session expired. Sign in again.")
        case let .networkError(message):
            AppLocalization.text("Abacus 接口错误：\(message)", "Abacus API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Abacus 用量：\(message)", "Could not parse Abacus usage: \(message)")
        case .unauthorized:
            AppLocalization.text("Abacus 未授权，请重新登录", "Abacus is unauthorized. Sign in again.")
        }
    }
}

nonisolated struct AbacusUsageSnapshot: Sendable, Equatable {
    let creditsUsed: Double?
    let creditsTotal: Double?
    let resetsAt: Date?
    let planName: String?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        let fraction: Double
        if let creditsUsed, let creditsTotal, creditsTotal > 0 {
            fraction = min(1, max(0, creditsUsed / creditsTotal))
        } else {
            fraction = 0
        }
        let detail: String?
        if let creditsUsed, let creditsTotal {
            detail = "\(Self.formatCredits(creditsUsed)) / \(Self.formatCredits(creditsTotal)) credits"
        } else {
            detail = nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "abacus"),
            state: .ready,
            windows: [UsageWindow(
                id: "abacus-credits",
                label: "Credits",
                usedFraction: fraction,
                resetsAt: resetsAt,
                detail: detail
            )],
            balance: nil,
            plan: planName,
            updatedAt: updatedAt,
            message: nil
        )
    }

    static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1_000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}

nonisolated enum AbacusUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    private struct JSONDictionaryBox: @unchecked Sendable {
        let value: [String: Any]
    }

    static let computePointsURL = URL(string: "https://apps.abacus.ai/api/_getOrganizationComputePoints")!
    static let billingInfoURL = URL(string: "https://apps.abacus.ai/api/_getBillingInfo")!
    private static let cookieDomains = ["abacus.ai", "apps.abacus.ai"]
    private static let knownSessionCookieNames: Set<String> = [
        "sessionid", "session_id", "session_token", "auth_token", "access_token",
    ]
    private static let sessionCookieSubstrings = ["session", "auth", "sid", "jwt"]
    private static let excludedCookiePrefixes = ["csrf", "_ga", "_gid", "tracking", "analytics"]

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if source == .cookie {
            guard let cookie = normalizedCookie(credential) else { throw AbacusUsageError.noSessionCookie }
            return try await fetchWithCookieHeader(cookie, session: session, now: now).toProviderUsage()
        }
        guard source == .automatic || source == .account else { throw AbacusUsageError.noSessionCookie }

        if let cached = normalizedCookie(cachedCookieHeader) {
            do {
                return try await fetchWithCookieHeader(cached, session: session, now: now).toProviderUsage()
            } catch let error as AbacusUsageError where error.shouldTryNextImportedSession {
                if error.shouldClearCachedCookie { await cacheUpdate(nil) }
            }
        }

        var lastError: AbacusUsageError = .noSessionCookie
        for cookie in automaticCookieHeaders() {
            do {
                let usage = try await fetchWithCookieHeader(cookie, session: session, now: now)
                await cacheUpdate(cookie)
                return usage.toProviderUsage()
            } catch let error as AbacusUsageError where error.shouldTryNextImportedSession {
                lastError = error
            } catch {
                lastError = .networkError(error.localizedDescription)
            }
        }
        throw lastError
    }

    static func fetchWithCookieHeader(
        _ cookieHeader: String,
        session: URLSession,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> AbacusUsageSnapshot {
        async let required = fetchJSON(
            url: computePointsURL,
            method: "GET",
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session
        )
        async let optional = fetchOptionalBillingInfo(
            cookieHeader: cookieHeader,
            timeout: min(timeout, 5),
            session: session
        )
        let computePoints = try await required
        let billingInfo = await optional
        return try parseResults(computePoints: computePoints, billingInfo: billingInfo, now: now)
    }

    private static func fetchOptionalBillingInfo(
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession
    ) async -> [String: Any] {
        (try? await fetchJSON(
            url: billingInfoURL,
            method: "POST",
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session
        )) ?? [:]
    }

    private static func fetchJSON(
        url: URL,
        method: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if method == "POST" { request.httpBody = Data("{}".utf8) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AbacusUsageError.networkError("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AbacusUsageError.unauthorized }
        guard http.statusCode == 200 else {
            throw AbacusUsageError.networkError("HTTP \(http.statusCode)")
        }

        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AbacusUsageError.parseFailed("\(url.lastPathComponent): top-level JSON is not a dictionary")
            }
            root = value
        } catch let error as AbacusUsageError {
            throw error
        } catch {
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): invalid JSON")
        }

        guard root["success"] as? Bool == true,
              let result = root["result"] as? [String: Any]
        else {
            let message = (root["error"] as? String ?? "Unknown error").lowercased()
            let authenticationWords = [
                "expired", "session", "login", "authenticate", "unauthorized", "unauthenticated", "forbidden",
            ]
            if authenticationWords.contains(where: message.contains) { throw AbacusUsageError.unauthorized }
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): \(message)")
        }
        return result
    }

    static func parseResults(
        computePoints: [String: Any],
        billingInfo: [String: Any],
        now: Date = Date()
    ) throws -> AbacusUsageSnapshot {
        guard let total = number(computePoints["totalComputePoints"]),
              let remaining = number(computePoints["computePointsLeft"])
        else {
            throw AbacusUsageError.parseFailed(
                "Missing credit fields in compute points response. Keys: [\(computePoints.keys.sorted().joined(separator: ", "))]"
            )
        }
        return AbacusUsageSnapshot(
            creditsUsed: total - remaining,
            creditsTotal: total,
            resetsAt: parseDate(billingInfo["nextBillingDate"] as? String),
            planName: billingInfo["currentTier"] as? String,
            updatedAt: now
        )
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)\bcookie:\s*'([^']+)'"#,
            #"(?i)\bcookie:\s*\"([^\"]+)\""#,
            #"(?i)\bcookie:\s*([^\r\n]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value)
            else { continue }
            value = String(value[range])
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func containsSessionCookie(_ names: [String]) -> Bool {
        names.contains { name in
            let lowered = name.lowercased()
            if knownSessionCookieNames.contains(lowered) { return true }
            if excludedCookiePrefixes.contains(where: lowered.hasPrefix) { return false }
            return sessionCookieSubstrings.contains(where: lowered.contains)
        }
    }

    private static func automaticCookieHeaders() -> [String] {
        let browsers = [Browser.chrome] + Browser.defaultImportOrder.filter { $0 != .chrome }
        let query = BrowserCookieQuery(domains: cookieDomains)
        let client = BrowserCookieClient()
        var headers: [String] = []
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources where !source.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard containsSessionCookie(cookies.map(\.name)) else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !header.isEmpty, !headers.contains(header) { headers.append(header) }
            }
        }
        return headers
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let integer = value as? Int { return Double(integer) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
