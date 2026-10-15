import Foundation

nonisolated enum AixyUsageError: LocalizedError {
    case missingCredentials
    case invalidEndpoint
    case unauthorized
    case permissionDenied
    case endpointUnavailable
    case rateLimited
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: AppLocalization.text("缺少 Aixy API Key", "Missing Aixy API key")
        case .invalidEndpoint: AppLocalization.text("Aixy Base URL 无效", "Invalid Aixy base URL")
        case .unauthorized: AppLocalization.text("Aixy API Key 已失效或被撤销", "The Aixy API key has expired or was revoked")
        case .permissionDenied: AppLocalization.text("Aixy 不允许此密钥读取用量", "Aixy denied access to this key's usage")
        case .endpointUnavailable: AppLocalization.text("Aixy 网关不支持用量接口，请检查地址或更新网关", "The Aixy gateway does not provide usage; check its base URL or update the gateway")
        case .rateLimited: AppLocalization.text("Aixy 请求过于频繁", "The Aixy rate limit was exceeded")
        case let .apiError(status): AppLocalization.text("Aixy 请求失败（HTTP \(status)）", "Aixy request failed (HTTP \(status))")
        case .invalidResponse: AppLocalization.text("Aixy 返回的用量或预算数据无效", "Aixy returned invalid usage or budget data")
        }
    }
}

