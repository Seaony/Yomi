import Foundation

nonisolated enum BifrostUsageError: LocalizedError {
    case missingCredentials
    case missingBaseURL
    case invalidBaseURL
    case apiError(Int)
    case inactiveKey
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Bifrost 虚拟 Key", "Missing Bifrost virtual key")
        case .missingBaseURL:
            AppLocalization.text("缺少 Bifrost Base URL", "Missing Bifrost base URL")
        case .invalidBaseURL:
            AppLocalization.text(
                "Bifrost Base URL 无效。仅允许 HTTPS，或私有网络地址使用 HTTP，且不能包含认证信息。",
                "Invalid Bifrost base URL. Use HTTPS, or HTTP for private-network addresses, without credentials."
            )
        case let .apiError(status):
            AppLocalization.text("Bifrost 接口请求失败（HTTP \(status)）", "Bifrost API returned HTTP \(status)")
        case .inactiveKey:
            AppLocalization.text("Bifrost 虚拟 Key 已停用，且没有预算或限流信息", "Bifrost virtual key is inactive and has no budgets or rate limits")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Bifrost 用量：\(message)", "Failed to parse Bifrost usage: \(message)")
        }
    }
}

nonisolated enum BifrostUsageFetcher {
    private struct Scope: Decodable {
        let virtualKeyName: String?
        let isActive: Bool?
        let provider: String?
        let modelName: String?
        let budgets: [Budget]?
        let rateLimits: [RateLimit]?
        let rateLimit: RateLimit?
        let providerConfigs: [Scope]?
        let modelConfigs: [Scope]?
    }

    private struct Budget: Decodable {
        let id: String?
        let sourceName: String?
        let maxLimit: Double?
        let currentUsage: Double?
        let overrideAmount: Double?
        let overrideMode: String?
        let overrideCyclesRemaining: Double?
        let resetDuration: String?
        let lastReset: String?
        let perModelUsage: [ModelUsage]?
    }

    private struct RateLimit: Decodable {
        let sourceName: String?
        let tokenMaxLimit: Double?
        let tokenCurrentUsage: Double?
        let tokenResetDuration: String?
        let tokenLastReset: String?
        let requestMaxLimit: Double?
        let requestCurrentUsage: Double?
        let requestResetDuration: String?
        let requestLastReset: String?
    }

    private struct ModelUsage: Decodable {
        let model: String?
        let provider: String?
        let totalCost: Double?
        let totalTokens: Double?
    }

    private struct BudgetUsage {
        let id: String
        let scopeID: String
        let title: String
        let budget: Budget
        let used: Double
        let limit: Double
        let timing: Timing

        var window: UsageWindow {
            UsageWindow(
                id: id,
                label: title,
                usedFraction: min(max(used / limit, 0), 1),
                resetsAt: timing.resetsAt,
                detail: [timing.label, "\(usd(used)) / \(usd(limit))"].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }

    private struct Timing {
        let seconds: Double?
        let label: String?
        let resetsAt: Date?
    }

    static func fetch(
        apiKey configuredKey: String?,
        endpointOverride configuredBaseURL: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let key = cleaned(configuredKey) ?? cleaned(environment["BIFROST_API_KEY"]) else {
            throw BifrostUsageError.missingCredentials
        }
        guard let rawBaseURL = cleaned(configuredBaseURL) ?? cleaned(environment["BIFROST_BASE_URL"]) else {
            throw BifrostUsageError.missingBaseURL
        }
        guard let baseURL = ProviderEndpointValidator.privateNetworkURL(rawBaseURL) else {
            throw BifrostUsageError.invalidBaseURL
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/governance/virtual-keys/quota"))
        request.setValue(key, forHTTPHeaderField: "x-bf-vk")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BifrostUsageError.apiError(0) }
        guard (200..<300).contains(response.statusCode) else { throw BifrostUsageError.apiError(response.statusCode) }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let root: Scope
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            root = try decoder.decode(Scope.self, from: data)
        } catch {
            throw BifrostUsageError.parseFailed(error.localizedDescription)
        }
        var scopes: [(id: String, title: String?, body: Scope)] = [("", nil, root)]
        scopes += (root.providerConfigs ?? []).enumerated().map { index, scope in
            ("provider-\(index)-", AppLocalization.text("服务商", "Provider") + " \(cleaned(scope.provider) ?? String(index + 1))", scope)
        }
        scopes += (root.modelConfigs ?? []).enumerated().map { index, scope in
            ("model-\(index)-", AppLocalization.text("模型", "Model") + " " + [cleaned(scope.provider), cleaned(scope.modelName) ?? String(index + 1)].compactMap { $0 }.joined(separator: " · "), scope)
        }
        var budgets: [BudgetUsage] = []
        for scope in scopes {
            for budget in scope.body.budgets ?? [] {
                guard let id = cleaned(budget.id) else { continue }
                let amount = budget.overrideAmount ?? 0
                let cycles = budget.overrideCyclesRemaining ?? 0
                guard cycles.rounded() == cycles else {
                    throw BifrostUsageError.parseFailed(AppLocalization.text("追加预算周期无效", "Invalid override cycles"))
                }
                let active = amount > 0 && (budget.overrideMode == "forever" || budget.overrideMode == "cycles" && cycles > 0)
                let limit = (budget.maxLimit ?? 0) + (active ? amount : 0)
                guard limit.isFinite else {
                    throw BifrostUsageError.parseFailed(AppLocalization.text("预算上限无效", "Invalid budget limit"))
                }
                budgets.append(BudgetUsage(
                    id: "bifrost-\(scope.id)budget-\(id)",
                    scopeID: scope.id,
                    title: [scope.title, cleaned(budget.sourceName) ?? AppLocalization.text("预算", "Budget")].compactMap { $0 }.joined(separator: " · "),
                    budget: budget,
                    used: budget.currentUsage ?? 0,
                    limit: limit,
                    timing: timing(budget.resetDuration, lastReset: budget.lastReset, now: now)
                ))
            }
        }
        budgets.sort {
            let first = $0.timing.seconds ?? .infinity
            let second = $1.timing.seconds ?? .infinity
            return first == second ? ($0.budget.id ?? "") < ($1.budget.id ?? "") : first < second
        }
        let keyWindows = budgets.filter { $0.scopeID.isEmpty && $0.limit > 0 }.map(\.window)
        var additionalWindows = Array(keyWindows.dropFirst(2)) + budgets.filter { !$0.scopeID.isEmpty && $0.limit > 0 }.map(\.window)
        var details: [UsageDetail] = []
        var hasRateLimits = false
        for scope in scopes {
            let components = scope.body.rateLimits ?? []
            let limits = components.isEmpty ? scope.body.rateLimit.map { [$0] } ?? [] : components
            hasRateLimits = hasRateLimits || !limits.isEmpty
            for (index, limit) in limits.enumerated() {
                let dimensions = [
                    ("tokens", AppLocalization.text("Token", "Tokens"), limit.tokenMaxLimit, limit.tokenCurrentUsage, limit.tokenResetDuration, limit.tokenLastReset),
                    ("requests", AppLocalization.text("请求", "Requests"), limit.requestMaxLimit, limit.requestCurrentUsage, limit.requestResetDuration, limit.requestLastReset),
                ]
                for (dimension, name, maximum, current, reset, lastReset) in dimensions {
                    let known = (maximum ?? 0) > 0
                    guard known || cleaned(reset) != nil else { continue }
                    let id = "bifrost-\(scope.id)\(dimension)-\(index)"
                    let title = [scope.title, cleaned(limit.sourceName), name].compactMap { $0 }.joined(separator: " ")
                    let time = timing(reset, lastReset: lastReset, now: now)
                    if let maximum, known {
                        additionalWindows.append(UsageWindow(
                            id: id,
                            label: title,
                            usedFraction: min(max((current ?? 0) / maximum, 0), 1),
                            resetsAt: time.resetsAt,
                            detail: time.label
                        ))
                    } else {
                        details.append(UsageDetail(
                            id: id,
                            label: title,
                            value: [AppLocalization.text("不可用", "Unavailable"), time.label, time.resetsAt?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
                        ))
                    }
                }
            }
        }
        if root.isActive == false {
            guard !budgets.isEmpty || hasRateLimits else { throw BifrostUsageError.inactiveKey }
            details.insert(UsageDetail(id: "bifrost-key-inactive", label: AppLocalization.text("虚拟 Key", "Virtual key"), value: AppLocalization.text("已停用", "Inactive")), at: 0)
        }
        let first = budgets.first { $0.scopeID.isEmpty }
        if let name = cleaned(root.virtualKeyName) {
            details.append(UsageDetail(id: "bifrost-key-name", label: AppLocalization.text("虚拟 Key", "Virtual key"), value: name))
        }
        if budgets.count > 1 || budgets.contains(where: { !$0.scopeID.isEmpty }) {
            details += budgets.prefix(24).map { budget in
                UsageDetail(id: "\(budget.id)-detail", label: budget.title, value: budget.limit > 0 ? "\(usd(budget.used)) / \(usd(budget.limit))" : usd(budget.used))
            }
        }
        let models = (first?.budget.perModelUsage ?? []).filter { ($0.totalCost ?? 0) != 0 || ($0.totalTokens ?? 0) != 0 }.sorted {
            if ($0.totalCost ?? 0) != ($1.totalCost ?? 0) { return ($0.totalCost ?? 0) > ($1.totalCost ?? 0) }
            if ($0.totalTokens ?? 0) != ($1.totalTokens ?? 0) { return ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) }
            return ($0.model ?? "") < ($1.model ?? "")
        }
        let visibleModels = Array(models.prefix(5))
        let modelNames = visibleModels.map { modelName(cleaned($0.model) ?? AppLocalization.text("模型", "Model")) }
        let mixedProviders = Set(visibleModels.compactMap { cleaned($0.provider) }).count > 1
        for (index, model) in visibleModels.enumerated() {
            let cost = model.totalCost.map(usd) ?? "—"
            let tokens = model.totalTokens.map { AppLocalization.text("\($0.formatted(.number.precision(.fractionLength(0)))) Token", "\($0.formatted(.number.precision(.fractionLength(0)))) tokens") }
            let duplicateName = modelNames.filter { $0 == modelNames[index] }.count > 1
            let name = duplicateName ? model.model ?? modelNames[index] : modelNames[index]
            details.append(UsageDetail(
                id: "bifrost-model-\(index)",
                label: [mixedProviders ? cleaned(model.provider) : nil, name].compactMap { $0 }.joined(separator: " · "),
                value: [cost, tokens].compactMap { $0 }.joined(separator: " · ")
            ))
        }
        if models.count > 5 {
            details.append(UsageDetail(id: "bifrost-other-models", label: AppLocalization.text("其他模型", "Other models"), value: String(models.count - 5)))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "bifrost"),
            state: .ready,
            windows: Array(keyWindows.prefix(2)),
            additionalWindows: additionalWindows,
            providerCost: first.map {
                ProviderCostSummary(used: $0.used, limit: max(0, $0.limit), currencyCode: "USD", period: $0.timing.label ?? ($0.limit > 0 ? AppLocalization.text("预算", "Budget") : AppLocalization.text("花费", "Spend")))
            },
            details: details,
            updatedAt: now
        )
    }

    private static func timing(_ raw: String?, lastReset: String?, now: Date) -> Timing {
        let raw = cleaned(raw) ?? ""
        let seconds = duration(raw)
        let labels = [
            "1h": AppLocalization.text("每小时", "Hourly"), "1d": AppLocalization.text("每日", "Daily"),
            "1w": AppLocalization.text("每周", "Weekly"), "1M": AppLocalization.text("每月", "Monthly"),
            "1Q": AppLocalization.text("每季度", "Quarterly"), "1Y": AppLocalization.text("每年", "Yearly"),
        ]
        var reset: Date?
        if !raw.isEmpty, !"dwMQY".contains(raw.last!), let seconds, let lastReset {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let start = formatter.date(from: lastReset) ?? ISO8601DateFormatter().date(from: lastReset) {
                reset = start.addingTimeInterval((max(0, floor(now.timeIntervalSince(start) / seconds)) + 1) * seconds)
            }
        }
        return Timing(seconds: seconds, label: labels[raw], resetsAt: reset)
    }

    private static func duration(_ raw: String) -> Double? {
        let units: [String: Double] = ["Y": 31536000, "Q": 7776000, "M": 2592000, "w": 604800, "d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 0.001, "us": 0.000001, "µs": 0.000001, "μs": 0.000001, "ns": 0.000000001]
        let extended = raw.range(of: "^\\d+(?:\\.\\d+)?[dwMQY]$", options: .regularExpression) != nil
        let pattern = extended ? "(\\d+(?:\\.\\d+)?)([dwMQY])" : "(\\d+(?:\\.\\d*)?|\\.\\d+)(ns|us|µs|μs|ms|s|m|h)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard !matches.isEmpty, matches.reduce(0, { $0 + $1.range.length }) == raw.utf16.count else { return nil }
        var seconds = 0.0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: raw), let unitRange = Range(match.range(at: 2), in: raw),
                  let amount = Double(raw[numberRange]), let unit = units[String(raw[unitRange])] else { return nil }
            seconds += amount * unit
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    private static func modelName(_ raw: String) -> String {
        var name = raw
        for pattern in ["(?i)^(us-gov|us|eu|apac|global)\\.", "(?i)^(ai21|amazon|anthropic|cohere|deepseek|luma|meta|mistral|openai|qwen|stability|twelvelabs|writer)\\.", "-v\\d+:\\d+$", "(?:-|\\s)(?:\\d{8}|\\d{4}-\\d{2}-\\d{2})$", "[ \\t-]+$"] {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return name.isEmpty ? raw : name
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2, value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'" {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
