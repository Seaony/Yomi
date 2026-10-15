import Foundation

nonisolated enum V0UsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case permissionDenied
    case apiError(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 v0 API Key，请在 v0.app/settings/keys 创建", "Missing v0 API key. Create one at v0.app/settings/keys.")
        case .unauthorized:
            AppLocalization.text("v0 API Key 无效或已过期", "The v0 API key is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("v0 不允许访问此项目范围", "v0 denied access to this scope")
        case let .apiError(status):
            AppLocalization.text("v0 接口请求失败（HTTP \(status)）", "v0 API request failed (HTTP \(status))")
        case let .invalidResponse(field):
            AppLocalization.text("无法解析 v0 用量：\(field)", "Could not parse v0 usage: \(field)")
        }
    }
}

nonisolated enum V0UsageFetcher {
    private struct Quota {
        let limit: Double
        let remaining: Double?
        let resetsAt: Date?

        var usedFraction: Double? {
            guard let remaining else { return nil }
            guard limit > 0 else { return 1 }
            return min(1, max(0, (limit - remaining) / limit))
        }

        var detail: String {
            if let remaining {
                return AppLocalization.text(
                    "剩余 \(V0UsageFetcher.format(remaining)) / \(V0UsageFetcher.format(limit))",
                    "\(V0UsageFetcher.format(remaining)) remaining of \(V0UsageFetcher.format(limit))"
                )
            }
            return AppLocalization.text(
                "剩余额度未知 · 上限 \(V0UsageFetcher.format(limit))",
                "Remaining unavailable · limit \(V0UsageFetcher.format(limit))"
            )
        }
    }

    static let baseURL = URL(string: "https://api.v0.dev/v1")!
    static let apiKeyEnvironmentKey = "V0_API_KEY"
    static let scopeEnvironmentKey = "V0_SCOPE"

    static func fetch(
        apiKey configured: String?,
        scope configuredScope: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configured) ?? cleaned(environment[apiKeyEnvironmentKey]) else {
            throw V0UsageError.missingCredentials
        }
        let scope = cleaned(configuredScope) ?? cleaned(environment[scopeEnvironmentKey])
        let billing = try await get(path: "user/billing", apiKey: apiKey, scope: scope, session: session)
        let rateLimit = try await get(path: "rate-limits", apiKey: apiKey, scope: scope, session: session)
        return try parse(billing: billing, rateLimit: rateLimit, scope: scope, now: now)
    }

    static func parse(
        billing: Data,
        rateLimit: Data,
        scope: String? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let billingRoot = try jsonObject(billing, field: "billing response")
        guard let billingType = billingRoot["billingType"] as? String,
              ["token", "legacy"].contains(billingType.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw V0UsageError.invalidResponse("billingType")
        }
        let type = billingType.trimmingCharacters(in: .whitespacesAndNewlines)
        let billingData = try object(billingRoot["data"], field: "billing.data")
        let billingQuota: Quota
        var onDemandBalance: Double?
        if type == "token" {
            let balance = try object(billingData["balance"], field: "billing.data.balance")
            let cycle = try object(billingData["billingCycle"], field: "billing.data.billingCycle")
            let total = try number(balance["total"], field: "billing.data.balance.total")
            guard total >= 0 else { throw V0UsageError.invalidResponse("billing.data.balance.total") }
            billingQuota = Quota(
                limit: total,
                remaining: try number(balance["remaining"], field: "billing.data.balance.remaining"),
                resetsAt: try reset(cycle["end"], field: "billing.data.billingCycle.end")
            )
            if let value = billingData["onDemand"], !(value is NSNull) {
                let onDemand = try object(value, field: "billing.data.onDemand")
                onDemandBalance = try number(onDemand["balance"], field: "billing.data.onDemand.balance")
            }
        } else {
            billingQuota = try quota(billingData, field: "billing.data")
        }
        let rateQuota = try quota(jsonObject(rateLimit, field: "rate limit response"), field: "rate limit")
        var windows: [UsageWindow] = []
        if let fraction = billingQuota.usedFraction {
            windows.append(UsageWindow(
                id: "v0-billing", label: AppLocalization.text("计费额度", "Billing"),
                usedFraction: fraction, resetsAt: billingQuota.resetsAt, detail: billingQuota.detail
            ))
        }
        if let fraction = rateQuota.usedFraction {
            windows.append(UsageWindow(
                id: "v0-rate-limit", label: AppLocalization.text("请求额度", "Rate limit"),
                usedFraction: fraction, resetsAt: rateQuota.resetsAt, detail: rateQuota.detail
            ))
        }
        var details = [UsageDetail(
            id: "v0-billing-remaining", label: AppLocalization.text("计费剩余额度", "Billing remaining"), value: billingQuota.detail
        )]
        if let onDemandBalance {
            details.append(UsageDetail(
                id: "v0-on-demand", label: AppLocalization.text("按量余额", "On-demand balance"), value: format(onDemandBalance)
            ))
        }
        details.append(UsageDetail(
            id: "v0-rate-remaining", label: AppLocalization.text("请求剩余额度", "Rate-limit remaining"), value: rateQuota.detail
        ))
        details.append(UsageDetail(
            id: "v0-billing-type", label: AppLocalization.text("计费方式", "Billing type"), value: type
        ))
        if let scope = cleaned(scope) {
            details.append(UsageDetail(
                id: "v0-scope", label: AppLocalization.text("项目范围", "Scope"), value: String(scope.prefix(120))
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "v0"), state: .ready, windows: windows, details: details, updatedAt: now
        )
    }

    private static func get(path: String, apiKey: String, scope: String?, session: URLSession) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let scope { components.queryItems = [URLQueryItem(name: "scope", value: scope)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw V0UsageError.invalidResponse(path) }
        switch http.statusCode {
        case 200: return data
        case 401: throw V0UsageError.unauthorized
        case 403: throw V0UsageError.permissionDenied
        default: throw V0UsageError.apiError(http.statusCode)
        }
    }

    private static func quota(_ payload: [String: Any], field: String) throws -> Quota {
        let limit = try number(payload["limit"], field: "\(field).limit")
        guard limit >= 0 else { throw V0UsageError.invalidResponse("\(field).limit") }
        return Quota(
            limit: limit,
            remaining: try optionalNumber(payload["remaining"], field: "\(field).remaining"),
            resetsAt: try reset(payload["reset"], field: "\(field).reset")
        )
    }

    private static func jsonObject(_ data: Data, field: String) throws -> [String: Any] {
        try object(try? JSONSerialization.jsonObject(with: data), field: field)
    }

    private static func object(_ value: Any?, field: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw V0UsageError.invalidResponse(field) }
        return object
    }

    private static func number(_ value: Any?, field: String) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw V0UsageError.invalidResponse(field)
        }
        return value.doubleValue
    }

    private static func optionalNumber(_ value: Any?, field: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        return try number(value, field: field)
    }

    private static func reset(_ value: Any?, field: String) throws -> Date? {
        guard let timestamp = try optionalNumber(value, field: field), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp >= 1_000_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
