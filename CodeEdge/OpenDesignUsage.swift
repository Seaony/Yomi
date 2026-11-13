import Foundation
import SweetCookieKit

nonisolated enum OpenDesignUsageError: LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable
    case apiFailure(Int)
    case usageUnavailable
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingSession, .sessionExpired:
            AppLocalization.text("请先登录 OpenDesign，然后刷新", "Sign in to OpenDesign, then refresh.")
        case .permissionDenied:
            AppLocalization.text("OpenDesign 拒绝读取账单", "OpenDesign billing access was denied.")
        case .rateLimited:
            AppLocalization.text("OpenDesign 请求频率受限，请稍后再试", "OpenDesign rate limit reached. Try again later.")
        case .providerUnavailable:
            AppLocalization.text("OpenDesign 服务暂时不可用，请稍后再试", "OpenDesign is temporarily unavailable. Try again later.")
        case let .apiFailure(status):
            AppLocalization.text("OpenDesign 请求失败（HTTP \(status)）", "OpenDesign request failed (HTTP \(status))")
        case .usageUnavailable:
            AppLocalization.text("当前工作区没有 OpenDesign 订阅用量", "OpenDesign subscription usage is unavailable for this workspace.")
        case .parseFailure:
            AppLocalization.text("OpenDesign 用量格式已变化", "OpenDesign usage response format changed.")
        }
    }
}

nonisolated enum OpenDesignUsageFetcher {
    private static let host = "amr-api.open-design.ai"

    static func fetch(manualCookie: String?, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        let manual = manualCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headers = manual.isEmpty ? automaticCookieHeaders() : [manual]
        var rejected = false
        for header in headers {
            do {
                let workspace = try await get("current", cookie: header, workspace: nil, session: session)
                guard let id = text(workspace["workspaceId"]),
                      id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
                    throw OpenDesignUsageError.parseFailure
                }
                let usage = try await get("\(id)/billing/coding-plan-usage", cookie: header, workspace: id, session: session)
                return try parse(usage: usage, workspace: workspace, workspaceID: id, now: now)
            } catch OpenDesignUsageError.sessionExpired {
                // 这个浏览器会话过期了，换下一个。
                rejected = true
            }
        }
        throw rejected ? OpenDesignUsageError.sessionExpired : OpenDesignUsageError.missingSession
    }

    static func parse(usage: [String: Any], workspace: [String: Any], workspaceID: String, now: Date = Date()) throws -> ProviderUsage {
        guard usage["workspaceId"] as? String == workspaceID,
              let eligible = usage["eligible"] as? Bool,
              let rawWindows = usage["windows"] as? [Any] else { throw OpenDesignUsageError.parseFailure }
        guard eligible else { throw OpenDesignUsageError.usageUnavailable }
        func window(seconds: Int, id: String, label: String) throws -> UsageWindow? {
            let matches = rawWindows.compactMap { $0 as? [String: Any] }
                .filter { ($0["durationSeconds"] as? NSNumber)?.intValue == seconds }
            guard !matches.isEmpty else { return nil }
            guard matches.count == 1, let item = matches.first else { throw OpenDesignUsageError.parseFailure }
            let used = try credits(item["usedCredits"])
            let limit = try credits(item["limitCredits"])
            guard limit > 0 else { throw OpenDesignUsageError.parseFailure }
            return UsageWindow(
                id: id, label: label, usedFraction: min(1, used / limit),
                resetsAt: (item["resetsAt"] as? String).flatMap(parseDate),
                detail: AppLocalization.text(
                    "\(number(used)) / \(number(limit)) Credits", "\(number(used)) / \(number(limit)) credits"
                )
            )
        }
        let windows = [
            try window(seconds: 18_000, id: "opendesign-5h", label: "5-hour"),
            try window(seconds: 604_800, id: "opendesign-weekly", label: "Weekly"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw OpenDesignUsageError.usageUnavailable }
        var details: [UsageDetail] = []
        if let name = text(workspace["workspaceName"]) {
            details.append(UsageDetail(id: "opendesign-workspace", label: AppLocalization.text("工作区", "Workspace"), value: name))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "opendesign"),
            state: .ready,
            windows: windows,
            plan: text(usage["tier"]) ?? text(workspace["personalMembershipTier"]),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func get(
        _ path: String, cookie: String, workspace: String?, session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://\(host)/api/v1/workspaces/\(path)")!)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspace { request.setValue(workspace, forHTTPHeaderField: "X-Vela-Workspace-Id") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenDesignUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 401: throw OpenDesignUsageError.sessionExpired
        case 403: throw OpenDesignUsageError.permissionDenied
        case 429: throw OpenDesignUsageError.rateLimited
        case 408, 500...: throw OpenDesignUsageError.providerUnavailable
        default: throw OpenDesignUsageError.apiFailure(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenDesignUsageError.parseFailure
        }
        return object
    }

    private static func automaticCookieHeaders() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: [host])
        // 按实际请求路径挑 Cookie，Path 限定在接口目录下的会话也能带上。
        let target = URL(string: "https://\(host)/api/v1/workspaces/")!
        var headers: [String] = []
        for browser in Browser.defaultImportOrder {
            guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: client) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if let header = QwenCloudUsageFetcher.cookieHeader(cookies, targetURL: target), !headers.contains(header) {
                    headers.append(header)
                }
            }
        }
        return headers
    }

    private static func credits(_ value: Any?) throws -> Double {
        let amount: Double? = if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            number.doubleValue
        } else if let text = value as? String, text.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            Double(text)
        } else {
            nil
        }
        guard let amount, amount.isFinite, amount >= 0, amount <= 9_007_199_254_740_991 else {
            throw OpenDesignUsageError.parseFailure
        }
        return amount
    }

    private static func parseDate(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }
}
