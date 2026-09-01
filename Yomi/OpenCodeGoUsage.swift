import Foundation

enum OpenCodeGoUsageFetcher {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent",
        "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec",
        "resetsInSec", "resetsInSeconds", "resetIn", "resetSec",
    ]
    private static let resetAtKeys = [
        "resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset", "renewAt", "renew_at",
    ]
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential: String,
        workspaceID: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let normalized = normalizeAPIKey(credential)
        if let cookie = OpenCodeUsageFetcher.requestCookieHeader(from: normalized) {
            return try await fetchWeb(cookie: cookie, workspaceID: workspaceID, session: session, now: now)
        }
        if !normalized.isEmpty {
            return try await fetchAPI(apiKey: normalized, session: session, now: now)
        }
        if let cookie = OpenCodeUsageFetcher.automaticCookieHeader() {
            return try await fetchWeb(cookie: cookie, workspaceID: workspaceID, session: session, now: now)
        }
        throw UsageCollectionError.missingCredential
    }

    static func fetchAPI(
        apiKey: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let token = normalizeAPIKey(apiKey)
        guard !token.isEmpty else { throw UsageCollectionError.missingCredential }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return try parseAPI(data: data, now: now)
    }

    static func parseAPI(data: Data, now: Date) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let rolling = usage["rolling"] as? [String: Any]
        else { throw UsageCollectionError.unreadableResponse }
        let renewal = dateValue(value(usage, keys: ["renewAt", "renew_at"]))
            ?? dateValue(value(root, keys: ["renewAt", "renew_at"]))
        guard let snapshot = snapshot(
            rolling: rolling,
            weekly: usage["weekly"] as? [String: Any],
            monthly: usage["monthly"] as? [String: Any],
            renewal: renewal,
            directPercentIsFraction: false,
            now: now
        ) else { throw UsageCollectionError.unreadableResponse }
        return providerUsage(snapshot, now: now)
    }

    static func parseWeb(text: String, now: Date) throws -> ProviderUsage {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let snapshot = parseJSON(object, inheritedRenewal: nil, now: now) {
            return providerUsage(snapshot, now: now)
        }
        guard let rollingPercent = captureDouble(
            #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text
        ), let rollingReset = captureInt(
            #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text
        ) else { throw UsageCollectionError.unreadableResponse }
        let weeklyPercent = captureDouble(
            #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text
        )
        let weeklyReset = captureInt(#"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text)
        let monthlyPercent = captureDouble(
            #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text
        )
        let monthlyReset = captureInt(#"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text)
        return providerUsage(OpenCodeGoSnapshot(
            rollingPercent: rollingPercent,
            rollingReset: rollingReset,
            weeklyPercent: weeklyPercent,
            weeklyReset: weeklyReset,
            monthlyPercent: monthlyPercent,
            monthlyReset: monthlyReset,
            renewal: nil,
            zenBalance: nil
        ), now: now)
    }

    static func parseZenBalance(text: String) -> Double? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let balance = explicitBalance(in: object) { return balance }
        let patterns = [
            #"(?i)(?:current\s+balance|zen\s+balance|現在の残高)[^$]{0,80}\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
            #"(?i)(?:balance|残高)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
        ]
        return patterns.lazy.compactMap { capture($0, text).flatMap {
            Double($0.replacingOccurrences(of: ",", with: ""))
        } }.first
    }

    static func parseBillingBalance(text: String) -> Double? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let raw = rawBillingBalance(in: object) { return raw / 100_000_000 }
        let customer = #"(?:\"customerID\"|customerID)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\"[^\"]+\""#
        guard text.range(of: customer, options: .regularExpression) != nil else { return nil }
        return captureDouble(
            #"(?:\"balance\"|balance)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?(-?[0-9]+(?:\.[0-9]+)?)"#,
            text
        ).map { $0 / 100_000_000 }
    }

    nonisolated static func normalizeAPIKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func fetchWeb(
        cookie: String,
        workspaceID rawWorkspaceID: String?,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let workspaceID: String
        if let configured = OpenCodeUsageFetcher.normalizeWorkspaceID(rawWorkspaceID) {
            workspaceID = configured
        } else {
            workspaceID = try await OpenCodeUsageFetcher.fetchWorkspaceID(cookie: cookie, session: session)
        }
        let goURL = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")!
        async let goText = pageText(url: goURL, cookie: cookie, session: session)
        async let balance = zenBalance(workspaceID: workspaceID, cookie: cookie, session: session)
        var usage = try parseWeb(text: await goText, now: now)
        if let resolvedBalance = try? await balance {
            usage.providerCost = ProviderCostSummary(
                used: resolvedBalance,
                limit: 0,
                currencyCode: "USD",
                period: "Zen balance",
                balance: resolvedBalance
            )
            usage.balance = String(format: "$%.2f", resolvedBalance)
        }
        return usage
    }

    private static func zenBalance(
        workspaceID: String,
        cookie: String,
        session: URLSession
    ) async throws -> Double? {
        let root = URL(string: "https://opencode.ai/workspace/\(workspaceID)")!
        let text = try await pageText(url: root, cookie: cookie, session: session)
        if let balance = parseZenBalance(text: text) { return balance }
        let billing = try await billingText(workspaceID: workspaceID, cookie: cookie, session: session)
        return parseBillingBalance(text: billing)
    }

    private static func pageText(url: URL, cookie: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsageCollectionError.requestFailed(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw UsageCollectionError.unreadableResponse }
        if signedOut(text) { throw UsageCollectionError.missingCredential }
        return text
    }

    private static func billingText(workspaceID: String, cookie: String, session: URLSession) async throws -> String {
        let args = String(data: try JSONSerialization.data(withJSONObject: [workspaceID]), encoding: .utf8)!
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: billingServerID),
            URLQueryItem(name: "args", value: args),
        ]
        var request = URLRequest(url: components?.url ?? serverURL)
        request.timeoutInterval = 18
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(billingServerID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("https://opencode.ai/workspace/\(workspaceID)", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsageCollectionError.requestFailed(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw UsageCollectionError.unreadableResponse }
        return text
    }

    private static func providerUsage(_ snapshot: OpenCodeGoSnapshot, now: Date) -> ProviderUsage {
        var windows = [UsageWindow(
            id: "opencodego-rolling",
            label: "5-hour",
            usedFraction: snapshot.rollingPercent / 100,
            resetsAt: now.addingTimeInterval(TimeInterval(snapshot.rollingReset)),
            detail: nil
        )]
        if let percent = snapshot.weeklyPercent, let reset = snapshot.weeklyReset {
            windows.append(UsageWindow(
                id: "opencodego-weekly", label: "Weekly", usedFraction: percent / 100,
                resetsAt: now.addingTimeInterval(TimeInterval(reset)), detail: nil
            ))
        }
        if let percent = snapshot.monthlyPercent, let reset = snapshot.monthlyReset {
            windows.append(UsageWindow(
                id: "opencodego-monthly", label: "Monthly", usedFraction: percent / 100,
                resetsAt: now.addingTimeInterval(TimeInterval(reset)), detail: nil
            ))
        }
        let cost = snapshot.zenBalance.map {
            ProviderCostSummary(used: $0, limit: 0, currencyCode: "USD", period: "Zen balance", balance: $0)
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "opencodego"), state: .ready, windows: windows,
            additionalWindows: [],
            balance: snapshot.zenBalance.map { String(format: "$%.2f", $0) },
            providerCost: cost, updatedAt: now, message: nil
        )
    }

    private static func parseJSON(_ object: Any, inheritedRenewal: Date?, now: Date) -> OpenCodeGoSnapshot? {
        guard let dict = object as? [String: Any] else { return nil }
        let renewal = dateValue(value(dict, keys: ["renewAt", "renew_at"])) ?? inheritedRenewal
        if let usage = dict["usage"] as? [String: Any],
           let parsed = parseJSON(usage, inheritedRenewal: renewal, now: now) { return parsed }
        let rolling = dictionary(dict, keys: ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"])
        let weekly = dictionary(dict, keys: ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"])
        let monthly = dictionary(dict, keys: ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"])
        if let rolling,
           let parsed = snapshot(
               rolling: rolling, weekly: weekly, monthly: monthly, renewal: renewal,
               directPercentIsFraction: true, now: now
           ) { return parsed }
        for child in dict.values {
            if let parsed = parseJSON(child, inheritedRenewal: renewal, now: now) { return parsed }
        }
        return nil
    }

    private static func snapshot(
        rolling: [String: Any], weekly: [String: Any]?, monthly: [String: Any]?,
        renewal: Date?, directPercentIsFraction: Bool, now: Date
    ) -> OpenCodeGoSnapshot? {
        guard let rolling = window(rolling, fraction: directPercentIsFraction, now: now) else { return nil }
        let weeklyWindow = nestedWindow(weekly, fraction: directPercentIsFraction, now: now)
        let monthlyWindow = nestedWindow(monthly, fraction: directPercentIsFraction, now: now)
        return OpenCodeGoSnapshot(
            rollingPercent: rolling.percent, rollingReset: rolling.reset,
            weeklyPercent: weeklyWindow?.percent, weeklyReset: weeklyWindow?.reset,
            monthlyPercent: monthlyWindow?.percent, monthlyReset: monthlyWindow?.reset,
            renewal: renewal, zenBalance: nil
        )
    }

    private static func nestedWindow(
        _ dict: [String: Any]?, fraction: Bool, now: Date
    ) -> (percent: Double, reset: Int)? {
        guard let dict else { return nil }
        if let direct = window(dict, fraction: fraction, now: now) { return direct }
        for child in dict.values {
            if let child = child as? [String: Any],
               let parsed = nestedWindow(child, fraction: fraction, now: now) { return parsed }
        }
        return nil
    }

    private static func window(
        _ dict: [String: Any], fraction: Bool, now: Date
    ) -> (percent: Double, reset: Int)? {
        var percent = numeric(dict, keys: percentKeys)
        let direct = percent != nil
        if percent == nil, let used = numeric(dict, keys: ["used", "usage", "consumed", "count", "usedTokens"]),
           let limit = numeric(dict, keys: ["limit", "total", "quota", "max", "cap", "tokenLimit"]), limit > 0 {
            percent = used / limit * 100
        }
        guard var percent else { return nil }
        if direct, fraction, (0...1).contains(percent) { percent *= 100 }
        percent = min(100, max(0, percent))
        var reset = integer(dict, keys: resetInKeys)
        if reset == nil, let date = dateValue(value(dict, keys: resetAtKeys)) {
            let interval = date.timeIntervalSince(now)
            if interval.isFinite, interval < Double(Int.max) { reset = max(0, Int(interval)) }
        }
        return (percent, max(0, reset ?? 0))
    }

    private static func dictionary(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        keys.lazy.compactMap { dict[$0] as? [String: Any] }.first
    }

    private static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        keys.lazy.compactMap { dict[$0] }.first
    }

    private static func numeric(_ dict: [String: Any], keys: [String]) -> Double? {
        keys.lazy.compactMap { number(dict[$0]) }.first
    }

    private static func integer(_ dict: [String: Any], keys: [String]) -> Int? {
        keys.lazy.compactMap { key in
            if let number = dict[key] as? NSNumber { return number.intValue }
            if let string = dict[key] as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }.first
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number = (value as? NSNumber)?.doubleValue
            ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let number = number(value) {
            if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func explicitBalance(in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, child) in dict {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["zenbalance", "zencurrentbalance", "currentbalance", "currentbalanceusd", "balanceusd", "usdbalance"].contains(normalized),
                   let number = number(child) { return number }
                if let found = explicitBalance(in: child) { return found }
            }
        } else if let array = object as? [Any] {
            for child in array { if let found = explicitBalance(in: child) { return found } }
        }
        return nil
    }

    private static func rawBillingBalance(in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            if dict["balance"] != nil {
                guard let customer = dict["customerID"] as? String, !customer.isEmpty else { return nil }
                return number(dict["balance"])
            }
            for child in dict.values { if let found = rawBillingBalance(in: child) { return found } }
        } else if let array = object as? [Any] {
            for child in array { if let found = rawBillingBalance(in: child) { return found } }
        }
        return nil
    }

    private static func captureDouble(_ pattern: String, _ text: String) -> Double? {
        capture(pattern, text).flatMap(Double.init)
    }

    private static func captureInt(_ pattern: String, _ text: String) -> Int? {
        capture(pattern, text).flatMap(Int.init)
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func signedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sign in") || lower.contains("auth/authorize")
            || lower.contains("not associated with an account") || lower.contains("actor of type \"public\"")
    }
}

private struct OpenCodeGoSnapshot {
    let rollingPercent: Double
    let rollingReset: Int
    let weeklyPercent: Double?
    let weeklyReset: Int?
    let monthlyPercent: Double?
    let monthlyReset: Int?
    let renewal: Date?
    let zenBalance: Double?
}
