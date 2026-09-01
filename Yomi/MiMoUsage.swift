import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum MiMoUsageError: LocalizedError, Equatable {
    case missingCookie
    case invalidCookie
    case invalidEndpointOverride
    case invalidCredentials
    case loginRequired
    case requestFailed(Int)
    case networkError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "未找到 Xiaomi MiMo 浏览器会话，请先登录 platform.xiaomimimo.com",
                "No Xiaomi MiMo browser session was found. Sign in to platform.xiaomimimo.com first."
            )
        case .invalidCookie:
            AppLocalization.text(
                "Xiaomi MiMo 需要 api-platform_serviceToken 和 userId Cookie",
                "Xiaomi MiMo requires the api-platform_serviceToken and userId cookies."
            )
        case .invalidEndpointOverride:
            AppLocalization.text(
                "Xiaomi MiMo 接口覆盖地址必须使用 HTTPS 或不带协议的主机地址",
                "The Xiaomi MiMo endpoint override must use HTTPS or a bare host."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "Xiaomi MiMo 浏览器会话已失效，请重新登录",
                "The Xiaomi MiMo browser session has expired. Sign in again."
            )
        case .loginRequired:
            AppLocalization.text("Xiaomi MiMo 需要登录", "Xiaomi MiMo login required.")
        case let .requestFailed(status):
            AppLocalization.text(
                "Xiaomi MiMo 请求失败（HTTP \(status)）",
                "Xiaomi MiMo request failed (HTTP \(status))."
            )
        case let .networkError(message):
            AppLocalization.text(
                "Xiaomi MiMo 网络请求失败：\(message)",
                "Xiaomi MiMo network request failed: \(message)"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Xiaomi MiMo 数据：\(message)",
                "Could not parse Xiaomi MiMo data: \(message)"
            )
        }
    }
}

nonisolated struct MiMoUsageSnapshot: Equatable, Sendable {
    let balance: Double
    let currency: String
    let cashBalance: Double?
    let giftBalance: Double?
    let planCode: String?
    let planPeriodEnd: Date?
    let planExpired: Bool
    let tokenUsed: Int
    let tokenLimit: Int
    let tokenPercent: Double
    let updatedAt: Date

    init(
        balance: Double,
        currency: String,
        cashBalance: Double? = nil,
        giftBalance: Double? = nil,
        planCode: String? = nil,
        planPeriodEnd: Date? = nil,
        planExpired: Bool = false,
        tokenUsed: Int = 0,
        tokenLimit: Int = 0,
        tokenPercent: Double = 0,
        updatedAt: Date
    ) {
        self.balance = balance
        self.currency = currency
        self.cashBalance = cashBalance
        self.giftBalance = giftBalance
        self.planCode = planCode
        self.planPeriodEnd = planPeriodEnd
        self.planExpired = planExpired
        self.tokenUsed = tokenUsed
        self.tokenLimit = tokenLimit
        self.tokenPercent = tokenPercent
        self.updatedAt = updatedAt
    }

    func toProviderUsage() -> ProviderUsage {
        let balanceText = Self.currency(balance, code: currency)
        let balanceDetail: String
        if let cashBalance, let giftBalance {
            balanceDetail = "\(balanceText) (Paid: \(Self.currency(cashBalance, code: currency)) / "
                + "Granted: \(Self.currency(giftBalance, code: currency)))"
        } else {
            balanceDetail = balanceText
        }
        let windows: [UsageWindow]
        if tokenLimit > 0 {
            windows = [UsageWindow(
                id: "mimo-token-plan",
                label: "Credits",
                usedFraction: max(0, min(1, tokenPercent)),
                resetsAt: planPeriodEnd,
                detail: "\(Self.count(tokenUsed)) / \(Self.count(tokenLimit)) Credits"
            )]
        } else {
            windows = []
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "mimo"),
            state: .ready,
            windows: windows,
            balance: balanceText,
            plan: planCode.map { $0.capitalized },
            details: [UsageDetail(id: "mimo-balance", label: "Balance", value: balanceDetail)],
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func currency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(value)"
    }

    private static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

nonisolated enum MiMoCookieHeader {
    static let requiredCookieNames: Set<String> = ["api-platform_serviceToken", "userId"]
    static let knownCookieNames = requiredCookieNames.union(["api-platform_ph", "api-platform_slh"])

    static func normalized(from raw: String?) -> String? {
        guard let value = normalizeInput(raw) else { return nil }
        var cookies: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let cookieValue = String(pair[pair.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownCookieNames.contains(name), !cookieValue.isEmpty else { continue }
            cookies[name] = cookieValue
        }
        guard requiredCookieNames.isSubset(of: Set(cookies.keys)) else { return nil }
        return cookies.keys.sorted().compactMap { name in
            cookies[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }

    static func header(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let requestURL = URL(string: "https://platform.xiaomimimo.com/api/v1/balance")!
        var selected: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard knownCookieNames.contains(cookie.name), !cookie.value.isEmpty else { continue }
            if let expires = cookie.expiresDate, expires < now { continue }
            guard matches(cookie, requestURL) else { continue }
            if let current = selected[cookie.name] {
                if sortKey(cookie) >= sortKey(current) { selected[cookie.name] = cookie }
            } else {
                selected[cookie.name] = cookie
            }
        }
        guard requiredCookieNames.isSubset(of: Set(selected.keys)) else { return nil }
        return selected.keys.sorted().compactMap { name in
            selected[name].map { "\($0.name)=\($0.value)" }
        }.joined(separator: "; ")
    }

    private static func normalizeInput(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)\bcookie:\s*'([^']+)'"#,
            #"(?i)\bcookie:\s*\"([^\"]+)\""#,
            #"(?i)\bcookie:\s*([^\r\n]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let range = Range(match.range(at: 1), in: value)
            else { continue }
            value = String(value[range])
            break
        }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix(".\(domain)") else { return false }
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath == "/" || cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary == requestPath.endIndex || requestPath[boundary] == "/"
    }

    private static func sortKey(_ cookie: HTTPCookie) -> (Int, Int, Date) {
        (
            cookie.path.count,
            cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).count,
            cookie.expiresDate ?? .distantPast
        )
    }
}

