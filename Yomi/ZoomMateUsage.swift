import CryptoKit
import Foundation
import SweetCookieKit

nonisolated enum ZoomMateUsageError: LocalizedError, Equatable {
    case noCapture
    case noSession
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCapture:
            AppLocalization.text(
                "请粘贴 ai.zoom.us 或 zoommate.zoom.us 的 HTTPS credits/status 完整 cURL 请求",
                "Paste the full HTTPS credits/status cURL request from ai.zoom.us or zoommate.zoom.us."
            )
        case .noSession:
            AppLocalization.text(
                "未找到 ZoomMate 缓存会话或 Chrome 会话，请先在 Chrome 登录 zoommate.zoom.us 后手动刷新",
                "No cached ZoomMate session or Chrome session was found. Sign in to zoommate.zoom.us in Chrome and refresh manually."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "ZoomMate 会话已失效，请重新登录 Chrome 或粘贴新的 cURL 请求",
                "ZoomMate rejected the current session. Sign in again in Chrome or paste a fresh cURL request."
            )
        case let .apiError(message):
            AppLocalization.text("ZoomMate 接口错误：\(message)", "ZoomMate API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 ZoomMate 用量：\(message)", "Could not parse ZoomMate usage: \(message)")
        }
    }
}

nonisolated struct ZoomMateCookieHeaders: Codable, Equatable, Sendable {
    static let allowedHosts = ["ai.zoom.us", "zoommate.zoom.us"]
    private let headersByHost: [String: String]

    init(headersByHost: [String: String]) {
        self.headersByHost = Dictionary(uniqueKeysWithValues: Self.allowedHosts.compactMap { host in
            guard let value = headersByHost[host]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return (host, value)
        })
    }

    func header(forHost host: String) -> String? { headersByHost[host.lowercased()] }
    var isEmpty: Bool { headersByHost.isEmpty }

    func encodedForStorage() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFromStorage(_ value: String?) -> Self? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated struct ZoomMateCreditStatus: Decodable, Sendable, Equatable {
    let budgetCap: Double?
    let usedCredit: Double?
    let remainingCredit: Double?
    let overageCredit: Double?
    let allowOverage: Bool?
    let cycleStartDate: Int64?
    let cycleEndDate: Int64?
    let isQuotaAvailable: Bool?
    let isUnlimited: Bool?

    private enum CodingKeys: String, CodingKey {
        case budgetCap = "budget_cap"
        case usedCredit = "used_credit"
        case remainingCredit = "remaining_credit"
        case overageCredit = "overage_credit"
        case allowOverage = "allow_overage"
        case cycleStartDate = "cycle_start_date"
        case cycleEndDate = "cycle_end_date"
        case isQuotaAvailable = "is_quota_available"
        case isUnlimited = "is_unlimited"
    }

    init(
        budgetCap: Double? = nil,
        usedCredit: Double? = nil,
        remainingCredit: Double? = nil,
        overageCredit: Double? = nil,
        allowOverage: Bool? = nil,
        cycleStartDate: Int64? = nil,
        cycleEndDate: Int64? = nil,
        isQuotaAvailable: Bool? = nil,
        isUnlimited: Bool? = nil
    ) {
        self.budgetCap = budgetCap
        self.usedCredit = usedCredit
        self.remainingCredit = remainingCredit
        self.overageCredit = overageCredit
        self.allowOverage = allowOverage
        self.cycleStartDate = cycleStartDate
        self.cycleEndDate = cycleEndDate
        self.isQuotaAvailable = isQuotaAvailable
        self.isUnlimited = isUnlimited
    }
}

nonisolated struct ZoomMateCreditHistoryRecord: Decodable, Sendable, Equatable {
    let sessionID: String?
    let title: String?
    let cost: Double?
    let time: String?
    let isRunning: Bool?
    let isDeleted: Bool?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title, cost, time
        case isRunning = "is_running"
        case isDeleted = "is_deleted"
    }

    init(
        sessionID: String? = nil,
        title: String? = nil,
        cost: Double? = nil,
        time: String? = nil,
        isRunning: Bool? = nil,
        isDeleted: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cost = cost
        self.time = time
        self.isRunning = isRunning
        self.isDeleted = isDeleted
    }
}

