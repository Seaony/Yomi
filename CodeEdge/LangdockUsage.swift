import CoreFoundation
import Foundation

nonisolated enum LangdockUsageError: LocalizedError, Equatable {
    case missingCookie
    case invalidSession
    case permissionDenied
    case rateLimited
    case unavailable
    case requestFailed(Int)
    case rejectedRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "请粘贴 Langdock Cookie 标头（需要 auth_token）",
                "Paste a Langdock Cookie header containing auth_token."
            )
        case .invalidSession:
            AppLocalization.text("Langdock 会话已过期，请重新登录", "The Langdock session expired. Sign in again.")
        case .permissionDenied:
            AppLocalization.text("Langdock 拒绝访问个人用量", "Langdock denied access to personal usage.")
        case .rateLimited:
            AppLocalization.text("Langdock 用量请求过于频繁", "Langdock usage requests are rate limited.")
        case .unavailable:
            AppLocalization.text("Langdock 个人用量暂时不可用", "Langdock personal usage is temporarily unavailable.")
        case let .requestFailed(status):
            AppLocalization.text("Langdock 请求失败（HTTP \(status)）", "Langdock request failed (HTTP \(status)).")
        case .rejectedRequest:
            AppLocalization.text("Langdock 拒绝了个人用量请求", "Langdock rejected the personal usage request.")
        case .invalidResponse:
            AppLocalization.text("无法解析 Langdock 个人用量", "Could not parse Langdock personal usage.")
        }
    }
}

nonisolated enum LangdockUsageFetcher {
    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .cookie,
              let cookie = cookieHeader(credential) else {
            throw LangdockUsageError.missingCookie
        }
        var components = URLComponents(string: "https://app.langdock.com/api/trpc/usageSettings.getPersonalUsage")!
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: #"{"0":{"json":null,"meta":{"values":["undefined"],"v":1}}}"#),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://app.langdock.com/settings/account/usage", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LangdockUsageError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw LangdockUsageError.invalidSession
        case 403: throw LangdockUsageError.permissionDenied
        case 429: throw LangdockUsageError.rateLimited
        case 500...: throw LangdockUsageError.unavailable
        default: throw LangdockUsageError.requestFailed(http.statusCode)
        }
        return try parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              root.count == 1,
              let envelope = root.first else { throw LangdockUsageError.invalidResponse }
        if let error = envelope["error"] {
            guard let error = error as? [String: Any],
                  let json = error["json"] as? [String: Any],
                  let data = json["data"] as? [String: Any],
                  let code = data["code"] as? String, !code.isEmpty else {
                throw LangdockUsageError.invalidResponse
            }
            switch code {
            case "UNAUTHORIZED": throw LangdockUsageError.invalidSession
            case "FORBIDDEN": throw LangdockUsageError.permissionDenied
            case "TOO_MANY_REQUESTS": throw LangdockUsageError.rateLimited
            case "INTERNAL_SERVER_ERROR", "TIMEOUT": throw LangdockUsageError.unavailable
            default: throw LangdockUsageError.rejectedRequest
            }
        }
        guard let result = envelope["result"] as? [String: Any],
              let data = result["data"] as? [String: Any],
              let payload = data["json"] as? [String: Any] else {
            throw LangdockUsageError.invalidResponse
        }
        let hasLimits = try payload["hasIncludedUsageLimits"].map { try boolean($0) }
        if hasLimits == false || payload["planUsage"] == nil || payload["planUsage"] is NSNull {
            return ProviderUsage(
                id: ProviderID(rawValue: "langdock"),
                state: .ready,
                windows: [],
                details: [UsageDetail(
                    id: "langdock-included-limits",
                    label: AppLocalization.text("套餐额度", "Included limits"),
                    value: AppLocalization.text("没有可用的套餐额度", "No included usage limits available")
                )],
                updatedAt: now
            )
        }
        guard let plan = payload["planUsage"] as? [String: Any] else {
            throw LangdockUsageError.invalidResponse
        }
        let sessionEnabled = try boolean(plan["sessionUsageLimitsEnabled"])
        let sessionReset = try resetDate(plan["sessionResetsAt"])
        let weeklyReset = try resetDate(plan["weeklyResetsAt"])
        var windows: [UsageWindow] = []
        if sessionEnabled {
            windows.append(UsageWindow(
                id: "langdock-session",
                label: AppLocalization.text("会话", "Session"),
                usedFraction: try percentage(plan["sessionUsagePercent"]) / 100,
                resetsAt: sessionReset,
                detail: nil
            ))
        }
        windows.append(UsageWindow(
            id: "langdock-weekly",
            label: AppLocalization.text("每周", "Weekly"),
            usedFraction: try percentage(plan["weeklyUsagePercent"]) / 100,
            resetsAt: weeklyReset,
            detail: nil
        ))
        return ProviderUsage(id: ProviderID(rawValue: "langdock"), state: .ready, windows: windows, updatedAt: now)
    }

    private static func cookieHeader(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let hasToken = value.split(separator: ";").contains { part in
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return pair.count == 2 && pair[0] == "auth_token" && !pair[1].isEmpty
        }
        return hasToken ? value : nil
    }

    private static func boolean(_ raw: Any?) throws -> Bool {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw LangdockUsageError.invalidResponse
        }
        return number.boolValue
    }

    private static func percentage(_ raw: Any?) throws -> Double {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw LangdockUsageError.invalidResponse
        }
        return max(0, number.doubleValue)
    }

    private static func resetDate(_ raw: Any?) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw LangdockUsageError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw LangdockUsageError.invalidResponse }
        return date
    }
}
