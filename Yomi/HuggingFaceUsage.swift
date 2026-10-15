import Foundation

nonisolated enum HuggingFaceUsageError: LocalizedError {
    case missingCredentials
    case unauthorized
    case billingPermissionRequired
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 Hugging Face 访问令牌。请在设置中添加、设置 HF_TOKEN，或运行 hf auth login。",
                "Missing Hugging Face access token. Add one in Settings, set HF_TOKEN, or run hf auth login."
            )
        case .unauthorized:
            AppLocalization.text("Hugging Face 访问令牌无效或已过期。", "The Hugging Face access token is invalid or expired.")
        case .billingPermissionRequired:
            AppLocalization.text(
                "Hugging Face 令牌无法读取账单。请使用经典 read 令牌，或为细粒度令牌启用 Billing read 权限。",
                "The Hugging Face token cannot read billing. Use a classic read token or enable Billing read on a fine-grained token."
            )
        case let .requestFailed(status):
            AppLocalization.text("Hugging Face 接口返回 HTTP \(status)。", "Hugging Face API returned HTTP \(status).")
        case .invalidResponse:
            AppLocalization.text("无法解析 Hugging Face 用量。", "Could not parse Hugging Face usage.")
        }
    }
}

nonisolated enum HuggingFaceUsageFetcher {
    private static let baseURL = URL(string: "https://huggingface.co")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let token = resolvedAPIKey(configured: configuredAPIKey, environment: environment) else {
            throw HuggingFaceUsageError.missingCredentials
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        var url = URLComponents(url: baseURL.appendingPathComponent("api/settings/billing/usage-v2"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "startDate", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "endDate", value: String(Int(now.timeIntervalSince1970))),
        ]
        let data = try await response(url: url.url!, token: token, session: session, timeout: 15)
        let inference: HuggingFaceBillingResponse.Inference
        do {
            inference = try JSONDecoder().decode(HuggingFaceBillingResponse.self, from: data).usage.inferenceProviders
        } catch {
            throw HuggingFaceUsageError.invalidResponse
        }
        guard validAmount(inference.usedNanoUsd), validAmount(inference.includedNanoUsd),
              inference.limitNanoUsd.map(validAmount) ?? true,
              inference.numRequests.map({ validAmount($0) && $0.rounded() == $0 && $0 <= 9_007_199_254_740_991 }) ?? true else {
            throw HuggingFaceUsageError.invalidResponse
        }
        let gross = inference.usedNanoUsd / 1e9
        let included = inference.includedNanoUsd / 1e9
        let billable = max(0, gross - included)
        let limit = (inference.limitNanoUsd ?? 0) / 1e9
        var details = [UsageDetail(
            id: "huggingface-billable",
            label: AppLocalization.text("计费用量", "Billable usage"),
            value: usd(billable)
        )]
        if included > 0 {
            details.append(UsageDetail(
                id: "huggingface-gross",
                label: AppLocalization.text("推理总用量", "Gross inference usage"),
                value: usd(gross)
            ))
            details.append(UsageDetail(
                id: "huggingface-included",
                label: AppLocalization.text("已含推理金额", "Included inference amount"),
                value: usd(included)
            ))
        }
        if limit > 0 {
            details.append(UsageDetail(
                id: "huggingface-limit",
                label: AppLocalization.text("支出上限", "Spending limit"),
                value: usd(limit)
            ))
        }
        if let requests = inference.numRequests {
            details.append(UsageDetail(
                id: "huggingface-requests",
                label: AppLocalization.text("请求数", "Requests"),
                value: String(format: "%.0f", requests)
            ))
        }
        var windows: [UsageWindow] = []
        if let gpuData = try? await response(
            url: baseURL.appendingPathComponent("api/spaces/zero-gpu/quota"),
            token: token, session: session, timeout: 2
        ), let gpu = try? JSONDecoder().decode(HuggingFaceGPUResponse.self, from: gpuData),
           validAmount(gpu.base), gpu.base > 0, validAmount(gpu.current) {
            let consumed = max(0, gpu.base - gpu.current)
            windows.append(UsageWindow(
                id: "huggingface-zerogpu",
                label: AppLocalization.text("ZeroGPU 额度", "ZeroGPU quota"),
                usedFraction: min(1, consumed / gpu.base),
                resetsAt: gpu.resetsAt?.date,
                detail: "\(minutes(consumed)) / \(minutes(gpu.base))"
            ))
            details.append(UsageDetail(
                id: "huggingface-gpu-used",
                label: AppLocalization.text("已用 GPU 时间", "GPU time used"),
                value: minutes(consumed)
            ))
            details.append(UsageDetail(
                id: "huggingface-gpu-remaining",
                label: AppLocalization.text("剩余 GPU 时间", "GPU time remaining"),
                value: minutes(gpu.current)
            ))
        }
        var plan: String?
        if let profileData = try? await response(
            url: baseURL.appendingPathComponent("api/whoami-v2"),
            token: token, session: session, timeout: 2
        ), let profile = try? JSONDecoder().decode(HuggingFaceProfileResponse.self, from: profileData) {
            plan = profile.isPro.map { $0 ? "PRO" : AppLocalization.text("免费", "Free") }
            if let account = cleaned(profile.name) ?? cleaned(profile.email) {
                details.append(UsageDetail(
                    id: "huggingface-account",
                    label: AppLocalization.text("账号", "Account"),
                    value: account
                ))
            }
        }
        try Task.checkCancellation()
        return ProviderUsage(
            id: ProviderID(rawValue: "huggingface"),
            state: .ready,
            windows: windows,
            plan: plan,
            providerCost: ProviderCostSummary(
                used: billable, limit: limit, currencyCode: "USD",
                period: AppLocalization.text("本月", "This month"), balance: nil
            ),
            details: details,
            updatedAt: now
        )
    }

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        for value in [configured, environment["HF_TOKEN"], environment["HUGGING_FACE_HUB_TOKEN"]] {
            if let token = cleaned(value) { return token }
        }
        func expanded(_ path: String) -> URL {
            if path == "~" { return homeDirectory }
            if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path)
        }
        let tokenURL: URL
        if let path = cleaned(environment["HF_TOKEN_PATH"]) {
            tokenURL = expanded(path)
        } else if let home = cleaned(environment["HF_HOME"]) {
            tokenURL = expanded(home).appendingPathComponent("token")
        } else {
            let cache = cleaned(environment["XDG_CACHE_HOME"]).map(expanded)
                ?? homeDirectory.appendingPathComponent(".cache")
            tokenURL = cache.appendingPathComponent("huggingface/token")
        }
        guard let contents = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        return cleaned(contents.split(whereSeparator: \.isNewline).first.map(String.init))
    }

    private static func response(url: URL, token: String, session: URLSession, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceUsageError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw HuggingFaceUsageError.unauthorized
        case 403: throw HuggingFaceUsageError.billingPermissionRequired
        default: throw HuggingFaceUsageError.requestFailed(http.statusCode)
        }
    }

    private static func validAmount(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
    private static func minutes(_ seconds: Double) -> String {
        let number = String(format: seconds >= 600 ? "%.0f" : "%.1f", seconds / 60)
        return AppLocalization.text("\(number) 分钟", "\(number) min")
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

private nonisolated struct HuggingFaceBillingResponse: Decodable {
    struct Usage: Decodable { let inferenceProviders: Inference }
    struct Inference: Decodable {
        let usedNanoUsd: Double
        let includedNanoUsd: Double
        let limitNanoUsd: Double?
        let numRequests: Double?
    }
    let usage: Usage
}

private nonisolated struct HuggingFaceGPUResponse: Decodable {
    let base: Double
    let current: Double
    let resetsAt: ResetDate?

    struct ResetDate: Decodable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite, seconds > 0, seconds <= 64_092_211_200 {
                date = Date(timeIntervalSince1970: seconds)
            } else if let text = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = formatter.date(from: text) {
                    date = parsed
                } else {
                    formatter.formatOptions = [.withInternetDateTime]
                    date = formatter.date(from: text)
                }
            } else {
                date = nil
            }
        }
    }
}

private nonisolated struct HuggingFaceProfileResponse: Decodable {
    let name: String?
    let email: String?
    let isPro: Bool?
}
