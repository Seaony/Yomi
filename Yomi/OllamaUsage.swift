import Foundation
import SweetCookieKit

nonisolated enum OllamaUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case noSessionCookie
    case notLoggedIn
    case invalidCredentials
    case apiUnauthorized
    case safariCookieAccessDenied
    case browserCookieAccessDenied(String)
    case requestFailed(Int)
    case networkError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppLocalization.text("缺少 Ollama API Key", "Missing Ollama API key")
        case .noSessionCookie:
            AppLocalization.text(
                "未找到 Ollama 登录会话，请先在浏览器登录",
                "No Ollama session was found. Sign in in your browser first."
            )
        case .notLoggedIn:
            AppLocalization.text("Ollama 尚未登录", "Ollama is not signed in")
        case .invalidCredentials:
            AppLocalization.text("Ollama 会话已过期，请重新登录", "Ollama session has expired. Sign in again.")
        case .apiUnauthorized:
            AppLocalization.text("Ollama API Key 无效或已被撤销", "Ollama API key is invalid or revoked")
        case .safariCookieAccessDenied:
            AppLocalization.text(
                "读取 Safari Cookie 需要为 Yomi 开启完全磁盘访问权限",
                "Reading Safari cookies requires Full Disk Access for Yomi"
            )
        case let .browserCookieAccessDenied(browser):
            AppLocalization.text(
                "读取 \(browser) Cookie 的权限被拒绝",
                "Access to \(browser) cookies was denied"
            )
        case let .requestFailed(status):
            AppLocalization.text("Ollama 请求失败（HTTP \(status)）", "Ollama request failed (HTTP \(status))")
        case let .networkError(message):
            AppLocalization.text("Ollama 网络错误：\(message)", "Ollama network error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Ollama 用量：\(message)", "Failed to parse Ollama usage: \(message)")
        }
    }
}