nonisolated enum MiMoUsageFetcher {
    static let apiURLKey = "MIMO_API_URL"
    static let defaultBaseURL = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    private static let cookieDomains = ["platform.xiaomimimo.com", "xiaomimimo.com"]
    private static let requestTimeout: TimeInterval = 15

    static func fetch(
        credential: String,
        source: ProviderSource,
        endpointOverride: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let baseURL = try resolvedBaseURL(configured: endpointOverride, environment: environment)
        let manual = MiMoCookieHeader.normalized(from: credential)
        let explicitWeb = source == .cookie || source == .token
        if explicitWeb {
            guard let manual else { throw credential.isEmpty ? MiMoUsageError.missingCookie : .invalidCookie }
            return try await fetchUsage(cookieHeader: manual, baseURL: baseURL, session: session, now: now)
                .toProviderUsage()
        }

        var candidates: [String] = []
        if let manual { candidates.append(manual) }
        candidates.append(contentsOf: automaticCookieHeaders().filter { !candidates.contains($0) })
        var lastError: Error?
        for cookie in candidates {
            do {
                return try await fetchUsage(cookieHeader: cookie, baseURL: baseURL, session: session, now: now)
                    .toProviderUsage()
            } catch {
                guard shouldRetryNextSession(error) else { throw error }
                lastError = error
            }
        }

        let webError = lastError ?? MiMoUsageError.missingCookie
        if shouldFallbackToLocal(webError),
           let local = MiMoLocalUsageFallback.providerUsage(environment: environment, now: now) {
            return local
        }
        throw webError
    }

    static func fetchUsage(
        cookieHeader: String,
        baseURL: URL = defaultBaseURL,
        session: URLSession,
        now: Date = Date()
    ) async throws -> MiMoUsageSnapshot {
        guard let cookie = MiMoCookieHeader.normalized(from: cookieHeader) else {
            throw MiMoUsageError.invalidCookie
        }
        guard let secureBase = normalizedHTTPSURL(baseURL.absoluteString) else {
            throw MiMoUsageError.invalidEndpointOverride
        }
        let guardedSession = redirectGuardedSession(copying: session)
        defer { guardedSession.finishTasksAndInvalidate() }
        return try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask {
                .balance(try await request(
                    secureBase.appendingPathComponent("balance"), cookie: cookie, session: guardedSession
                ))
            }
            group.addTask {
                .detail(try? await request(
                    secureBase.appendingPathComponent("tokenPlan/detail"), cookie: cookie, session: guardedSession
                ))
            }
            group.addTask {
                .usage(try? await request(
                    secureBase.appendingPathComponent("tokenPlan/usage"), cookie: cookie, session: guardedSession
                ))
            }
            var balance: Data?
            var detail: Data?
            var usage: Data?
            while let part = try await group.next() {
                switch part {
                case let .balance(data): balance = data
                case let .detail(data): detail = data
                case let .usage(data): usage = data
                }
            }
            guard let balance else { throw MiMoUsageError.networkError("Balance request did not complete") }
            return try parseCombined(
                balanceData: balance,
                tokenDetailData: detail,
                tokenUsageData: usage,
                now: now
            )
        }
    }

    static func parseCombined(
        balanceData: Data,
        tokenDetailData: Data?,
        tokenUsageData: Data?,
        now: Date = Date()
    ) throws -> MiMoUsageSnapshot {
        let balance = try parseBalance(balanceData, now: now)
        let detail = tokenDetailData.flatMap { try? parseTokenPlanDetail($0) }
        let usage = tokenUsageData.flatMap { try? parseTokenPlanUsage($0) }
        return MiMoUsageSnapshot(
            balance: balance.balance,
            currency: balance.currency,
            cashBalance: balance.cashBalance,
            giftBalance: balance.giftBalance,
            planCode: detail?.planCode,
            planPeriodEnd: detail?.periodEnd,
            planExpired: detail?.expired ?? false,
            tokenUsed: usage?.used ?? 0,
            tokenLimit: usage?.limit ?? 0,
            tokenPercent: usage?.percent ?? 0,
            updatedAt: now
        )
    }

    static func parseBalance(_ data: Data, now: Date = Date()) throws -> MiMoUsageSnapshot {
        let response: BalanceResponse
        do { response = try JSONDecoder().decode(BalanceResponse.self, from: data) }
        catch { throw MiMoUsageError.parseFailed(error.localizedDescription) }
        guard response.code == 0 else {
            if response.code == 401 { throw MiMoUsageError.loginRequired }
            if response.code == 403 { throw MiMoUsageError.invalidCredentials }
            throw MiMoUsageError.parseFailed(response.message?.nilIfBlank ?? "code \(response.code)")
        }
        guard let payload = response.data else { throw MiMoUsageError.parseFailed("Missing balance payload") }
        guard let balance = Double(payload.balance) else { throw MiMoUsageError.parseFailed("Invalid balance value") }
        let currency = payload.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else { throw MiMoUsageError.parseFailed("Missing currency") }
        return MiMoUsageSnapshot(
            balance: balance,
            currency: currency,
            cashBalance: payload.cashBalance.flatMap(Double.init),
            giftBalance: payload.giftBalance.flatMap(Double.init),
            updatedAt: now
        )
    }

    static func parseTokenPlanDetail(_ data: Data) throws -> (planCode: String?, periodEnd: Date?, expired: Bool) {
        let response: TokenPlanDetailResponse
        do { response = try JSONDecoder().decode(TokenPlanDetailResponse.self, from: data) }
        catch { throw MiMoUsageError.parseFailed(error.localizedDescription) }
        guard response.code == 0, let payload = response.data else { return (nil, nil, false) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return (
            payload.planCode,
            payload.currentPeriodEnd.flatMap(formatter.date(from:)),
            payload.expired
        )
    }

    static func parseTokenPlanUsage(_ data: Data) throws -> (used: Int, limit: Int, percent: Double) {
        let response: TokenPlanUsageResponse
        do { response = try JSONDecoder().decode(TokenPlanUsageResponse.self, from: data) }
        catch { throw MiMoUsageError.parseFailed(error.localizedDescription) }
        guard response.code == 0, let item = response.data?.monthUsage?.items.first else { return (0, 0, 0) }
        return (item.used, item.limit, item.percent)
    }

    static func resolvedBaseURL(
        configured: String?,
        environment: [String: String]
    ) throws -> URL {
        let raw = cleaned(configured) ?? cleaned(environment[apiURLKey])
        guard let raw else { return defaultBaseURL }
        guard let url = normalizedHTTPSURL(raw) else { throw MiMoUsageError.invalidEndpointOverride }
        return url
    }

    static func normalizedHTTPSURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil
            ? "https://\(value)" : value
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false), !host.isEmpty,
              !host.contains("%"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let encodedHost = url.host(percentEncoded: true), !encodedHost.contains("%")
        else { return nil }
        return url
    }

    static func shouldFallbackToLocal(_ error: Error) -> Bool {
        guard let error = error as? MiMoUsageError else { return false }
        switch error {
        case .missingCookie, .invalidCookie, .invalidCredentials, .loginRequired: return true
        case .invalidEndpointOverride, .requestFailed, .networkError, .parseFailed: return false
        }
    }

    private enum FetchPart {
        case balance(Data)
        case detail(Data?)
        case usage(Data?)
    }

    private static func request(_ url: URL, cookie: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("UTC+01:00", forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "https://platform.xiaomimimo.com/#/console/balance",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw MiMoUsageError.networkError(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw MiMoUsageError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200: return data
        case 300..<400, 401: throw MiMoUsageError.loginRequired
        case 403: throw MiMoUsageError.invalidCredentials
        default: throw MiMoUsageError.requestFailed(http.statusCode)
        }
    }

    private static func automaticCookieHeaders() -> [String] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        let client = BrowserCookieClient()
        let browsers: [Browser] = [.safari, .chrome, .chromeBeta, .chromeCanary, .firefox, .edge]
        var result: [String] = []
        for browser in browsers {
            var sources = (try? client.records(matching: query, in: browser)) ?? []
            if browser == .firefox {
                sources = MiMoFirefoxSessionCookieImporter.resolvedSources(
                    persisted: sources,
                    stores: client.stores(for: browser)
                )
            }
            let groups = Dictionary(grouping: sources, by: { $0.store.profile.id })
            for group in groups.values {
                let cookies = group.flatMap {
                    BrowserCookieClient.makeHTTPCookies($0.records, origin: query.origin)
                }
                if let header = MiMoCookieHeader.header(from: cookies), !result.contains(header) {
                    result.append(header)
                }
            }
        }
        return result
    }

    private static func shouldRetryNextSession(_ error: Error) -> Bool {
        guard let error = error as? MiMoUsageError else { return false }
        switch error {
        case .invalidCredentials, .loginRequired, .parseFailed: return true
        default: return false
        }
    }

    private static func redirectGuardedSession(copying session: URLSession) -> URLSession {
        URLSession(configuration: session.configuration, delegate: MiMoRedirectGuard(), delegateQueue: nil)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private struct BalanceResponse: Decodable {
        let code: Int
        let message: String?
        let data: BalancePayload?
    }

    private struct BalancePayload: Decodable {
        let balance: String
        let currency: String
        let cashBalance: String?
        let giftBalance: String?
    }

    private struct TokenPlanDetailResponse: Decodable {
        let code: Int
        let data: TokenPlanDetailPayload?
    }

    private struct TokenPlanDetailPayload: Decodable {
        let planCode: String?
        let currentPeriodEnd: String?
        let expired: Bool
    }

    private struct TokenPlanUsageResponse: Decodable {
        let code: Int
        let data: TokenPlanUsagePayload?
    }

    private struct TokenPlanUsagePayload: Decodable {
        let monthUsage: MonthUsage?
    }

    private struct MonthUsage: Decodable {
        let items: [UsageItem]
    }

    private struct UsageItem: Decodable {
        let used: Int
        let limit: Int
        let percent: Double
    }
}