nonisolated struct ZoomMateCreditDailyBreakdown: Sendable, Equatable {
    let day: String
    let totalCreditsUsed: Double
}

nonisolated struct ZoomMateCreditsHistorySnapshot: Sendable, Equatable {
    let records: [ZoomMateCreditHistoryRecord]
    let creditStatus: ZoomMateCreditStatus?
    let updatedAt: Date

    func dailyBreakdown(calendar: Calendar = .current, now: Date = Date()) -> [ZoomMateCreditDailyBreakdown] {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let since = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -29, to: now) ?? now
        )
        var totals: [String: Double] = [:]
        for record in records {
            guard record.isDeleted != true,
                  let cost = record.cost, cost >= 0,
                  let rawTime = record.time,
                  let date = ZoomMateUsageFetcher.parseRecordTime(rawTime),
                  date >= since
            else { continue }
            totals[dayFormatter.string(from: date), default: 0] += cost
        }
        return totals.map { ZoomMateCreditDailyBreakdown(day: $0.key, totalCreditsUsed: $0.value) }
            .sorted { $0.day < $1.day }
    }

    func todayCreditsUsed(calendar: Calendar = .current, now: Date = Date()) -> Double? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: now)
        return dailyBreakdown(calendar: calendar, now: now).first { $0.day == key }?.totalCreditsUsed
    }
}

