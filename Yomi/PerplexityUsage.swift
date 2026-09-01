import Foundation
import SweetCookieKit

enum PerplexityUsageError: LocalizedError, Equatable {
    case missingSession
    case invalidCookie
    case invalidSession
    case requestFailed(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "未找到 Perplexity 浏览器会话，请先登录 perplexity.ai",
                "No Perplexity browser session was found. Sign in to perplexity.ai first."
            )
        case .invalidCookie:
            AppLocalization.text(
                "Perplexity Cookie 或会话令牌为空或无效",
                "The Perplexity cookie or session token is empty or invalid."
            )
        case .invalidSession:
            AppLocalization.text(
                "Perplexity 会话无效或已过期，请重新登录",
                "The Perplexity session is invalid or expired. Sign in again."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Perplexity 用量请求失败（HTTP \(status)）",
                "Perplexity usage request failed (HTTP \(status))"
            )
        case .unreadableResponse:
            AppLocalization.text(
                "无法解析 Perplexity 用量数据",
                "Could not parse Perplexity usage data."
            )
        }
    }
}

nonisolated enum PerplexityUsageFetcher {
    struct CookieOverride: Sendable, Equatable {
        let name: String
        let token: String
        let requestCookieNames: [String]

        init(name: String, token: String, requestCookieNames: [String]? = nil) {
            self.name = name
            self.token = token
            self.requestCookieNames = requestCookieNames ?? [name]
        }
    }

    struct CreditGrant: Decodable, Sendable, Equatable {
        let type: String
        let amountCents: Double
        let expiresAt: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case type
            case amountCentsSnake = "amount_cents"
            case amountCentsCamel = "amountCents"
            case expiresAtSnake = "expires_at_ts"
            case expiresAtCamel = "expiresAtTs"
        }

        init(type: String, amountCents: Double, expiresAt: TimeInterval?) {
            self.type = type
            self.amountCents = amountCents
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            if let value = try values.decodeIfPresent(Double.self, forKey: .amountCentsSnake) {
                amountCents = value
            } else {
                amountCents = try values.decode(Double.self, forKey: .amountCentsCamel)
            }
            expiresAt = try values.decodeIfPresent(Double.self, forKey: .expiresAtSnake)
                ?? values.decodeIfPresent(Double.self, forKey: .expiresAtCamel)
        }
    }

    struct CreditsResponse: Decodable, Sendable, Equatable {
        let balanceCents: Double
        let renewalDate: TimeInterval
        let currentPeriodPurchasedCents: Double
        let creditGrants: [CreditGrant]
        let totalUsageCents: Double

        private enum CodingKeys: String, CodingKey {
            case balanceCentsSnake = "balance_cents"
            case balanceCentsCamel = "balanceCents"
            case renewalDateSnake = "renewal_date_ts"
            case renewalDateCamel = "renewalDateTs"
            case purchasedCentsSnake = "current_period_purchased_cents"
            case purchasedCentsCamel = "currentPeriodPurchasedCents"
            case creditGrantsSnake = "credit_grants"
            case creditGrantsCamel = "creditGrants"
            case totalUsageCentsSnake = "total_usage_cents"
            case totalUsageCentsCamel = "totalUsageCents"
        }

        init(
            balanceCents: Double,
            renewalDate: TimeInterval,
            currentPeriodPurchasedCents: Double,
            creditGrants: [CreditGrant],
            totalUsageCents: Double
        ) {
            self.balanceCents = balanceCents
            self.renewalDate = renewalDate
            self.currentPeriodPurchasedCents = currentPeriodPurchasedCents
            self.creditGrants = creditGrants
            self.totalUsageCents = totalUsageCents
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            balanceCents = try Self.requiredNumber(
                values,
                snake: .balanceCentsSnake,
                camel: .balanceCentsCamel
            )
            renewalDate = try Self.requiredNumber(
                values,
                snake: .renewalDateSnake,
                camel: .renewalDateCamel
            )
            currentPeriodPurchasedCents = try Self.requiredNumber(
                values,
                snake: .purchasedCentsSnake,
                camel: .purchasedCentsCamel
            )
            creditGrants = try values.decodeIfPresent([CreditGrant].self, forKey: .creditGrantsSnake)
                ?? values.decode([CreditGrant].self, forKey: .creditGrantsCamel)
            totalUsageCents = try Self.requiredNumber(
                values,
                snake: .totalUsageCentsSnake,
                camel: .totalUsageCentsCamel
            )
        }

        private static func requiredNumber(
            _ values: KeyedDecodingContainer<CodingKeys>,
            snake: CodingKeys,
            camel: CodingKeys
        ) throws -> Double {
            if let value = try values.decodeIfPresent(Double.self, forKey: snake) {
                return value
            }
            return try values.decode(Double.self, forKey: camel)
        }
    }

    struct Snapshot: Sendable, Equatable {
        let recurringTotal: Double
        let recurringUsed: Double
        let promoTotal: Double
        let promoUsed: Double
        let purchasedTotal: Double
        let purchasedUsed: Double
        let balanceCents: Double
        let totalUsageCents: Double
        let renewalDate: Date
        let promoExpiration: Date?
        let updatedAt: Date

        var planName: String? {
            if recurringTotal <= 0 { return nil }
            return recurringTotal < 5_000 ? "Pro" : "Max"
        }

        func toProviderUsage() -> ProviderUsage {
            var windows: [UsageWindow] = []
            if recurringTotal > 0 {
                windows.append(UsageWindow(
                    id: "perplexity-recurring",
                    label: "Credits",
                    usedFraction: PerplexityUsageFetcher.fraction(used: recurringUsed, total: recurringTotal),
                    resetsAt: renewalDate,
                    detail: "\(PerplexityUsageFetcher.integer(recurringUsed))/"
                        + "\(PerplexityUsageFetcher.integer(recurringTotal)) credits"
                ))
            } else if promoTotal <= 0, purchasedTotal <= 0 {
                windows.append(UsageWindow(
                    id: "perplexity-recurring",
                    label: "Credits",
                    usedFraction: 1,
                    resetsAt: renewalDate,
                    detail: "0/0 credits"
                ))
            }

            var promoDetail = "\(PerplexityUsageFetcher.integer(promoUsed))/"
                + "\(PerplexityUsageFetcher.integer(promoTotal)) bonus"
            if let promoExpiration {
                promoDetail += " · exp. \(PerplexityUsageFetcher.promoExpiryFormatter.string(from: promoExpiration))"
            }
            windows.append(UsageWindow(
                id: "perplexity-promotional",
                label: "Bonus credits",
                usedFraction: promoTotal > 0
                    ? PerplexityUsageFetcher.fraction(used: promoUsed, total: promoTotal)
                    : 1,
                resetsAt: nil,
                detail: promoDetail
            ))
            windows.append(UsageWindow(
                id: "perplexity-purchased",
                label: "Purchased",
                usedFraction: purchasedTotal > 0
                    ? PerplexityUsageFetcher.fraction(used: purchasedUsed, total: purchasedTotal)
                    : 1,
                resetsAt: nil,
                detail: "\(PerplexityUsageFetcher.integer(purchasedUsed))/"
                    + "\(PerplexityUsageFetcher.integer(purchasedTotal)) credits"
            ))

            return ProviderUsage(
                id: ProviderID(rawValue: "perplexity"),
                state: .ready,
                windows: windows,
                balance: nil,
                plan: planName,
                updatedAt: updatedAt,
                message: nil
            )
        }
    }

    static let defaultSessionCookieName = "__Secure-next-auth.session-token"
    static let supportedSessionCookieNames = [
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]

    private static let endpoint = URL(
        string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default"
    )!
    private static let cookieDomains = ["www.perplexity.ai", "perplexity.ai"]
    static let promoExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let candidates: [CookieOverride]
        switch source {
        case .cookie, .token:
            guard let cookie = cookieOverride(from: credential) else {
                throw PerplexityUsageError.invalidCookie
            }
            candidates = [cookie]
        case .automatic, .account:
            var resolved = automaticCookieOverrides()
            if let configured = cookieOverride(from: credential) {
                resolved.append(configured)
            }
            if let environment = environmentCookieOverride() {
                resolved.append(environment)
            }
            candidates = deduplicated(resolved)
        case .command, .endpoint:
            throw PerplexityUsageError.missingSession
        }

        guard !candidates.isEmpty else { throw PerplexityUsageError.missingSession }
        var sawInvalidSession = false
        for candidate in candidates {
            for cookieName in candidate.requestCookieNames {
                do {
                    return try await fetchCredits(
                        sessionToken: candidate.token,
                        cookieName: cookieName,
                        session: session,
                        now: now
                    ).toProviderUsage()
                } catch PerplexityUsageError.invalidSession {
                    sawInvalidSession = true
                }
            }
        }
        if sawInvalidSession { throw PerplexityUsageError.invalidSession }
        throw PerplexityUsageError.missingSession
    }

    static func fetchCredits(
        sessionToken: String,
        cookieName: String = defaultSessionCookieName,
        session: URLSession,
        now: Date = Date()
    ) async throws -> Snapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(cookieName)=\(sessionToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.perplexity.ai/account/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PerplexityUsageError.unreadableResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PerplexityUsageError.invalidSession
            }
            throw PerplexityUsageError.requestFailed(http.statusCode)
        }
        return try parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date = Date()) throws -> Snapshot {
        let response: CreditsResponse
        do {
            response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw PerplexityUsageError.unreadableResponse
        }

        let recurring = response.creditGrants.filter { $0.type == "recurring" }
        let promotional = response.creditGrants.filter {
            $0.type == "promotional" && ($0.expiresAt ?? .infinity) > now.timeIntervalSince1970
        }
        let purchased = response.creditGrants.filter { $0.type == "purchased" }

        let recurringTotal = max(0, recurring.reduce(0) { $0 + $1.amountCents })
        let promoTotal = max(0, promotional.reduce(0) { $0 + $1.amountCents })
        let purchasedFromGrants = max(0, purchased.reduce(0) { $0 + $1.amountCents })
        let purchasedTotal = max(purchasedFromGrants, max(0, response.currentPeriodPurchasedCents))

        var remaining = response.totalUsageCents
        let recurringUsed = min(remaining, recurringTotal)
        remaining -= recurringUsed
        let purchasedUsed = min(remaining, purchasedTotal)
        remaining -= purchasedUsed
        let promoUsed = min(remaining, promoTotal)

        return Snapshot(
            recurringTotal: recurringTotal,
            recurringUsed: recurringUsed,
            promoTotal: promoTotal,
            promoUsed: promoUsed,
            purchasedTotal: purchasedTotal,
            purchasedUsed: purchasedUsed,
            balanceCents: response.balanceCents,
            totalUsageCents: response.totalUsageCents,
            renewalDate: Date(timeIntervalSince1970: response.renewalDate),
            promoExpiration: promotional.compactMap(\.expiresAt).min().map(Date.init(timeIntervalSince1970:)),
            updatedAt: now
        )
    }

    static func cookieOverride(from raw: String?) -> CookieOverride? {
        guard let value = cleaned(raw) else { return nil }
        if !value.contains("="), !value.contains(";") {
            return CookieOverride(
                name: defaultSessionCookieName,
                token: value,
                requestCookieNames: supportedSessionCookieNames
            )
        }
        return sessionCookie(from: cookiePairs(value))
    }

    static func environmentCookieOverride(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CookieOverride? {
        if let token = cleaned(
            environment["PERPLEXITY_SESSION_TOKEN"] ?? environment["perplexity_session_token"]
        ) {
            return cookieOverride(from: token)
        }
        return cookieOverride(from: cleaned(environment["PERPLEXITY_COOKIE"]))
    }

    static func sessionCookie(from cookies: [HTTPCookie]) -> CookieOverride? {
        sessionCookie(from: cookies.map { (name: $0.name, value: $0.value) })
    }

    private static func automaticCookieOverrides() -> [CookieOverride] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        let client = BrowserCookieClient()
        var result: [CookieOverride] = []
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
            for group in groups.values {
                let cookies = group.flatMap {
                    BrowserCookieClient.makeHTTPCookies($0.records, origin: query.origin)
                }
                if let cookie = sessionCookie(from: cookies) {
                    result.append(cookie)
                }
            }
        }
        return deduplicated(result)
    }

    private static func cookiePairs(_ raw: String) -> [(name: String, value: String)] {
        raw.split(separator: ";").compactMap { part in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name: name, value: value)
        }
    }

    private static func sessionCookie(
        from cookies: [(name: String, value: String)]
    ) -> CookieOverride? {
        var exact: [String: (name: String, value: String)] = [:]
        var chunks: [String: [Int: (name: String, value: String)]] = [:]
        for cookie in cookies {
            let lowered = cookie.name.lowercased()
            exact[lowered] = cookie
            for supported in supportedSessionCookieNames {
                let prefix = supported.lowercased() + "."
                guard lowered.hasPrefix(prefix),
                      let index = Int(lowered.dropFirst(prefix.count))
                else { continue }
                chunks[supported.lowercased(), default: [:]][index] = cookie
            }
        }

        for supported in supportedSessionCookieNames {
            let key = supported.lowercased()
            if let cookie = exact[key] {
                return CookieOverride(name: cookie.name, token: cookie.value)
            }
            guard let pieces = chunks[key], let first = pieces[0], let maximum = pieces.keys.max() else {
                continue
            }
            var token = ""
            for index in 0...maximum {
                guard let piece = pieces[index] else {
                    token = ""
                    break
                }
                token += piece.value
            }
            guard !token.isEmpty, let separator = first.name.lastIndex(of: ".") else { continue }
            return CookieOverride(name: String(first.name[..<separator]), token: token)
        }
        return nil
    }

    private static func deduplicated(_ cookies: [CookieOverride]) -> [CookieOverride] {
        var result: [CookieOverride] = []
        for cookie in cookies where !result.contains(where: {
            $0.token == cookie.token && $0.requestCookieNames == cookie.requestCookieNames
        }) {
            result.append(cookie)
        }
        return result
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func fraction(used: Double, total: Double) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, used / total))
    }

    private static func integer(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
