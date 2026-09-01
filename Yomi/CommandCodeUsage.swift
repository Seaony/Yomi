import Foundation
import SweetCookieKit

nonisolated enum CommandCodeUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)
    case unknownPlan(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未找到 Command Code 浏览器会话，请先登录 commandcode.ai",
                "No Command Code browser session was found. Sign in to commandcode.ai first."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "Command Code 会话已失效，请重新登录",
                "The Command Code session has expired. Sign in again."
            )
        case let .networkError(message):
            AppLocalization.text(
                "Command Code 网络错误：\(message)",
                "Command Code network error: \(message)"
            )
        case let .apiError(status):
            AppLocalization.text(
                "Command Code 请求失败（HTTP \(status)）",
                "Command Code request failed (HTTP \(status))."
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Command Code 用量：\(message)",
                "Failed to parse Command Code usage: \(message)"
            )
        case let .unknownPlan(planID):
            AppLocalization.text(
                "未知的 Command Code 套餐：\(planID)",
                "Unknown Command Code plan: \(planID)"
            )
        }
    }
}

nonisolated enum CommandCodePlanCatalog {
    struct Plan: Sendable, Equatable {
        let id: String
        let displayName: String
        let monthlyCreditsUSD: Double
    }

    static let plans = [
        Plan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
        Plan(id: "individual-goat", displayName: "GOAT", monthlyCreditsUSD: 70),
        Plan(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
        Plan(id: "individual-pro-v1", displayName: "Pro", monthlyCreditsUSD: 80),
        Plan(id: "individual-max", displayName: "Max", monthlyCreditsUSD: 150),
        Plan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300),
    ]

    static func plan(forID id: String) -> Plan? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plans.first { $0.id == normalized }
    }
}

nonisolated struct CommandCodeCookieOverride: Sendable, Equatable {
    let name: String
    let token: String

    var headerValue: String { "\(name)=\(token)" }
}

