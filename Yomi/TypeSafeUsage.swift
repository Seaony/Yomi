import CoreFoundation
import Foundation
import SweetCookieKit

nonisolated enum TypeSafeUsageError: LocalizedError, Equatable {
    case missingCookie
    case invalidCookie
    case sessionExpired
    case billingUnavailable
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "未找到 TypeSafe 会话，请登录 console.typesafe.ai/billing 或添加 /api/billing/overview 请求的完整 Cookie 标头",
                "No TypeSafe session was found. Sign in at console.typesafe.ai/billing or add the full Cookie header from its /api/billing/overview request."
            )
        case .sessionExpired:
            AppLocalization.text("TypeSafe 会话已过期，请重新登录", "The TypeSafe session expired. Sign in again.")
        case .invalidCookie:
            AppLocalization.text("TypeSafe 需要账单页面的完整 Cookie 标头", "TypeSafe needs a full Cookie header from its billing page.")
        case .billingUnavailable:
            AppLocalization.text(
                "无法读取 TypeSafe 账单概览，请打开 console.typesafe.ai/billing 确认能否访问；能打开就说明接口有变",
                "The TypeSafe billing overview could not be read. Open console.typesafe.ai/billing to check access; if the page opens, the integration needs an update."
            )
        case .parseFailed:
            AppLocalization.text("无法识别 TypeSafe 账单数据", "The TypeSafe billing data could not be read.")
        }
    }
}