nonisolated struct ZoomMateUsageSnapshot: Sendable, Equatable {
    let creditStatus: ZoomMateCreditStatus
    let updatedAt: Date

    func toProviderUsage(
        history: ZoomMateCreditsHistorySnapshot? = nil,
        accountEmail _: String? = nil,
        language _: AppLanguage = AppLocalization.currentLanguage
    ) -> ProviderUsage {
        let budget = creditStatus.budgetCap ?? 0
        let used = creditStatus.usedCredit ?? 0
        let unlimited = creditStatus.isUnlimited ?? false
        let fraction = unlimited || budget <= 0 ? 0 : min(1, max(0, used / budget))
        let reset = unlimited || budget <= 0
            ? nil
            : ZoomMateUsageFetcher.date(fromMilliseconds: creditStatus.cycleEndDate)
        var details: [UsageDetail] = []
        if let history {
            let breakdown = history.dailyBreakdown(now: updatedAt)
            details.append(UsageDetail(
                id: "zoommate-today",
                label: "Today",
                value: Self.creditsString(history.todayCreditsUsed(now: updatedAt) ?? 0)
            ))
            details.append(UsageDetail(
                id: "zoommate-30d",
                label: "30d credits",
                value: Self.creditsString(breakdown.reduce(0) { $0 + $1.totalCreditsUsed })
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "zoommate"),
            state: .ready,
            windows: [UsageWindow(
                id: "zoommate-credits",
                label: "Credits",
                usedFraction: fraction,
                resetsAt: reset,
                detail: "Credits"
            )],
            details: details,
            updatedAt: updatedAt
        )
    }

    private static func creditsString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

nonisolated enum ZoomMateCookieImporter {
    struct SessionInfo: Sendable {
        let cookieHeaders: ZoomMateCookieHeaders
        let sourceLabel: String
    }

    static func isSendable(cookieDomain: String, scope: BrowserCookieScope, toHost host: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix(".").lowercased()
        let host = host.lowercased()
        guard ZoomMateCookieHeaders.allowedHosts.contains(host), !domain.isEmpty else { return false }
        switch scope {
        case .hostOnly: return host == domain
        case .domain: return host == domain || host.hasSuffix("." + domain)
        }
    }

    static func cookieHeaders(from records: [BrowserCookieRecord]) -> ZoomMateCookieHeaders {
        let pairs = ZoomMateCookieHeaders.allowedHosts.compactMap { host -> (String, String)? in
            let sendable = records.filter {
                isSendable(cookieDomain: $0.domain, scope: $0.scope, toHost: host)
            }
            guard !sendable.isEmpty else { return nil }
            return (host, sendable.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
        return ZoomMateCookieHeaders(headersByHost: Dictionary(uniqueKeysWithValues: pairs))
    }

    static func importSessions() throws -> [SessionInfo] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["zoommate.zoom.us", "ai.zoom.us", "zoom.us"])
        var sessions: [SessionInfo] = []
        if let sources = try? client.records(matching: query, in: .chrome) {
            for source in sources where !source.records.isEmpty {
                let headers = cookieHeaders(from: source.records)
                guard !headers.isEmpty else { continue }
                sessions.append(SessionInfo(
                    cookieHeaders: headers,
                    sourceLabel: "Chrome:\(source.store.profile.name)"
                ))
            }
        }
        guard !sessions.isEmpty else { throw ZoomMateUsageError.noSession }
        return sessions
    }
}

actor ZoomMateBearerTokenCache {
    static let shared = ZoomMateBearerTokenCache()
    static let refreshSkew: TimeInterval = 60

    struct Entry: Sendable, Equatable {
        let token: String
        let accountEmail: String?
        let expiry: Date
    }

    private var entries: [String: Entry] = [:]

    static func key(forCookieHeaders headers: ZoomMateCookieHeaders) -> String {
        let digest = SHA256.hash(data: Data((headers.encodedForStorage() ?? "").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func validEntry(forKey key: String, now: Date) -> Entry? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiry.addingTimeInterval(-Self.refreshSkew) > now else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    func store(_ entry: Entry, forKey key: String) { entries[key] = entry }
    func invalidate(forKey key: String) { entries[key] = nil }
}

nonisolated enum ZoomMateUsageFetcher {
    struct RequestContext: Sendable, Equatable {
        let authorization: String
        let headers: [String: String]
        let cookieHeaders: ZoomMateCookieHeaders
        let preferredHost: String?
        let accountEmail: String?
        let cacheKey: String?

        init(
            authorization: String,
            headers: [String: String] = [:],
            cookieHeaders: ZoomMateCookieHeaders = ZoomMateCookieHeaders(headersByHost: [:]),
            preferredHost: String? = nil,
            accountEmail: String? = nil,
            cacheKey: String? = nil
        ) {
            self.authorization = authorization
            self.headers = headers
            self.cookieHeaders = cookieHeaders
            self.preferredHost = preferredHost
            self.accountEmail = accountEmail
            self.cacheKey = cacheKey
        }
    }

    struct MintedToken: Sendable, Equatable {
        let bearerToken: String
        let accountEmail: String?
    }

    static let apiHosts = ZoomMateCookieHeaders.allowedHosts
    static let creditsStatusPath = "/ai-computer/api/v1/credits/status"
    static let historyPath = "/ai-computer/api/v1/credits/history"
    static let defaultPageLimit = 50
    static let maxPages = 20
    private static let origin = "https://zoommate.zoom.us"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let forwardedManualHeaders = [
        "authorization": "Authorization", "cookie": "Cookie", "user-agent": "User-Agent",
        "accept": "Accept", "accept-language": "Accept-Language", "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode", "sec-fetch-site": "Sec-Fetch-Site",
    ]

    static func fetch(
        credential: String?,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeaders: String? = nil,
        allowBrowserImport: Bool = false,
        cacheUpdate: @escaping @Sendable (String?) async -> Void = { _ in },
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let context: RequestContext
        switch source {
        case .cookie, .token:
            guard let parsed = requestContext(from: credential) else { throw ZoomMateUsageError.noCapture }
            context = parsed
        case .automatic, .account:
            context = try await automaticContext(
                cachedCookieHeaders: cachedCookieHeaders,
                allowBrowserImport: allowBrowserImport,
                cacheUpdate: cacheUpdate,
                session: session
            )
        case .command, .endpoint:
            throw ZoomMateUsageError.noSession
        }
        return try await fetchProviderUsage(
            context: context,
            source: source,
            session: session,
            cachedCookieHeaders: cachedCookieHeaders,
            allowBrowserImport: allowBrowserImport,
            cacheUpdate: cacheUpdate,
            now: now
        )
    }

    private static func fetchProviderUsage(
        context: RequestContext,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeaders: String?,
        allowBrowserImport: Bool,
        cacheUpdate: @escaping @Sendable (String?) async -> Void,
        now: Date
    ) async throws -> ProviderUsage {
        let status: ZoomMateUsageSnapshot
        do {
            status = try await fetchCreditsStatus(context: context, session: session, now: now)
        } catch ZoomMateUsageError.invalidCredentials
            where source == .automatic || source == .account {
            if let key = context.cacheKey { await ZoomMateBearerTokenCache.shared.invalidate(forKey: key) }
            await cacheUpdate(nil)
            guard cachedCookieHeaders != nil else {
                throw ZoomMateUsageError.invalidCredentials
            }
            guard allowBrowserImport else {
                throw ZoomMateUsageError.noSession
            }
            let fresh = try await importedContext(cacheUpdate: cacheUpdate, session: session)
            return try await fetchProviderUsage(
                context: fresh,
                source: source,
                session: session,
                cachedCookieHeaders: nil,
                allowBrowserImport: false,
                cacheUpdate: cacheUpdate,
                now: now
            )
        }

        var history: ZoomMateCreditsHistorySnapshot?
        do {
            let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            history = try await fetchHistory(
                context: context,
                startTime: start,
                endTime: now,
                creditStatus: status.creditStatus,
                session: session,
                now: now
            )
        } catch ZoomMateUsageError.invalidCredentials {
            if let key = context.cacheKey { await ZoomMateBearerTokenCache.shared.invalidate(forKey: key) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            history = nil
        }
        return status.toProviderUsage(history: history, accountEmail: context.accountEmail)
    }

    private static func automaticContext(
        cachedCookieHeaders: String?,
        allowBrowserImport: Bool,
        cacheUpdate: @escaping @Sendable (String?) async -> Void,
        session: URLSession
    ) async throws -> RequestContext {
        if let headers = ZoomMateCookieHeaders.decodeFromStorage(cachedCookieHeaders), !headers.isEmpty {
            do {
                return try await requestContext(forCookieHeaders: headers, session: session)
            } catch ZoomMateUsageError.invalidCredentials {
                await cacheUpdate(nil)
                guard allowBrowserImport else { throw ZoomMateUsageError.noSession }
                return try await importedContext(cacheUpdate: cacheUpdate, session: session)
            }
        }
        guard allowBrowserImport else { throw ZoomMateUsageError.noSession }
        return try await importedContext(cacheUpdate: cacheUpdate, session: session)
    }

    private static func importedContext(
        cacheUpdate: @escaping @Sendable (String?) async -> Void,
        session: URLSession
    ) async throws -> RequestContext {
        let sessions = try ZoomMateCookieImporter.importSessions()
        var sawInvalid = false
        for candidate in sessions {
            do {
                let context = try await requestContext(forCookieHeaders: candidate.cookieHeaders, session: session)
                await cacheUpdate(candidate.cookieHeaders.encodedForStorage())
                return context
            } catch ZoomMateUsageError.invalidCredentials {
                sawInvalid = true
            }
        }
        throw sawInvalid ? ZoomMateUsageError.invalidCredentials : ZoomMateUsageError.noSession
    }

    static func requestContext(
        forCookieHeaders headers: ZoomMateCookieHeaders,
        cache: ZoomMateBearerTokenCache = .shared,
        session: URLSession,
        now: Date = Date()
    ) async throws -> RequestContext {
        let key = ZoomMateBearerTokenCache.key(forCookieHeaders: headers)
        let minted: MintedToken
        if let entry = await cache.validEntry(forKey: key, now: now) {
            minted = MintedToken(bearerToken: entry.token, accountEmail: entry.accountEmail)
        } else {
            minted = try await mintBearerToken(cookieHeaders: headers, session: session)
            if let expiry = expiry(fromJWT: minted.bearerToken) {
                await cache.store(.init(
                    token: minted.bearerToken,
                    accountEmail: minted.accountEmail,
                    expiry: expiry
                ), forKey: key)
            }
        }
        return RequestContext(
            authorization: bearerHeaderValue(from: minted.bearerToken),
            cookieHeaders: headers,
            accountEmail: minted.accountEmail,
            cacheKey: key
        )
    }

    static func mintBearerToken(
        cookieHeaders: ZoomMateCookieHeaders,
        session: URLSession,
        timeout: TimeInterval = 15
    ) async throws -> MintedToken {
        try await withHostFailover { host in
            var components = URLComponents(string: "https://\(host)/ai-computer/api/v1/login/")!
            components.queryItems = [URLQueryItem(name: "continue", value: "https://zoommate.zoom.us/")]
            guard let url = components.url else { throw ZoomMateUsageError.apiError("Invalid login URL") }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            applyDefaultHeaders(to: &request)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin, forHTTPHeaderField: "Referer")
            request.setValue(cookieHeaders.header(forHost: host), forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            let http = try httpResponse(response)
            guard http.statusCode == 200 else { throw statusError(http.statusCode) }
            do {
                let envelope = try JSONDecoder().decode(LoginEnvelope.self, from: data)
                guard let token = envelope.data?.nak, !token.isEmpty else {
                    throw ZoomMateUsageError.parseFailed("Missing nak in login bootstrap response.")
                }
                let email = envelope.data?.userProfile?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                return MintedToken(
                    bearerToken: token,
                    accountEmail: (email?.isEmpty ?? true) ? nil : email
                )
            } catch let error as ZoomMateUsageError {
                throw error
            } catch {
                throw ZoomMateUsageError.parseFailed(error.localizedDescription)
            }
        }
    }

    static func fetchCreditsStatus(
        context: RequestContext,
        session: URLSession,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> ZoomMateUsageSnapshot {
        try await withHostFailover(hosts: hosts(preferred: context.preferredHost)) { host in
            var request = URLRequest(url: URL(string: "https://\(host)\(creditsStatusPath)")!)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            applyDefaultHeaders(to: &request)
            applyContext(context, host: host, to: &request)
            let (data, response) = try await session.data(for: request)
            let http = try httpResponse(response)
            guard http.statusCode == 200 else { throw statusError(http.statusCode) }
            do {
                let envelope = try JSONDecoder().decode(StatusEnvelope.self, from: data)
                guard let status = envelope.data?.creditStatus else {
                    throw ZoomMateUsageError.parseFailed("Missing credit_status object.")
                }
                return ZoomMateUsageSnapshot(creditStatus: status, updatedAt: now)
            } catch let error as ZoomMateUsageError {
                throw error
            } catch {
                throw ZoomMateUsageError.parseFailed(error.localizedDescription)
            }
        }
    }

    static func fetchHistory(
        context: RequestContext,
        startTime: Date,
        endTime: Date,
        creditStatus: ZoomMateCreditStatus? = nil,
        limit: Int = defaultPageLimit,
        session: URLSession,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> ZoomMateCreditsHistorySnapshot {
        try await withHostFailover(hosts: hosts(preferred: context.preferredHost)) { host in
            var records: [ZoomMateCreditHistoryRecord] = []
            var page = 0
            var total = Int.max
            while page * limit < total, page < maxPages {
                var components = URLComponents(string: "https://\(host)\(historyPath)")!
                components.queryItems = [
                    URLQueryItem(name: "app_id", value: "demo_app"),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "sort_by", value: "time"),
                    URLQueryItem(name: "sort_order", value: "desc"),
                    URLQueryItem(name: "start_time", value: iso8601(startTime)),
                    URLQueryItem(name: "end_time", value: iso8601(endTime)),
                ]
                guard let url = components.url else { throw ZoomMateUsageError.apiError("Invalid history URL") }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = timeout
                applyDefaultHeaders(to: &request)
                applyContext(context, host: host, to: &request)
                let (data, response) = try await session.data(for: request)
                let http = try httpResponse(response)
                guard http.statusCode == 200 else { throw statusError(http.statusCode) }
                let envelope: HistoryEnvelope
                do {
                    envelope = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
                } catch {
                    throw ZoomMateUsageError.parseFailed(error.localizedDescription)
                }
                guard let box = envelope.data else {
                    throw ZoomMateUsageError.parseFailed("Missing data object in credits/history response.")
                }
                let pageRecords = box.records ?? []
                records.append(contentsOf: pageRecords)
                total = box.total ?? records.count
                if pageRecords.isEmpty { break }
                if pageRecords.allSatisfy({
                    guard let raw = $0.time, let date = parseRecordTime(raw) else { return false }
                    return date < startTime
                }) { break }
                page += 1
            }
            return ZoomMateCreditsHistorySnapshot(records: records, creditStatus: creditStatus, updatedAt: now)
        }
    }

    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = cleaned(raw),
              let url = ZoomMateCurlCapture.requestURL(from: raw),
              isAllowedCaptureURL(url),
              let host = url.host?.lowercased()
        else { return nil }
        let fields = ZoomMateCurlCapture.headerFields(from: raw)
        guard let authorization = ZoomMateCurlCapture.headerValue(named: "Authorization", in: fields) else {
            return nil
        }
        var headers = ZoomMateCurlCapture.forwardedHeaders(from: fields, allowlist: forwardedManualHeaders)
        headers.removeValue(forKey: "Authorization")
        let cookie = headers.removeValue(forKey: "Cookie")
        return RequestContext(
            authorization: bearerHeaderValue(from: authorization),
            headers: headers,
            cookieHeaders: ZoomMateCookieHeaders(headersByHost: cookie.map { [host: $0] } ?? [:]),
            preferredHost: host
        )
    }

    static func expiry(fromJWT token: String) -> Date? {
        let normalized = bearerHeaderValue(from: token)
        let raw = normalized.dropFirst("Bearer ".count)
        let parts = raw.split(separator: ".")
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = (object["exp"] as? NSNumber)?.doubleValue,
              expiry > 0
        else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    static func bearerHeaderValue(from raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.lowercased().hasPrefix("bearer ") ? value : "Bearer \(value)"
    }

    static func hosts(preferred: String?) -> [String] {
        guard let host = preferred?.lowercased(), apiHosts.contains(host) else { return apiHosts }
        return [host] + apiHosts.filter { $0 != host }
    }

    static func parseRecordTime(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func date(fromMilliseconds value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }

    static func withHostFailover<T: Sendable>(
        hosts: [String] = apiHosts,
        operation: (String) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for host in hosts {
            try Task.checkCancellation()
            do { return try await operation(host) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch ZoomMateUsageError.invalidCredentials { throw ZoomMateUsageError.invalidCredentials }
            catch let ZoomMateUsageError.parseFailed(message) { throw ZoomMateUsageError.parseFailed(message) }
            catch { lastError = error }
        }
        throw lastError ?? ZoomMateUsageError.apiError("No ZoomMate API host succeeded.")
    }

    private static func isAllowedCaptureURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return url.scheme?.lowercased() == "https"
            && apiHosts.contains(host)
            && url.port == nil && url.user == nil && url.password == nil
            && url.path == creditsStatusPath && url.query == nil && url.fragment == nil
    }

    private static func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
    }

    private static func applyContext(_ context: RequestContext, host: String, to request: inout URLRequest) {
        for (name, value) in context.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(context.cookieHeaders.header(forHost: host), forHTTPHeaderField: "Cookie")
        request.setValue(context.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "Referer")
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ZoomMateUsageError.apiError("Invalid HTTP response")
        }
        return http
    }

    private static func statusError(_ status: Int) -> ZoomMateUsageError {
        status == 401 || status == 403 ? .invalidCredentials : .apiError("HTTP \(status)")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private struct StatusEnvelope: Decodable {
        struct DataBox: Decodable {
            let creditStatus: ZoomMateCreditStatus?
            private enum CodingKeys: String, CodingKey { case creditStatus = "credit_status" }
        }
        let data: DataBox?
    }

    private struct LoginEnvelope: Decodable {
        struct UserProfile: Decodable { let email: String? }
        struct DataBox: Decodable {
            let nak: String?
            let userProfile: UserProfile?
            private enum CodingKeys: String, CodingKey { case nak; case userProfile = "user_profile" }
        }
        let data: DataBox?
    }

    private struct HistoryEnvelope: Decodable {
        struct DataBox: Decodable {
            let records: [ZoomMateCreditHistoryRecord]?
            let total: Int?
        }
        let data: DataBox?
    }
}

private nonisolated enum ZoomMateCurlCapture {
    static func requestURL(from raw: String) -> URL? {
        let pattern = #"(?s)(?:^|\s)curl\s+(?:\$'((?:\\.|[^'])*)'|'([^']*)'|\"((?:\\.|[^\"])*)\"|([^\s\\]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw))
        else { return nil }
        let value = capture(1, match, raw).map { unescape($0, ansi: true) }
            ?? capture(2, match, raw)
            ?? capture(3, match, raw).map { unescape($0, ansi: false) }
            ?? capture(4, match, raw).map { unescape($0, ansi: false) }
        guard let value, let url = URL(string: value), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    static func headerFields(from raw: String) -> [String] {
        let pattern = #"(?s)(?:^|\s)(?:-H|--header)(?:\s+|=|(?=['\"$]))(?:\$'((?:\\.|[^'])*)'|'([^']*)'|\"((?:\\.|[^\"])*)\"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)).compactMap { match in
            capture(1, match, raw).map { unescape($0, ansi: true) }
                ?? capture(2, match, raw)
                ?? capture(3, match, raw).map { unescape($0, ansi: false) }
                ?? capture(4, match, raw).map { unescape($0, ansi: false) }
        }
    }

    static func headerValue(named name: String, in fields: [String]) -> String? {
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let fieldName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fieldName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func forwardedHeaders(from fields: [String], allowlist: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let name = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = allowlist[name.lowercased()], !value.isEmpty else { continue }
            result[canonical] = value
        }
        return result
    }

    private static func capture(_ index: Int, _ match: NSTextCheckingResult, _ raw: String) -> String? {
        guard match.numberOfRanges > index, let range = Range(match.range(at: index), in: raw) else { return nil }
        return String(raw[range])
    }

    private static func unescape(_ raw: String, ansi: Bool) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "\\" else {
                output.append(raw[index]); index = raw.index(after: index); continue
            }
            let next = raw.index(after: index)
            guard next < raw.endIndex else { return output }
            switch raw[next] {
            case "n" where ansi: output.append("\n")
            case "r" where ansi: output.append("\r")
            case "t" where ansi: output.append("\t")
            case "\n": break
            default: output.append(raw[next])
            }
            index = raw.index(after: next)
        }
        return output
    }
}
