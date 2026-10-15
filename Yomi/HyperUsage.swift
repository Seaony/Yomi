import Foundation
import SweetCookieKit

nonisolated enum HyperUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCookie
    case expiredSession
    case networkError
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "请登录 hyper.charm.land，或配置 Charm Hyper API Key",
                "Sign in to hyper.charm.land or configure a Charm Hyper API key"
            )
        case .invalidCookie:
            AppLocalization.text(
                "请粘贴 hyper.charm.land 已登录请求的 Cookie 请求头",
                "Paste a Cookie header from a signed-in hyper.charm.land request"
            )
        case .expiredSession:
            AppLocalization.text(
                "Charm Hyper 会话已失效，请重新登录或粘贴新的 Cookie",
                "Charm Hyper session expired. Sign in again or paste a fresh Cookie header"
            )
        case .networkError:
            AppLocalization.text("Charm Hyper 网络请求失败", "Charm Hyper network request failed")
        case let .apiError(status):
            AppLocalization.text(
                "Charm Hyper 接口错误：HTTP \(status)",
                "Charm Hyper API error: HTTP \(status)"
            )
        case .parseFailed:
            AppLocalization.text(
                "无法读取 Charm Hyper 返回的 Hypercredit 余额",
                "Could not read the Hypercredit balance returned by Charm Hyper"
            )
        }
    }
}

nonisolated enum HyperUsageFetcher {
    static let apiKeyEnvironmentKey = "HYPER_API_KEY"
    static let dashboardURL = URL(string: "https://hyper.charm.land/")!
    static let creditsURL = URL(string: "https://hyper.charm.land/v1/credits")!
    private static let teamPattern = #"/teams/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        cachedCookieHeader: String? = nil,
        cacheUpdate: @escaping @Sendable (String?) async -> Void = { _ in },
        allowBrowserImport: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        let guardedSession = URLSession(
            configuration: configuration,
            delegate: HyperRedirectGuard(),
            delegateQueue: nil
        )
        defer { guardedSession.finishTasksAndInvalidate() }

        if source == .cookie {
            guard let cookie = cookieHeader(credential) else { throw HyperUsageError.invalidCookie }
            let balance = try await sessionBalance(cookie: cookie, session: guardedSession)
            return providerUsage(balance: balance, now: now)
        }
        guard source == .automatic || source == .token else {
            throw HyperUsageError.missingCredentials
        }

        let apiKey = cleaned(credential) ?? cleaned(environment[apiKeyEnvironmentKey])
        if source == .automatic {
            var sessionError: HyperUsageError?
            let cachedCookie = cachedCookieHeader.flatMap(cookieHeader)
            if let cachedCookie {
                do {
                    let balance = try await sessionBalance(cookie: cachedCookie, session: guardedSession)
                    return providerUsage(balance: balance, now: now)
                } catch let error as HyperUsageError {
                    switch error {
                    case .expiredSession:
                        await cacheUpdate(nil)
                        sessionError = error
                    case .networkError:
                        sessionError = error
                    default:
                        throw error
                    }
                }
            }
            if allowBrowserImport {
                for cookie in automaticCookieHeaders() where cookie != cachedCookie {
                    do {
                        let balance = try await sessionBalance(cookie: cookie, session: guardedSession)
                        await cacheUpdate(cookie)
                        return providerUsage(balance: balance, now: now)
                    } catch let error as HyperUsageError {
                        switch error {
                        case .expiredSession, .networkError:
                            sessionError = error
                        default:
                            throw error
                        }
                    }
                }
            }
            if apiKey == nil, let sessionError { throw sessionError }
        }
        guard let apiKey else { throw HyperUsageError.missingCredentials }
        let (data, response) = try await request(
            url: creditsURL,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
            timeout: 10,
            session: guardedSession
        )
        guard response.statusCode == 200 else { throw HyperUsageError.apiError(response.statusCode) }
        return providerUsage(balance: try parseAPIBalance(data), now: now)
    }

    static func parseAPIBalance(_ data: Data) throws -> Double {
        struct Response: Decodable { let balance: Double }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.balance.isFinite, response.balance >= 0
        else { throw HyperUsageError.parseFailed }
        return response.balance
    }

    static func parseDashboardBalance(_ html: String) throws -> Double {
        let pattern = #"Hypercredits Available[\s\S]{0,400}?text-5xl font-bold">\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*<"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let balance = Double(html[range].replacingOccurrences(of: ",", with: "")),
              balance.isFinite, balance >= 0
        else { throw HyperUsageError.parseFailed }
        return balance
    }

    private static func sessionBalance(cookie: String, session: URLSession) async throws -> Double {
        let (data, response) = try await request(
            url: dashboardURL,
            headers: ["Cookie": cookie, "Accept": "text/html"],
            timeout: 8,
            session: session
        )
        let html = String(data: data, encoding: .utf8) ?? ""
        let reachedTeam = [response.url?.absoluteString ?? "", html].contains {
            $0.range(of: teamPattern, options: .regularExpression) != nil
        }
        if response.statusCode == 401 || response.statusCode == 403
            || (300..<400).contains(response.statusCode)
            || response.statusCode == 200 && !reachedTeam {
            throw HyperUsageError.expiredSession
        }
        guard response.statusCode == 200 else { throw HyperUsageError.apiError(response.statusCode) }
        return try parseDashboardBalance(html)
    }

    private static func request(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.allHTTPHeaderFields = headers
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HyperUsageError.networkError }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HyperUsageError.networkError
        }
    }

    private static func providerUsage(balance: Double, now: Date) -> ProviderUsage {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let balanceText = "\(formatter.string(from: NSNumber(value: balance)) ?? String(balance)) HC"
        return ProviderUsage(
            id: ProviderID(rawValue: "hyper"),
            state: .ready,
            windows: [],
            balance: balanceText,
            details: [UsageDetail(
                id: "hyper-balance",
                label: AppLocalization.text("余额", "Balance"),
                value: balanceText
            )],
            updatedAt: now,
            message: nil
        )
    }

    private static func automaticCookieHeaders() -> [String] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: ["hyper.charm.land"], domainMatch: .exact, includeExpired: false)
        var headers: [String] = []
        for browser in Browser.defaultImportOrder {
            guard let sources = try? client.records(matching: query, in: browser) else { continue }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard !cookies.isEmpty else { continue }
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !headers.contains(header) { headers.append(header) }
            }
        }
        return headers
    }

    private static func cookieHeader(_ raw: String) -> String? {
        guard var value = cleaned(raw) else { return nil }
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.contains("\r"), !value.contains("\n"), value.contains("=") else { return nil }
        return value
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

private nonisolated final class HyperRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              original.scheme == "https", redirected.scheme == "https",
              original.host?.lowercased() == redirected.host?.lowercased(),
              (original.port ?? 443) == (redirected.port ?? 443)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