nonisolated enum MiMoFirefoxSessionCookieImporter {
    enum LoadOutcome {
        case loaded([BrowserCookieRecord])
        case unavailable
        case resourceLimited
    }

    private static let maximumInputBytes = 64 * 1024 * 1024
    private static let maximumOutputBytes = 128 * 1024 * 1024
    private static let maximumCookieRecords = 4_096
    private static let magic = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])

    static func resolvedSources(
        persisted: [BrowserCookieStoreRecords],
        stores: [BrowserCookieStore]
    ) -> [BrowserCookieStoreRecords] {
        var byProfile = Dictionary(uniqueKeysWithValues: persisted.map { ($0.store.profile.id, $0) })
        var orderedIDs = persisted.map(\.store.profile.id)
        for store in stores where store.browser == .firefox {
            guard let profileDirectory = store.databaseURL?.deletingLastPathComponent() else { continue }
            switch load(profileDirectory: profileDirectory) {
            case let .loaded(records):
                let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: .domainBased)
                guard MiMoCookieHeader.header(from: cookies) != nil else { continue }
                byProfile[store.profile.id] = BrowserCookieStoreRecords(store: store, records: records)
                if !orderedIDs.contains(store.profile.id) { orderedIDs.append(store.profile.id) }
            case .unavailable, .resourceLimited:
                continue
            }
        }
        return orderedIDs.compactMap { byProfile[$0] }
    }

    static func load(profileDirectory: URL, now: Date = Date()) -> LoadOutcome {
        for file in sessionRestoreFiles(profileDirectory: profileDirectory) {
            do {
                let input = try read(file, maximumBytes: maximumInputBytes)
                let json = try decode(input, maximumOutputBytes: maximumOutputBytes)
                return .loaded(try cookieRecords(json, now: now, maximumRecords: maximumCookieRecords))
            } catch MiMoFirefoxImportError.resourceLimit {
                return .resourceLimited
            } catch {
                continue
            }
        }
        return .unavailable
    }

    static func sessionRestoreFiles(profileDirectory: URL) -> [URL] {
        let backup = profileDirectory.appendingPathComponent("sessionstore-backups", isDirectory: true)
        let upgrades = ((try? FileManager.default.contentsOfDirectory(
            at: backup,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("upgrade.jsonlz4-") }
        let newestUpgrade = upgrades.max { $0.lastPathComponent < $1.lastPathComponent }
        let candidates = [
            profileDirectory.appendingPathComponent("sessionstore.jsonlz4"),
            backup.appendingPathComponent("recovery.jsonlz4"),
            backup.appendingPathComponent("recovery.baklz4"),
            backup.appendingPathComponent("previous.jsonlz4"),
        ] + (newestUpgrade.map { [$0] } ?? [])
        var seen = Set<String>()
        return candidates.filter {
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw MiMoFirefoxImportError.resourceLimit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MiMoFirefoxImportError.resourceLimit }
        return data
    }

    static func decode(_ data: Data, maximumOutputBytes: Int) throws -> Data {
        guard maximumOutputBytes >= 0 else { throw MiMoFirefoxImportError.resourceLimit }
        guard data.starts(with: magic) else { throw MiMoFirefoxImportError.invalidData }
        let payload = data.dropFirst(magic.count)
        guard payload.count >= 4 else { throw MiMoFirefoxImportError.invalidData }
        let size = Array(payload.prefix(4))
        let declaredSize = Int(size[0]) | (Int(size[1]) << 8) | (Int(size[2]) << 16) | (Int(size[3]) << 24)
        guard declaredSize <= maximumOutputBytes else { throw MiMoFirefoxImportError.resourceLimit }
        let decoded = try decodeLZ4(Data(payload.dropFirst(4)), maximumOutputBytes: maximumOutputBytes)
        guard decoded.count == declaredSize else { throw MiMoFirefoxImportError.invalidData }
        return decoded
    }

    static func cookieRecords(
        _ data: Data,
        now: Date = Date(),
        maximumRecords: Int = maximumCookieRecords
    ) throws -> [BrowserCookieRecord] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiMoFirefoxImportError.invalidData
        }
        guard let rawCookies = root["cookies"] else { return [] }
        guard let cookies = rawCookies as? [Any], cookies.count <= maximumRecords else {
            throw MiMoFirefoxImportError.resourceLimit
        }
        var result: [BrowserCookieRecord] = []
        for raw in cookies {
            guard let value = raw as? [String: Any] else { throw MiMoFirefoxImportError.invalidData }
            if let record = cookieRecord(value, now: now) { result.append(record) }
        }
        return result
    }

    private static func cookieRecord(_ value: [String: Any], now: Date) -> BrowserCookieRecord? {
        guard let name = value["name"] as? String,
              MiMoCookieHeader.knownCookieNames.contains(name),
              let cookieValue = value["value"] as? String,
              !cookieValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = (value["host"] as? String) ?? (value["domain"] as? String),
              defaultOriginAttributes(value)
        else { return nil }
        let domain = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let lower = domain.lowercased()
        guard lower == "xiaomimimo.com" || lower == "platform.xiaomimimo.com"
                || lower.hasSuffix(".xiaomimimo.com")
        else { return nil }
        let expiry = expiryDate(value["expires"] ?? value["expiry"])
        if let expiry, expiry < now { return nil }
        return BrowserCookieRecord(
            domain: domain,
            name: name,
            path: (value["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/",
            value: cookieValue,
            expires: expiry,
            isSecure: value["secure"] as? Bool ?? false,
            isHTTPOnly: (value["httponly"] as? Bool) ?? (value["httpOnly"] as? Bool) ?? false
        )
    }

    private static func defaultOriginAttributes(_ value: [String: Any]) -> Bool {
        if let partitioned = value["isPartitioned"], !boolean(partitioned, equals: false) { return false }
        guard let raw = value["originAttributes"] else { return true }
        if let text = raw as? String { return text.isEmpty }
        guard let attributes = raw as? [String: Any] else { return false }
        for (key, entry) in attributes {
            switch key {
            case "userContextId", "privateBrowsingId":
                guard zero(entry) else { return false }
            case "firstPartyDomain", "geckoViewSessionContextId", "partitionKey":
                guard let text = entry as? String, text.isEmpty else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func zero(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType))
        else { return false }
        return number.int64Value == 0
    }

    private static func boolean(_ value: Any, equals expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }

    private static func expiryDate(_ value: Any?) -> Date? {
        if let value = value as? Int, value > 0 { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? Int64, value > 0 { return Date(timeIntervalSince1970: TimeInterval(value)) }
        if let value = value as? Double, value > 0 { return Date(timeIntervalSince1970: value) }
        return nil
    }

    private static func decodeLZ4(_ input: Data, maximumOutputBytes: Int) throws -> Data {
        let bytes = [UInt8](input)
        var index = 0
        var output: [UInt8] = []
        while index < bytes.count {
            let token = bytes[index]
            index += 1
            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                literalLength += try extendedLength(
                    bytes,
                    index: &index,
                    maximum: maximumOutputBytes - literalLength
                )
            }
            guard literalLength <= bytes.count - index,
                  literalLength <= maximumOutputBytes - output.count
            else { throw MiMoFirefoxImportError.resourceLimit }
            output.append(contentsOf: bytes[index..<index + literalLength])
            index += literalLength
            guard index < bytes.count else { break }
            guard bytes.count - index >= 2 else { throw MiMoFirefoxImportError.invalidData }
            let offset = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
            guard offset > 0, offset <= output.count else { throw MiMoFirefoxImportError.invalidData }
            var matchLength = Int(token & 0x0F) + 4
            if token & 0x0F == 15 {
                matchLength += try extendedLength(
                    bytes,
                    index: &index,
                    maximum: maximumOutputBytes - matchLength
                )
            }
            guard matchLength <= maximumOutputBytes - output.count else {
                throw MiMoFirefoxImportError.resourceLimit
            }
            for _ in 0..<matchLength { output.append(output[output.count - offset]) }
        }
        return Data(output)
    }

    private static func extendedLength(
        _ bytes: [UInt8],
        index: inout Int,
        maximum: Int
    ) throws -> Int {
        var length = 0
        while index < bytes.count {
            let next = Int(bytes[index])
            index += 1
            guard length <= maximum, next <= maximum - length else { throw MiMoFirefoxImportError.resourceLimit }
            length += next
            if next != 255 { break }
        }
        return length
    }
}

private nonisolated enum MiMoFirefoxImportError: Error {
    case resourceLimit
    case invalidData
}

private nonisolated final class MiMoRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              original.scheme?.lowercased() == "https", redirected.scheme?.lowercased() == "https",
              original.host?.lowercased() == redirected.host?.lowercased(),
              Self.port(original) == Self.port(redirected)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func port(_ url: URL) -> Int { url.port ?? 443 }
}

nonisolated enum MiMoLocalUsageFallback {
    static func providerUsage(
        environment: [String: String],
        now: Date = Date()
    ) -> ProviderUsage? {
        snapshot(path: cachePath(environment: environment), now: now)
    }

    static func cachePath(environment: [String: String]) -> String {
        if let raw = environment["MIMO_LOCAL_USAGE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return NSString(string: raw).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/mimo-local-usage.json").path
    }

    static func snapshot(path: String, now: Date = Date()) -> ProviderUsage? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windows"] as? [String: Any],
              let today = windows["today"] as? [String: Any],
              let week = windows["week"] as? [String: Any]
        else { return nil }
        let updatedAt = updatedAt(root, url: url, fallback: now)
        let todayTotal = total(today)
        let weekTotal = total(week)
        return ProviderUsage(
            id: ProviderID(rawValue: "mimo"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            today: DailyTokenUsage(tokens: Int64(todayTotal), valueUSD: nil),
            weeklyEstimate: DailyTokenUsage(tokens: Int64(weekTotal), valueUSD: nil),
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func total(_ window: [String: Any]) -> Int {
        ["input", "output", "cache_read", "cache_create"].reduce(into: 0) { result, key in
            let (sum, overflow) = result.addingReportingOverflow(integer(window[key]))
            result = overflow ? Int.max : sum
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return max(0, value) }
        if let value = value as? Double, value.isFinite, value >= 0, value <= Double(Int.max) {
            return Int(value)
        }
        if let value = value as? String, let number = Int(value) { return max(0, number) }
        return 0
    }

    private static func updatedAt(_ root: [String: Any], url: URL, fallback: Date) -> Date {
        if let raw = root["updated_at"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? fallback
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