nonisolated enum OllamaUsageFetcher {
    struct Snapshot: Sendable, Equatable {
        let plan: String?
        let email: String?
        let monthlyUsedPercent: Double?
        let monthlyResetsAt: Date?
        let sessionUsedPercent: Double?
        let weeklyUsedPercent: Double?
        let sessionResetsAt: Date?
        let weeklyResetsAt: Date?
        let details: [UsageDetail]
    }

    private struct CookieCandidate: Sendable {
        let header: String
    }

    private static let settingsURL = URL(string: "https://ollama.com/settings")!
    static let tagsURL = URL(string: "https://ollama.com/api/tags")!
    static let validationURL = URL(string: "https://ollama.com/api/web_search")!
    static let apiKeyEnvironmentKeys = ["OLLAMA_API_KEY", "OLLAMA_KEY"]
    private static let defaultSessionCookieName = "__Secure-session"
    private static let sessionCookieNames: Set<String> = [
        "session",
        defaultSessionCookieName,
        "ollama_session",
        "__Host-ollama_session",
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]
    private static let usageLabels = ["Monthly usage", "Free usage", "Session usage", "Hourly usage", "Weekly usage"]
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        switch source {
        case .cookie:
            let candidates: [CookieCandidate]
            if let header = normalizedCookie(rawCredential, allowBareValue: true) {
                candidates = [CookieCandidate(header: header)]
            } else {
                candidates = try automaticCookieCandidates()
            }
            guard !candidates.isEmpty else { throw OllamaUsageError.noSessionCookie }
            return try await fetchWeb(candidates: candidates, session: session, now: now)

        case .token:
            guard let key = resolvedAPIKey(configured: rawCredential, environment: environment) else {
                throw OllamaUsageError.missingAPIKey
            }
            return try await fetchAPI(apiKey: key, session: session, now: now)

        case .automatic:
            let explicitCookie = normalizedCookie(rawCredential, allowBareValue: false)
            let candidates: [CookieCandidate]
            if let explicitCookie {
                candidates = [CookieCandidate(header: explicitCookie)]
            } else {
                do {
                    candidates = try automaticCookieCandidates()
                } catch let error as OllamaUsageError {
                    if let key = resolvedAPIKey(configured: rawCredential, environment: environment) {
                        return try await fetchAPI(apiKey: key, session: session, now: now)
                    }
                    throw error
                }
            }
            if !candidates.isEmpty {
                do {
                    return try await fetchWeb(candidates: candidates, session: session, now: now)
                } catch let error as OllamaUsageError {
                    if let key = resolvedAPIKey(configured: rawCredential, environment: environment) {
                        return try await fetchAPI(apiKey: key, session: session, now: now)
                    }
                    throw error
                }
            }
            guard let key = resolvedAPIKey(configured: rawCredential, environment: environment) else {
                throw OllamaUsageError.noSessionCookie
            }
            return try await fetchAPI(apiKey: key, session: session, now: now)

        case .account, .command, .endpoint:
            throw UsageCollectionError.missingCredential
        }
    }

    static func parseSettingsHTML(_ html: String, now: Date = Date()) throws -> ProviderUsage {
        let snapshot = try parseSnapshot(html)
        return providerUsage(snapshot, now: now)
    }

    static func parseSnapshot(_ html: String) throws -> Snapshot {
        let monthly = parseUsageBlock(labels: ["Monthly usage", "Free usage"], html: html)
        let session = parseUsageBlock(labels: ["Session usage", "Hourly usage"], html: html)
        let weekly = parseUsageBlock(labels: ["Weekly usage"], html: html)
        let details = parseCreditDetails(html)
        guard monthly != nil || session != nil || weekly != nil || !details.isEmpty else {
            if looksSignedOut(html) { throw OllamaUsageError.notLoggedIn }
            throw OllamaUsageError.parseFailed("Missing Ollama usage data.")
        }
        return Snapshot(
            plan: [
                #"Included usage\s*</span>\s*<span[^>]*>([^<]+)</span"#,
                #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#,
                #"<h[1-6][^>]*>\s*Usage credits\s*<span[^>]*>\s*([^<]+)</span"#,
            ].lazy.compactMap {
                firstCapture($0, in: html, options: [.dotMatchesLineSeparators]).flatMap(cleaned)
            }.first,
            email: firstCapture(
                #"id=\"header-email\"[^>]*>([^<]+)<"#,
                in: html,
                options: [.dotMatchesLineSeparators]
            ).flatMap { value in
                guard let value = cleaned(value), value.contains("@") else { return nil }
                return value
            },
            monthlyUsedPercent: monthly?.percent,
            monthlyResetsAt: monthly?.resetsAt,
            sessionUsedPercent: session?.percent,
            weeklyUsedPercent: weekly?.percent,
            sessionResetsAt: session?.resetsAt,
            weeklyResetsAt: weekly?.resetsAt,
            details: details
        )
    }

    static func providerUsage(_ snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let percent = snapshot.monthlyUsedPercent {
            windows.append(UsageWindow(
                id: "ollama-monthly",
                label: "Monthly",
                usedFraction: min(1, max(0, percent / 100)),
                resetsAt: snapshot.monthlyResetsAt,
                detail: nil
            ))
        } else if let percent = snapshot.sessionUsedPercent {
            windows.append(UsageWindow(
                id: "ollama-session",
                label: "Session",
                usedFraction: min(1, max(0, percent / 100)),
                resetsAt: snapshot.sessionResetsAt,
                detail: nil
            ))
        }
        if let percent = snapshot.weeklyUsedPercent {
            windows.append(UsageWindow(
                id: "ollama-weekly",
                label: "Weekly",
                usedFraction: min(1, max(0, percent / 100)),
                resetsAt: snapshot.weeklyResetsAt,
                detail: nil
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "ollama"),
            state: .ready,
            windows: windows,
            balance: snapshot.details.first(where: { $0.id == "ollama-credit-balance" })?.value,
            plan: snapshot.plan,
            details: snapshot.details,
            updatedAt: now,
            message: nil
        )
    }

    static func normalizedCookie(_ raw: String?, allowBareValue: Bool) -> String? {
        guard var value = cleaned(raw) else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("curl ") {
            let patterns = [
                #"(?i)-H\s*['\"]Cookie:\s*([^'\"]+)['\"]"#,
                #"(?i)-H\s*Cookie:\s*([^\s]+)"#,
                #"(?i)--cookie\s*['\"]([^'\"]+)['\"]"#,
                #"(?i)-b\s*['\"]?([^'\"\s]+)"#,
            ]
            guard let captured = patterns.lazy.compactMap({ firstCapture($0, in: value) }).first else { return nil }
            value = captured
        } else if lower.hasPrefix("cookie:") {
            guard value.rangeOfCharacter(from: .newlines) == nil else { return nil }
            value = String(value.dropFirst(value.firstIndex(of: ":").map { value.distance(from: value.startIndex, to: $0) + 1 } ?? 0))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.rangeOfCharacter(from: .newlines) != nil {
            return nil
        }
        let pairs = cookiePairs(value)
        if pairs.contains(where: { isSessionCookieName($0.name) }) {
            return pairs.map { pair in
                let name = pair.name.caseInsensitiveCompare(defaultSessionCookieName) == .orderedSame
                    ? defaultSessionCookieName
                    : pair.name
                return "\(name)=\(pair.value)"
            }.joined(separator: "; ")
        }
        if value.contains(";") || !allowBareValue { return nil }
        guard !value.isEmpty else { return nil }
        return "\(defaultSessionCookieName)=\(value)"
    }

    static func resolvedAPIKey(configured: String?, environment: [String: String]) -> String? {
        if let configured = cleanedCredential(configured), !looksLikeCookie(configured) { return configured }
        for key in apiKeyEnvironmentKeys {
            if let value = cleanedCredential(environment[key]) { return value }
        }
        return nil
    }

    static func shouldAttachCookie(to url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
        return host == "ollama.com" || host == "www.ollama.com" || host.hasSuffix(".ollama.com")
    }

    static func isSignInLanding(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let url, let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "ollama.com" || host == "www.ollama.com" { return path == "/signin" }
        if host == "signin.ollama.com" { return true }
        return host.hasSuffix(".workos.com") && path.hasPrefix("/user_management/authorize")
    }

    static func fetchAPI(
        apiKey: String,
        tagsURL: URL = tagsURL,
        validationURL override: URL? = nil,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OllamaUsageError.missingAPIKey }
        _ = try resolvedValidationURL(tagsURL: tagsURL, override: override)
        let balanceURL = tagsURL.deletingLastPathComponent().appendingPathComponent("balance")
        var request = URLRequest(url: balanceURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi/1.0", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await response(for: request, session: session)
        switch http.statusCode {
        case 200: break
        case 401, 403: throw OllamaUsageError.apiUnauthorized
        default: throw OllamaUsageError.requestFailed(http.statusCode)
        }
        return try parseAPIBalance(data, now: now)
    }

    static func parseAPIBalance(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let invalid = OllamaUsageError.parseFailed(AppLocalization.text(
            "无法识别额度余额数据。", "Unrecognized credit balance response."
        ))
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw invalid }
        var details: [UsageDetail] = []
        var monthlyPercent: Double?
        var resetsAt: Date?
        if let purchased = root["purchased"], !(purchased is NSNull) {
            guard let wallet = purchased as? [String: Any], let balance = amount(wallet["balance_usd"]) else {
                throw invalid
            }
            details.append(UsageDetail(id: "ollama-credit-balance", label: "Credit balance", value: usd(balance)))
        }
        if let included = root["included"], !(included is NSNull) {
            guard let wallet = included as? [String: Any],
                  let allowance = amount(wallet["allowance_usd"]), allowance >= 0,
                  let balance = amount(wallet["balance_usd"]) else { throw invalid }
            let used = max(0, allowance - balance)
            guard used.isFinite else { throw invalid }
            details.append(UsageDetail(id: "ollama-monthly-used", label: "Monthly credits used", value: usd(used)))
            if allowance > 0 { monthlyPercent = min(100, used / allowance * 100) }
            if let period = wallet["period"], !(period is NSNull) {
                guard let period = period as? [String: Any] else { throw invalid }
                if let until = period["until"], !(until is NSNull) {
                    guard let raw = until as? String,
                          raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                                    options: .regularExpression) != nil,
                          let date = isoDate(raw), validCalendarDate(raw) else { throw invalid }
                    resetsAt = date
                }
            }
        }
        guard !details.isEmpty else { throw invalid }
        return providerUsage(Snapshot(
            plan: nil, email: nil, monthlyUsedPercent: monthlyPercent, monthlyResetsAt: resetsAt,
            sessionUsedPercent: nil, weeklyUsedPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
            details: details
        ), now: now)
    }

    private static func amount(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    private static func validCalendarDate(_ raw: String) -> Bool {
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let parsed = calendar.dateComponents([.year, .month, .day], from: date)
        return parsed.year == parts[0] && parsed.month == parts[1] && parsed.day == parts[2]
    }

    private static func fetchWeb(
        candidates: [CookieCandidate],
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var lastError: Error = OllamaUsageError.noSessionCookie
        for candidate in candidates {
            do {
                var request = URLRequest(url: settingsURL)
                request.timeoutInterval = 20
                request.setValue(candidate.header, forHTTPHeaderField: "Cookie")
                request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                request.setValue("https://ollama.com", forHTTPHeaderField: "Origin")
                request.setValue(settingsURL.absoluteString, forHTTPHeaderField: "Referer")
                request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
                let redirectDelegate = RedirectDelegate(cookieHeader: candidate.header)
                let requestSession = URLSession(
                    configuration: session.configuration,
                    delegate: redirectDelegate,
                    delegateQueue: nil
                )
                defer { requestSession.finishTasksAndInvalidate() }
                let (data, response) = try await response(for: request, session: requestSession)
                if response.statusCode == 200, isSignInLanding(response.url) {
                    throw OllamaUsageError.invalidCredentials
                }
                switch response.statusCode {
                case 200: break
                case 401, 403: throw OllamaUsageError.invalidCredentials
                default: throw OllamaUsageError.requestFailed(response.statusCode)
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    throw OllamaUsageError.parseFailed("Invalid UTF-8 response.")
                }
                return try parseSettingsHTML(html, now: now)
            } catch {
                lastError = error
                guard shouldTryNextCookie(after: error) else { throw error }
            }
        }
        throw lastError
    }

    private static func response(for request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OllamaUsageError.networkError("Invalid response")
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaUsageError {
            throw error
        } catch {
            throw OllamaUsageError.networkError(error.localizedDescription)
        }
    }

    private static func automaticCookieCandidates() throws -> [CookieCandidate] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["ollama.com", "www.ollama.com"])
        let order = [Browser.chrome] + Browser.defaultImportOrder.filter { $0 != .chrome }
        var candidates: [CookieCandidate] = []
        var accessError: OllamaUsageError?
        for browser in order {
            let sources: [BrowserCookieStoreRecords]
            do {
                sources = try client.records(matching: query, in: browser)
            } catch let BrowserCookieError.accessDenied(deniedBrowser, _) {
                let mapped: OllamaUsageError = deniedBrowser == .safari
                    ? .safariCookieAccessDenied
                    : .browserCookieAccessDenied(deniedBrowser.displayName)
                if deniedBrowser != .safari || accessError == nil { accessError = mapped }
                continue
            } catch {
                continue
            }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard cookies.contains(where: { isSessionCookieName($0.name) }) else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                candidates.append(CookieCandidate(header: header))
            }
        }
        if candidates.isEmpty, let accessError { throw accessError }
        return candidates
    }

    private static func resolvedValidationURL(tagsURL: URL, override: URL?) throws -> URL {
        let validation = override
            ?? (tagsURL == Self.tagsURL
                ? Self.validationURL
                : tagsURL.deletingLastPathComponent().appendingPathComponent("web_search"))
        guard isSecureEndpoint(tagsURL), isSecureEndpoint(validation) else {
            throw OllamaUsageError.networkError("Ollama API endpoints must use HTTPS or loopback HTTP.")
        }
        guard sameOrigin(tagsURL, validation) else {
            throw OllamaUsageError.networkError(
                "Ollama key validation and model catalog endpoints must share an origin."
            )
        }
        return validation
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return url.host != nil }
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        if url.scheme?.lowercased() == "https" { return 443 }
        if url.scheme?.lowercased() == "http" { return 80 }
        return nil
    }

    private static func shouldTryNextCookie(after error: Error) -> Bool {
        switch error {
        case OllamaUsageError.invalidCredentials, OllamaUsageError.notLoggedIn:
            true
        case let OllamaUsageError.parseFailed(message):
            message == "Missing Ollama usage data."
        default:
            false
        }
    }

    private struct UsageBlock {
        let percent: Double
        let resetsAt: Date?
    }

    private static func parseCreditDetails(_ html: String) -> [UsageDetail] {
        let page = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression
        ).replacingOccurrences(of: "&nbsp;", with: " ")
        let heading = #"<h[1-6][^>]*>\s*Usage credits(?:\s*<span[^>]*>[^<]*</span\s*>)?\s*</h[1-6]\s*>"#
        guard let wallet = firstCapture(
            heading + #"(.*?)(?=</section\s*>|<h[1-6]\b|$)"#,
            in: page, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let amount = #"(\$(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
        let fields = [
            ("ollama-credit-balance", "Credit balance", #"^\s*(?:<div[^>]*>\s*)*<span[^>]*>\s*\#(amount)\s*</span\s*>"#),
            ("ollama-monthly-used", "Monthly credits used",
             #"<span[^>]*>\s*Monthly credits used\s*</span\s*>\s*<span[^>]*>\s*\#(amount)\s*</span\s*>"#),
            ("ollama-next-refill", "Next refill",
             #"<p[^>]*>\s*Refills\s+(to\s+\#(amount)\s+in\s+[^<]{1,160}?)\s*</p\s*>"#),
        ]
        let details = fields.compactMap { id, label, pattern in
            firstCapture(pattern, in: wallet, options: [.caseInsensitive])
                .map { UsageDetail(id: id, label: label, value: id == "ollama-next-refill" ? refillText($0) : $0) }
        }
        return details.contains(where: { $0.id != "ollama-next-refill" }) ? details : []
    }

    private static func refillText(_ text: String) -> String {
        let pattern = #"^to\s+(\$[0-9,.]+)\s+in\s+([0-9]+(?:\.[0-9]+)?)\s+(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let countRange = Range(match.range(at: 2), in: text),
              let unitRange = Range(match.range(at: 3), in: text) else { return text }
        let units = ["second": "秒", "minute": "分钟", "hour": "小时", "day": "天", "week": "周", "month": "个月", "year": "年"]
        let unit = text[unitRange].lowercased()
        guard let chineseUnit = units[unit.hasSuffix("s") ? String(unit.dropLast()) : unit] else { return text }
        return AppLocalization.text("\(text[countRange]) \(chineseUnit)后补充至 \(text[amountRange])", text)
    }

    private static func parseUsageBlock(labels: [String], html: String) -> UsageBlock? {
        for label in labels {
            guard let labelRange = html.range(of: #">\s*\#(label)\s*<"#, options: .regularExpression) else { continue }
            let tail = String(html[labelRange.upperBound...])
            let boundary = usageLabels
                .filter { $0 != label }
                .compactMap { tail.range(of: #">\s*\#($0)\s*<"#, options: .regularExpression)?.lowerBound }
                .min()
            let bounded = boundary.map { String(tail[..<$0]) } ?? String(tail.prefix(4000))
            let block = String(bounded.prefix(4000))
            let percent = firstCapture(
                #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#,
                in: block,
                options: [.caseInsensitive]
            ).flatMap(Double.init) ?? dollarUsedPercent(block) ?? firstCapture(
                #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#,
                in: block,
                options: [.caseInsensitive]
            ).flatMap(Double.init)
            guard let percent else { continue }
            return UsageBlock(percent: percent, resetsAt: parseISODate(block))
        }
        return nil
    }

    private static func dollarUsedPercent(_ text: String) -> Double? {
        let amount = #"((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
        let pattern = #"\$\#(amount)\s+of\s+\$\#(amount)\s+used"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let usedRange = Range(match.range(at: 1), in: text),
              let limitRange = Range(match.range(at: 2), in: text),
              let used = Double(text[usedRange].replacingOccurrences(of: ",", with: "")),
              let limit = Double(text[limitRange].replacingOccurrences(of: ",", with: "")),
              used.isFinite, limit.isFinite, limit > 0 else { return nil }
        let percent = used / limit * 100
        return percent.isFinite ? percent : nil
    }

    private static func parseISODate(_ text: String) -> Date? {
        guard let raw = firstCapture(#"data-time=\"([^\"]+)\""#, in: text) else { return nil }
        return isoDate(raw)
    }

    private static func isoDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        let heading = lower.contains("sign in to ollama") || lower.contains("log in to ollama")
        let route = lower.contains("/api/auth/signin") || lower.contains("/auth/signin")
            || lower.contains("action=\"/login\"") || lower.contains("action='/login'")
            || lower.contains("href=\"/login\"") || lower.contains("href='/login'")
            || lower.contains("action=\"/signin\"") || lower.contains("action='/signin'")
            || lower.contains("href=\"/signin\"") || lower.contains("href='/signin'")
        let password = lower.contains("type=\"password\"") || lower.contains("type='password'")
        let email = lower.contains("type=\"email\"") || lower.contains("type='email'")
        let form = lower.contains("<form")
        return (heading && form && (email || password || route)) || (form && route) || (form && password && email)
    }

    private static func cookiePairs(_ header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { component in
            let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else { return nil }
            let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (String(name), String(value))
        }
    }

    private static func isSessionCookieName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if sessionCookieNames.contains(where: { $0.lowercased() == lower }) { return true }
        return lower.hasPrefix("__secure-next-auth.session-token.")
            || lower.hasPrefix("next-auth.session-token.")
    }

    private static func looksLikeCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("cookie:") || lower.hasPrefix("curl ")
            || cookiePairs(value).contains(where: { isSessionCookieName($0.name) })
    }

    private static func cleanedCredential(_ raw: String?) -> String? {
        guard var value = cleaned(raw) else { return nil }
        if value == "\"" || value == "'" { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func firstCapture(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let cookieHeader: String

        init(cookieHeader: String) {
            self.cookieHeader = cookieHeader
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var request = request
            if shouldAttachCookie(to: request.url) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            } else {
                request.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            request.setValue(response.url?.absoluteString, forHTTPHeaderField: "Referer")
            completionHandler(request)
        }
    }
}
