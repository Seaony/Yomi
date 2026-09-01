import Foundation

nonisolated enum SakanaUsageError: LocalizedError, Equatable {
    case missingCookie
    case loginRequired
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text("缺少 Sakana Cookie 标头", "Missing Sakana cookie header")
        case .loginRequired:
            AppLocalization.text("需要登录 Sakana", "Sakana login is required")
        case let .apiError(status):
            AppLocalization.text("Sakana 账单请求失败（HTTP \(status)）", "Sakana billing failed (HTTP \(status))")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Sakana 账单页面：\(message)", "Failed to parse Sakana billing page: \(message)")
        }
    }
}

nonisolated enum SakanaUsageFetcher {
    struct QuotaWindow: Sendable, Equatable {
        let usedFraction: Double
        let resetsAt: Date?
    }

    struct PayAsYouGo: Sendable, Equatable {
        let creditBalance: Double
        let periodUsageTotal: Double?
        let periodLabel: String?
    }

    struct Snapshot: Sendable, Equatable {
        let planName: String?
        let priceLabel: String?
        let fiveHour: QuotaWindow?
        let weekly: QuotaWindow?
        let payAsYouGo: PayAsYouGo?
        let updatedAt: Date

        func providerUsage() -> ProviderUsage {
            var windows: [UsageWindow] = []
            if let fiveHour {
                windows.append(UsageWindow(
                    id: "sakana-five-hour",
                    label: "5-hour",
                    usedFraction: fiveHour.usedFraction,
                    resetsAt: fiveHour.resetsAt,
                    detail: nil
                ))
            }
            if let weekly {
                windows.append(UsageWindow(
                    id: "sakana-weekly",
                    label: "Weekly",
                    usedFraction: weekly.usedFraction,
                    resetsAt: weekly.resetsAt,
                    detail: nil
                ))
            }
            var details: [UsageDetail] = []
            if let payAsYouGo {
                details.append(UsageDetail(
                    id: "sakana-payg-balance",
                    label: "Balance",
                    value: SakanaUsageFetcher.currency(payAsYouGo.creditBalance)
                ))
                if let usage = payAsYouGo.periodUsageTotal {
                    let suffix = payAsYouGo.periodLabel.map { " · \($0)" } ?? ""
                    details.append(UsageDetail(
                        id: "sakana-payg-usage",
                        label: "Usage",
                        value: SakanaUsageFetcher.currency(usage) + suffix
                    ))
                }
            }
            let plan = [planName, priceLabel]
                .compactMap { value -> String? in
                    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                .joined(separator: " ")
            return ProviderUsage(
                id: ProviderID(rawValue: "sakana"),
                state: .ready,
                windows: windows,
                plan: plan.isEmpty ? nil : plan,
                details: details,
                updatedAt: updatedAt,
                message: nil
            )
        }
    }

    private static let billingURL = URL(string: "https://console.sakana.ai/billing")!
    private static let payAsYouGoURL = URL(string: "https://console.sakana.ai/billing?tab=payAsYouGo")!

    static func fetch(
        cookie rawCookie: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        includeOptionalUsage: Bool = true
    ) async throws -> ProviderUsage {
        guard let cookie = normalizedCookie(rawCookie) ?? normalizedCookie(environment["SAKANA_COOKIE"]) else {
            throw SakanaUsageError.missingCookie
        }
        let requestSession = guardedSession(copying: session)
        defer { requestSession.finishTasksAndInvalidate() }
        let result = SakanaOptionalResult()
        let startedAt = Date()
        let optionalTask: Task<Void, Never>? = includeOptionalUsage ? Task {
            let value = await fetchPayAsYouGo(cookie: cookie, session: requestSession)
            result.complete(value)
        } : nil
        do {
            let primary = try await fetchBilling(cookie: cookie, session: requestSession, now: now)
            if let optionalTask {
                let remaining = max(0, 0.2 - Date().timeIntervalSince(startedAt))
                if !result.isCompleted, remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                optionalTask.cancel()
            }
            return Snapshot(
                planName: primary.planName,
                priceLabel: primary.priceLabel,
                fiveHour: primary.fiveHour,
                weekly: primary.weekly,
                payAsYouGo: result.value,
                updatedAt: now
            ).providerUsage()
        } catch {
            optionalTask?.cancel()
            throw error
        }
    }

    private static func fetchBilling(cookie: String, session: URLSession, now: Date) async throws -> Snapshot {
        let (data, http) = try await response(url: billingURL, cookie: cookie, session: session)
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode) {
            throw SakanaUsageError.loginRequired
        }
        guard sameBillingOrigin(http.url) else { throw SakanaUsageError.loginRequired }
        guard http.statusCode == 200 else { throw SakanaUsageError.apiError(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw SakanaUsageError.parseFailed("Billing page response was empty.")
        }
        return try parseBillingHTML(html, now: now)
    }

    private static func fetchPayAsYouGo(cookie: String, session: URLSession) async -> PayAsYouGo? {
        do {
            let (data, http) = try await response(url: payAsYouGoURL, cookie: cookie, session: session)
            guard http.statusCode == 200, sameBillingOrigin(http.url),
                  let html = String(data: data, encoding: .utf8), !html.isEmpty
            else { return nil }
            return parsePayAsYouGoHTML(html)
        } catch {
            return nil
        }
    }

    private static func response(url: URL, cookie: String, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SakanaUsageError.apiError(0) }
        return (data, http)
    }

    static func parseBillingHTML(_ html: String, now: Date = Date()) throws -> Snapshot {
        let fiveHour = try parseWindow(label: "5-hour", html: html)
        let weekly = try parseWindow(label: "Weekly", html: html)
        guard fiveHour != nil || weekly != nil else {
            throw SakanaUsageError.parseFailed("Usage limit windows were not found.")
        }
        return Snapshot(
            planName: capture(
                #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>\s*([^<]+?)\s*</span>"#,
                in: html
            ),
            priceLabel: capture(
                #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>[^<]+</span>\s*<span[^>]*>\s*([^<]+?)\s*</span>"#,
                in: html
            ),
            fiveHour: fiveHour,
            weekly: weekly,
            payAsYouGo: nil,
            updatedAt: now
        )
    }

    static func parsePayAsYouGoHTML(_ html: String) -> PayAsYouGo? {
        guard let balance = capture(
            #"<h2[^>]*>\s*Credit balance\s*</h2>[\s\S]{0,900}?<p[^>]*tabular-nums[^"]*"[^>]*>\$?([0-9][0-9,]*(?:\.[0-9]+)?)</p>"#,
            in: html
        ).flatMap(amount) else { return nil }
        let usage = capture(
            #"<h2[^>]*>\s*Usage\s*</h2>\s*<span[^>]*>\s*Total(?:<!--\s*-->)?:\s*(?:<!--\s*-->)?\$?([0-9][0-9,]*(?:\.[0-9]+)?)\s*</span>"#,
            in: html
        ).flatMap(amount)
        let period = capture(#"aria-label="Usage date range"[^>]*>([\s\S]*?)</button>"#, in: html)
            .map(stripHTMLComments)
        return PayAsYouGo(creditBalance: balance, periodUsageTotal: usage, periodLabel: period)
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased().hasPrefix("curl ") {
            let patterns = [#"(?i)-H\s*'Cookie:\s*([^']+)'"#, #"(?i)-H\s*"Cookie:\s*([^"]+)""#]
            guard let extracted = patterns.lazy.compactMap({ capture($0, in: value) }).first else { return nil }
            value = extracted
        } else if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(value.firstIndex(of: ":").map { value.distance(from: value.startIndex, to: $0) + 1 } ?? 0))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil,
              value.split(separator: ";").allSatisfy({ $0.contains("=") })
        else { return nil }
        return value
    }

    private static func parseWindow(label: String, html: String) throws -> QuotaWindow? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let labelPattern = "<p[^>]*>\\s*\(escaped)\\s*</p>"
        guard let labelMatch = firstMatch(labelPattern, in: html),
              let start = Range(labelMatch.range, in: html)?.upperBound
        else { return nil }
        let offset = NSMaxRange(labelMatch.range)
        let boundary = #"<p[^>]*>\s*(?:5-hour|Weekly)\s*</p>|<div[^>]*data-slot=(?:"card"|'card'|"card-title"|'card-title')[^>]*>"#
        let nsRange = NSRange(location: offset, length: max(0, (html as NSString).length - offset))
        let end = (try? NSRegularExpression(pattern: boundary, options: [.caseInsensitive]))?
            .firstMatch(in: html, range: nsRange)
            .flatMap { Range($0.range, in: html)?.lowerBound } ?? html.endIndex
        let body = String(html[start..<end])
        guard let percentText = capture(#"<p[^>]*>\s*([0-9]+(?:\.[0-9]+)?)% used\s*</p>"#, in: body),
              let percent = Double(percentText), percent.isFinite, (0...100).contains(percent)
        else { throw SakanaUsageError.parseFailed("Invalid \(label) usage percentage.") }
        let reset = capture(#"<p[^>]*>\s*Resets on ([^<]+?)\s*</p>"#, in: body).flatMap(parseResetDate)
        return QuotaWindow(usedFraction: percent / 100, resetsAt: reset)
    }

    private static func parseResetDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func amount(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")), value.isFinite else { return nil }
        return value
    }

    private static func stripHTMLComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let match = firstMatch(pattern, in: value), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        let result = value[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func firstMatch(_ pattern: String, in value: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func sameBillingOrigin(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == billingURL.host?.lowercased()
    }

    private static func currency(_ value: Double) -> String { String(format: "$%.2f", value) }

    private static func guardedSession(copying session: URLSession) -> URLSession {
        URLSession(configuration: session.configuration, delegate: SakanaRedirectGuard(), delegateQueue: nil)
    }
}

private nonisolated final class SakanaOptionalResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: SakanaUsageFetcher.PayAsYouGo?
    private var completed = false

    var value: SakanaUsageFetcher.PayAsYouGo? { lock.withLock { storedValue } }
    var isCompleted: Bool { lock.withLock { completed } }

    func complete(_ value: SakanaUsageFetcher.PayAsYouGo?) {
        lock.withLock {
            storedValue = value
            completed = true
        }
    }
}

private nonisolated final class SakanaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