nonisolated enum TypeSafeUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    private static let origin = "https://console.typesafe.ai"
    private static let overviewURL = URL(string: origin + "/api/billing/overview")!

    static func fetch(
        credential: String,
        source: ProviderSource,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping CacheUpdate = { _ in },
        allowBrowserImport: Bool = false,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        if !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let cookie = normalizedCookie(credential) else { throw TypeSafeUsageError.invalidCookie }
            return try await fetchUsage(cookie: cookie, now: now)
        }
        guard source == .automatic else { throw TypeSafeUsageError.missingCookie }
        var lastError = TypeSafeUsageError.missingCookie
        if let cookie = normalizedCookie(cachedCookieHeader ?? "") {
            do {
                return try await fetchUsage(cookie: cookie, now: now)
            } catch let error as TypeSafeUsageError where error == .sessionExpired {
                lastError = error
                await cacheUpdate(nil)
            }
        }
        guard allowBrowserImport else { throw lastError }
        // 按浏览器逐个读取，第一个会话验证成功就停，不去碰后面浏览器的钥匙串。
        for browser in Browser.defaultImportOrder {
            for cookie in automaticCookies(in: browser) {
                do {
                    let usage = try await fetchUsage(cookie: cookie, now: now)
                    await cacheUpdate(cookie)
                    return usage
                } catch let error as TypeSafeUsageError where error == .sessionExpired {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private static func fetchUsage(cookie: String, now: Date) async throws -> ProviderUsage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: TypeSafeRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: overviewURL)
        request.timeoutInterval = 10
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await FetchDiagnostics.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else { throw TypeSafeUsageError.parseFailed }
        try validate(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"))
        return try parse(String(decoding: data, as: UTF8.self), now: now)
    }

    static func validate(status: Int, location: String?) throws {
        if status == 401 || status == 403 { throw TypeSafeUsageError.sessionExpired }
        // 只有跳到登录页才算会话失效，账单路由迁移这类跳转按接口异常处理
        if (300..<400).contains(status) {
            throw isLoginRedirect(location) ? TypeSafeUsageError.sessionExpired : TypeSafeUsageError.billingUnavailable
        }
        guard (200..<300).contains(status) else { throw UsageCollectionError.requestFailed(status) }
    }

    private static func isLoginRedirect(_ location: String?) -> Bool {
        guard let target = location?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return false }
        let loginPath = #"(?i)(?:^|[/?#])(?:login|sign-?in|signin|auth|oauth|sso)(?:[/?#]|$)"#
        let matchesLogin = target.range(of: loginPath, options: .regularExpression) != nil
        guard let hostRange = target.range(of: #"(?i)^(?:https?:)?//([^/?#]+)"#, options: .regularExpression) else {
            return matchesLogin
        }
        let host = target[hostRange].lowercased()
            .replacingOccurrences(of: #"^(?:https?:)?//"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        let knownHost = host == "typesafe.ai" || host == "console.typesafe.ai" || host.hasSuffix(".typesafe.ai")
        return !knownHost || matchesLogin
    }

    static func parse(_ body: String, now: Date = Date()) throws -> ProviderUsage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 未登录时控制台可能直接返回 HTML 登录页而不是 JSON
        if trimmed.hasPrefix("<") {
            if trimmed.range(of: #"(?i)(?:login|sign[-\s]?in|\(auth\))"#, options: .regularExpression) != nil {
                throw TypeSafeUsageError.sessionExpired
            }
            throw TypeSafeUsageError.billingUnavailable
        }
        guard let payload = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let billing = payload["billing"] as? [String: Any],
              let spent = number(billing["spent"]), let balance = number(billing["balance"])
        else { throw TypeSafeUsageError.parseFailed }
        let cycle = nonempty(billing["cycleLabel"] as? String)
        let rawPlan = nonempty(billing["plan"] as? String)
        let plan = rawPlan == "free_plan" ? AppLocalization.text("免费", "Free")
            : rawPlan?.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.capitalized }.joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.currentLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        var credits: [UsageDetail] = []
        for credit in billing["credits"] as? [[String: Any]] ?? [] {
            guard let amount = number(credit["amount"]), let remaining = number(credit["remaining"]), remaining > 0,
                  let expiresRaw = credit["expiresAt"] as? String,
                  let expires = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(expiresRaw))
                    ?? (try? Date.ISO8601FormatStyle().parse(expiresRaw))
            else { continue }
            let left = remaining.formatted(.number.precision(.fractionLength(0...2)))
            let total = amount.formatted(.number.precision(.fractionLength(0...2)))
            let date = formatter.string(from: expires)
            credits.append(UsageDetail(
                id: "typesafe-credit-\(credits.count)",
                label: AppLocalization.text("赠送额度", "Credit"),
                value: AppLocalization.text("剩余 \(left) / \(total)，\(date)到期", "\(left) of \(total), expires \(date)")
            ))
        }
        var details = Array(credits.prefix(24))
        if credits.count > 24 {
            details = Array(credits.prefix(23)) + [UsageDetail(
                id: "typesafe-additional-credits",
                label: AppLocalization.text("其他额度", "Additional credits"),
                value: String(credits.count - 23)
            )]
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "typesafe"),
            state: .ready,
            windows: [],
            balance: String(format: balance < 0 ? "-$%.2f" : "$%.2f", abs(balance)),
            plan: plan,
            providerCost: ProviderCostSummary(used: spent, limit: 0, currencyCode: "USD", period: cycle, balance: balance),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func automaticCookies(in browser: Browser) -> [String] {
        let query = BrowserCookieQuery(domains: ["console.typesafe.ai", "typesafe.ai"], domainMatch: .exact, includeExpired: false)
        var headers: [String] = []
        guard let sources = try? BrowserCookieAccess.records(matching: query, in: browser, client: BrowserCookieClient()) else { return [] }
        for source in sources {
            let records = source.records.enumerated().filter { _, record in
                let domain = record.domain.lowercased()
                let hostMatches = record.scope == .hostOnly ? domain == "console.typesafe.ai"
                    : ["console.typesafe.ai", "typesafe.ai"].contains(domain.hasPrefix(".") ? String(domain.dropFirst()) : domain)
                let path = record.path
                let target = "/api/billing/overview"
                return hostMatches && (target == path || target.hasPrefix(path)
                    && (path.hasSuffix("/") || target.dropFirst(path.count).first == "/"))
            }.sorted {
                $0.element.path.count == $1.element.path.count ? $0.offset < $1.offset : $0.element.path.count > $1.element.path.count
            }
            let header = records.map { "\($0.element.name)=\($0.element.value)" }.joined(separator: "; ")
            if !header.isEmpty { headers.append(header) }
        }
        return headers
    }

    private static func normalizedCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.contains("\r"), !value.contains("\n"), value.split(separator: ";").allSatisfy({ $0.contains("=") }) else { return nil }
        return value.isEmpty ? nil : value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private nonisolated final class TypeSafeRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
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
