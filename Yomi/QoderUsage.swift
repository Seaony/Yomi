import Foundation
import SweetCookieKit

nonisolated enum QoderUsageError: LocalizedError, Equatable {
    case missingSession
    case invalidSession
    case requestFailed(Int)
    case parseFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "未找到 Qoder 会话，请先登录 qoder.com 或 qoder.com.cn，或粘贴 Cookie 标头",
                "No Qoder session was found. Sign in to qoder.com or qoder.com.cn, or paste a Cookie header."
            )
        case .invalidSession:
            AppLocalization.text(
                "Qoder 会话无效或已过期，请重新登录",
                "The Qoder session is invalid or expired. Sign in again."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Qoder 用量请求失败（HTTP \(status)）",
                "Qoder usage request failed (HTTP \(status))"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Qoder 用量：\(message)",
                "Could not parse Qoder usage: \(message)"
            )
        case let .networkError(message):
            AppLocalization.text(
                "Qoder 接口错误：\(message)",
                "Qoder API error: \(message)"
            )
        }
    }
}

nonisolated enum QoderWebSite: CaseIterable, Sendable {
    case international
    case china

    var usageURL: URL {
        switch self {
        case .international: URL(string: "https://qoder.com/api/v2/me/usages/big_model_credits")!
        case .china: URL(string: "https://qoder.com.cn/api/v2/me/usages/big_model_credits")!
        }
    }

    var dashboardURL: URL {
        switch self {
        case .international: URL(string: "https://qoder.com/account/usage")!
        case .china: URL(string: "https://qoder.com.cn/account/usage")!
        }
    }

    var origin: String {
        switch self {
        case .international: "https://qoder.com"
        case .china: "https://qoder.com.cn"
        }
    }

    var cookieDomains: [String] {
        switch self {
        case .international: ["qoder.com", "www.qoder.com"]
        case .china: ["qoder.com.cn", "www.qoder.com.cn"]
        }
    }

    var cacheKey: String {
        switch self {
        case .international: "international"
        case .china: "china"
        }
    }

    init?(cacheKey: String) {
        switch cacheKey {
        case "international": self = .international
        case "china": self = .china
        default: return nil
        }
    }
}

nonisolated struct QoderUsageSnapshot: Sendable, Equatable {
    let usedCredits: Double
    let totalCredits: Double
    let remainingCredits: Double
    let usagePercentage: Double
    let unit: String?
    let resetsAt: Date?
    let updatedAt: Date

    func toProviderUsage() -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "qoder"),
            state: .ready,
            windows: [UsageWindow(
                id: "qoder-credits",
                label: "Credits",
                usedFraction: min(1, max(0, usagePercentage / 100)),
                resetsAt: resetsAt,
                detail: "\(Self.formatCredits(usedCredits)) / \(Self.formatCredits(totalCredits)) credits"
            )],
            balance: nil,
            plan: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }

    static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

