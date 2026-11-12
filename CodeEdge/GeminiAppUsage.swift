import Foundation
import SweetCookieKit

// gemini.google.com/usage 页面上的 5 小时和每周额度，和 Gemini CLI 的额度是两套。
nonisolated enum GeminiAppUsageFetcher {
    enum FetchError: LocalizedError, Equatable {
        case missingSession
        case sessionExpired
        case rateLimited
        case unavailable
        case noWindows
        case requestFailed(Int)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .missingSession:
                AppLocalization.text(
                    "未找到 Gemini 应用的登录会话，请在浏览器登录 gemini.google.com/usage，或填写 Cookie",
                    "No Gemini app session found. Sign in at gemini.google.com/usage or paste its Cookie header."
                )
            case .sessionExpired:
                AppLocalization.text(
                    "Gemini 应用登录已失效，请在 gemini.google.com/usage 重新登录",
                    "Gemini app session expired. Sign in again at gemini.google.com/usage."
                )
            case .rateLimited:
                AppLocalization.text("Gemini 应用用量请求过于频繁", "Gemini app usage is rate limited")
            case .unavailable:
                AppLocalization.text("Gemini 应用用量暂时不可用", "Gemini app usage is temporarily unavailable")
            case .noWindows:
                AppLocalization.text(
                    "当前 Google 账号没有 Gemini 应用额度窗口",
                    "This Google account reports no Gemini app usage windows."
                )
            case let .requestFailed(status):
                AppLocalization.text("Gemini 应用请求失败（HTTP \(status)）", "Gemini app request failed (HTTP \(status))")
            case .parseFailed:
                AppLocalization.text("Gemini 应用用量格式已变化，无法解析", "Gemini app usage response changed")
            }
        }
    }

    private static let domain = "gemini.google.com"
    private static let cookieDomains = ["gemini.google.com", "google.com"]
    // 来自 Gemini 网页 UsagePageQuery 的公开查询签名。
    private static let querySignature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="

    static var usageURL: URL {
        let variables = #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#
        var components = URLComponents(string: "https://\(domain)/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")!
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "query_signature", value: encode(querySignature)),
            URLQueryItem(name: "variables", value: encode(variables)),
        ]
        return components.url!
    }

    static func fetch(manualCookie: String?, session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        let manual = manualCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let headers = manual.isEmpty ? automaticCookieHeaders() : [manual]
        var rejected = false
        for header in headers {
            var request = URLRequest(url: usageURL)
            request.timeoutInterval = 15
            request.setValue(header, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://\(domain)/usage", forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.parseFailed }
            let body = String(decoding: data, as: UTF8.self)
            if http.statusCode == 401 || http.statusCode == 403
                || http.statusCode == 200 && body.drop(while: \.isWhitespace).hasPrefix("<") {
                rejected = true
                continue
            }
            if http.statusCode == 429 { throw FetchError.rateLimited }
            if http.statusCode >= 500 { throw FetchError.unavailable }
            guard http.statusCode == 200 else { throw FetchError.requestFailed(http.statusCode) }
            guard let usage = try parse(body, now: now) else {
                // viewer 为空表示这个会话没登录，换下一个浏览器会话。
                rejected = true
                continue
            }
            return usage
        }
        throw rejected ? FetchError.sessionExpired : FetchError.missingSession
    }

    /// 返回 nil 表示会话未登录。
    static func parse(_ body: String, now: Date = Date()) throws -> ProviderUsage? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let results = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            throw FetchError.parseFailed
        }
        let data = results.compactMap { ($0 as? [String: Any])?["data"] as? [String: Any] }
        guard let result = data.first(where: { $0.keys.contains("viewer") }) else { throw FetchError.parseFailed }
        if result["viewer"] is NSNull { return nil }
        guard let viewer = result["viewer"] as? [String: Any],
              let usage = (viewer["rpcs"] as? [String: Any])?["getUsageInfo"] as? [String: Any],
              let pools = usage["pools"] as? [Any] else { throw FetchError.parseFailed }

        func window(_ type: String, id: String, label: String, minutes: Int) -> UsageWindow? {
            guard let pool = pools.compactMap({ $0 as? [String: Any] }).first(where: { $0["poolType"] as? String == type }),
                  let percent = (pool["percentageUsed"] as? NSNumber)?.doubleValue,
                  percent.isFinite, percent >= 0 else { return nil }
            let rawReset = (pool["gxu"] as? [String: Any])?["windowRefreshesAt"] as? String
            return UsageWindow(
                id: id, label: label, usedFraction: min(1, percent),
                resetsAt: rawReset.flatMap(parseDate), detail: nil, windowMinutes: minutes
            )
        }
        let windows = [
            window("GXU_FIVE_HOURLY", id: "gemini-app-5h", label: "5-hour", minutes: 300),
            window("GXU_WEEKLY", id: "gemini-app-weekly", label: "Weekly", minutes: 10080),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw FetchError.noWindows }
        return ProviderUsage(
            id: ProviderID(rawValue: "gemini"), state: .ready, windows: windows,
            balance: nil, plan: usage["subscriptionTier"] as? String == "TIER1" ? "Pro" : nil,
            details: [], updatedAt: now, message: nil
        )
    }

    private static func automaticCookieHeaders() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: cookieDomains)
        let target = URL(string: "https://\(domain)/")!
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

    private static func parseDate(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
