import Foundation
import SQLite3
import SweetCookieKit

nonisolated enum WindsurfUsageError: LocalizedError, Equatable {
    case noSession
    case invalidManualSession(String)
    case requestFailed(String)
    case databaseNotFound(String)
    case databaseFailed(String)
    case noCachedPlan
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            AppLocalization.text(
                "未在 Chromium localStorage 中找到 Windsurf 会话。请先登录 app.devin.ai 或 windsurf.com。",
                "No Windsurf session was found in Chromium localStorage. Sign in to app.devin.ai or windsurf.com first."
            )
        case let .invalidManualSession(message):
            AppLocalization.text("Windsurf 会话数据无效：\(message)", "Invalid Windsurf session payload: \(message)")
        case let .requestFailed(message):
            AppLocalization.text("Windsurf 接口调用失败：\(message)", "Windsurf API call failed: \(message)")
        case let .databaseNotFound(path):
            AppLocalization.text(
                "未找到 Windsurf 数据库：\(path)。请确认 Windsurf 已安装并至少启动过一次。",
                "Windsurf database not found at \(path). Ensure Windsurf is installed and has been launched at least once."
            )
        case let .databaseFailed(message):
            AppLocalization.text("读取 Windsurf 数据库失败：\(message)", "Could not read Windsurf database: \(message)")
        case .noCachedPlan:
            AppLocalization.text(
                "Windsurf 数据库中没有套餐数据，请先登录 Windsurf。",
                "No plan data was found in the Windsurf database. Sign in to Windsurf first."
            )
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Windsurf 用量：\(message)", "Could not parse Windsurf usage: \(message)")
        }
    }
}

nonisolated struct WindsurfSessionAuth: Codable, Equatable, Sendable {
    let sessionToken: String
    let auth1Token: String
    let accountID: String
    let primaryOrgID: String
}

