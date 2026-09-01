import CoreFoundation
import Foundation

nonisolated enum ZaiUsageRegion: String, CaseIterable, Sendable {
    case global
    case bigModelCN = "bigmodel-cn"

    static let quotaPath = "api/monitor/usage/quota/limit"

    var baseURL: URL {
        switch self {
        case .global: URL(string: "https://api.z.ai")!
        case .bigModelCN: URL(string: "https://open.bigmodel.cn")!
        }
    }

    var dashboardURL: URL {
        switch self {
        case .global: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!
        case .bigModelCN: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
        }
    }

    var teamDashboardURL: URL {
        switch self {
        case .global: dashboardURL
        case .bigModelCN: URL(string: "https://bigmodel.cn/coding-plan/team/usage-stats")!
        }
    }

    var quotaURL: URL {
        baseURL.appendingPathComponent(Self.quotaPath)
    }

    var balanceURL: URL? {
        switch self {
        case .global: nil
        case .bigModelCN:
            URL(string: "https://www.bigmodel.cn/api/biz/account/query-customer-account-report")!
        }
    }
}

nonisolated enum ZaiUsageScope: String, Sendable {
    case personal
    case team
}

nonisolated enum ZaiUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidRegion(String)
    case invalidUsageScope(String)
    case missingTeamContext
    case invalidEndpointOverride(String)
    case endpointRegionMismatch(String, ZaiUsageRegion)
    case requestFailed(Int, String)
    case network(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return AppLocalization.text(
                "未找到 z.ai / GLM API Key",
                "z.ai / GLM API key was not found"
            )
        case let .invalidRegion(region):
            return AppLocalization.text(
                "不支持 z.ai / GLM 区域：\(region)",
                "Unsupported z.ai / GLM region: \(region)"
            )
        case let .invalidUsageScope(scope):
            return AppLocalization.text(
                "不支持 z.ai / GLM 用量范围：\(scope)",
                "Unsupported z.ai / GLM usage scope: \(scope)"
            )
        case .missingTeamContext:
            return AppLocalization.text(
                "z.ai / GLM 团队用量需要 Organization ID 和 Project ID",
                "z.ai / GLM team usage requires both Organization ID and Project ID"
            )
        case let .invalidEndpointOverride(key):
            return AppLocalization.text(
                "z.ai / GLM 接口覆盖项 \(key) 必须是 HTTPS 地址或裸主机名",
                "z.ai / GLM endpoint override \(key) must use HTTPS or a bare host"
            )
        case let .endpointRegionMismatch(key, region):
            return AppLocalization.text(
                "z.ai / GLM 接口覆盖项 \(key) 与所选区域 \(region.rawValue) 不一致",
                "z.ai / GLM endpoint override \(key) does not match the selected \(region.rawValue) region"
            )
        case let .requestFailed(status, message):
            return AppLocalization.text(
                "z.ai / GLM 请求失败（HTTP \(status)）" + (message.isEmpty ? "" : "：\(message)"),
                "z.ai / GLM request failed (HTTP \(status))" + (message.isEmpty ? "" : ": \(message)")
            )
        case let .network(message):
            return AppLocalization.text(
                "z.ai / GLM 网络错误：\(message)",
                "z.ai / GLM network error: \(message)"
            )
        case let .parseFailed(message):
            return AppLocalization.text(
                "无法解析 z.ai / GLM 用量：\(message)",
                "Could not parse z.ai / GLM usage: \(message)"
            )
        }
    }
}

