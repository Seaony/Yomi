import Foundation

nonisolated enum RaycastUsageError: LocalizedError, Equatable {
    case missingSession
    case expiredSession
    case permissionDenied
    case rateLimited
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "缺少 Raycast 网站会话，请粘贴 www.raycast.com/settings 请求中的 Cookie，必须包含 __raycast_session。",
                "Missing Raycast website session. Paste the Cookie header from a www.raycast.com/settings request, including __raycast_session."
            )
        case .expiredSession:
            AppLocalization.text("Raycast 网站会话已过期，请重新登录并更新 Cookie。", "Raycast website session expired. Sign in again and update the Cookie header.")
        case .permissionDenied:
            AppLocalization.text("Raycast 不允许此账号读取积分。", "Raycast denied access to credits for this account.")
        case .rateLimited:
            AppLocalization.text("Raycast 积分请求过于频繁，请稍后刷新。", "Raycast credit requests are rate limited. Refresh later.")
        case let .apiError(status):
            AppLocalization.text("Raycast 积分请求失败（HTTP \(status)）", "Raycast credits request failed (HTTP \(status))")
        case let .parseFailed(field):
            AppLocalization.text("无法解析 Raycast 积分：\(field)", "Could not parse Raycast credits: \(field)")
        }
    }
}

nonisolated enum RaycastUsageFetcher {
    static let creditsURL = URL(string: "https://www.raycast.com/frontend_api/current_user/ai_credits")!

    static func fetch(
        credential: String?,
        source: ProviderSource,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let configured = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCookie = configured?.isEmpty == false ? configured : environment["RAYCAST_COOKIE"]
        guard source == .automatic || source == .cookie,
              let cookie = cookieHeader(rawCookie) else {
            throw RaycastUsageError.missingSession
        }
        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.raycast.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.raycast.com/settings", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        switch response.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw RaycastUsageError.expiredSession
        case 403: throw RaycastUsageError.permissionDenied
        case 429: throw RaycastUsageError.rateLimited
        default: throw RaycastUsageError.apiError(response.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RaycastUsageError.parseFailed("JSON")
        }
        let remaining = try amount(root["remaining_balance_credits"], field: "remaining_balance_credits")
        let total = try amount(root["total_balance_credits"], field: "total_balance_credits")
        guard remaining != nil || total != nil else {
            throw RaycastUsageError.parseFailed("remaining_balance_credits / total_balance_credits")
        }
        var renewal: Date?
        if let raw = root["next_credits_at"], !(raw is NSNull) {
            guard let raw = raw as? String, let date = date(raw) else {
                throw RaycastUsageError.parseFailed("next_credits_at")
            }
            renewal = date
        }
        var plan: String?
        if let raw = root["funding_subscription"], !(raw is NSNull) {
            guard let funding = raw as? [String: Any] else {
                throw RaycastUsageError.parseFailed("funding_subscription")
            }
            let tier = (funding["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            plan = switch tier {
            case "pro": "Pro"
            case "pro_plus": "Pro+"
            case "max": "Max"
            case "", nil: nil
            default: tier
            }
        }
        var windows: [UsageWindow] = []
        var details: [UsageDetail] = []
        if let remaining, let total, total > 0 {
            windows.append(UsageWindow(
                id: "raycast-credits",
                label: AppLocalization.text("积分", "Credits"),
                usedFraction: max(0, total - remaining) / total,
                resetsAt: renewal,
                detail: AppLocalization.text(
                    "剩余 \(formatted(remaining)) / \(formatted(total)) 积分",
                    "\(formatted(remaining)) / \(formatted(total)) credits left"
                )
            ))
        } else {
            if let remaining {
                details.append(UsageDetail(id: "raycast-left", label: AppLocalization.text("剩余积分", "Credits left"), value: formatted(remaining)))
            }
            if let total {
                details.append(UsageDetail(id: "raycast-total", label: AppLocalization.text("总积分", "Total credits"), value: formatted(total)))
            }
            if let renewal {
                details.append(UsageDetail(
                    id: "raycast-renewal",
                    label: AppLocalization.text("续期", "Renews"),
                    value: renewal.formatted(date: .abbreviated, time: .shortened)
                ))
            }
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "raycast"),
            state: .ready,
            windows: windows,
            plan: plan,
            details: details,
            updatedAt: now
        )
    }

    static func cookieHeader(_ raw: String?) -> String? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("cookie:") {
            raw = String(raw.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("__raycast_session=") || $0.hasPrefix("csrf_token=") }
        guard pairs.contains(where: {
            $0.hasPrefix("__raycast_session=")
                && !$0.dropFirst("__raycast_session=".count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return pairs.joined(separator: "; ")
    }

    private static func amount(_ raw: Any?, field: String) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        let value: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else if let text = raw as? String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = text.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil
                ? Double(text) : nil
        } else {
            value = nil
        }
        guard let value, value.isFinite, value >= 0 else { throw RaycastUsageError.parseFailed(field) }
        return value
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...2)))
    }
}
