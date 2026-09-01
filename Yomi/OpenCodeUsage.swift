import Foundation
import SweetCookieKit

enum OpenCodeUsageFetcher {
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"
    private static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
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

    static func fetch(
        cookie rawCookie: String,
        workspaceID rawWorkspaceID: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let cookie: String
        if let manual = requestCookieHeader(from: rawCookie) {
            cookie = manual
        } else if rawCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let imported = automaticCookieHeader() {
            cookie = imported
        } else {
            throw UsageCollectionError.missingCredential
        }

        let workspaceID: String
        if let configured = normalizeWorkspaceID(rawWorkspaceID) {
            workspaceID = configured
        } else {
            workspaceID = try await fetchWorkspaceID(cookie: cookie, session: session)
        }
        do {
            let text = try await subscriptionText(
                workspaceID: workspaceID,
                cookie: cookie,
                session: session
            )
            return try parseSubscription(text: text, now: now)
        } catch let error as UsageCollectionError {
            switch error {
            case .requestFailed, .unreadableResponse:
                if let usage = try await payAsYouGoUsage(
                    workspaceID: workspaceID,
                    cookie: cookie,
                    session: session,
                    now: now
                ) {
                    return usage
                }
            default:
                break
            }
            throw error
        }
    }

    static func parseSubscription(text: String, now: Date) throws -> ProviderUsage {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let snapshot = parseUsageJSON(object: object, now: now) {
            return usage(from: snapshot, now: now)
        }
        guard let rollingPercent = captureDouble(
            #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            in: text
        ), let rollingReset = captureInt(
            #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            in: text
        ), let weeklyPercent = captureDouble(
            #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            in: text
        ), let weeklyReset = captureInt(
            #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            in: text
        ) else {
            throw UsageCollectionError.unreadableResponse
        }
        return usage(from: OpenCodeSubscription(
            rollingPercent: rollingPercent,
            weeklyPercent: weeklyPercent,
            rollingReset: rollingReset,
            weeklyReset: weeklyReset,
            renewsAt: nil
        ), now: now)
    }

    static func parseWorkspaceIDs(text: String) -> [String] {
        var ids: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"id\s*:\s*\"(wrk_[^\"]+)\""#),
           !text.isEmpty {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            ids = regex.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        if !ids.isEmpty { return ids }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        collectWorkspaceIDs(object, into: &ids)
        return ids
    }

    static func parseBilling(text: String, now: Date) -> ProviderUsage? {
        guard let billing = OpenCodeBilling.parse(text) else { return nil }
        let cost = ProviderCostSummary(
            used: billing.monthlyUsageUSD,
            limit: billing.monthlyLimitUSD ?? 0,
            currencyCode: "USD",
            period: "Monthly",
            balance: billing.balanceUSD
        )
        let windows: [UsageWindow]
        if let limit = billing.monthlyLimitUSD, limit > 0 {
            windows = [UsageWindow(
                id: "opencode-monthly",
                label: "Monthly",
                usedFraction: min(1, max(0, billing.monthlyUsageUSD / limit)),
                resetsAt: nil,
                detail: nil
            )]
        } else {
            windows = []
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "opencode"),
            state: .ready,
            windows: windows,
            balance: billing.balanceUSD.map { String(format: "$%.2f", $0) },
            providerCost: cost,
            updatedAt: now,
            message: nil
        )
    }