nonisolated enum CommandCodeCookieHeader {
    static let supportedSessionCookieNames = [
        "__Secure-commandcode_prod_.session_token",
        "commandcode_prod_.session_token",
        "__Host-commandcode_prod_.session_token",
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]

    static func override(from raw: String?) -> CommandCodeCookieOverride? {
        guard let raw = cleaned(raw) else { return nil }
        if !raw.contains("="), !raw.contains(";") {
            return CommandCodeCookieOverride(
                name: "__Secure-better-auth.session_token",
                token: raw
            )
        }
        return sessionCookie(from: cookiePairs(raw))
    }

    static func sessionCookie(from cookies: [HTTPCookie]) -> CommandCodeCookieOverride? {
        sessionCookie(from: cookies.map { (name: $0.name, value: $0.value) })
    }

    private static func sessionCookie(
        from pairs: [(name: String, value: String)]
    ) -> CommandCodeCookieOverride? {
        var byName: [String: (name: String, value: String)] = [:]
        for pair in pairs {
            byName[pair.name.lowercased()] = pair
        }
        for supported in supportedSessionCookieNames {
            if let match = byName[supported.lowercased()] {
                return CommandCodeCookieOverride(name: match.name, token: match.value)
            }
        }
        return nil
    }

    private static func cookiePairs(_ raw: String) -> [(name: String, value: String)] {
        raw.split(separator: ";").compactMap { chunk in
            let value = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = value.firstIndex(of: "=") else { return nil }
            let name = String(value[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let token = String(value[value.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !token.isEmpty else { return nil }
            return (name: name, value: token)
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

nonisolated struct CommandCodeUsageSnapshot: Sendable, Equatable {
    let monthlyCreditsRemaining: Double
    let purchasedCredits: Double
    let premiumMonthlyCredits: Double
    let opensourceMonthlyCredits: Double
    let fiveHourWindow: CommandCodeUsageFetcher.RollingWindow?
    let weeklyWindow: CommandCodeUsageFetcher.RollingWindow?
    let plan: CommandCodePlanCatalog.Plan?
    let billingPeriodEnd: Date?
    let subscriptionStatus: String?
    let subscriptionEnrichmentUnavailable: Bool
    let updatedAt: Date

    var monthlyCreditsTotal: Double? { plan?.monthlyCreditsUSD }

    var monthlyCreditsUsed: Double? {
        guard let total = monthlyCreditsTotal else { return nil }
        return max(0, min(total, total - monthlyCreditsRemaining))
    }

    func toProviderUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let fiveHourWindow {
            windows.append(fiveHourWindow.usageWindow(id: "commandcode-five-hour", label: "5-hour"))
        }
        if let weeklyWindow {
            windows.append(weeklyWindow.usageWindow(id: "commandcode-weekly", label: "Weekly"))
        }
        if let monthly = monthlyWindow() { windows.append(monthly) }

        return ProviderUsage(
            id: ProviderID(rawValue: "commandcode"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: plan?.displayName,
            details: [],
            commandCodeSubscriptionEnrichmentUnavailable: subscriptionEnrichmentUnavailable,
            commandCodeHasSubscriptionPlan: plan != nil,
            commandCodeMonthlyGrantDepleted: monthlyCreditsRemaining <= 0,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private func monthlyWindow() -> UsageWindow? {
        guard let total = monthlyCreditsTotal, total > 0 else { return nil }
        return UsageWindow(
            id: "commandcode-monthly",
            label: "Monthly",
            usedFraction: (monthlyCreditsUsed ?? 0) / total,
            resetsAt: billingPeriodEnd,
            detail: nil
        )
    }

}

nonisolated enum CommandCodeUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    struct CookieSession: Sendable, Equatable {
        let cookieHeader: String
        let sourceLabel: String
    }

    struct RollingWindow: Sendable, Equatable {
        let usedFraction: Double
        let windowMinutes: Int
        let resetsAt: Date?

        func usageWindow(id: String, label: String) -> UsageWindow {
            UsageWindow(
                id: id,
                label: label,
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                detail: nil
            )
        }
    }

    struct CreditsPayload: Sendable, Equatable {
        let monthlyCredits: Double
        let purchasedCredits: Double
        let premiumMonthlyCredits: Double
        let opensourceMonthlyCredits: Double
        let fiveHourWindow: RollingWindow?
        let weeklyWindow: RollingWindow?
    }

    struct SubscriptionPayload: Sendable, Equatable {
        let planID: String
        let status: String
        let currentPeriodEnd: Date?
    }

    static let apiBase = URL(string: "https://api.commandcode.ai")!
    static let creditsPath = "/internal/billing/credits"
    static let subscriptionsPath = "/internal/billing/subscriptions"
    static let cookieDomains = ["commandcode.ai", "www.commandcode.ai"]
    static let browserOrder = Browser.defaultImportOrder
    static let requestTimeout: TimeInterval = 15
    static let subscriptionGrace: Duration = .seconds(2)
    static let webOrigin = "https://commandcode.ai"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        now: Date = Date(),
        joinGrace: Duration = subscriptionGrace
    ) async throws -> ProviderUsage {
        let sessions: [CookieSession]
        switch source {
        case .cookie:
            guard let cookie = CommandCodeCookieHeader.override(from: credential) else {
                throw CommandCodeUsageError.missingCredentials
            }
            sessions = [CookieSession(cookieHeader: cookie.headerValue, sourceLabel: "Manual")]
        case .automatic, .account:
            var imported: [CookieSession] = []
            if let cached = cleaned(cachedCookieHeader) {
                imported.append(CookieSession(cookieHeader: cached, sourceLabel: "Cache"))
            }
            imported.append(contentsOf: automaticCookieSessions())
            sessions = deduplicated(imported)
        case .token, .command, .endpoint:
            throw CommandCodeUsageError.missingCredentials
        }
        guard !sessions.isEmpty else { throw CommandCodeUsageError.missingCredentials }
        return try await fetchFromSessions(
            sessions,
            session: session,
            cacheUpdate: cacheUpdate,
            shouldUpdateCache: source == .automatic || source == .account,
            now: now,
            joinGrace: joinGrace
        )
    }

    static func fetchFromSessions(
        _ sessions: [CookieSession],
        session: URLSession,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        shouldUpdateCache: Bool = true,
        now: Date = Date(),
        joinGrace: Duration = subscriptionGrace
    ) async throws -> ProviderUsage {
        var lastError: CommandCodeUsageError = .invalidCredentials
        for candidate in sessions {
            do {
                let snapshot = try await fetchSnapshot(
                    cookieHeader: candidate.cookieHeader,
                    session: session,
                    now: now,
                    joinGrace: joinGrace
                )
                if shouldUpdateCache { await cacheUpdate(candidate.cookieHeader) }
                return snapshot.toProviderUsage()
            } catch CommandCodeUsageError.invalidCredentials {
                lastError = .invalidCredentials
                if shouldUpdateCache, candidate.sourceLabel == "Cache" { await cacheUpdate(nil) }
            } catch let error as CommandCodeUsageError {
                throw error
            }
        }
        throw lastError
    }

    static func fetchSnapshot(
        cookieHeader: String,
        session: URLSession,
        now: Date = Date(),
        joinGrace: Duration = subscriptionGrace
    ) async throws -> CommandCodeUsageSnapshot {
        let subscriptionTask = Task<SubscriptionPayload?, Error> {
            try await fetchSubscription(cookieHeader: cookieHeader, session: session)
        }
        let credits: CreditsPayload
        do {
            credits = try await withTaskCancellationHandler {
                try await fetchCredits(cookieHeader: cookieHeader, session: session)
            } onCancel: {
                subscriptionTask.cancel()
            }
        } catch {
            subscriptionTask.cancel()
            throw error
        }

        do {
            try Task.checkCancellation()
        } catch {
            subscriptionTask.cancel()
            throw error
        }

        let subscription: SubscriptionPayload?
        let enrichmentUnavailable: Bool
        let join = CommandCodeBoundedTaskJoin(sourceTask: subscriptionTask)
        switch await join.value(joinGrace: joinGrace) {
        case let .value(value):
            try Task.checkCancellation()
            subscription = value
            enrichmentUnavailable = false
        case .timedOut:
            try Task.checkCancellation()
            subscription = nil
            enrichmentUnavailable = true
        case .failure:
            subscriptionTask.cancel()
            try Task.checkCancellation()
            subscription = nil
            enrichmentUnavailable = true
        }

        let plan = subscription.flatMap { CommandCodePlanCatalog.plan(forID: $0.planID) }
        if let subscription, subscription.status.lowercased() == "active", plan == nil {
            throw CommandCodeUsageError.unknownPlan(subscription.planID)
        }
        return CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: credits.monthlyCredits,
            purchasedCredits: credits.purchasedCredits,
            premiumMonthlyCredits: credits.premiumMonthlyCredits,
            opensourceMonthlyCredits: credits.opensourceMonthlyCredits,
            fiveHourWindow: credits.fiveHourWindow,
            weeklyWindow: credits.weeklyWindow,
            plan: plan,
            billingPeriodEnd: subscription?.currentPeriodEnd,
            subscriptionStatus: subscription?.status,
            subscriptionEnrichmentUnavailable: enrichmentUnavailable,
            updatedAt: now
        )
    }

    static func parseCredits(data: Data) throws -> CreditsPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Invalid JSON")
        }
        guard let credits = root["credits"] as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Missing credits")
        }
        guard let monthly = number(credits["monthlyCredits"]) else {
            throw CommandCodeUsageError.parseFailed("Missing monthlyCredits")
        }
        let limits = root["windowLimits"] as? [String: Any]
            ?? credits["windowLimits"] as? [String: Any]
        return CreditsPayload(
            monthlyCredits: monthly,
            purchasedCredits: number(credits["purchasedCredits"]) ?? 0,
            premiumMonthlyCredits: number(credits["premiumMonthlyCredits"]) ?? 0,
            opensourceMonthlyCredits: number(credits["opensourceMonthlyCredits"]) ?? 0,
            fiveHourWindow: rollingWindow(limits?["fiveHour"], windowMinutes: 5 * 60),
            weeklyWindow: rollingWindow(limits?["weekly"], windowMinutes: 7 * 24 * 60)
        )
    }

    static func parseSubscription(data: Data) throws -> SubscriptionPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Invalid subscription JSON")
        }
        guard root["success"] as? Bool == true else {
            throw CommandCodeUsageError.parseFailed("Subscription lookup failed")
        }
        guard root.keys.contains("data") else {
            throw CommandCodeUsageError.parseFailed("Missing subscription data")
        }
        if root["data"] is NSNull { return nil }
        guard let subscription = root["data"] as? [String: Any],
              let planID = cleaned(subscription["planId"] as? String)
        else {
            throw CommandCodeUsageError.parseFailed("Missing subscription planId")
        }
        return SubscriptionPayload(
            planID: planID,
            status: cleaned(subscription["status"] as? String) ?? "unknown",
            currentPeriodEnd: date(subscription["currentPeriodEnd"])
        )
    }

    static func automaticCookieSessions() -> [CookieSession] {
        CommandCodeImportSessionCache.shared.sessions {
            let client = BrowserCookieClient()
            let query = BrowserCookieQuery(domains: cookieDomains)
            var sessions: [CookieSession] = []
            for browser in browserOrder {
                guard let sources = try? client.records(matching: query, in: browser) else { continue }
                let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
                for group in groups.values.sorted(by: { mergedLabel($0) < mergedLabel($1) }) {
                    let records = mergedRecords(group)
                    let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    sessions.append(CookieSession(
                        cookieHeader: cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                        sourceLabel: mergedLabel(group)
                    ))
                }
            }
            return sessions
        }
    }

    static func mergedRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sources = sources.sorted { storePriority($0.store.kind) < storePriority($1.store.kind) }
        var merged: [String: BrowserCookieRecord] = [:]
        for source in sources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                if let existing = merged[key] {
                    if shouldReplace(existing: existing, candidate: record) { merged[key] = record }
                } else {
                    merged[key] = record
                }
            }
        }
        return Array(merged.values)
    }

    static func invalidateImportSessionCache() {
        CommandCodeImportSessionCache.shared.invalidate()
    }

    private static func fetchCredits(cookieHeader: String, session: URLSession) async throws -> CreditsPayload {
        let data = try await send(path: creditsPath, cookieHeader: cookieHeader, session: session)
        return try parseCredits(data: data)
    }

    private static func fetchSubscription(
        cookieHeader: String,
        session: URLSession
    ) async throws -> SubscriptionPayload? {
        let data = try await send(path: subscriptionsPath, cookieHeader: cookieHeader, session: session)
        return try parseSubscription(data: data)
    }

    private static func send(path: String, cookieHeader: String, session: URLSession) async throws -> Data {
        let url = apiBase.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(webOrigin)/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CommandCodeUsageError.networkError("Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CommandCodeUsageError.invalidCredentials
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CommandCodeUsageError.apiError(http.statusCode)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as CommandCodeUsageError {
            throw error
        } catch {
            throw CommandCodeUsageError.networkError(error.localizedDescription)
        }
    }

    private static func rollingWindow(_ raw: Any?, windowMinutes: Int) -> RollingWindow? {
        guard let object = raw as? [String: Any], let cap = number(object["cap"]), cap > 0 else {
            return nil
        }
        let used = number(object["used"]) ?? 0
        return RollingWindow(
            usedFraction: min(1, max(0, used / cap)),
            windowMinutes: windowMinutes,
            resetsAt: date(object["resetAt"])
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        if let string = raw as? String {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(value), number.isFinite { return number }
        }
        return nil
    }

    private static func date(_ raw: Any?) -> Date? {
        if let number = number(raw) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        }
        guard let string = cleaned(raw as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func mergedLabel(_ sources: [BrowserCookieStoreRecords]) -> String {
        guard let label = sources.map(\.label).min() else { return "Unknown" }
        return label.hasSuffix(" (Network)")
            ? String(label.dropLast(" (Network)".count))
            : label
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }

    private static func deduplicated(_ sessions: [CookieSession]) -> [CookieSession] {
        var result: [CookieSession] = []
        for session in sessions where !result.contains(where: { $0.cookieHeader == session.cookieHeader }) {
            result.append(session)
        }
        return result
    }
}

nonisolated final class CommandCodeImportSessionCache: @unchecked Sendable {
    static let shared = CommandCodeImportSessionCache(ttl: 5)

    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entry: (sessions: [CommandCodeUsageFetcher.CookieSession], expiresAt: Date)?

    init(ttl: TimeInterval) { self.ttl = ttl }

    func sessions(
        now: Date = Date(),
        load: () -> [CommandCodeUsageFetcher.CookieSession]
    ) -> [CommandCodeUsageFetcher.CookieSession] {
        lock.lock()
        if let entry, entry.expiresAt > now {
            lock.unlock()
            return entry.sessions
        }
        lock.unlock()
        let sessions = load()
        if !sessions.isEmpty {
            lock.lock()
            entry = (sessions, now.addingTimeInterval(ttl))
            lock.unlock()
        }
        return sessions
    }

    func invalidate() {
        lock.lock()
        entry = nil
        lock.unlock()
    }
}

nonisolated enum CommandCodeBoundedTaskJoinOutcome<Value: Sendable> {
    case value(Value)
    case failure(any Error)
    case timedOut
}

nonisolated final class CommandCodeBoundedTaskJoin<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceTask: Task<Value, Error>
    private var outcome: CommandCodeBoundedTaskJoinOutcome<Value>?
    private var continuation: CheckedContinuation<CommandCodeBoundedTaskJoinOutcome<Value>, Never>?
    private var observerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(sourceTask: Task<Value, Error>) { self.sourceTask = sourceTask }

    func value(joinGrace: Duration) async -> CommandCodeBoundedTaskJoinOutcome<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                self.continuation = continuation
                let sourceTask = sourceTask
                observerTask = Task { [weak self] in
                    do { self?.resolve(.value(try await sourceTask.value), cancelSource: false) }
                    catch { self?.resolve(.failure(error), cancelSource: false) }
                }
                timeoutTask = Task { [weak self] in
                    do {
                        if joinGrace > .zero { try await Task.sleep(for: joinGrace) }
                        self?.resolve(.timedOut, cancelSource: true)
                    } catch {}
                }
                lock.unlock()
            }
        } onCancel: {
            resolve(.failure(CancellationError()), cancelSource: true)
        }
    }

    private func resolve(_ outcome: CommandCodeBoundedTaskJoinOutcome<Value>, cancelSource: Bool) {
        lock.lock()
        guard self.outcome == nil else { lock.unlock(); return }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        let observerTask = observerTask
        let timeoutTask = timeoutTask
        self.observerTask = nil
        self.timeoutTask = nil
        lock.unlock()
        if cancelSource { sourceTask.cancel() }
        observerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: outcome)
    }
}
