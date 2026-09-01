import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum ManusUsageFetcher {
    struct Credits: Decodable, Equatable {
        var totalCredits: Double
        var freeCredits: Double
        var periodicCredits: Double
        var addonCredits: Double
        var refreshCredits: Double
        var maxRefreshCredits: Double
        var proMonthlyCredits: Double
        var eventCredits: Double
        var nextRefreshTime: Date?
        var refreshInterval: String?

        enum CodingKeys: String, CodingKey {
            case totalCredits, freeCredits, periodicCredits, addonCredits
            case refreshCredits, maxRefreshCredits, proMonthlyCredits, eventCredits
            case nextRefreshTime, refreshInterval
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            totalCredits = Self.number(values, .totalCredits) ?? 0
            freeCredits = Self.number(values, .freeCredits) ?? 0
            periodicCredits = Self.number(values, .periodicCredits) ?? 0
            addonCredits = Self.number(values, .addonCredits) ?? 0
            refreshCredits = Self.number(values, .refreshCredits) ?? 0
            maxRefreshCredits = Self.number(values, .maxRefreshCredits) ?? 0
            proMonthlyCredits = Self.number(values, .proMonthlyCredits) ?? 0
            eventCredits = Self.number(values, .eventCredits) ?? 0
            nextRefreshTime = Self.date(values, .nextRefreshTime)
            refreshInterval = try? values.decodeIfPresent(String.self, forKey: .refreshInterval)
        }

        private static func number(
            _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Double? {
            if let value = try? values.decodeIfPresent(Double.self, forKey: key) { return value }
            if let value = try? values.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
            if let value = try? values.decodeIfPresent(String.self, forKey: key) {
                return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func date(
            _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Date? {
            if let value = try? values.decodeIfPresent(String.self, forKey: key) {
                return ISO8601DateFormatter().date(from: value)
            }
            if let value = Self.number(values, key) {
                return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
            }
            return nil
        }
    }

    private struct Envelope: Decodable {
        var data: Credits?
        var result: Credits?
        var response: Credits?
        var availableCredits: Credits?
    }

    private static let url = URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!
    private static let cookieDomains = ["manus.im", "www.manus.im"]

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var tokens: [String] = []
        let configured = token(from: credential)
        if source == .cookie, let configured {
            tokens = [configured]
        } else {
            if source == .automatic { tokens += automaticTokens() }
            if let configured { tokens.append(configured) }
            if let environment = environmentToken() { tokens.append(environment) }
        }
        var seen = Set<String>()
        tokens = tokens.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !tokens.isEmpty else { throw UsageCollectionError.missingCredential }
        var lastStatus: Int?
        for token in tokens {
            do {
                return try await fetch(token: token, session: session, now: now)
            } catch UsageCollectionError.requestFailed(let status) where status == 401 || status == 403 {
                lastStatus = status
            }
        }
        if let lastStatus { throw UsageCollectionError.requestFailed(lastStatus) }
        throw UsageCollectionError.missingCredential
    }

    static func fetch(
        token: String, session: URLSession, now: Date = Date()
    ) async throws -> ProviderUsage {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return try providerUsage(credits: parse(data: data), now: now)
    }

    static func parse(data: Data) throws -> Credits {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           let response = envelope.data ?? envelope.result ?? envelope.response ?? envelope.availableCredits {
            return response
        }
        guard let response = try? decoder.decode(Credits.self, from: data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !expectedKeys.isDisjoint(with: root.keys)
        else { throw UsageCollectionError.unreadableResponse }
        return response
    }

    static func providerUsage(credits: Credits, now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if credits.proMonthlyCredits > 0 {
            windows.append(UsageWindow(
                id: "manus-monthly", label: "Monthly credits",
                usedFraction: max(0, min(1,
                    (credits.proMonthlyCredits - credits.periodicCredits) / credits.proMonthlyCredits
                )),
                resetsAt: nil,
                detail: "Total \(format(credits.totalCredits)) • Free \(format(credits.freeCredits))"
            ))
        }
        if credits.maxRefreshCredits > 0 {
            let interval = credits.refreshInterval?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = "\(interval?.isEmpty == false ? interval!.capitalized + ": " : "")"
                + "\(format(credits.refreshCredits)) / \(format(credits.maxRefreshCredits))"
            windows.append(UsageWindow(
                id: "manus-refresh", label: "Daily refresh",
                usedFraction: max(0, min(1,
                    (credits.maxRefreshCredits - credits.refreshCredits) / credits.maxRefreshCredits
                )),
                resetsAt: credits.nextRefreshTime, detail: detail
            ))
        }
        let total = format(credits.totalCredits)
        return ProviderUsage(
            id: ProviderID(rawValue: "manus"), state: .ready, windows: windows,
            balance: "\(total) credits", plan: nil,
            updatedAt: now, message: nil
        )
    }

    static func token(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if !raw.contains("="), !raw.contains(";") { return raw }
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, parts[0].caseInsensitiveCompare("session_id") == .orderedSame,
               !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    static func environmentToken(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for key in [
            "MANUS_SESSION_TOKEN", "manus_session_token", "MANUS_SESSION_ID", "manus_session_id",
            "MANUS_COOKIE", "manus_cookie",
        ] {
            var value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let current = value, current.count >= 2,
               current.hasPrefix("\"") && current.hasSuffix("\"")
                || current.hasPrefix("'") && current.hasSuffix("'") {
                value = String(current.dropFirst().dropLast())
            }
            if let token = token(from: value) { return token }
        }
        return nil
    }

    private static func automaticTokens() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        let browsers: [Browser] = [.chrome, .chromeBeta, .brave, .edge, .arc, .firefox, .safari]
        var tokens: [String] = []
        for browser in browsers {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
            for group in grouped.values {
                let cookies = group.flatMap {
                    BrowserCookieClient.makeHTTPCookies($0.records, origin: query.origin)
                }
                for cookie in cookies where cookie.name.caseInsensitiveCompare("session_id") == .orderedSame {
                    let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { tokens.append(value) }
                }
            }
        }
        return tokens
    }

    private static let expectedKeys: Set<String> = [
        "totalCredits", "freeCredits", "periodicCredits", "addonCredits",
        "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits",
    ]

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }
}