    static func requestCookieHeader(from raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = Set(["auth", "__Host-auth"])
        let components = raw.split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator])
            guard allowed.contains(name) else { return nil }
            return pair
        }
        return components.isEmpty ? nil : components.joined(separator: "; ")
    }

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 { return trimmed }
        if let url = URL(string: trimmed),
           let index = url.pathComponents.firstIndex(of: "workspace"),
           url.pathComponents.count > index + 1 {
            let candidate = url.pathComponents[index + 1]
            if candidate.hasPrefix("wrk_"), candidate.count > 4 { return candidate }
        }
        if let range = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return nil
    }

    static func automaticCookieHeader() -> String? {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["opencode.ai", "app.opencode.ai"])
        for browser in [Browser.chrome, Browser.dia] {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if let filtered = requestCookieHeader(from: header) { return filtered }
            }
        }
        return nil
    }

    static func fetchWorkspaceID(cookie: String, session: URLSession) async throws -> String {
        var text = try await serverText(
            serverID: workspacesServerID,
            args: nil,
            method: "GET",
            referer: baseURL,
            cookie: cookie,
            session: session
        )
        var ids = parseWorkspaceIDs(text: text)
        if ids.isEmpty {
            text = try await serverText(
                serverID: workspacesServerID,
                args: [],
                method: "POST",
                referer: baseURL,
                cookie: cookie,
                session: session
            )
            ids = parseWorkspaceIDs(text: text)
        }
        guard let first = ids.first else { throw UsageCollectionError.unreadableResponse }
        return first
    }

    private static func subscriptionText(
        workspaceID: String,
        cookie: String,
        session: URLSession
    ) async throws -> String {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing") ?? baseURL
        var text = try await serverText(
            serverID: subscriptionServerID,
            args: [workspaceID],
            method: "GET",
            referer: referer,
            cookie: cookie,
            session: session
        )
        if isExplicitNull(text) { throw UsageCollectionError.unreadableResponse }
        if (try? parseSubscription(text: text, now: Date())) == nil {
            text = try await serverText(
                serverID: subscriptionServerID,
                args: [workspaceID],
                method: "POST",
                referer: referer,
                cookie: cookie,
                session: session
            )
            if isExplicitNull(text) { throw UsageCollectionError.unreadableResponse }
        }
        return text
    }

    private static func payAsYouGoUsage(
        workspaceID: String,
        cookie: String,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage? {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)") ?? baseURL
        let text = try await serverText(
            serverID: billingServerID,
            args: [workspaceID],
            method: "GET",
            referer: referer,
            cookie: cookie,
            session: session
        )
        guard let billing = OpenCodeBilling.parse(text), !billing.hasSubscription else { return nil }
        return parseBilling(text: text, now: now)
    }

    private static func serverText(
        serverID: String,
        args: [Any]?,
        method: String,
        referer: URL,
        cookie: String,
        session: URLSession
    ) async throws -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        if method == "GET" {
            var items = [URLQueryItem(name: "id", value: serverID)]
            if let args, !args.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: args),
               let value = String(data: data, encoding: .utf8) {
                items.append(URLQueryItem(name: "args", value: value))
            }
            components?.queryItems = items
        }
        var request = URLRequest(url: components?.url ?? serverURL)
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method != "GET", let args {
            request.httpBody = try JSONSerialization.data(withJSONObject: args)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsageCollectionError.requestFailed(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw UsageCollectionError.unreadableResponse }
        let lower = text.lowercased()
        if lower.contains("sign in") || lower.contains("auth/authorize")
            || lower.contains("not associated with an account") || lower.contains("actor of type \"public\"") {
            throw UsageCollectionError.missingCredential
        }
        return text
    }

    private static func usage(from snapshot: OpenCodeSubscription, now: Date) -> ProviderUsage {
        return ProviderUsage(
            id: ProviderID(rawValue: "opencode"),
            state: .ready,
            windows: [
                UsageWindow(
                    id: "opencode-rolling",
                    label: "5-hour",
                    usedFraction: snapshot.rollingPercent / 100,
                    resetsAt: now.addingTimeInterval(TimeInterval(snapshot.rollingReset)),
                    detail: nil
                ),
                UsageWindow(
                    id: "opencode-weekly",
                    label: "Weekly",
                    usedFraction: snapshot.weeklyPercent / 100,
                    resetsAt: now.addingTimeInterval(TimeInterval(snapshot.weeklyReset)),
                    detail: nil
                ),
            ],
            additionalWindows: [],
            balance: nil,
            updatedAt: now,
            message: nil
        )
    }

    private static func parseUsageJSON(object: Any, now: Date, inheritedRenewal: Date? = nil) -> OpenCodeSubscription? {
        guard let dict = object as? [String: Any] else {
            return parseCandidates(object, now: now, inheritedRenewal: inheritedRenewal)
        }
        let renewal = dateValue(value(dict, keys: ["renewAt", "renew_at"])) ?? inheritedRenewal
        if let usage = dict["usage"] as? [String: Any],
           let parsed = parseUsageJSON(object: usage, now: now, inheritedRenewal: renewal) { return parsed }
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let rolling = rollingKeys.lazy.compactMap { dict[$0] as? [String: Any] }.first
        let weekly = weeklyKeys.lazy.compactMap { dict[$0] as? [String: Any] }.first
        if let rolling, let weekly,
           let rollingWindow = parseWindow(rolling, now: now),
           let weeklyWindow = parseWindow(weekly, now: now) {
            return OpenCodeSubscription(
                rollingPercent: rollingWindow.percent,
                weeklyPercent: weeklyWindow.percent,
                rollingReset: rollingWindow.reset,
                weeklyReset: weeklyWindow.reset,
                renewsAt: renewal
            )
        }
        for key in ["data", "result", "billing", "payload"] {
            if let nested = dict[key],
               let parsed = parseUsageJSON(object: nested, now: now, inheritedRenewal: renewal) { return parsed }
        }
        for nested in dict.values {
            if let parsed = parseUsageJSON(object: nested, now: now, inheritedRenewal: renewal) { return parsed }
        }
        return parseCandidates(object, now: now, inheritedRenewal: renewal)
    }

    private static func parseCandidates(_ object: Any, now: Date, inheritedRenewal: Date?) -> OpenCodeSubscription? {
        var candidates: [OpenCodeCandidate] = []
        collectCandidates(object, now: now, path: [], into: &candidates)
        guard candidates.count >= 2 else { return nil }
        let rollingPreferred = candidates.filter {
            $0.path.contains("rolling") || $0.path.contains("hour") || $0.path.contains("5h")
        }
        let weeklyPreferred = candidates.filter { $0.path.contains("weekly") || $0.path.contains("week") }
        let rolling = (rollingPreferred.isEmpty ? candidates : rollingPreferred).min {
            $0.reset == $1.reset ? $0.percent > $1.percent : $0.reset < $1.reset
        }
        let weeklyPool = (weeklyPreferred.isEmpty ? candidates : weeklyPreferred).filter { $0.id != rolling?.id }
        let weekly = weeklyPool.min {
            $0.reset == $1.reset ? $0.percent > $1.percent : $0.reset > $1.reset
        }
        guard let rolling, let weekly else { return nil }
        return OpenCodeSubscription(
            rollingPercent: rolling.percent,
            weeklyPercent: weekly.percent,
            rollingReset: rolling.reset,
            weeklyReset: weekly.reset,
            renewsAt: inheritedRenewal
        )
    }

    private static func collectCandidates(
        _ object: Any,
        now: Date,
        path: [String],
        into candidates: inout [OpenCodeCandidate]
    ) {
        if let dict = object as? [String: Any] {
            if let window = parseWindow(dict, now: now) {
                candidates.append(OpenCodeCandidate(
                    id: UUID(), percent: window.percent, reset: window.reset,
                    path: path.joined(separator: ".").lowercased()
                ))
            }
            for (key, child) in dict { collectCandidates(child, now: now, path: path + [key], into: &candidates) }
        } else if let array = object as? [Any] {
            for (index, child) in array.enumerated() {
                collectCandidates(child, now: now, path: path + ["[\(index)]"], into: &candidates)
            }
        }
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> (percent: Double, reset: Int)? {
        var percent = double(dict, keys: percentKeys)
        let direct = percent != nil
        if percent == nil, let used = double(dict, keys: ["used", "usage", "consumed", "count", "usedTokens"]),
           let limit = double(dict, keys: ["limit", "total", "quota", "max", "cap", "tokenLimit"]), limit > 0 {
            percent = used / limit * 100
        }
        guard var percent else { return nil }
        if direct, (0...1).contains(percent) { percent *= 100 }
        percent = min(100, max(0, percent))
        var reset = integer(dict, keys: resetInKeys)
        if reset == nil, let date = dateValue(value(dict, keys: resetAtKeys)) {
            let interval = date.timeIntervalSince(now)
            if interval.isFinite, interval < Double(Int.max) { reset = max(0, Int(interval)) }
        }
        return (percent, max(0, reset ?? 0))
    }

    private static func collectWorkspaceIDs(_ object: Any, into ids: inout [String]) {
        if let dict = object as? [String: Any] {
            for child in dict.values { collectWorkspaceIDs(child, into: &ids) }
        } else if let array = object as? [Any] {
            for child in array { collectWorkspaceIDs(child, into: &ids) }
        } else if let string = object as? String, string.hasPrefix("wrk_"), !ids.contains(string) {
            ids.append(string)
        }
    }

    private static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        keys.lazy.compactMap { dict[$0] }.first
    }

    private static func double(_ dict: [String: Any], keys: [String]) -> Double? {
        keys.lazy.compactMap { doubleValue(dict[$0]) }.first
    }

    private static func integer(_ dict: [String: Any], keys: [String]) -> Int? {
        keys.lazy.compactMap { value -> Int? in
            if let number = dict[value] as? NSNumber { return number.intValue }
            if let string = dict[value] as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }.first
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        let result: Double?
        if value is Bool { result = nil }
        else if let number = value as? NSNumber { result = number.doubleValue }
        else if let string = value as? String { result = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let number = doubleValue(value) {
            if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func captureDouble(_ pattern: String, in text: String) -> Double? {
        capture(pattern, in: text).flatMap(Double.init)
    }

    private static func captureInt(_ pattern: String, in text: String) -> Int? {
        capture(pattern, in: text).flatMap(Int.init)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func isExplicitNull(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("null") == .orderedSame { return true }
        return trimmed.range(
            of: #"\]\s*=\s*\[\s*\]\s*,\s*null\s*\)\s*$"#,
            options: .regularExpression
        ) != nil
    }
}

private struct OpenCodeSubscription {
    let rollingPercent: Double
    let weeklyPercent: Double
    let rollingReset: Int
    let weeklyReset: Int
    let renewsAt: Date?
}

private struct OpenCodeCandidate {
    let id: UUID
    let percent: Double
    let reset: Int
    let path: String
}

struct OpenCodeBilling: Equatable {
    static let usdScale = 100_000_000.0

    let monthlyUsageUSD: Double
    let monthlyLimitUSD: Double?
    let balanceUSD: Double?
    let hasSubscription: Bool
    let usageUpdatedAt: Date?

    static func parse(_ text: String) -> OpenCodeBilling? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let customer = customer(in: object),
           let usage = number(customer["monthlyUsage"]) {
            return OpenCodeBilling(
                monthlyUsageUSD: usage / usdScale,
                monthlyLimitUSD: number(customer["monthlyLimit"]),
                balanceUSD: number(customer["balance"]).map { $0 / usdScale },
                hasSubscription: customer["subscription"] != nil && !(customer["subscription"] is NSNull),
                usageUpdatedAt: date(customer["timeMonthlyUsageUpdated"])
            )
        }
        guard matches(field: "customerID", value: #"\"[^\"]+\""#, text: text),
              let usage = fieldNumber("monthlyUsage", text: text) else { return nil }
        return OpenCodeBilling(
            monthlyUsageUSD: usage / usdScale,
            monthlyLimitUSD: fieldNumber("monthlyLimit", text: text),
            balanceUSD: fieldNumber("balance", text: text).map { $0 / usdScale },
            hasSubscription: matches(field: "subscription", value: #"(?!null)[^,}]+"#, text: text),
            usageUpdatedAt: fieldDate("timeMonthlyUsageUpdated", text: text)
        )
    }

    private static func customer(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let id = dict["customerID"] as? String, !id.isEmpty { return dict }
            for child in dict.values { if let found = customer(in: child) { return found } }
        } else if let array = object as? [Any] {
            for child in array { if let found = customer(in: child) { return found } }
        }
        return nil
    }

    private static func pattern(field: String, value: String) -> String {
        #"(?:\""# + field + #"\"|"# + field + #")\s*:\s*(?:\$R\[\d+\]\s*=\s*)?"# + value
    }

    private static func matches(field: String, value: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern(field: field, value: value)) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func fieldNumber(_ field: String, text: String) -> Double? {
        capture(pattern(field: field, value: #"(-?[0-9]+(?:\.[0-9]+)?)"#), text: text).flatMap(Double.init)
    }

    private static func fieldDate(_ field: String, text: String) -> Date? {
        let value = #"(?:new\s+Date\(\s*)?\"([^\"]+)\""#
        return capture(pattern(field: field, value: value), text: text).flatMap { date($0) }
    }

    private static func capture(_ pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number = (value as? NSNumber)?.doubleValue
            ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        guard let number = number(value) else { return nil }
        if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
        if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        return nil
    }
}