nonisolated struct WindsurfPlanStatusResponse: Sendable, Equatable {
    let planStatus: PlanStatus?

    struct PlanStatus: Sendable, Equatable {
        let planInfo: PlanInfo?
        let planStart: Date?
        let planEnd: Date?
        let dailyQuotaRemainingPercent: Int?
        let weeklyQuotaRemainingPercent: Int?
        let dailyQuotaResetAtUnix: Int64?
        let weeklyQuotaResetAtUnix: Int64?
        let topUpStatus: TopUpStatus?
        let gracePeriodStatus: Int?

        struct PlanInfo: Sendable, Equatable {
            let planName: String?
            let teamsTier: Int?
        }

        struct TopUpStatus: Sendable, Equatable {
            let topUpTransactionStatus: Int?
        }
    }

    func toProviderUsage(now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let remaining = planStatus?.dailyQuotaRemainingPercent {
            windows.append(UsageWindow(
                id: "windsurf-daily",
                label: "Daily",
                usedFraction: WindsurfUsageFetcher.clampedUsedPercent(fromRemaining: Double(remaining)) / 100,
                resetsAt: planStatus?.dailyQuotaResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                detail: nil
            ))
        }
        if let remaining = planStatus?.weeklyQuotaRemainingPercent {
            windows.append(UsageWindow(
                id: "windsurf-weekly",
                label: "Weekly",
                usedFraction: WindsurfUsageFetcher.clampedUsedPercent(fromRemaining: Double(remaining)) / 100,
                resetsAt: planStatus?.weeklyQuotaResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                detail: nil
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "windsurf"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: planStatus?.planInfo?.planName,
            details: [],
            updatedAt: now,
            message: nil
        )
    }

}

nonisolated struct WindsurfCachedPlanInfo: Codable, Sendable, Equatable {
    let planName: String?
    let startTimestamp: Int64?
    let endTimestamp: Int64?
    let usage: Usage?
    let quotaUsage: QuotaUsage?

    struct Usage: Codable, Sendable, Equatable {
        let messages: Int?
        let usedMessages: Int?
        let remainingMessages: Int?
        let flowActions: Int?
        let usedFlowActions: Int?
        let remainingFlowActions: Int?
        let flexCredits: Int?
        let usedFlexCredits: Int?
        let remainingFlexCredits: Int?
    }

    struct QuotaUsage: Codable, Sendable, Equatable {
        let dailyRemainingPercent: Double?
        let weeklyRemainingPercent: Double?
        let dailyResetAtUnix: Int64?
        let weeklyResetAtUnix: Int64?
    }

    func toProviderUsage(now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let remaining = quotaUsage?.dailyRemainingPercent {
            windows.append(UsageWindow(
                id: "windsurf-daily",
                label: "Daily",
                usedFraction: WindsurfUsageFetcher.clampedUsedPercent(fromRemaining: remaining) / 100,
                resetsAt: quotaUsage?.dailyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                detail: nil
            ))
        } else if let window = Self.countWindow(
            id: "windsurf-daily",
            label: "Daily",
            used: usage?.usedMessages,
            remaining: usage?.remainingMessages,
            total: usage?.messages,
            unit: "messages"
        ) {
            windows.append(window)
        }
        if let remaining = quotaUsage?.weeklyRemainingPercent {
            windows.append(UsageWindow(
                id: "windsurf-weekly",
                label: "Weekly",
                usedFraction: WindsurfUsageFetcher.clampedUsedPercent(fromRemaining: remaining) / 100,
                resetsAt: quotaUsage?.weeklyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                detail: nil
            ))
        } else if let window = Self.countWindow(
            id: "windsurf-weekly",
            label: "Weekly",
            used: usage?.usedFlowActions,
            remaining: usage?.remainingFlowActions,
            total: usage?.flowActions,
            unit: "flow actions"
        ) {
            windows.append(window)
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "windsurf"),
            state: .ready,
            windows: windows,
            balance: nil,
            plan: planName,
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    private static func countWindow(
        id: String,
        label: String,
        used rawUsed: Int?,
        remaining rawRemaining: Int?,
        total rawTotal: Int?,
        unit: String
    ) -> UsageWindow? {
        guard let total = rawTotal, total > 0 else { return nil }
        guard let used = rawUsed ?? rawRemaining.map({ max(0, total - $0) }) else { return nil }
        let clampedUsed = min(total, max(0, used))
        return UsageWindow(
            id: id,
            label: label,
            usedFraction: Double(clampedUsed) / Double(total),
            resetsAt: nil,
            detail: "\(clampedUsed) / \(total) \(unit)"
        )
    }
}

nonisolated enum WindsurfUsageDataSource: String, CaseIterable, Sendable {
    case automatic
    case web
    case local
}

nonisolated enum WindsurfSessionSource: String, CaseIterable, Sendable {
    case automatic
    case manual
    case off
}

nonisolated enum WindsurfUsageFetcher {
    static let getPlanStatusURL = URL(
        string: "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus"
    )!
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")

    static func fetch(
        source: ProviderSource,
        manualSessionInput: String?,
        session: URLSession,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories(),
        databaseURL: URL? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        switch source {
        case .cookie:
            return try await fetch(
                dataSource: .web,
                sessionSource: .manual,
                manualSessionInput: manualSessionInput,
                session: session,
                homeDirectories: homeDirectories,
                databaseURL: databaseURL,
                now: now
            )
        case .account, .command:
            return try await fetch(
                dataSource: .local,
                sessionSource: .off,
                manualSessionInput: nil,
                session: session,
                homeDirectories: homeDirectories,
                databaseURL: databaseURL,
                now: now
            )
        case .automatic, .token, .endpoint:
            let hasManualSession = !(manualSessionInput ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return try await fetch(
                dataSource: .automatic,
                sessionSource: hasManualSession ? .manual : .automatic,
                manualSessionInput: manualSessionInput,
                session: session,
                homeDirectories: homeDirectories,
                databaseURL: databaseURL,
                now: now
            )
        }
    }

    static func fetch(
        dataSource: WindsurfUsageDataSource,
        sessionSource: WindsurfSessionSource,
        manualSessionInput: String?,
        session: URLSession,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories(),
        databaseURL: URL? = nil,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if dataSource == .local {
            return try fetchLocal(databaseURL: databaseURL, now: now)
        }

        let fetchWebUsage: () async throws -> ProviderUsage = {
            switch sessionSource {
            case .automatic:
                try await fetchWebAutomatically(
                    session: session,
                    homeDirectories: homeDirectories,
                    now: now
                )
            case .manual:
                try await fetchWeb(
                    auth: parseManualSessionInput(manualSessionInput ?? ""),
                    session: session,
                    now: now
                )
            case .off:
                throw WindsurfUsageError.noSession
            }
        }

        if dataSource == .web { return try await fetchWebUsage() }
        do {
            return try await fetchWebUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            return try fetchLocal(databaseURL: databaseURL, now: now)
        }
    }

    static func fetchWeb(
        auth: WindsurfSessionAuth,
        session: URLSession,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var request = URLRequest(url: getPlanStatusURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("https://windsurf.com", forHTTPHeaderField: "Origin")
        request.setValue("https://windsurf.com/profile", forHTTPHeaderField: "Referer")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-auth-token")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-devin-session-token")
        request.setValue(auth.auth1Token, forHTTPHeaderField: "x-devin-auth1-token")
        request.setValue(auth.accountID, forHTTPHeaderField: "x-devin-account-id")
        request.setValue(auth.primaryOrgID, forHTTPHeaderField: "x-devin-primary-org-id")
        request.httpBody = WindsurfPlanStatusProtoCodec.encodeRequest(
            authToken: auth.sessionToken,
            includeTopUpStatus: true
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw WindsurfUsageError.requestFailed("Invalid response")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WindsurfUsageError.requestFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = body.map { !$0.isEmpty ? ": \($0.prefix(200))" : ": <binary \(data.count) bytes>" }
                ?? ": <binary \(data.count) bytes>"
            throw WindsurfUsageError.requestFailed("HTTP \(http.statusCode)\(suffix)")
        }
        do {
            return try WindsurfPlanStatusProtoCodec.decodeResponse(data).toProviderUsage(now: now)
        } catch {
            throw WindsurfUsageError.requestFailed("Parse error: \(error.localizedDescription)")
        }
    }

    static func fetchWebAutomatically(
        session: URLSession,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories(),
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let preferred = WindsurfSessionImporter.importPreferredSessions(homeDirectories: homeDirectories)
        if !preferred.isEmpty {
            do {
                return try await fetchWeb(sessions: preferred, session: session, now: now)
            } catch {
                guard isRecoverableImportedSessionError(error) else { throw error }
            }
        }
        let fallback = WindsurfSessionImporter.importFallbackSessions(homeDirectories: homeDirectories)
        guard !fallback.isEmpty else { throw WindsurfUsageError.noSession }
        return try await fetchWeb(sessions: fallback, session: session, now: now)
    }

    static func fetchLocal(databaseURL: URL? = nil, now: Date = Date()) throws -> ProviderUsage {
        let info = try WindsurfStatusProbe(databaseURL: databaseURL).fetch()
        return info.toProviderUsage(now: now)
    }

    static func parseManualSessionInput(_ raw: String) throws -> WindsurfSessionAuth {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WindsurfUsageError.invalidManualSession("empty input") }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = sessionAuth(from: object) {
            return auth
        }
        let separators = CharacterSet(charactersIn: "\n,;")
        let segments = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .components(separatedBy: separators)
        var values: [String: Any] = [:]
        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            let delimiter: Character? = segment.contains("=") ? "=" : (segment.contains(":") ? ":" : nil)
            guard let delimiter, let index = segment.firstIndex(of: delimiter) else { continue }
            let key = String(segment[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: index)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        if let auth = sessionAuth(from: values) { return auth }
        throw WindsurfUsageError.invalidManualSession(
            "expected JSON with devin_session_token, devin_auth1_token, devin_account_id, and devin_primary_org_id"
        )
    }

    static func clampedUsedPercent(fromRemaining remaining: Double) -> Double {
        min(100, max(0, 100 - remaining))
    }

    private static func sessionAuth(from values: [String: Any]) -> WindsurfSessionAuth? {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                guard let raw = values[key] as? String else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }
        guard let sessionToken = value(["devin_session_token", "devinSessionToken", "sessionToken"]),
              let auth1Token = value(["devin_auth1_token", "devinAuth1Token", "auth1Token"]),
              let accountID = value(["devin_account_id", "devinAccountId", "accountID", "accountId"]),
              let primaryOrgID = value([
                  "devin_primary_org_id", "devinPrimaryOrgId", "primaryOrgID", "primaryOrgId",
              ]) else { return nil }
        return WindsurfSessionAuth(
            sessionToken: sessionToken,
            auth1Token: auth1Token,
            accountID: accountID,
            primaryOrgID: primaryOrgID
        )
    }

    static func fetchWeb(
        sessions: [WindsurfSessionImporter.SessionInfo],
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var lastError: Error?
        for sessionInfo in sessions {
            do {
                return try await fetchWeb(auth: sessionInfo.session, session: session, now: now)
            } catch {
                guard isRecoverableImportedSessionError(error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? WindsurfUsageError.noSession
    }

    private static func isRecoverableImportedSessionError(_ error: Error) -> Bool {
        guard case let WindsurfUsageError.requestFailed(message) = error else { return false }
        return ["HTTP 400", "HTTP 401", "HTTP 403"].contains { message.hasPrefix($0) }
    }
}

nonisolated enum WindsurfSessionImporter {
    struct SessionInfo: Equatable, Sendable {
        let session: WindsurfSessionAuth
        let sourceLabel: String
    }

    struct LocalStorageCandidate: Sendable {
        let label: String
        let url: URL
    }

    struct LocalStorageSnapshot: Equatable, Sendable {
        let storage: [String: String]
        let sourceSuffix: String?
    }

    struct OriginEntries {
        let origin: URL
        let entries: [ChromiumLocalStorageEntry]
    }

    static let preferredBrowsers: [Browser] = [.chrome]
    static let fallbackBrowsers: [Browser] = [
        .chromeBeta, .chromeCanary, .edge, .edgeBeta, .edgeCanary,
        .brave, .braveBeta, .braveNightly, .vivaldi, .arc, .arcBeta,
        .arcCanary, .dia, .chatgptAtlas, .chromium, .helium,
    ]
    static let localStorageOrigins = [
        URL(string: "https://app.devin.ai")!,
        URL(string: "https://windsurf.com")!,
    ]
    static let targetKeys: Set<String> = [
        "devin_session_token", "devin_auth1_token", "devin_account_id", "devin_primary_org_id",
    ]

    static func importPreferredSessions(
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [SessionInfo] {
        importSessions(browsers: preferredBrowsers, homeDirectories: homeDirectories)
    }

    static func importFallbackSessions(
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [SessionInfo] {
        importSessions(browsers: fallbackBrowsers, homeDirectories: homeDirectories)
    }

    static func session(from storage: [String: String], sourceLabel: String) -> SessionInfo? {
        guard let sessionToken = storage["devin_session_token"],
              let auth1Token = storage["devin_auth1_token"],
              let accountID = storage["devin_account_id"],
              let primaryOrgID = storage["devin_primary_org_id"] else { return nil }
        return SessionInfo(
            session: WindsurfSessionAuth(
                sessionToken: sessionToken,
                auth1Token: auth1Token,
                accountID: accountID,
                primaryOrgID: primaryOrgID
            ),
            sourceLabel: sourceLabel
        )
    }

    static func deduplicateSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var tokens = Set<String>()
        return sessions.filter { tokens.insert($0.session.sessionToken).inserted }
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

    static func localStorageSnapshots(
        from originEntries: [OriginEntries],
        textEntries: [ChromiumLevelDBTextEntry] = []
    ) -> [LocalStorageSnapshot] {
        var snapshots = originEntries.compactMap { entry -> LocalStorageSnapshot? in
            let values = storage(from: entry.entries)
            guard values.count == targetKeys.count else { return nil }
            return LocalStorageSnapshot(storage: values, sourceSuffix: entry.origin.host)
        }
        let textValues = storage(from: textEntries)
        if textValues.count == targetKeys.count {
            snapshots.append(LocalStorageSnapshot(storage: textValues, sourceSuffix: nil))
        }
        return snapshots
    }

    static func chromeLocalStorageCandidates(
        browsers: [Browser],
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()
    ) -> [LocalStorageCandidate] {
        let roots = ChromiumProfileLocator.roots(for: browsers, homeDirectories: homeDirectories)
        return roots.flatMap { root in
            chromeProfileLocalStorageDirs(root: root.url, labelPrefix: root.labelPrefix)
        }
    }

    private static func importSessions(browsers: [Browser], homeDirectories: [URL]) -> [SessionInfo] {
        let sessions = chromeLocalStorageCandidates(browsers: browsers, homeDirectories: homeDirectories)
            .flatMap { candidate in
                readLocalStorageSnapshots(from: candidate.url).compactMap { snapshot in
                    let suffix = snapshot.sourceSuffix.map { " (\($0))" } ?? ""
                    return session(from: snapshot.storage, sourceLabel: candidate.label + suffix)
                }
            }
        return deduplicateSessions(sessions)
    }

    private static func chromeProfileLocalStorageDirs(root: URL, labelPrefix: String) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { profile in
            let levelDB = profile.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDB.path) else { return nil }
            return LocalStorageCandidate(label: "\(labelPrefix) \(profile.lastPathComponent)", url: levelDB)
        }
    }

    private static func readLocalStorageSnapshots(from levelDBURL: URL) -> [LocalStorageSnapshot] {
        let origins = localStorageOrigins.map { origin in
            OriginEntries(
                origin: origin,
                entries: ChromiumLocalStorageReader.readEntries(for: origin.absoluteString, in: levelDBURL)
            )
        }
        return localStorageSnapshots(
            from: origins,
            textEntries: ChromiumLocalStorageReader.readTextEntries(in: levelDBURL)
        )
    }

    private static func storage(from entries: [ChromiumLocalStorageEntry]) -> [String: String] {
        var storage: [String: String] = [:]
        for entry in entries where storage[entry.key] == nil && targetKeys.contains(entry.key) {
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        return storage
    }

    private static func storage(from entries: [ChromiumLevelDBTextEntry]) -> [String: String] {
        var storage: [String: String] = [:]
        for entry in entries where storage[entry.key] == nil && targetKeys.contains(entry.key) {
            storage[entry.key] = decodedStorageValue(entry.value)
        }
        return storage
    }
}

nonisolated struct WindsurfStatusProbe: Sendable {
    private static let query =
        "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;"
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? WindsurfUsageFetcher.defaultDatabaseURL
    }

    func fetch() throws -> WindsurfCachedPlanInfo {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindsurfUsageError.databaseNotFound(databaseURL.path)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            throw WindsurfUsageError.databaseFailed(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.query, -1, &statement, nil) == SQLITE_OK else {
            throw WindsurfUsageError.databaseFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { throw WindsurfUsageError.noCachedPlan }
            throw WindsurfUsageError.databaseFailed(String(cString: sqlite3_errmsg(database)))
        }
        guard let string = Self.decodeSQLiteValue(statement: statement, index: 0),
              let data = string.data(using: .utf8) else { throw WindsurfUsageError.noCachedPlan }
        do {
            return try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: data)
        } catch {
            throw WindsurfUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func decodeSQLiteValue(statement: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_TEXT:
            guard let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
            for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
                guard let value = String(data: data, encoding: encoding) else { continue }
                let trimmed = value.trimmingCharacters(in: .controlCharacters)
                guard let jsonData = trimmed.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: jsonData)) != nil else { continue }
                return trimmed
            }
            return nil
        default:
            return nil
        }
    }
}

nonisolated enum WindsurfPlanStatusProtoCodec {
    struct Request: Equatable {
        let authToken: String
        let includeTopUpStatus: Bool
    }

    static func encodeRequest(authToken: String, includeTopUpStatus: Bool) -> Data {
        var data = Data()
        appendFieldKey(1, wireType: .lengthDelimited, to: &data)
        appendString(authToken, to: &data)
        appendFieldKey(2, wireType: .varint, to: &data)
        appendVarint(includeTopUpStatus ? 1 : 0, to: &data)
        return data
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        var reader = WindsurfProtoReader(data: data)
        var authToken: String?
        var includeTopUpStatus = false
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): authToken = try reader.readString()
            case (2, .varint): includeTopUpStatus = try reader.readVarint() != 0
            default: try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        guard let authToken else { throw WindsurfProtoError.missingField("auth_token") }
        return Request(authToken: authToken, includeTopUpStatus: includeTopUpStatus)
    }

    static func decodeResponse(_ data: Data) throws -> WindsurfPlanStatusResponse {
        var reader = WindsurfProtoReader(data: data)
        var planStatus: WindsurfPlanStatusResponse.PlanStatus?
        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == .lengthDelimited {
                planStatus = try decodePlanStatus(reader.readLengthDelimitedData())
            } else {
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        return WindsurfPlanStatusResponse(planStatus: planStatus)
    }

    private static func decodePlanStatus(_ data: Data) throws -> WindsurfPlanStatusResponse.PlanStatus {
        var reader = WindsurfProtoReader(data: data)
        var planInfo: WindsurfPlanStatusResponse.PlanStatus.PlanInfo?
        var planStart: Date?
        var planEnd: Date?
        var dailyRemaining: Int?
        var weeklyRemaining: Int?
        var dailyReset: Int64?
        var weeklyReset: Int64?
        var topUp: WindsurfPlanStatusResponse.PlanStatus.TopUpStatus?
        var grace: Int?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): planInfo = try decodePlanInfo(reader.readLengthDelimitedData())
            case (2, .lengthDelimited): planStart = try decodeTimestamp(reader.readLengthDelimitedData())
            case (3, .lengthDelimited): planEnd = try decodeTimestamp(reader.readLengthDelimitedData())
            case (10, .lengthDelimited): topUp = try decodeTopUpStatus(reader.readLengthDelimitedData())
            case (12, .varint): grace = try Int(reader.readVarint())
            case (14, .varint): dailyRemaining = try Int(reader.readVarint())
            case (15, .varint): weeklyRemaining = try Int(reader.readVarint())
            case (17, .varint): dailyReset = try Int64(reader.readVarint())
            case (18, .varint): weeklyReset = try Int64(reader.readVarint())
            default: try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        return .init(
            planInfo: planInfo,
            planStart: planStart,
            planEnd: planEnd,
            dailyQuotaRemainingPercent: dailyRemaining,
            weeklyQuotaRemainingPercent: weeklyRemaining,
            dailyQuotaResetAtUnix: dailyReset,
            weeklyQuotaResetAtUnix: weeklyReset,
            topUpStatus: topUp,
            gracePeriodStatus: grace
        )
    }

    private static func decodePlanInfo(_ data: Data) throws -> WindsurfPlanStatusResponse.PlanStatus.PlanInfo {
        var reader = WindsurfProtoReader(data: data)
        var name: String?
        var tier: Int?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): tier = try Int(reader.readVarint())
            case (2, .lengthDelimited): name = try reader.readString()
            default: try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        return .init(planName: name, teamsTier: tier)
    }

    private static func decodeTopUpStatus(_ data: Data) throws -> WindsurfPlanStatusResponse.PlanStatus.TopUpStatus {
        var reader = WindsurfProtoReader(data: data)
        var status: Int?
        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == .varint {
                status = try Int(reader.readVarint())
            } else {
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        return .init(topUpTransactionStatus: status)
    }

    private static func decodeTimestamp(_ data: Data) throws -> Date {
        var reader = WindsurfProtoReader(data: data)
        var seconds: Int64 = 0
        var nanos: Int32 = 0
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): seconds = try Int64(reader.readVarint())
            case (2, .varint): nanos = try Int32(reader.readVarint())
            default: try reader.skipFieldBody(wireType: field.wireType)
            }
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendFieldKey(_ number: Int, wireType: WindsurfProtoWireType, to data: inout Data) {
        appendVarint(UInt64((number << 3) | Int(wireType.rawValue)), to: &data)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7f) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

nonisolated enum WindsurfProtoError: LocalizedError {
    case truncated
    case invalidWireType(UInt64)
    case invalidUTF8
    case missingField(String)
    case unsupportedWireType(WindsurfProtoWireType)
    case malformedFieldKey

    var errorDescription: String? {
        switch self {
        case .truncated: "truncated protobuf payload"
        case let .invalidWireType(value): "invalid wire type \(value)"
        case .invalidUTF8: "invalid UTF-8 string"
        case let .missingField(name): "missing protobuf field \(name)"
        case let .unsupportedWireType(type): "unsupported protobuf wire type \(type.rawValue)"
        case .malformedFieldKey: "malformed protobuf field key"
        }
    }
}

nonisolated enum WindsurfProtoWireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

private nonisolated struct WindsurfProtoField {
    let number: Int
    let wireType: WindsurfProtoWireType
}

private nonisolated struct WindsurfProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func nextField() throws -> WindsurfProtoField? {
        guard index < bytes.count else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        guard number > 0 else { throw WindsurfProtoError.malformedFieldKey }
        guard let wireType = WindsurfProtoWireType(rawValue: key & 0x07) else {
            throw WindsurfProtoError.invalidWireType(key & 0x07)
        }
        return WindsurfProtoField(number: number, wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw WindsurfProtoError.truncated }
        }
        throw WindsurfProtoError.truncated
    }

    mutating func readLengthDelimitedData() throws -> Data {
        let length = try Int(readVarint())
        guard index + length <= bytes.count else { throw WindsurfProtoError.truncated }
        let data = Data(bytes[index..<(index + length)])
        index += length
        return data
    }

    mutating func readString() throws -> String {
        guard let string = String(data: try readLengthDelimitedData(), encoding: .utf8) else {
            throw WindsurfProtoError.invalidUTF8
        }
        return string
    }

    mutating func skipFieldBody(wireType: WindsurfProtoWireType) throws {
        switch wireType {
        case .varint: _ = try readVarint()
        case .fixed64:
            guard index + 8 <= bytes.count else { throw WindsurfProtoError.truncated }
            index += 8
        case .lengthDelimited: _ = try readLengthDelimitedData()
        case .fixed32:
            guard index + 4 <= bytes.count else { throw WindsurfProtoError.truncated }
            index += 4
        case .startGroup, .endGroup: throw WindsurfProtoError.unsupportedWireType(wireType)
        }
    }
}