nonisolated enum AixyUsageFetcher {
    private struct Budget {
        let id: String
        let title: String
        let hard: Bool
        let spent: Double?
        let reserved: Double?
        let remaining: Double?
        let limit: Double
        let used: Double?
        let resetsAt: Date?

        var fraction: Double { min(max((used ?? 0) / limit, 0), 1) }
        var window: UsageWindow? {
            guard used != nil, let remaining else { return nil }
            return UsageWindow(
                id: id,
                label: title,
                usedFraction: fraction,
                resetsAt: resetsAt,
                detail: AppLocalization.text("剩余 \(AixyUsageFetcher.usd(remaining))", "\(AixyUsageFetcher.usd(remaining)) remaining")
            )
        }
    }

    static func fetch(
        apiKey configuredKey: String?,
        endpointOverride configuredEndpoint: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredKey) ?? cleaned(environment["AIXY_API_KEY"]) else {
            throw AixyUsageError.missingCredentials
        }
        let raw = cleaned(configuredEndpoint) ?? cleaned(environment["AIXY_BASE_URL"]) ?? "https://api.aixy-gateway.com"
        guard let baseURL = ProviderEndpointValidator.privateNetworkURL(raw), baseURL.query == nil, baseURL.fragment == nil else {
            throw AixyUsageError.invalidEndpoint
        }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
        guard let url = URL(string: root + "/v1/usage") else { throw AixyUsageError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AixyUsageError.apiError(0) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw AixyUsageError.unauthorized
        case 403: throw AixyUsageError.permissionDenied
        case 404: throw AixyUsageError.endpointUnavailable
        case 429: throw AixyUsageError.rateLimited
        default: throw AixyUsageError.apiError(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "key.usage", root["currency"] as? String == "USD",
              let observed = try date(root["as_of"]),
              let rawBudgets = root["budgets"] as? [Any], rawBudgets.count <= 64 else {
            throw AixyUsageError.invalidResponse
        }
        let key = try object(root["key"])
        let keyID = try text(key["id"])
        let projectID = try text(key["project_id"])
        var details = [
            UsageDetail(id: "aixy-key", label: AppLocalization.text("密钥", "Key"), value: String(try text(key["name"] is NSNull ? keyID : key["name"] ?? keyID).prefix(120))),
            UsageDetail(id: "aixy-project", label: AppLocalization.text("项目", "Project"), value: String(try text(key["project_name"] is NSNull ? projectID : key["project_name"] ?? projectID).prefix(120))),
            UsageDetail(id: "aixy-observed", label: AppLocalization.text("数据时间", "Observed"), value: ISO8601DateFormatter().string(from: observed)),
        ]
        var ids = Set<String>()
        let budgets = try rawBudgets.map { raw -> Budget in
            let budget = try object(raw)
            let id = try text(budget["id"])
            guard ids.insert(id).inserted else { throw AixyUsageError.invalidResponse }
            let scope = try text(budget["scope"])
            let interval = try text(budget["interval"])
            let scopes = ["organization": AppLocalization.text("组织", "Organization"), "project": AppLocalization.text("项目", "Project"), "team": AppLocalization.text("团队", "Team"), "user": AppLocalization.text("用户", "User"), "api_key": AppLocalization.text("密钥", "Key")]
            let intervals = ["daily": AppLocalization.text("每日", "Daily"), "weekly": AppLocalization.text("每周", "Weekly"), "monthly": AppLocalization.text("每月", "Monthly"), "lifetime": AppLocalization.text("累计", "Lifetime")]
            guard let scopeLabel = scopes[scope], let intervalLabel = intervals[interval],
                  let enforcement = budget["enforcement"] as? String, ["hard", "monitor"].contains(enforcement),
                  let sharedValue = budget["shared"] as? NSNumber, CFGetTypeID(sharedValue) == CFBooleanGetTypeID(),
                  let limit = try number(budget["limit_usd"]), limit > 0,
                  let appliesTo = budget["applies_to"] as? [Any], !appliesTo.isEmpty else {
                throw AixyUsageError.invalidResponse
            }
            let shared = sharedValue.boolValue
            for item in appliesTo {
                let target = try object(item)
                guard target["api_key_id"] as? String == keyID, target["project_id"] as? String == projectID else {
                    throw AixyUsageError.invalidResponse
                }
            }
            let availability = try object(budget["availability"])
            let availabilityStatus = try text(availability["status"])
            let spendStatus = try text(budget["spend_status"])
            guard ["available", "unavailable", "not_enforced"].contains(availabilityStatus), ["available", "unavailable"].contains(spendStatus) else {
                throw AixyUsageError.invalidResponse
            }
            let hard = enforcement == "hard"
            let known = hard ? availabilityStatus == "available" : spendStatus == "available"
            let spent = try number(hard ? availability["spent_usd"] : budget["spend_usd"])
            let reserved = hard ? try number(availability["reserved_usd"]) : 0
            let remaining = try number(hard ? availability["remaining_usd"] : budget["remaining_usd"])
            if known && (spent == nil || reserved == nil || remaining == nil) { throw AixyUsageError.invalidResponse }
            let used = known ? spent! + reserved! : nil
            if let used, !used.isFinite { throw AixyUsageError.invalidResponse }
            let start = try date(budget["starts_at"])
            let reset = try date(budget["resets_at"])
            if let start, let reset, reset <= start { throw AixyUsageError.invalidResponse }
            let title = "\(scopeLabel) · \(intervalLabel) · \(shared ? AppLocalization.text("共享", "Shared") : AppLocalization.text("个人", "Personal")) · \(hard ? AppLocalization.text("硬限制", "Hard") : AppLocalization.text("监测", "Monitor"))"
            return Budget(id: "aixy-\(id)", title: title, hard: hard, spent: spent, reserved: reserved, remaining: remaining, limit: limit, used: used, resetsAt: reset)
        }.sorted {
            if $0.hard != $1.hard { return $0.hard }
            if ($0.used != nil) != ($1.used != nil) { return $0.used != nil }
            if $0.fraction != $1.fraction { return $0.fraction > $1.fraction }
            return $0.id < $1.id
        }
        for budget in budgets {
            var value = AppLocalization.text("暂不可用", "Unavailable")
            if let remaining = budget.remaining, let spent = budget.spent, budget.used != nil {
                value = AppLocalization.text("剩余 \(usd(remaining)) / \(usd(budget.limit)) · 已花费 \(usd(spent))", "\(usd(remaining)) / \(usd(budget.limit)) remaining · \(usd(spent)) spent")
                if budget.hard, let reserved = budget.reserved {
                    value += AppLocalization.text(" · 预留 \(usd(reserved))", " · \(usd(reserved)) reserved")
                }
            }
            if let reset = budget.resetsAt {
                value += AppLocalization.text(" · 重置 ", " · Resets ") + ISO8601DateFormatter().string(from: reset)
            }
            details.append(UsageDetail(id: budget.id, label: budget.title, value: value))
        }
        var cost: ProviderCostSummary?
        if let rawUsage = root["usage"], !(rawUsage is NSNull) {
            let usage = try object(rawUsage)
            guard usage["window"] as? String == "7d" else { throw AixyUsageError.invalidResponse }
            let requests = try count(usage["requests"])
            let tokens = try count(usage["total_tokens"])
            let attributed = try count(usage["attributed_requests"])
            let partial = try count(usage["partial_requests"])
            let spend = try number(usage["spend_usd"])
            guard attributed <= requests, partial <= attributed, !(spend != nil && spend! > 0 && attributed == 0) else {
                throw AixyUsageError.invalidResponse
            }
            if let spend {
                cost = ProviderCostSummary(used: spend, limit: 0, currencyCode: "USD", period: AppLocalization.text("最近 7 天 · 归属支出（估算）", "Last 7 days · attributed (estimated)"))
            }
            details.append(contentsOf: [
                UsageDetail(id: "aixy-requests", label: AppLocalization.text("最近 7 天请求", "Last 7 days requests"), value: String(requests)),
                UsageDetail(id: "aixy-tokens", label: AppLocalization.text("最近 7 天 Token", "Last 7 days tokens"), value: String(tokens)),
                UsageDetail(id: "aixy-attributed-spend", label: AppLocalization.text("归属支出（估算）", "Attributed spend (estimated)"), value: spend.map(usd) ?? AppLocalization.text("暂不可用", "Unavailable")),
                UsageDetail(id: "aixy-coverage", label: AppLocalization.text("费用覆盖", "Cost coverage"), value: AppLocalization.text("\(attributed) / \(requests) 个请求 · \(partial) 个部分归属", "\(attributed) / \(requests) requests · \(partial) partial")),
            ])
        } else {
            details.append(UsageDetail(id: "aixy-usage", label: AppLocalization.text("最近 7 天用量", "Last 7 days usage"), value: AppLocalization.text("暂不可用", "Unavailable")))
        }
        let windows = budgets.compactMap(\.window)
        return ProviderUsage(id: ProviderID(rawValue: "aixy"), state: .ready, windows: Array(windows.prefix(2)), additionalWindows: Array(windows.dropFirst(2)), providerCost: cost, details: details, updatedAt: now)
    }

    private static func object(_ raw: Any?) throws -> [String: Any] {
        guard let result = raw as? [String: Any] else { throw AixyUsageError.invalidResponse }
        return result
    }

    private static func text(_ raw: Any?) throws -> String {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AixyUsageError.invalidResponse
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        let value: Double?
        if let string = raw as? String {
            guard string.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else { throw AixyUsageError.invalidResponse }
            value = Double(string)
        } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else {
            throw AixyUsageError.invalidResponse
        }
        guard let value, value.isFinite, value >= 0 else { throw AixyUsageError.invalidResponse }
        return value
    }

    private static func count(_ raw: Any?) throws -> Int64 {
        guard let value = try number(raw), value <= 9_007_199_254_740_991, value.rounded(.down) == value else {
            throw AixyUsageError.invalidResponse
        }
        return Int64(value)
    }

    private static func date(_ raw: Any?) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        let value = try text(raw)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let result = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw AixyUsageError.invalidResponse
        }
        return result
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
