import Foundation
import SweetCookieKit

nonisolated enum TraeCNUsageError: LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case rateLimited
    case providerUnavailable
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingSession, .sessionExpired:
            AppLocalization.text("请在 trae.cn 登录 Trae CN，然后刷新", "Sign in to Trae CN at trae.cn, then refresh.")
        case .rateLimited:
            AppLocalization.text("Trae CN 请求频率受限，请稍后刷新", "Trae CN rate limit reached. Try refreshing later.")
        case .providerUnavailable:
            AppLocalization.text("Trae CN 服务暂时不可用，请稍后刷新", "Trae CN is temporarily unavailable. Try refreshing later.")
        case let .apiFailure(status):
            AppLocalization.text("Trae CN 请求失败（HTTP \(status)）", "Trae CN request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("Trae CN 用量格式已变化", "Trae CN usage response format changed.")
        }
    }
}

nonisolated enum TraeCNUsageFetcher {
    private static let tokenURL = URL(string: "https://api.trae.cn/cloudide/api/v3/common/GetUserToken")!
    private static let usageURL = URL(string: "https://api.trae.cn/trae/api/v2/pay/user_current_entitlement_list")!

    static func fetch(manualCookie: String?, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        let manual = manualCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headers = manual.isEmpty ? automaticCookieHeaders() : [manual]
        var rejected = false
        for cookie in headers {
            guard let tokenData = try await post(tokenURL, cookie: cookie, token: nil, body: [:], session: session) else {
                rejected = true
                continue
            }
            guard let tokenRoot = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                  let token = ((tokenRoot["Result"] as? [String: Any])?["Token"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw TraeCNUsageError.parseFailure
            }
            // 换来的临时令牌只在这次刷新里用，并且只发回 api.trae.cn。
            guard let usageData = try await post(
                usageURL, cookie: cookie, token: token, body: ["require_usage": true, "full_data": true], session: session
            ) else {
                rejected = true
                continue
            }
            guard let usage = try parse(usageData, now: now) else {
                rejected = true
                continue
            }
            return usage
        }
        throw rejected ? TraeCNUsageError.sessionExpired : TraeCNUsageError.missingSession
    }

    /// 返回 nil 表示会话已失效（code 1001）。
    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TraeCNUsageError.parseFailure
        }
        if (root["code"] as? NSNumber)?.intValue == 1001 { return nil }
        let summary = root["usage_summary"] as? [String: Any]
        guard root["is_credits_billing"] as? Bool == true,
              let total = amount(summary?["total_amount"]),
              let used = amount(summary?["consumed_amount"]) else { throw TraeCNUsageError.parseFailure }
        let packs = root["user_entitlement_pack_list"] as? [Any] ?? []
        let subscription = packs.compactMap { $0 as? [String: Any] }.first { pack in
            (pack["group_type"] as? NSNumber)?.intValue == 0
                && (pack["status"] == nil || (pack["status"] as? NSNumber)?.intValue == 1)
        }
        let plan = (subscription?["display_desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = max(0, total - used)
        let hasFraction = [used, total, remaining].contains { $0.rounded() != $0 }
        func format(_ value: Double) -> String {
            value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(hasFraction ? 2...2 : 0...2)))
        }
        // 套餐包的到期时间不等于整体额度的重置时间，所以不显示重置时间。
        return ProviderUsage(
            id: ProviderID(rawValue: "traecn"),
            state: .ready,
            windows: total > 0 ? [UsageWindow(
                id: "traecn-credits", label: "Usage", usedFraction: min(1, used / total), resetsAt: nil, detail: nil
            )] : [],
            plan: plan?.isEmpty == false ? plan : nil,
            details: [
                UsageDetail(id: "traecn-used", label: AppLocalization.text("已用", "Used"), value: format(used)),
                UsageDetail(id: "traecn-total", label: AppLocalization.text("总量", "Total"), value: format(total)),
                UsageDetail(id: "traecn-remaining", label: AppLocalization.text("剩余", "Remaining"), value: format(remaining)),
            ],
            updatedAt: now,
            message: nil
        )
    }

    /// 返回 nil 表示 Cookie 被拒绝（401、403 或跳转）。
    private static func post(
        _ url: URL, cookie: String, token: String?, body: [String: Any], session: URLSession
    ) async throws -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.trae.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://www.trae.cn/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Cloud-IDE-JWT \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 不跟随跳转：过期会话会被重定向到登录页，要当作拒绝并换下一个会话。
        let (data, response) = try await session.data(for: request, delegate: TraeCNRedirectBlocker())
        guard let http = response as? HTTPURLResponse else { throw TraeCNUsageError.parseFailure }
        switch http.statusCode {
        case 200: return data
        case 401, 403, 300..<400: return nil
        case 429: throw TraeCNUsageError.rateLimited
        case 408, 500...: throw TraeCNUsageError.providerUnavailable
        default: throw TraeCNUsageError.apiFailure(http.statusCode)
        }
    }

    private static func automaticCookieHeaders() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["trae.cn", "api.trae.cn"])
        let target = URL(string: "https://api.trae.cn/")!
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

    private static func amount(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}

private nonisolated final class TraeCNRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
