import Foundation
import SweetCookieKit

nonisolated enum ReplicateUsageError: LocalizedError, Equatable {
    case missingSession
    case invalidCookie
    case sessionExpired
    case requestFailed(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .missingSession:
            AppLocalization.text(
                "未找到 Replicate 浏览器会话，请登录 replicate.com/account/billing 或填写 Cookie",
                "No Replicate browser session was found. Sign in to replicate.com/account/billing or enter a Cookie header."
            )
        case .invalidCookie:
            AppLocalization.text(
                "Replicate 需要包含非空 sessionid 的 Cookie，API Token 不能用于读取网站账单",
                "Replicate needs a Cookie header with a nonempty sessionid. API tokens cannot read website billing."
            )
        case .sessionExpired:
            AppLocalization.text("Replicate 会话无效或已过期，请重新登录", "The Replicate session is invalid or expired. Sign in again.")
        case let .requestFailed(status):
            AppLocalization.text("Replicate 账单请求失败（HTTP \(status)）", "Replicate billing request failed (HTTP \(status))")
        case .unreadableResponse:
            AppLocalization.text("无法解析 Replicate 账单数据", "Could not parse Replicate billing data.")
        }
    }
}

nonisolated enum ReplicateUsageFetcher {
    struct Account: Sendable, Equatable {
        let kind: String
        let username: String
    }

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        allowBrowserImport: Bool = false,
        now: Date = Date(),
        cacheUpdate: @escaping @Sendable (String?) async -> Void = { _ in }
    ) async throws -> ProviderUsage {
        let isAutomatic = credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (source == .automatic || source == .account)
        let candidates: [String]
        if !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let cookie = normalizedCookie(credential) else { throw ReplicateUsageError.invalidCookie }
            candidates = [cookie]
        } else if isAutomatic {
            candidates = cachedCookieHeader.flatMap(normalizedCookie).map { [$0] } ?? []
        } else {
            throw ReplicateUsageError.missingSession
        }
        guard !candidates.isEmpty || isAutomatic && allowBrowserImport else { throw ReplicateUsageError.missingSession }

        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let guardedSession = URLSession(configuration: configuration, delegate: ReplicateRedirectGuard(), delegateQueue: nil)
        defer { guardedSession.invalidateAndCancel() }
        var sawExpiredSession = false
        for cookie in candidates {
            do {
                return try await fetchBilling(cookie: cookie, session: guardedSession, now: now)
            } catch ReplicateUsageError.sessionExpired {
                try Task.checkCancellation()
                guard isAutomatic else { throw ReplicateUsageError.sessionExpired }
                sawExpiredSession = true
                await cacheUpdate(nil)
            }
        }
        if isAutomatic && allowBrowserImport {
            for cookie in automaticCookies() where !candidates.contains(cookie) {
                do {
                    let usage = try await fetchBilling(cookie: cookie, session: guardedSession, now: now)
                    try Task.checkCancellation()
                    await cacheUpdate(cookie)
                    return usage
                } catch ReplicateUsageError.sessionExpired {
                    try Task.checkCancellation()
                    sawExpiredSession = true
                }
            }
        }
        throw sawExpiredSession ? ReplicateUsageError.sessionExpired : ReplicateUsageError.missingSession
    }

    static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.contains("\r"), !value.contains("\n") else { return nil }
        let pairs = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard pairs.contains(where: { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "sessionid"
                && !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return pairs.joined(separator: "; ")
    }

    private static func fetchBilling(cookie: String, session: URLSession, now: Date) async throws -> ProviderUsage {
        let page = try await response(
            url: URL(string: "https://replicate.com/account/billing")!,
            cookie: cookie,
            accept: "text/html",
            session: session
        )
        guard let html = String(data: page, encoding: .utf8) else { throw ReplicateUsageError.unreadableResponse }
        let account = try parseAccount(html)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let username = account.username.addingPercentEncoding(withAllowedCharacters: allowed),
              let base = URL(string: "https://replicate.com/api/\(account.kind == "organization" ? "organizations" : "users")/\(username)")
        else { throw ReplicateUsageError.unreadableResponse }
        let invoices = try await response(url: base.appendingPathComponent("invoices"), cookie: cookie, session: session)
        let spent = try parseSpend(invoices, now: now)
        var balance: Double?
        do {
            let credit = try await response(
                url: base.appendingPathComponent("unused-credit"), cookie: cookie, timeout: 2, session: session
            )
            if let object = try? JSONSerialization.jsonObject(with: credit) as? [String: Any] {
                balance = money(object["unused_credit"])
            }
        } catch {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        var details = [UsageDetail(
            id: "replicate-spend",
            label: AppLocalization.text("本月花费", "Spent this month"),
            value: String(format: "$%.2f", spent)
        )]
        if let balance {
            details.append(UsageDetail(
                id: "replicate-credit", label: AppLocalization.text("预付余额", "Credit balance"),
                value: String(format: "$%.2f", balance)
            ))
        }
        details.append(UsageDetail(
            id: "replicate-account",
            label: account.kind == "organization" ? AppLocalization.text("组织", "Organization") : AppLocalization.text("账号", "Account"),
            value: account.username
        ))
        return ProviderUsage(
            id: ProviderID(rawValue: "replicate"), state: .ready, windows: [],
            balance: balance.map { String(format: "$%.2f", $0) },
            providerCost: ProviderCostSummary(
                used: spent, limit: 0, currencyCode: "USD",
                period: AppLocalization.text("本月", "This month"), balance: balance
            ),
            details: details, updatedAt: now, message: nil
        )
    }

    static func parseAccount(_ html: String) throws -> Account {
        let scripts = try NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>", options: [.caseInsensitive])
        var visited = 0
        for match in scripts.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let attributesRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let attributes = String(html[attributesRange])
            guard attributes.range(of: #"\bid\s*=\s*(["'])react-component-props[^"']*\1"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  attributes.range(of: #"\btype\s*=\s*(["'])application/json\1"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let root = try? JSONSerialization.jsonObject(with: Data(html[bodyRange].utf8)) else { continue }
            var queue: [Any] = [root]
            var index = 0
            while index < queue.count && visited < 4000 {
                let value = queue[index]
                index += 1
                visited += 1
                if let object = value as? [String: Any] {
                    if let account = object["account"] as? [String: Any],
                       let kind = account["kind"] as? String, kind == "user" || kind == "organization",
                       let rawUsername = account["username"] as? String {
                        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !username.isEmpty { return Account(kind: kind, username: username) }
                    }
                    let children = object.values.filter { $0 is [String: Any] || $0 is [Any] }
                    queue.append(contentsOf: children.prefix(max(0, 4000 - queue.count)))
                } else if let array = value as? [Any] {
                    let children = array.filter { $0 is [String: Any] || $0 is [Any] }
                    queue.append(contentsOf: children.prefix(max(0, 4000 - queue.count)))
                }
            }
        }
        if html.range(of: #"<title>\s*Sign in\s*\|\s*Replicate\s*</title>"#, options: [.regularExpression, .caseInsensitive]) != nil,
           html.range(of: #"<a\b[^>]*\bhref=["']/login/github/(?:\?[^"']*)?["']"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ReplicateUsageError.sessionExpired
        }
        throw ReplicateUsageError.unreadableResponse
    }

    static func parseSpend(_ data: Data, now: Date) throws -> Double {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let invoices = object["invoices"] as? [Any] else { throw ReplicateUsageError.unreadableResponse }
        for case let invoice as [String: Any] in invoices where invoice["type"] as? String == "monthly-usage" {
            if let end = invoice["ended_before"], !(end is NSNull) {
                guard let raw = end as? String, let date = invoiceDate(raw), date > now else { continue }
            }
            guard let spent = money(invoice["total_cost_before_adjustments"]) else {
                throw ReplicateUsageError.unreadableResponse
            }
            return spent
        }
        throw ReplicateUsageError.unreadableResponse
    }

    private static func money(_ raw: Any?) -> Double? {
        guard let string = raw as? String,
              string.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func invoiceDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: raw) { return date }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.date(from: raw)
    }

    private static func response(
        url: URL, cookie: String, accept: String = "application/json", timeout: TimeInterval = 8, session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReplicateUsageError.unreadableResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ReplicateUsageError.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw ReplicateUsageError.requestFailed(http.statusCode) }
        return data
    }

    private static func automaticCookies() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["replicate.com"], domainMatch: .exact, includeExpired: false)
        var candidates: [String] = []
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if let cookie = normalizedCookie(header), !candidates.contains(cookie) { candidates.append(cookie) }
            }
        }
        return candidates
    }
}

private nonisolated final class ReplicateRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              redirected.scheme == "https", original.host == redirected.host,
              (original.port ?? 443) == (redirected.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
