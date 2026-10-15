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
                "未找到 TypeSafe 会话，请登录 console.typesafe.ai/settings/billing 或添加该页面的完整 Cookie 标头",
                "No TypeSafe session was found. Sign in at console.typesafe.ai/settings/billing or add its full Cookie header."
            )
        case .sessionExpired:
            AppLocalization.text("TypeSafe 会话已过期，请重新登录", "The TypeSafe session expired. Sign in again.")
        case .invalidCookie:
            AppLocalization.text("TypeSafe 需要账单页面的完整 Cookie 标头", "TypeSafe needs a full Cookie header from its billing page.")
        case .billingUnavailable:
            AppLocalization.text("TypeSafe 账单请求失败", "The TypeSafe billing request failed.")
        case .parseFailed:
            AppLocalization.text("无法识别 TypeSafe 账单数据", "The TypeSafe billing data could not be read.")
        }
    }
}

nonisolated enum TypeSafeUsageFetcher {
    typealias CacheUpdate = @Sendable (String?) async -> Void

    private static let origin = "https://console.typesafe.ai"
    private static let billingURL = URL(string: origin + "/settings/billing")!
    private static let actionCache = TypeSafeActionCache()

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
        for cookie in automaticCookies() {
            do {
                let usage = try await fetchUsage(cookie: cookie, now: now)
                await cacheUpdate(cookie)
                return usage
            } catch let error as TypeSafeUsageError where error == .sessionExpired {
                lastError = error
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
        let cached = await actionCache.value(now: now)
        var actionID: String
        if let cached {
            actionID = cached
        } else {
            actionID = try await discoverAction(cookie: cookie, session: session)
            await actionCache.store(actionID, now: now)
        }
        var response = try await billingResponse(actionID: actionID, cookie: cookie, session: session)
        if response.1.statusCode == 404,
           response.1.value(forHTTPHeaderField: "x-nextjs-action-not-found") == "1" {
            actionID = try await discoverAction(cookie: cookie, session: session)
            await actionCache.store(actionID, now: now)
            response = try await billingResponse(actionID: actionID, cookie: cookie, session: session)
        }
        try validate(response.1, body: response.0)
        return try parse(response.0, now: now)
    }

    private static func billingResponse(
        actionID: String,
        cookie: String,
        session: URLSession
    ) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: billingURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(actionID, forHTTPHeaderField: "Next-Action")
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("[]".utf8)
        return try await textResponse(request, session: session)
    }

    private static func discoverAction(cookie: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: billingURL)
        request.timeoutInterval = 6
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (html, response) = try await textResponse(request, session: session)
        try validate(response, body: html)
        let scriptPattern = #"<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>"#
        let actionPattern = #""([0-9a-f]{40,})"[^)]{0,150}"getBillingOverviewResult""#
        let scripts = try NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive)
        let action = try NSRegularExpression(pattern: actionPattern, options: .caseInsensitive)
        var seen: Set<URL> = []
        var discoveryFailure: Error?
        for match in scripts.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let url = URL(string: String(html[range]), relativeTo: billingURL)?.absoluteURL,
                  url.scheme == "https", url.host == "console.typesafe.ai", url.port == nil,
                  url.path.lowercased().hasSuffix(".js"), seen.insert(url).inserted
            else { continue }
            if seen.count > 60 { break }
            do {
                var chunkRequest = URLRequest(url: url)
                chunkRequest.timeoutInterval = 2
                let (chunk, chunkResponse) = try await textResponse(chunkRequest, session: session)
                if chunkResponse.statusCode == 429 || chunkResponse.statusCode == 408 || chunkResponse.statusCode >= 500 {
                    try validate(chunkResponse, body: chunk)
                }
                guard (200..<300).contains(chunkResponse.statusCode),
                      let actionMatch = action.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
                      let actionRange = Range(actionMatch.range(at: 1), in: chunk)
                else { continue }
                return String(chunk[actionRange])
            } catch {
                try Task.checkCancellation()
                if discoveryFailure == nil { discoveryFailure = error }
            }
        }
        if let discoveryFailure { throw discoveryFailure }
        throw TypeSafeUsageError.parseFailed
    }

    private static func textResponse(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (String, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let body = String(data: data, encoding: .utf8) else {
            throw TypeSafeUsageError.parseFailed
        }
        return (body, http)
    }

    private static func validate(_ response: HTTPURLResponse, body: String) throws {
        let status = response.statusCode
        if status == 401 || status == 403 || (300..<400).contains(status)
            || body.range(of: #"\\?"\(auth\)\\?",\{\\?"children\\?":\[\\?"login\\?""#, options: .regularExpression) != nil {
            throw TypeSafeUsageError.sessionExpired
        }
        guard (200..<300).contains(status) else { throw UsageCollectionError.requestFailed(status) }
    }

    static func parse(_ body: String, now: Date = Date()) throws -> ProviderUsage {
        var result: [String: Any]?
        for line in body.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  let data = String(line[line.index(after: separator)...]).data(using: .utf8),
                  let candidate = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  candidate["ok"] != nil
            else { continue }
            result = candidate
            break
        }
        guard let result else { throw TypeSafeUsageError.parseFailed }
        guard let ok = result["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue
        else { throw TypeSafeUsageError.billingUnavailable }
        guard let data = result["data"] as? [String: Any],
              let billing = data["billing"] as? [String: Any],
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

    private static func automaticCookies() -> [String] {
        let query = BrowserCookieQuery(domains: ["console.typesafe.ai", "typesafe.ai"], domainMatch: .exact, includeExpired: false)
        let client = BrowserCookieClient()
        var headers: [String] = []
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let records = source.records.enumerated().filter { _, record in
                    let domain = record.domain.lowercased()
                    let hostMatches = record.scope == .hostOnly ? domain == "console.typesafe.ai"
                        : ["console.typesafe.ai", "typesafe.ai"].contains(domain.hasPrefix(".") ? String(domain.dropFirst()) : domain)
                    let path = record.path
                    let target = "/settings/billing"
                    return hostMatches && (target == path || target.hasPrefix(path)
                        && (path.hasSuffix("/") || target.dropFirst(path.count).first == "/"))
                }.sorted {
                    $0.element.path.count == $1.element.path.count ? $0.offset < $1.offset : $0.element.path.count > $1.element.path.count
                }
                let header = records.map { "\($0.element.name)=\($0.element.value)" }.joined(separator: "; ")
                if !header.isEmpty { headers.append(header) }
            }
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

private actor TypeSafeActionCache {
    private var actionID: String?
    private var expiresAt = Date.distantPast

    func value(now: Date) -> String? { expiresAt > now ? actionID : nil }

    func store(_ value: String, now: Date) {
        actionID = value
        expiresAt = now.addingTimeInterval(12 * 60 * 60)
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
