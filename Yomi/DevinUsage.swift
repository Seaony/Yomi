import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum DevinUsageError: LocalizedError, Equatable {
    case noSession
    case missingOrganization
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            AppLocalization.text(
                "未找到 Devin 浏览器会话。请登录 app.devin.ai，或粘贴 Bearer Token。",
                "No Devin browser session found. Sign in to app.devin.ai or paste a Bearer token."
            )
        case .missingOrganization:
            AppLocalization.text(
                "未找到 Devin 组织。请先打开 app.devin.ai/org/... 页面，或在设置中填写组织。",
                "No Devin organization was found. Open an app.devin.ai/org/... page or set the organization."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "Devin 会话令牌无效或已过期。",
                "The Devin session token is invalid or expired."
            )
        case let .apiError(message):
            AppLocalization.text("Devin 接口错误：\(message)", "Devin API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Devin 用量：\(message)", "Could not parse Devin usage: \(message)")
        }
    }
}

nonisolated struct DevinQuotaWindow: Sendable, Equatable {
    let usedPercent: Double
    let resetsAt: Date?

    init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }
}

nonisolated struct DevinUsageSnapshot: Sendable, Equatable {
    let daily: DevinQuotaWindow?
    let weekly: DevinQuotaWindow?
    let planName: String?
    let organization: String?
    let updatedAt: Date
    let overageBalance: Double?

    func toProviderUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let daily {
            windows.append(UsageWindow(
                id: "devin-daily",
                label: "Daily",
                usedFraction: daily.usedPercent / 100,
                resetsAt: daily.resetsAt,
                detail: nil
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "devin-weekly",
                label: "Weekly",
                usedFraction: weekly.usedPercent / 100,
                resetsAt: weekly.resetsAt,
                detail: nil
            ))
        }
        let providerCost = overageBalance.map {
            ProviderCostSummary(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                balance: nil
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "devin"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: planName,
            providerCost: providerCost,
            details: [],
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum DevinUsageParser {
    static func parse(_ data: Data, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DevinUsageError.parseFailed("Invalid JSON response.")
        }
        return try parse(object, organization: organization, now: now)
    }

    static func parse(_ object: Any, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let current = (object as? [String: Any]).map(currentQuotaWindows)
        let daily = current?.daily ?? findWindow(in: object, matching: isDailyKey)
        let weekly = current?.weekly ?? findWindow(in: object, matching: isWeeklyKey)
        guard daily != nil || weekly != nil else {
            throw DevinUsageError.parseFailed("Missing Devin quota windows.")
        }
        return DevinUsageSnapshot(
            daily: daily,
            weekly: weekly,
            planName: findPlanName(in: object),
            organization: displayOrganization(from: organization),
            updatedAt: now,
            overageBalance: findOverageBalance(in: object)
        )
    }

    private static func currentQuotaWindows(_ dictionary: [String: Any])
        -> (daily: DevinQuotaWindow?, weekly: DevinQuotaWindow?)
    {
        (
            currentQuotaWindow(
                percent: dictionary["daily_percentage"],
                resetsAt: dictionary["daily_reset_at"]
            ),
            currentQuotaWindow(
                percent: dictionary["weekly_percentage"],
                resetsAt: dictionary["weekly_reset_at"]
            )
        )
    }

    private static func currentQuotaWindow(percent: Any?, resetsAt: Any?) -> DevinQuotaWindow? {
        guard let usedPercent = double(percent) else { return nil }
        return DevinQuotaWindow(
            usedPercent: usedPercent < 1 ? usedPercent * 100 : usedPercent,
            resetsAt: date(from: resetsAt)
        )
    }

    private static func findOverageBalance(in object: Any) -> Double? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = nonnegativeFiniteDouble(dictionary["overage_balance"]) { return value }
        if let cents = nonnegativeFiniteDouble(dictionary["overage_balance_cents"]) { return cents / 100 }
        return nil
    }

    private static func nonnegativeFiniteDouble(_ value: Any?) -> Double? {
        guard let value = double(value), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func findWindow(in object: Any, matching keyMatches: (String) -> Bool) -> DevinQuotaWindow? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let window = window(from: value) { return window }
            }
            for value in dictionary.values {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        return nil
    }

    private static func window(from object: Any) -> DevinQuotaWindow? {
        guard let dictionary = object as? [String: Any] else {
            guard let percent = percent(from: object) else { return nil }
            return DevinQuotaWindow(usedPercent: percent)
        }
        if let percent = percent(from: dictionary) {
            return DevinQuotaWindow(usedPercent: percent, resetsAt: findResetDate(in: dictionary))
        }
        return dictionary.values.lazy.compactMap(window(from:)).first
    }

    private static func percent(from object: Any) -> Double? {
        if let number = double(object) {
            return number <= 1 ? number * 100 : number
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in [
            "used_percent", "usedPercent", "usage_percent", "usagePercent",
            "percent_used", "percentUsed", "percent",
        ] {
            if let value = double(dictionary[key]) {
                return value <= 1 ? value * 100 : value
            }
        }
        for key in ["remaining_percent", "remainingPercent", "percent_remaining", "percentRemaining"] {
            if let value = double(dictionary[key]) {
                let percent = value <= 1 ? value * 100 : value
                return 100 - percent
            }
        }
        let used = firstDouble(
            in: dictionary,
            keys: ["used", "usage", "used_count", "usedCount", "consumed"]
        )
        let limit = firstDouble(
            in: dictionary,
            keys: ["limit", "quota", "total", "max", "available"]
        )
        if let used, let limit, limit > 0 { return used / limit * 100 }
        let remaining = firstDouble(in: dictionary, keys: ["remaining", "left", "available"])
        if let remaining, let limit, limit > 0 { return (limit - remaining) / limit * 100 }
        return nil
    }

    private static func findPlanName(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"] {
                if let value = dictionary[key] as? String, let cleaned = cleanDisplay(value) {
                    return cleaned
                }
            }
            for value in dictionary.values {
                if let found = findPlanName(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findPlanName(in: value) { return found }
            }
        }
        return nil
    }

    private static func findResetDate(in dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains("reset") {
            if let reset = date(from: value) { return reset }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = value as? String {
            if let parsed = ISO8601DateFormatter().date(from: raw) { return parsed }
            if let number = Double(raw) { return date(from: number) }
        }
        if let number = double(value) { return date(from: number) }
        return nil
    }

    private static func date(from number: Double) -> Date? {
        guard number > 0 else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func firstDouble(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = double(dictionary[key]) { return value }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func isDailyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("daily") || key.contains("day"))
    }

    private static func isWeeklyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
    }

    private static func displayOrganization(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("org/") { return String(raw.dropFirst(4)) }
        if raw.hasPrefix("organizations/") { return String(raw.dropFirst("organizations/".count)) }
        return raw
    }

    private static func cleanDisplay(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.split(separator: "_").flatMap { $0.split(separator: "-") }.map { part in
            part.prefix(1).uppercased() + String(part.dropFirst())
        }.joined(separator: " ")
    }
}

nonisolated enum DevinUsageFetcher {
    struct RequestAuth: Sendable, Equatable {
        let bearerToken: String
        let organization: String?
        let internalOrganizationID: String?
        let sourceLabel: String
    }

    private static let baseURL = URL(string: "https://app.devin.ai")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        organization rawOrganization: String?,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        let organization = normalizedOrganization(
            cleaned(environment["DEVIN_ORGANIZATION"])
                ?? cleaned(environment["DEVIN_ORG"])
                ?? cleaned(rawOrganization)
        )
        let credential = cleaned(environment["DEVIN_BEARER_TOKEN"])
            ?? cleaned(environment["DEVIN_AUTHORIZATION"])
            ?? rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        let auths: [RequestAuth]
        if let manual = manualAuth(from: credential, organization: organization) {
            auths = [manual]
        } else {
            if source == .token || source == .cookie { throw DevinUsageError.noSession }
            auths = DevinSessionImporter.importSessions(organizationOverride: organization).map {
                RequestAuth(
                    bearerToken: $0.accessToken,
                    organization: organization ?? normalizedOrganization($0.organization),
                    internalOrganizationID: $0.internalOrganizationID,
                    sourceLabel: $0.sourceLabel
                )
            }
            guard !auths.isEmpty else { throw DevinUsageError.noSession }
        }

        var lastError: Error?
        for auth in auths {
            do {
                let snapshot = try await fetchQuotaUsage(
                    auth: auth,
                    organizationOverride: organization,
                    session: session,
                    now: now
                )
                return snapshot.toProviderUsage()
            } catch {
                lastError = error
                if auth.sourceLabel == "manual" || !shouldTryNextSession(after: error) { throw error }
            }
        }
        throw lastError ?? DevinUsageError.noSession
    }

    static func fetchQuotaUsage(
        auth: RequestAuth,
        organizationOverride: String? = nil,
        session: URLSession,
        now: Date = Date()
    ) async throws -> DevinUsageSnapshot {
        let organization = normalizedOrganization(organizationOverride) ?? normalizedOrganization(auth.organization)
        guard let organization else { throw DevinUsageError.missingOrganization }
        var lastError: Error?
        for path in candidatePaths(
            organization: organization,
            internalOrganizationID: auth.internalOrganizationID
        ) {
            let data: Data
            do {
                data = try await request(path: path, auth: auth, session: session)
            } catch {
                lastError = error
                if error as? DevinUsageError == .invalidCredentials { throw error }
                continue
            }
            return try DevinUsageParser.parse(data, organization: organization, now: now)
        }
        throw lastError ?? DevinUsageError.apiError("No Devin quota endpoint succeeded.")
    }

    static func manualAuth(from raw: String?, organization: String? = nil) -> RequestAuth? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if token.lowercased().hasPrefix("authorization:") {
            if let separator = token.firstIndex(of: ":") {
                token = String(token[token.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { return nil }
        return RequestAuth(
            bearerToken: token,
            organization: normalizedOrganization(organization),
            internalOrganizationID: internalOrganizationID(from: organization),
            sourceLabel: "manual"
        )
    }

    static func normalizedOrganization(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           host == "devin.ai" || host.hasSuffix(".devin.ai") {
            let components = url.path.split(separator: "/").map(String.init)
            if components.count >= 2, components[0] == "org" {
                value = "org/\(components[1])"
            } else if components.count >= 2, components[0] == "organizations" {
                value = "organizations/\(components[1])"
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("org/") || value.hasPrefix("organizations/") { return value }
        if isInternalOrganizationID(value) { return "organizations/\(value)" }
        return "org/\(value)"
    }

    static func candidatePaths(organization: String, internalOrganizationID: String?) -> [String] {
        var paths: [String] = []
        let normalized = normalizedOrganization(organization) ?? organization
        if let internalOrganizationID { paths.append("\(internalOrganizationID)/billing/quota/usage") }
        paths.append("\(normalized)/billing/quota/usage")
        if normalized.hasPrefix("org/") {
            paths.append("\(normalized.dropFirst(4))/billing/quota/usage")
        }
        if !normalized.hasPrefix("org/"), !normalized.hasPrefix("organizations/") {
            paths.append("org/\(normalized)/billing/quota/usage")
        }
        if let internalOrganizationID {
            paths.append("organizations/\(internalOrganizationID)/billing/quota/usage")
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static func shouldTryNextSession(after error: Error) -> Bool {
        switch error {
        case DevinUsageError.invalidCredentials, DevinUsageError.apiError, DevinUsageError.missingOrganization:
            true
        default:
            false
        }
    }

    static func isInternalOrganizationID(_ value: String) -> Bool {
        value.hasPrefix("org-") || value.hasPrefix("org_")
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func internalOrganizationID(from raw: String?) -> String? {
        guard let normalized = normalizedOrganization(raw), normalized.hasPrefix("organizations/") else {
            return nil
        }
        return String(normalized.dropFirst("organizations/".count))
    }

    private static func request(path: String, auth: RequestAuth, session: URLSession) async throws -> Data {
        let url = baseURL.appending(path: "api/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(auth.bearerToken)", forHTTPHeaderField: "Authorization")
        if let internalOrganizationID = auth.internalOrganizationID {
            request.setValue(internalOrganizationID, forHTTPHeaderField: "x-cog-org-id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DevinUsageError.apiError("Invalid response.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw DevinUsageError.invalidCredentials }
            throw DevinUsageError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }
}

nonisolated enum DevinSessionImporter {
    private static let storageOrigin = "https://app.devin.ai"
    private static let externalOrgPrefix = "last-internal-org-for-external-org-v1-"

    struct SessionInfo: Equatable, Sendable {
        let accessToken: String
        let organization: String?
        let internalOrganizationID: String?
        let sourceLabel: String
    }

    struct LocalStorageCandidate: Sendable {
        let label: String
        let url: URL
    }

    static func importSessions(
        organizationOverride: String? = nil,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        for candidate in chromeLocalStorageCandidates(homeDirectories: homeDirectories) {
            let storage = readLocalStorage(from: candidate.url)
            if let session = session(
                from: storage,
                organizationOverride: organizationOverride,
                sourceLabel: candidate.label
            ) {
                sessions.append(session)
            }
        }
        return rankSessions(deduplicateSessions(sessions))
    }

    static func session(
        from storage: [String: String],
        organizationOverride: String? = nil,
        sourceLabel: String
    ) -> SessionInfo? {
        guard let accessToken = accessToken(from: storage) else { return nil }
        let organizationInfo = organizationInfo(from: storage, organizationOverride: organizationOverride)
        return SessionInfo(
            accessToken: accessToken,
            organization: organizationInfo.organization,
            internalOrganizationID: organizationInfo.internalOrganizationID,
            sourceLabel: sourceLabel
        )
    }

    static func accessToken(from storage: [String: String]) -> String? {
        for (key, value) in storage where isAuth1StorageKey(key) {
            if let object = jsonObject(from: value), let token = findAuth1Token(in: object) { return token }
        }
        for (key, value) in storage where isAuth0StorageKey(key) {
            if let object = jsonObject(from: value), let token = findAccessToken(in: object) { return token }
        }
        for value in storage.values {
            if let object = jsonObject(from: value), let token = findAccessToken(in: object) { return token }
        }
        return nil
    }

    static func organizationInfo(
        from storage: [String: String],
        organizationOverride: String?
    ) -> (organization: String?, internalOrganizationID: String?) {
        let override = DevinUsageFetcher.normalizedOrganization(organizationOverride)
        let overrideSlug = override.flatMap(slug(fromNormalizedOrganization:))
        var firstInternalOrgID: String?
        for (key, value) in storage where isExternalOrgStorageKey(key) {
            let suffix = externalOrgSlug(from: key)
            let organizationID = cleanedOrgID(value)
            if firstInternalOrgID == nil { firstInternalOrgID = organizationID }
            if let overrideSlug, suffix == overrideSlug { return (override, organizationID) }
            if override == nil, suffix != "null" { return ("org/\(suffix)", organizationID) }
        }
        if let inferred = inferredOrganizationInfo(from: storage, override: override) { return inferred }
        if let override {
            return (override, firstInternalOrgID ?? orgID(fromNormalizedOrganization: override))
        }
        return (firstInternalOrgID.map { "organizations/\($0)" }, firstInternalOrgID)
    }

    static func deduplicateSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var order: [String] = []
        var bestByToken: [String: SessionInfo] = [:]
        for session in sessions {
            if let existing = bestByToken[session.accessToken] {
                if organizationScore(session) > organizationScore(existing) {
                    bestByToken[session.accessToken] = session
                }
            } else {
                order.append(session.accessToken)
                bestByToken[session.accessToken] = session
            }
        }
        return order.compactMap { bestByToken[$0] }
    }

    static func rankSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.enumerated().sorted { lhs, rhs in
            let left = organizationScore(lhs.element)
            let right = organizationScore(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    static func decodedStorageValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chromeLocalStorageCandidates(
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [LocalStorageCandidate] {
        let roots = ChromiumProfileLocator.roots(for: [.chrome], homeDirectories: homeDirectories)
        var candidates: [LocalStorageCandidate] = []
        for root in roots {
            candidates.append(contentsOf: chromeProfileLocalStorageDirs(
                root: root.url,
                labelPrefix: root.labelPrefix
            ))
        }
        return candidates
    }

    private static func chromeProfileLocalStorageDirs(
        root: URL,
        labelPrefix: String
    ) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            let levelDB = directory.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDB.path) else { return nil }
            return LocalStorageCandidate(label: "\(labelPrefix) \(directory.lastPathComponent)", url: levelDB)
        }
    }

    private static func readLocalStorage(from levelDBURL: URL) -> [String: String] {
        var storage: [String: String] = [:]
        for entry in ChromiumLocalStorageReader.readEntries(for: storageOrigin, in: levelDBURL) {
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        for entry in ChromiumLocalStorageReader.readTextEntries(in: levelDBURL) where storage[entry.key] == nil {
            if isUsefulStorageKey(entry.key) { storage[entry.key] = decodedStorageValue(entry.value) }
        }
        return storage
    }

    private static func organizationScore(_ session: SessionInfo) -> Int {
        (session.organization == nil ? 0 : 1) + (session.internalOrganizationID == nil ? 0 : 2)
    }

    private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findAuth1Token(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any], let token = dictionary["token"] as? String else {
            return nil
        }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("auth1_") && value.count > 20 ? value : nil
    }

    private static func findAccessToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["access_token", "accessToken"] {
                if let value = dictionary[key] as? String, looksLikeToken(value) { return value }
            }
            for value in dictionary.values {
                if let found = findAccessToken(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findAccessToken(in: value) { return found }
            }
        }
        return nil
    }

    private static func looksLikeToken(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 20 && (value.hasPrefix("eyJ") || value.contains("."))
    }

    private static func isAuth1StorageKey(_ key: String) -> Bool { key.hasSuffix("auth1_session") }
    private static func isAuth0StorageKey(_ key: String) -> Bool { key.contains("auth0spajs@@::") }
    private static func isExternalOrgStorageKey(_ key: String) -> Bool { key.contains(externalOrgPrefix) }

    private static func isUsefulStorageKey(_ key: String) -> Bool {
        isAuth1StorageKey(key)
            || isAuth0StorageKey(key)
            || isExternalOrgStorageKey(key)
            || key.contains("post-auth-v")
            || key.contains("member-info-v")
            || key.contains("feature-flags-cache:org-")
            || key.contains("feature-flags-cache:org_")
    }

    private static func inferredOrganizationInfo(
        from storage: [String: String],
        override: String?
    ) -> (organization: String?, internalOrganizationID: String?)? {
        let overrideSlug = override.flatMap(slug(fromNormalizedOrganization:))
        let overrideOrgID = override.flatMap(orgID(fromNormalizedOrganization:))
        var fallbackSlug: String?
        var fallbackInternalOrgID: String?
        for (key, value) in storage {
            let object = jsonObject(from: value)
            let internalOrgID = cleanedOrgID(firstString(
                in: object,
                matching: ["internalOrgId", "internal_org_id", "org_id", "orgId"]
            )) ?? internalOrgIDFromStorageKey(key)
            let foundSlug = cleanedSlug(
                slugFromPostAuthKey(key)
                    ?? firstString(
                        in: object,
                        matching: ["orgName", "org_name", "externalOrgId", "external_org_id"]
                    )
            )
            if let overrideOrgID, internalOrgID == overrideOrgID { return (override, internalOrgID) }
            if let overrideSlug, foundSlug == overrideSlug { return (override, internalOrgID) }
            if fallbackSlug == nil, let foundSlug { fallbackSlug = foundSlug }
            if fallbackInternalOrgID == nil, let internalOrgID { fallbackInternalOrgID = internalOrgID }
        }
        if let override, fallbackInternalOrgID != nil { return (override, fallbackInternalOrgID) }
        if let fallbackSlug { return ("org/\(fallbackSlug)", fallbackInternalOrgID) }
        if let fallbackInternalOrgID {
            return ("organizations/\(fallbackInternalOrgID)", fallbackInternalOrgID)
        }
        return nil
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String) -> String? {
        let value = decodedStorageValue(raw)
        return DevinUsageFetcher.isInternalOrganizationID(value) ? value : nil
    }

    private static func cleanedOrgID(_ raw: String?) -> String? {
        raw.flatMap(cleanedOrgID)
    }

    private static func cleanedSlug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = decodedStorageValue(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null", !DevinUsageFetcher.isInternalOrganizationID(value) else {
            return nil
        }
        return value.hasPrefix("org/") ? String(value.dropFirst(4)) : value
    }

    private static func slugFromPostAuthKey(_ key: String) -> String? {
        guard let range = key.range(of: "-org_name-") else { return nil }
        return String(key[range.upperBound...])
    }

    private static func internalOrgIDFromStorageKey(_ key: String) -> String? {
        guard let range = key.range(of: #"org[-_][A-Za-z0-9]{8,}"#, options: .regularExpression) else {
            return nil
        }
        return cleanedOrgID(String(key[range]))
    }

    private static func firstString(in object: Any?, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = value as? String, !string.isEmpty { return string }
                if let found = firstString(in: value, matching: keys) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = firstString(in: value, matching: keys) { return found }
            }
        }
        return nil
    }

    private static func slug(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("org/") else { return nil }
        return String(organization.dropFirst(4))
    }

    private static func orgID(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("organizations/") else { return nil }
        return String(organization.dropFirst("organizations/".count))
    }
}