nonisolated enum ZaiUsageFetcher {
    static let apiKeyEnvironmentKey = "Z_AI_API_KEY"
    static let regionEnvironmentKey = "Z_AI_REGION"
    static let usageScopeEnvironmentKey = "Z_AI_USAGE_SCOPE"
    static let apiHostEnvironmentKey = "Z_AI_API_HOST"
    static let quotaURLEnvironmentKey = "Z_AI_QUOTA_URL"
    static let balanceURLEnvironmentKey = "Z_AI_BALANCE_URL"
    static let organizationEnvironmentKey = "Z_AI_BIGMODEL_ORGANIZATION"
    static let projectEnvironmentKey = "Z_AI_BIGMODEL_PROJECT"
    static let bigModelAPIKeyEnvironmentKeys = [
        "BIGMODEL_API_KEY",
        "ZHIPU_API_KEY",
        "ZHIPUAI_API_KEY",
        "GLM_API_KEY",
    ]
    static let bigModelAPIKeyRelativePaths = [
        ".coding-relay/glm-api-key",
        ".config/bigmodel/api_key",
        ".config/zhipu/api_key",
    ]

    private static let timeout: TimeInterval = 18
    private static let balanceTimeout: TimeInterval = 5

    static func fetch(
        apiKey: String?,
        region configuredRegion: String?,
        usageScope configuredScope: String? = nil,
        organizationID configuredOrganizationID: String? = nil,
        projectID configuredProjectID: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let region = try resolvedRegion(configured: configuredRegion, environment: environment)
        let scope = try resolvedUsageScope(configured: configuredScope, environment: environment)
        let organizationID = cleaned(configuredOrganizationID) ?? cleaned(environment[organizationEnvironmentKey])
        let projectID = cleaned(configuredProjectID) ?? cleaned(environment[projectEnvironmentKey])
        if scope == .team, organizationID == nil || projectID == nil {
            throw ZaiUsageError.missingTeamContext
        }
        guard let token = resolvedAPIKey(
            configured: apiKey,
            region: region,
            environment: environment,
            homeDirectory: homeDirectory
        ) else {
            throw ZaiUsageError.missingAPIKey
        }

        try validateEndpointOverrides(region: region, environment: environment)
        let quotaEndpoint = quotaURL(region: region, environment: environment)
        var teamHeaders: [String: String] = [:]
        if scope == .team, let organizationID, let projectID {
            teamHeaders = [
                "Bigmodel-Organization": organizationID,
                "Bigmodel-Project": projectID,
            ]
        }
        let quotaRequest = request(
            url: scope == .team ? replacingTypeQuery(in: quotaEndpoint, value: "2") : quotaEndpoint,
            token: token,
            headers: teamHeaders,
            timeout: timeout
        )
        let quotaData = try await requiredData(for: quotaRequest, session: session)
        var usage = try parseQuota(quotaData, now: now)

        if let balanceEndpoint = balanceURL(region: region, environment: environment),
           let balance = try? await fetchBalance(
               url: balanceEndpoint,
               token: token,
               session: session
           )
        {
            usage.balance = balance.value
            usage.details.append(balance.detail)
        }

        usage.updatedAt = now
        return usage
    }

    static func resolvedRegion(
        configured: String?,
        environment: [String: String]
    ) throws -> ZaiUsageRegion {
        let raw = cleaned(configured) ?? cleaned(environment[regionEnvironmentKey]) ?? ZaiUsageRegion.global.rawValue
        guard let region = ZaiUsageRegion(rawValue: raw) else {
            throw ZaiUsageError.invalidRegion(raw)
        }
        return region
    }

    static func resolvedUsageScope(
        configured: String?,
        environment: [String: String]
    ) throws -> ZaiUsageScope {
        let raw = cleaned(configured) ?? cleaned(environment[usageScopeEnvironmentKey]) ?? ZaiUsageScope.personal.rawValue
        guard let scope = ZaiUsageScope(rawValue: raw.lowercased()) else {
            throw ZaiUsageError.invalidUsageScope(raw)
        }
        return scope
    }

    static func resolvedAPIKey(
        configured: String?,
        region: ZaiUsageRegion,
        environment: [String: String],
        homeDirectory: URL
    ) -> String? {
        if let configured = cleaned(configured) { return configured }
        if let direct = cleaned(environment[apiKeyEnvironmentKey]) { return direct }
        guard region == .bigModelCN else { return nil }
        for key in bigModelAPIKeyEnvironmentKeys {
            if let value = cleaned(environment[key]) { return value }
        }
        for relativePath in bigModelAPIKeyRelativePaths {
            let url = homeDirectory.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let raw = try? String(contentsOf: url, encoding: .utf8),
                  let line = raw.split(whereSeparator: \.isNewline).first,
                  let value = cleaned(String(line))
            else { continue }
            return value
        }
        return nil
    }

    static func quotaURL(region: ZaiUsageRegion, environment: [String: String]) -> URL {
        if let raw = cleaned(environment[quotaURLEnvironmentKey]),
           let url = normalizedHTTPSURL(raw) {
            return url
        }
        if let raw = cleaned(environment[apiHostEnvironmentKey]),
           let url = endpointURL(base: raw, path: ZaiUsageRegion.quotaPath) {
            return url
        }
        return region.quotaURL
    }

    static func balanceURL(region: ZaiUsageRegion, environment: [String: String]) -> URL? {
        if let raw = cleaned(environment[balanceURLEnvironmentKey]) {
            return normalizedHTTPSURL(raw)
        }
        return region.balanceURL
    }

    static func dashboardURL(
        region: ZaiUsageRegion,
        usageScope: ZaiUsageScope,
        environment: [String: String]
    ) -> URL {
        let quotaHost = quotaURL(region: region, environment: environment).host?.lowercased()
        let resolvedRegion: ZaiUsageRegion
        if quotaHost == ZaiUsageRegion.global.quotaURL.host?.lowercased() {
            resolvedRegion = .global
        } else if quotaHost == ZaiUsageRegion.bigModelCN.quotaURL.host?.lowercased() {
            resolvedRegion = .bigModelCN
        } else {
            resolvedRegion = region
        }
        return usageScope == .team ? resolvedRegion.teamDashboardURL : resolvedRegion.dashboardURL
    }

    static func validateEndpointOverrides(
        region: ZaiUsageRegion,
        environment: [String: String]
    ) throws {
        if let raw = cleaned(environment[quotaURLEnvironmentKey]) {
            guard let url = normalizedHTTPSURL(raw) else {
                throw ZaiUsageError.invalidEndpointOverride(quotaURLEnvironmentKey)
            }
            try validateKnownHost(url, region: region, key: quotaURLEnvironmentKey)
        }
        if let raw = cleaned(environment[apiHostEnvironmentKey]) {
            guard let url = normalizedHTTPSURL(raw) else {
                throw ZaiUsageError.invalidEndpointOverride(apiHostEnvironmentKey)
            }
            try validateKnownHost(url, region: region, key: apiHostEnvironmentKey)
        }
        if let raw = cleaned(environment[balanceURLEnvironmentKey]), normalizedHTTPSURL(raw) == nil {
            throw ZaiUsageError.invalidEndpointOverride(balanceURLEnvironmentKey)
        }
    }

    static func parseQuota(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              integer(root["code"]) == 200
        else {
            throw ZaiUsageError.parseFailed("invalid quota response")
        }
        guard let response = root["data"] as? [String: Any],
              let rawLimits = response["limits"] as? [Any]
        else {
            throw ZaiUsageError.parseFailed("missing quota limits")
        }

        let limits = try rawLimits.compactMap(parseLimit)
        let tokenLimits = limits.enumerated()
            .filter { $0.element.kind == .tokens || $0.element.kind == .credit }
            .sorted {
                let lhs = $0.element.windowMinutes ?? Int.max
                let rhs = $1.element.windowMinutes ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            .map(\.element)
        let timeLimit = limits.last { $0.kind == .time }
        let tokenLimit = tokenLimits.last
        let sessionLimit = tokenLimits.count >= 2 ? tokenLimits.first : nil
        let primaryLimit = sessionLimit ?? tokenLimit ?? timeLimit

        var windows: [UsageWindow] = []
        if let primaryLimit {
            windows.append(usageWindow(primaryLimit, id: "zai-primary", fallbackLabel: "5-hour"))
        }
        if sessionLimit != nil, let tokenLimit {
            windows.append(usageWindow(tokenLimit, id: "zai-secondary", fallbackLabel: "Weekly"))
        }
        var additional: [UsageWindow] = []
        if (tokenLimit != nil || sessionLimit != nil), let timeLimit {
            additional.append(usageWindow(timeLimit, id: "zai-mcp", fallbackLabel: "MCP"))
        }

        let plan = ["planName", "plan", "plan_type", "packageName", "level"]
            .lazy
            .compactMap { cleaned(response[$0] as? String) }
            .first

        return ProviderUsage(
            id: ProviderID(rawValue: "zai"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: nil,
            plan: plan,
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    private enum LimitKind: String {
        case tokens = "TOKENS_LIMIT"
        case time = "TIME_LIMIT"
        case credit = "CREDIT_LIMIT"
    }

    private struct Limit {
        let kind: LimitKind
        let unit: Int
        let number: Int
        let usage: Int?
        let remaining: Int?
        let percent: Double
        let windowMinutes: Int?
        let reset: Date?
        let details: [Any]
    }

    private static func parseLimit(_ raw: Any) throws -> Limit? {
        guard let object = raw as? [String: Any],
              let type = object["type"] as? String,
              let unit = integer(object["unit"]),
              let number = integer(object["number"]),
              let percentage = integer(object["percentage"])
        else {
            throw ZaiUsageError.parseFailed("invalid quota limit")
        }
        guard let kind = LimitKind(rawValue: type) else { return nil }
        let usage = try optionalInteger(object["usage"], field: "limit.usage")
        let current = try optionalInteger(object["currentValue"], field: "limit.currentValue")
        let remaining = try optionalInteger(object["remaining"], field: "limit.remaining")
        var percent = Double(percentage)
        if let usage, usage > 0 {
            let used: Int?
            if let remaining {
                used = max(usage - remaining, current ?? usage - remaining)
            } else {
                used = current
            }
            if let used {
                percent = Double(max(0, min(usage, used))) / Double(usage) * 100
            }
        }
        percent = max(0, min(100, percent))
        let multiplier = [1: 1440, 3: 60, 5: 1, 6: 10080][unit]
        let windowMinutes = number > 0 ? multiplier.map { number * $0 } : nil
        let resetMillis = try optionalInteger(object["nextResetTime"], field: "limit.nextResetTime")
        let details: [Any]
        if object["usageDetails"] == nil || object["usageDetails"] is NSNull {
            details = []
        } else if let values = object["usageDetails"] as? [Any] {
            details = values
        } else {
            throw ZaiUsageError.parseFailed("usageDetails is not an array")
        }
        return Limit(
            kind: kind,
            unit: unit,
            number: number,
            usage: usage,
            remaining: remaining,
            percent: percent,
            windowMinutes: windowMinutes,
            reset: resetMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            details: details
        )
    }

    private static func usageWindow(
        _ limit: Limit,
        id: String,
        fallbackLabel: String
    ) -> UsageWindow {
        let label: String
        if limit.kind == .time {
            label = "MCP"
        } else if limit.windowMinutes == 300 {
            label = "5-hour"
        } else if limit.windowMinutes == 10080 {
            label = "Weekly"
        } else {
            label = fallbackLabel
        }
        let detail = detailValue(limit)
        return UsageWindow(
            id: id,
            label: label,
            usedFraction: limit.percent / 100,
            resetsAt: limit.reset,
            detail: detail.isEmpty ? nil : detail
        )
    }

    private static func detailValue(_ limit: Limit) -> String {
        var parts: [String] = []
        if let usage = limit.usage { parts.append("\(usage) limit") }
        if let remaining = limit.remaining { parts.append("\(remaining) remaining") }
        return parts.joined(separator: " · ")
    }

    private static func fetchBalance(
        url: URL,
        token: String,
        session: URLSession
    ) async throws -> (value: String, detail: UsageDetail) {
        let balanceRequest = request(url: url, token: token, headers: [:], timeout: balanceTimeout)
        let (data, response) = try await session.data(for: balanceRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let object = root["data"] as? [String: Any]
        else { throw ZaiUsageError.parseFailed("invalid balance response") }
        let available = decimal(object["availableBalance"])
        let current = decimal(object["balance"])
        guard let value = available ?? current else {
            throw ZaiUsageError.parseFailed("missing account balance")
        }
        var secondary: [String] = []
        if let recharged = decimal(object["rechargeAmount"]) {
            secondary.append(String(format: "recharged ¥%.2f", recharged))
        }
        if let granted = decimal(object["giveAmount"]), granted > 0 {
            secondary.append(String(format: "granted ¥%.2f", granted))
        }
        if let spent = decimal(object["totalSpendAmount"]) {
            secondary.append(String(format: "spent ¥%.2f", spent))
        }
        let formatted = String(format: "¥%.2f", value)
        let detailValue = ([formatted] + secondary).joined(separator: " · ")
        return (
            formatted,
            UsageDetail(id: "zai-account-balance", label: "Account balance", value: detailValue)
        )
    }

    private static func requiredData(for request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ZaiUsageError.parseFailed("missing HTTP response")
            }
            guard http.statusCode == 200 else {
                throw ZaiUsageError.requestFailed(http.statusCode, responseMessage(data))
            }
            return data
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            throw ZaiUsageError.network(error.localizedDescription)
        }
    }

    private static func request(
        url: URL,
        token: String,
        headers: [String: String],
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func replacingTypeQuery(in url: URL, value: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "type" }
        items.append(URLQueryItem(name: "type", value: value))
        components.queryItems = items
        return components.url ?? url
    }

    private static func endpointURL(base: String, path: String) -> URL? {
        guard let url = normalizedHTTPSURL(base) else { return nil }
        if url.path.isEmpty || url.path == "/" { return url.appendingPathComponent(path) }
        return url
    }

    private static func normalizedHTTPSURL(_ raw: String) -> URL? {
        let value = cleaned(raw) ?? ""
        let candidate = hasExplicitScheme(value) ? value : "https://\(value)"
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty,
              !host.contains("%"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              !encodedHost.contains("%2f"),
              !encodedHost.contains("%3f"),
              !encodedHost.contains("%23"),
              !encodedHost.contains("%40")
        else { return nil }
        return url
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        if let end = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }), colon > end { return false }
        let after = raw.index(after: colon)
        let portEnd = raw[after...].firstIndex { ["/", "?", "#"].contains($0) } ?? raw.endIndex
        let suffix = raw[after..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0) }
    }

    private static func validateKnownHost(
        _ url: URL,
        region: ZaiUsageRegion,
        key: String
    ) throws {
        let host = url.host?.lowercased()
        let known = [ZaiUsageRegion.global.quotaURL.host?.lowercased(), ZaiUsageRegion.bigModelCN.quotaURL.host?.lowercased()]
        guard known.contains(host) else { return }
        guard host == region.quotaURL.host?.lowercased() else {
            throw ZaiUsageError.endpointRegionMismatch(key, region)
        }
    }

    private static func optionalInteger(_ value: Any?, field: String) throws -> Int? {
        if value == nil || value is NSNull { return nil }
        guard let value = integer(value) else {
            throw ZaiUsageError.parseFailed("\(field) must be an integer")
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int.min), double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }

    private static func decimal(_ value: Any?) -> Double? {
        guard value != nil, !(value is NSNull),
              let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func cleaned(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func formatPercent(_ percent: Double) -> String {
        percent.rounded() == percent ? String(format: "%.0f", percent) : String(format: "%.1f", percent)
    }

    private static func responseMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return cleaned(root["msg"] as? String) ?? cleaned(root["message"] as? String) ?? ""
    }
}
