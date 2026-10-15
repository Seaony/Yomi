import CoreFoundation
import Foundation

nonisolated enum GitKrakenUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidToken
    case invalidOrganization
    case unauthorized
    case permissionDenied
    case rateLimited
    case unavailable
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "请填写 GitKraken 访问令牌，或设置 GITKRAKEN_API_TOKEN。",
                "Set a GitKraken access token or GITKRAKEN_API_TOKEN."
            )
        case .invalidToken:
            AppLocalization.text(
                "GitKraken 令牌格式无效，请只粘贴 Bearer 后面的值。",
                "Invalid GitKraken token. Paste only the value after Bearer."
            )
        case .invalidOrganization:
            AppLocalization.text(
                "GitKraken 组织 ID 无效，请填写不含空白的单个 ID。",
                "Invalid GitKraken organization ID. Enter a single ID without whitespace."
            )
        case .unauthorized:
            AppLocalization.text("GitKraken 访问令牌已过期或被拒绝。", "GitKraken access token expired or was rejected.")
        case .permissionDenied:
            AppLocalization.text("GitKraken 拒绝访问此账号或组织。", "GitKraken denied access to this account or organization.")
        case .rateLimited:
            AppLocalization.text("GitKraken 用量请求过于频繁。", "GitKraken rate limited usage requests.")
        case .unavailable:
            AppLocalization.text("GitKraken 用量服务暂时不可用。", "GitKraken usage is temporarily unavailable.")
        case let .apiError(status):
            AppLocalization.text("GitKraken 请求失败（HTTP \(status)）。", "GitKraken returned HTTP \(status).")
        case .parseFailed:
            AppLocalization.text("无法解析 GitKraken 用量。", "GitKraken returned an unrecognized usage response.")
        }
    }
}

nonisolated enum GitKrakenUsageFetcher {
    private struct Quota {
        let used: Double
        let limit: Double

        var description: String {
            if limit <= 0 {
                let allowance = limit == -1
                    ? AppLocalization.text("不限量", "Unlimited")
                    : AppLocalization.text("无额度", "No allowance")
                return AppLocalization.text(
                    "已用 \(GitKrakenUsageFetcher.amount(used)) 积分 · \(allowance)",
                    "\(GitKrakenUsageFetcher.amount(used)) credits used · \(allowance)"
                )
            }
            return AppLocalization.text(
                "已用 \(GitKrakenUsageFetcher.amount(used)) / \(GitKrakenUsageFetcher.amount(limit)) 积分",
                "\(GitKrakenUsageFetcher.amount(used)) / \(GitKrakenUsageFetcher.amount(limit)) credits used"
            )
        }

        func window(id: String, label: String, resetsAt: Date) -> UsageWindow? {
            guard limit > 0 else { return nil }
            return UsageWindow(
                id: id,
                label: label,
                usedFraction: min(1, used / limit),
                resetsAt: resetsAt,
                detail: description
            )
        }
    }

    static func fetch(
        credential configuredToken: String?,
        source: ProviderSource,
        organization configuredOrganization: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .token,
              let token = cleaned(configuredToken) ?? cleaned(environment["GITKRAKEN_API_TOKEN"]) else {
            throw GitKrakenUsageError.missingCredentials
        }
        guard validHeaderValue(token, maximumLength: 16384) else { throw GitKrakenUsageError.invalidToken }
        let organization = cleaned(configuredOrganization) ?? cleaned(environment["GITKRAKEN_ORG_ID"])
        if let organization, !validHeaderValue(organization, maximumLength: 256) {
            throw GitKrakenUsageError.invalidOrganization
        }
        var request = URLRequest(url: URL(string: "https://api.gitkraken.dev/v1/ai-tasks/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi", forHTTPHeaderField: "Client-Name")
        request.setValue("Yomi", forHTTPHeaderField: "User-Agent")
        request.setValue(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            forHTTPHeaderField: "Client-Version"
        )
        if let organization { request.setValue(organization, forHTTPHeaderField: "gk-org-id") }
        let (data, response) = try await session.data(for: request, delegate: GitKrakenRedirectHandler())
        guard let http = response as? HTTPURLResponse else { throw GitKrakenUsageError.parseFailed }
        switch http.statusCode {
        case 200: break
        case 401: throw GitKrakenUsageError.unauthorized
        case 403: throw GitKrakenUsageError.permissionDenied
        case 429: throw GitKrakenUsageError.rateLimited
        case 500...599: throw GitKrakenUsageError.unavailable
        default: throw GitKrakenUsageError.apiError(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil || root["error"] is NSNull,
              let payload = root["data"] as? [String: Any],
              let personal = quota(payload),
              let rawReset = payload["resetsOn"] as? String,
              let resetsAt = resetDate(rawReset) else {
            throw GitKrakenUsageError.parseFailed
        }
        let pool = quota(payload["organization"])
        var windows: [UsageWindow] = []
        if let window = personal.window(id: "gitkraken-personal", label: "Personal", resetsAt: resetsAt) {
            windows.append(window)
        }
        if let window = pool?.window(id: "gitkraken-shared-pool", label: "Shared pool", resetsAt: resetsAt) {
            windows.append(window)
        }
        var details = [UsageDetail(
            id: "gitkraken-personal",
            label: AppLocalization.text("个人额度", "Personal"),
            value: personal.description
        )]
        if let pool {
            details.append(UsageDetail(
                id: "gitkraken-shared-pool",
                label: AppLocalization.text("共享额度", "Shared pool"),
                value: pool.description
            ))
            if let shared = number(payload["sharedUsed"]), shared >= 0, shared <= pool.used {
                details.append(UsageDetail(
                    id: "gitkraken-shared-used",
                    label: AppLocalization.text("你使用的共享额度", "Your shared usage"),
                    value: AppLocalization.text("\(amount(shared)) 积分", "\(amount(shared)) credits")
                ))
                details.append(UsageDetail(
                    id: "gitkraken-organization-rest",
                    label: AppLocalization.text("组织内其他成员", "Rest of organization"),
                    value: AppLocalization.text("\(amount(pool.used - shared)) 积分", "\(amount(pool.used - shared)) credits")
                ))
            }
        }
        if windows.isEmpty {
            details.append(UsageDetail(
                id: "gitkraken-reset",
                label: AppLocalization.text("重置时间", "Reset"),
                value: resetsAt.formatted(.dateTime.locale(AppLocalization.currentLanguage.locale))
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "gitkraken"),
            state: .ready,
            windows: windows,
            details: details,
            updatedAt: now
        )
    }

    private static func quota(_ value: Any?) -> Quota? {
        guard let object = value as? [String: Any],
              let used = number(object["used"]), used >= 0,
              let limit = number(object["limit"]), limit >= 0 || limit == -1,
              limit <= 0 || (used / limit * 100).isFinite else { return nil }
        return Quota(used: used, limit: limit)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func resetDate(_ value: String) -> Date? {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func validHeaderValue(_ value: String, maximumLength: Int) -> Bool {
        value.utf8.count <= maximumLength && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func amount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLocalization.currentLanguage.locale
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

nonisolated private final class GitKrakenRedirectHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
