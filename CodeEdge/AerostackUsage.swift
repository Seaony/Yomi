import CoreFoundation
import Foundation

nonisolated enum AerostackUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidSession
    case permissionDenied
    case rateLimited
    case unavailable
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "请填写 Aerostack 账户 JWT，不能使用 Agent Endpoint Key",
                "Enter an Aerostack account JWT, not an Agent Endpoint key."
            )
        case .invalidSession:
            AppLocalization.text("Aerostack 账户 JWT 已过期或被拒绝，请更换", "The Aerostack account JWT expired or was rejected. Replace it.")
        case .permissionDenied:
            AppLocalization.text("Aerostack 拒绝访问账户用量", "Aerostack denied access to account usage.")
        case .rateLimited:
            AppLocalization.text("Aerostack 用量请求过于频繁", "Aerostack usage requests are rate limited.")
        case .unavailable:
            AppLocalization.text("Aerostack 用量暂时不可用", "Aerostack usage is temporarily unavailable.")
        case let .requestFailed(status):
            AppLocalization.text("Aerostack 请求失败（HTTP \(status)）", "Aerostack request failed (HTTP \(status)).")
        case .invalidResponse:
            AppLocalization.text("无法解析 Aerostack 账户 Token 用量", "Could not parse Aerostack account token usage.")
        }
    }
}

nonisolated enum AerostackUsageFetcher {
    static let usageURL = URL(string: "https://api.aerostack.dev/api/billing/usage")!

    static func fetch(
        token: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let credential = [token, environment["AEROSTACK_TOKEN"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            throw AerostackUsageError.missingCredentials
        }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AerostackUsageError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw AerostackUsageError.invalidSession
        case 403: throw AerostackUsageError.permissionDenied
        case 429: throw AerostackUsageError.rateLimited
        case 500...: throw AerostackUsageError.unavailable
        default: throw AerostackUsageError.requestFailed(http.statusCode)
        }
        return try parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let tokens = usage["ai_tokens"] as? [String: Any] else {
            throw AerostackUsageError.invalidResponse
        }
        let used = try counter(tokens["used"])
        let limit = try counter(tokens["limit"])
        guard used != nil || limit != nil else { throw AerostackUsageError.invalidResponse }
        var details: [UsageDetail] = []
        if let used {
            details.append(UsageDetail(
                id: "aerostack-used",
                label: AppLocalization.text("已用 Token", "Tokens used"),
                value: count(used)
            ))
        }
        if let limit {
            details.append(UsageDetail(
                id: "aerostack-allowance",
                label: AppLocalization.text("额度", "Allowance"),
                value: count(limit)
            ))
        }
        var windows: [UsageWindow] = []
        if let used, let limit {
            details.append(UsageDetail(
                id: "aerostack-remaining",
                label: AppLocalization.text("剩余", "Remaining"),
                value: count(max(0, limit - used))
            ))
            if used > limit {
                details.append(UsageDetail(
                    id: "aerostack-overage",
                    label: AppLocalization.text("超出额度", "Above allowance"),
                    value: count(used - limit)
                ))
            }
            if limit > 0 {
                windows.append(UsageWindow(
                    id: "aerostack-monthly",
                    label: AppLocalization.text("每月 Token", "Monthly tokens"),
                    usedFraction: min(1, used / limit),
                    resetsAt: nil,
                    detail: "\(count(used)) / \(count(limit))"
                ))
            }
        }
        if let period = root["period"], !(period is NSNull) {
            guard let period = period as? String,
                  period.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
                throw AerostackUsageError.invalidResponse
            }
            details.append(UsageDetail(
                id: "aerostack-period",
                label: AppLocalization.text("月份", "Period"),
                value: period
            ))
        }
        var plan: String?
        if let tier = root["tier"], !(tier is NSNull) {
            guard let tier = tier as? String, tier.utf16.count <= 120 else {
                throw AerostackUsageError.invalidResponse
            }
            let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
            plan = trimmed.isEmpty ? nil : trimmed
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "aerostack"),
            state: .ready,
            windows: windows,
            plan: plan,
            details: details,
            updatedAt: now
        )
    }

    private static func counter(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw AerostackUsageError.invalidResponse
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991, value.rounded() == value else {
            throw AerostackUsageError.invalidResponse
        }
        return value
    }

    private static func count(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