nonisolated enum QoderUsageFetcher {
    typealias CacheUpdate = @Sendable (_ cookieHeader: String?, _ site: QoderWebSite?) async -> Void

    private struct ImportedSession {
        let cookieHeader: String
        let site: QoderWebSite
    }

    private struct QuotaResponse: Decodable {
        let totalQuota: QuotaContainer?
        let sharedQuota: QuotaContainer?
        let nextResetAt: Date?

        private enum CodingKeys: String, CodingKey {
            case totalQuota
            case totalQuotaSnake = "total_quota"
            case sharedQuota
            case sharedQuotaSnake = "shared_quota"
            case nextResetAt
            case nextResetAtSnake = "next_reset_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalQuota = try container.decodeIfPresent(QuotaContainer.self, forKey: .totalQuota)
                ?? container.decodeIfPresent(QuotaContainer.self, forKey: .totalQuotaSnake)
            sharedQuota = try container.decodeIfPresent(QuotaContainer.self, forKey: .sharedQuota)
                ?? container.decodeIfPresent(QuotaContainer.self, forKey: .sharedQuotaSnake)
            nextResetAt = Self.date(from: container, key: .nextResetAt)
                ?? Self.date(from: container, key: .nextResetAtSnake)
        }

        private static func date(
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Date? {
            if let value = try? container.decode(String.self, forKey: key) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) { return date }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            return nil
        }
    }

    private struct QuotaContainer: Decodable {
        let quotaSummary: QuotaSummary?

        private enum CodingKeys: String, CodingKey {
            case quotaSummary
            case quotaSummarySnake = "quota_summary"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quotaSummary = try container.decodeIfPresent(QuotaSummary.self, forKey: .quotaSummary)
                ?? container.decodeIfPresent(QuotaSummary.self, forKey: .quotaSummarySnake)
        }
    }

    private struct QuotaSummary: Decodable {
        let usedValue: Double
        let limitValue: Double
        let remainingValue: Double?
        let usagePercentage: Double?
        let unit: String?

        private enum CodingKeys: String, CodingKey {
            case usedValue
            case usedValueSnake = "used_value"
            case limitValue
            case limitValueSnake = "limit_value"
            case remainingValue
            case remainingValueSnake = "remaining_value"
            case usagePercentage
            case usagePercentageSnake = "usage_percentage"
            case unit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedValue = try container.decodeIfPresent(Double.self, forKey: .usedValue)
                ?? container.decode(Double.self, forKey: .usedValueSnake)
            limitValue = try container.decodeIfPresent(Double.self, forKey: .limitValue)
                ?? container.decode(Double.self, forKey: .limitValueSnake)
            remainingValue = try container.decodeIfPresent(Double.self, forKey: .remainingValue)
                ?? container.decodeIfPresent(Double.self, forKey: .remainingValueSnake)
            usagePercentage = try container.decodeIfPresent(Double.self, forKey: .usagePercentage)
                ?? container.decodeIfPresent(Double.self, forKey: .usagePercentageSnake)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
        }
    }

    private struct MergedQuota {
        let used: Double
        let total: Double
        let remaining: Double
        let percentage: Double
        let unit: String?
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cachedSite: QoderWebSite? = nil,
        cacheUpdate: @escaping CacheUpdate = { _, _ in },
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if source == .cookie {
            guard let cookie = normalizedCookie(credential) else { throw QoderUsageError.missingSession }
            guard let site = site(forManualInput: credential) else { throw QoderUsageError.invalidSession }
            return try await fetch(cookieHeader: cookie, site: site, session: session, now: now).toProviderUsage()
        }

        guard source == .automatic || source == .account else { throw QoderUsageError.missingSession }
        var lastError: QoderUsageError = .missingSession

        if let cachedCookieHeader = normalizedCookie(cachedCookieHeader), let cachedSite {
            do {
                return try await fetch(
                    cookieHeader: cachedCookieHeader,
                    site: cachedSite,
                    session: session,
                    now: now
                ).toProviderUsage()
            } catch let error as QoderUsageError {
                lastError = error
                if error == .invalidSession { await cacheUpdate(nil, nil) }
            }
        }

        for candidate in automaticSessions() {
            do {
                let snapshot = try await fetch(
                    cookieHeader: candidate.cookieHeader,
                    site: candidate.site,
                    session: session,
                    now: now
                )
                await cacheUpdate(candidate.cookieHeader, candidate.site)
                return snapshot.toProviderUsage()
            } catch let error as QoderUsageError {
                lastError = error
            }
        }
        throw lastError
    }

    static func fetch(
        cookieHeader: String,
        site: QoderWebSite = .international,
        session: URLSession,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> QoderUsageSnapshot {
        var request = URLRequest(url: site.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(site.origin, forHTTPHeaderField: "Origin")
        request.setValue("\(site.origin)/account/usage", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QoderUsageError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw QoderUsageError.networkError("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw QoderUsageError.invalidSession }
        guard (200..<300).contains(http.statusCode) else {
            throw QoderUsageError.requestFailed(http.statusCode)
        }
        return try parseUsage(data: data, now: now)
    }

    static func parseUsage(data: Data, now: Date = Date()) throws -> QoderUsageSnapshot {
        let response: QuotaResponse
        do {
            response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        } catch {
            throw QoderUsageError.parseFailed("invalid JSON: \(error.localizedDescription)")
        }
        guard let base = response.totalQuota?.quotaSummary else {
            throw QoderUsageError.parseFailed("missing totalQuota.quotaSummary")
        }
        let merged = try mergedQuota(base: base, shared: response.sharedQuota?.quotaSummary)
        return QoderUsageSnapshot(
            usedCredits: merged.used,
            totalCredits: merged.total,
            remainingCredits: merged.remaining,
            usagePercentage: merged.percentage,
            unit: merged.unit,
            resetsAt: response.nextResetAt,
            updatedAt: now
        )
    }

    private static func mergedQuota(base: QuotaSummary, shared: QuotaSummary?) throws -> MergedQuota {
        let baseRemaining = try remaining(for: base)
        guard let shared else {
            return MergedQuota(
                used: base.usedValue,
                total: base.limitValue,
                remaining: baseRemaining,
                percentage: try percentage(
                    used: base.usedValue,
                    total: base.limitValue,
                    remaining: baseRemaining,
                    provided: base.usagePercentage
                ),
                unit: base.unit
            )
        }
        let sharedRemaining = try remaining(for: shared)
        let used = base.usedValue + shared.usedValue
        let total = base.limitValue + shared.limitValue
        let remaining = baseRemaining + sharedRemaining
        return MergedQuota(
            used: used,
            total: total,
            remaining: remaining,
            percentage: try percentage(used: used, total: total, remaining: remaining, provided: nil),
            unit: base.unit ?? shared.unit
        )
    }

    private static func remaining(for summary: QuotaSummary) throws -> Double {
        guard summary.usedValue >= 0,
              summary.limitValue >= 0,
              summary.remainingValue.map({ $0 >= 0 }) ?? true
        else {
            throw QoderUsageError.parseFailed("quota values must be nonnegative")
        }
        return summary.remainingValue ?? max(0, summary.limitValue - summary.usedValue)
    }

    private static func percentage(
        used: Double,
        total: Double,
        remaining: Double,
        provided: Double?
    ) throws -> Double {
        guard used >= 0, total >= 0, remaining >= 0 else {
            throw QoderUsageError.parseFailed("quota values must be nonnegative")
        }
        guard total > 0 else {
            guard used == 0, remaining == 0 else {
                throw QoderUsageError.parseFailed("zero total quota must have zero usage and remaining")
            }
            return provided ?? 100
        }
        return provided ?? used / total * 100
    }

    static func normalizedCookie(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let patterns = [
            #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
            #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
            #"(?i)\bcookie:\s*'([^']+)'"#,
            #"(?i)\bcookie:\s*\"([^\"]+)\""#,
            #"(?i)\bcookie:\s*([^\r\n]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
            #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#,
            #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value)
            else { continue }
            value = String(value[range])
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func site(forManualInput raw: String?) -> QoderWebSite? {
        guard let raw else { return .international }
        if let route = curlRoute(raw) { return route }
        if let route = httpRoute(raw) { return route }
        var routed: QoderWebSite?
        for part in raw.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "domain"
            else { continue }
            guard let site = site(forHost: String(pieces[1])) else { return nil }
            if let routed, routed != site { return nil }
            routed = site
        }
        return routed ?? .international
    }

    private static func curlRoute(_ raw: String) -> QoderWebSite?? {
        guard containsCurlExecutable(raw) else { return nil }
        guard let processed = preprocessShell(raw) else { return .some(nil) }
        let tokens = shellTokens(processed)
        var index = tokens.startIndex
        while index < tokens.endIndex, isShellAssignment(tokens[index]) {
            index = tokens.index(after: index)
        }
        guard index < tokens.endIndex, isCurlExecutable(tokens[index]) else { return .some(nil) }
        let curlIndex = index
        var targets: [(Int, QoderWebSite)] = []
        var hostSites: [QoderWebSite] = []
        index = tokens.index(after: index)
        while index < tokens.endIndex {
            let token = tokens[index]
            let lower = token.lowercased()
            if lower == "--config" || lower.hasPrefix("--config=") || lower.hasPrefix("--expand-")
                || lower == "--location-trusted" || shortOptions(token, contain: "K")
            {
                return .some(nil)
            }
            if lower == "--url" {
                let valueIndex = tokens.index(after: index)
                guard valueIndex < tokens.endIndex,
                      let site = site(forURLText: tokens[valueIndex])
                else { return .some(nil) }
                targets.append((valueIndex, site))
                index = tokens.index(after: valueIndex)
                continue
            }
            if lower.hasPrefix("--url=") {
                guard let site = site(forURLText: String(token.dropFirst("--url=".count))) else {
                    return .some(nil)
                }
                targets.append((index, site))
            } else if let site = site(forURLText: token) {
                targets.append((index, site))
            } else if host(forURLText: token) != nil {
                return .some(nil)
            }

            let header: String?
            if lower == "--header" {
                let valueIndex = tokens.index(after: index)
                guard valueIndex < tokens.endIndex else { return .some(nil) }
                header = tokens[valueIndex]
                index = valueIndex
            } else if lower.hasPrefix("--header=") {
                header = String(token.dropFirst("--header=".count))
            } else if let short = shortHeader(token) {
                switch short {
                case let .attached(value): header = value
                case .next:
                    let valueIndex = tokens.index(after: index)
                    guard valueIndex < tokens.endIndex else { return .some(nil) }
                    header = tokens[valueIndex]
                    index = valueIndex
                case .invalid: return .some(nil)
                }
            } else {
                header = nil
            }
            if let header {
                let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.hasPrefix("@") else { return .some(nil) }
                let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if pieces.count == 2,
                   pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "host"
                {
                    guard let site = site(forHost: String(pieces[1])) else { return .some(nil) }
                    hostSites.append(site)
                } else if trimmed.lowercased() == "host" || trimmed.lowercased().hasPrefix("host;") {
                    return .some(nil)
                }
            }
            index = tokens.index(after: index)
        }
        let uniqueTargets = Dictionary(grouping: targets, by: { $0.0 })
        guard uniqueTargets.count == 1,
              let target = uniqueTargets.values.first?.first,
              target.0 == tokens.index(after: curlIndex) || tokens[target.0 - 1].lowercased() == "--url"
        else { return .some(nil) }
        guard hostSites.allSatisfy({ $0 == target.1 }) else { return .some(nil) }
        return .some(target.1)
    }

    private static func httpRoute(_ raw: String) -> QoderWebSite?? {
        let supported = ["get", "post", "put", "patch", "delete", "head", "options"]
        var requestSite: QoderWebSite?
        var sawRequest = false
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let method = String(parts[0]).lowercased()
            let versioned = parts.count >= 3 && parts[2].lowercased().hasPrefix("http/")
            if !supported.contains(method) {
                if versioned && parts[0].allSatisfy({ $0.isASCII && $0.isLetter }) { return .some(nil) }
                continue
            }
            guard !sawRequest else { return .some(nil) }
            sawRequest = true
            let target = String(parts[1])
            if target.hasPrefix("/") {
                requestSite = nil
            } else if let site = site(forURLText: target) {
                requestSite = site
            } else {
                return .some(nil)
            }
        }
        guard sawRequest else { return nil }
        var hosts: [QoderWebSite] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "host"
            else { continue }
            guard let site = site(forHost: String(pieces[1])) else { return .some(nil) }
            hosts.append(site)
        }
        guard hosts.dropFirst().allSatisfy({ $0 == hosts.first }) else { return .some(nil) }
        if let requestSite {
            guard hosts.first.map({ $0 == requestSite }) ?? true else { return .some(nil) }
            return .some(requestSite)
        }
        guard let host = hosts.first else { return .some(nil) }
        return .some(host)
    }

    private enum ShortHeader {
        case attached(String)
        case next
        case invalid
    }

    private static func shortHeader(_ token: String) -> ShortHeader? {
        guard token.hasPrefix("-"), !token.hasPrefix("--") else { return nil }
        let options = String(token.dropFirst())
        guard let header = options.firstIndex(of: "H") else { return nil }
        let safe = Set("fsSL")
        guard options[..<header].allSatisfy({ safe.contains($0) }) else { return .invalid }
        let value = String(options[options.index(after: header)...])
        return value.isEmpty ? .next : .attached(value)
    }

    private static func shortOptions(_ token: String, contain option: Character) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token.dropFirst().contains(option)
    }

    private static func containsCurlExecutable(_ raw: String) -> Bool {
        shellTokens(raw).contains(where: isCurlExecutable)
            || raw.range(
                of: #"(^|[\s;])(?:[^\s;=]+/)?curl($|[\s;])"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
    }

    private static func isCurlExecutable(_ token: String) -> Bool {
        guard !token.contains("="), !token.contains("://") else { return false }
        return (token.split(separator: "/").last.map(String.init) ?? token).lowercased() == "curl"
    }

    private static func isShellAssignment(_ token: String) -> Bool {
        guard !token.contains(";"), let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private enum ShellQuote: Equatable {
        case single
        case double
    }

    private static func preprocessShell(_ raw: String) -> String? {
        let scalars = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = scalars.startIndex
        var quote: ShellQuote?

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)

            if scalar == "\\" {
                if quote == nil {
                    if nextIndex < scalars.endIndex, scalars[nextIndex] == "\n" {
                        index = scalars.index(after: nextIndex)
                        continue
                    }
                    if nextIndex < scalars.endIndex, scalars[nextIndex] == "\r" {
                        let afterReturn = scalars.index(after: nextIndex)
                        if afterReturn < scalars.endIndex, scalars[afterReturn] == "\n" {
                            index = scalars.index(after: afterReturn)
                            continue
                        }
                    }
                }
                if quote != .single,
                   nextIndex < scalars.endIndex,
                   isSupportedEscapedShellLiteral(scalars[nextIndex])
                {
                    output.append(scalar)
                    output.append(scalars[nextIndex])
                    index = scalars.index(after: nextIndex)
                    continue
                }
                if quote == .double { return nil }
            }

            guard scalar.value >= 0x20, scalar.value != 0x7F else { return nil }

            switch quote {
            case .single:
                if scalar == "'" { quote = nil }
            case .double:
                if scalar == "\"" {
                    quote = nil
                } else if scalar == "`" || isUnsupportedDollarExpansion(in: scalars, at: index) {
                    return nil
                }
            case nil:
                if ";|&<>".unicodeScalars.contains(scalar) {
                    return nil
                } else if scalar == "'" {
                    quote = .single
                } else if scalar == "\"" {
                    quote = .double
                } else if scalar == "`"
                    || isUnsupportedDollarExpansion(in: scalars, at: index)
                    || isProcessSubstitution(in: scalars, at: index)
                {
                    return nil
                }
            }

            output.append(scalar)
            index = nextIndex
        }
        return quote == nil ? String(output) : nil
    }

    private static func isSupportedEscapedShellLiteral(_ scalar: UnicodeScalar) -> Bool {
        scalar == "'" || scalar == "\"" || scalar == "\\"
    }

    private static func isUnsupportedDollarExpansion(in scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard scalars[index] == "$" else { return false }
        let nextIndex = scalars.index(after: index)
        guard nextIndex < scalars.endIndex else { return false }
        let next = scalars[nextIndex]
        if next == "'" || next == "\"" || next == "(" || next == "{" || next == "[" { return true }
        if next == "_" || next.properties.isAlphabetic || (48...57).contains(Int(next.value)) { return true }
        return "*@#?$!-".unicodeScalars.contains(next)
    }

    private static func isProcessSubstitution(in scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard scalars[index] == "<" || scalars[index] == ">" else { return false }
        let nextIndex = scalars.index(after: index)
        return nextIndex < scalars.endIndex && scalars[nextIndex] == "("
    }

    private static func shellTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func host(forURLText text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let lower = value.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        return URL(string: value)?.host?.lowercased()
    }

    private static func site(forURLText text: String) -> QoderWebSite? {
        host(forURLText: text).flatMap(site(forHost:))
    }

    private static func site(forHost raw: String) -> QoderWebSite? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        if let separator = value.lastIndex(of: ":") {
            let hostname = value[..<separator]
            let port = value[value.index(after: separator)...]
            guard !hostname.contains(":"),
                  !port.isEmpty,
                  port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(port),
                  (1...65_535).contains(number)
            else { return nil }
            value = String(hostname)
        }
        switch value {
        case "qoder.com", "www.qoder.com": return .international
        case "qoder.com.cn", "www.qoder.com.cn": return .china
        default: return nil
        }
    }

    private static func automaticSessions() -> [ImportedSession] {
        let client = BrowserCookieClient()
        var results: [ImportedSession] = []
        for site in QoderWebSite.allCases {
            let query = cookieQuery(for: site)
            guard let sources = try? client.records(matching: query, in: .chrome) else { continue }
            for source in sources where !source.records.isEmpty {
                let records = records(source.records, for: site)
                let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                guard !cookies.isEmpty else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                guard !results.contains(where: { $0.cookieHeader == header && $0.site == site }) else { continue }
                results.append(ImportedSession(
                    cookieHeader: header,
                    site: site
                ))
            }
        }
        return results
    }

    static func cookieQuery(for site: QoderWebSite) -> BrowserCookieQuery {
        BrowserCookieQuery(domains: site.cookieDomains, domainMatch: .exact)
    }

    static func records(_ records: [BrowserCookieRecord], for site: QoderWebSite) -> [BrowserCookieRecord] {
        records.filter { record in
            let domain = record.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return site.cookieDomains.contains(domain)
        }
    }
}
