import CoreFoundation
import Foundation

nonisolated enum ParallelUsageError: LocalizedError, Equatable {
    case missingCookie
    case sessionExpired
    case rateLimited
    case unavailable(Int)
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            AppLocalization.text(
                "请粘贴 platform.parallel.ai 账单请求中的 Cookie 标头",
                "Paste the Cookie header from a platform.parallel.ai billing request."
            )
        case .sessionExpired:
            AppLocalization.text(
                "Parallel 会话已过期，请登录 platform.parallel.ai 并粘贴新的 Cookie 标头",
                "The Parallel session expired. Sign in to platform.parallel.ai and paste a fresh Cookie header."
            )
        case .rateLimited:
            AppLocalization.text("Parallel 账单请求过于频繁", "Parallel billing requests are rate limited.")
        case let .unavailable(status):
            AppLocalization.text("Parallel 暂时不可用（HTTP \(status)）", "Parallel is unavailable (HTTP \(status)).")
        case let .requestFailed(status):
            AppLocalization.text("Parallel 请求失败（HTTP \(status)）", "Parallel request failed (HTTP \(status)).")
        case .invalidResponse:
            AppLocalization.text("无法解析 Parallel 账单数据", "Could not parse Parallel billing data.")
        }
    }
}

nonisolated enum ParallelUsageFetcher {
    static let endpoint = URL(string: "https://platform.parallel.ai/api/rpc/billing/payments/refresh-balance")!

    static func fetch(
        credential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .cookie,
              let cookie = cookieHeader(credential) else {
            throw ParallelUsageError.missingCookie
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://platform.parallel.ai", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let requestSession = URLSession(
            configuration: session.configuration,
            delegate: ParallelRedirectGuard(),
            delegateQueue: nil
        )
        defer { requestSession.finishTasksAndInvalidate() }
        let (data, response) = try await requestSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ParallelUsageError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode)
            || http.statusCode == 200
                && (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html") {
            throw ParallelUsageError.sessionExpired
        }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 429: throw ParallelUsageError.rateLimited
        case 408, 500...599: throw ParallelUsageError.unavailable(http.statusCode)
        default: throw ParallelUsageError.requestFailed(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["kind"] as? String == "ok",
              let payload = root["data"] as? [String: Any],
              let balanceCents = number(payload["balance"]) else {
            throw ParallelUsageError.invalidResponse
        }
        let balance = currency(balanceCents / 100)
        var details = [UsageDetail(
            id: "parallel-balance",
            label: AppLocalization.text("余额", "Balance"),
            value: balance
        )]
        if let pendingCents = number(payload["pendingDebitBalanceCents"]), pendingCents != 0 {
            details.append(UsageDetail(
                id: "parallel-pending-debit",
                label: AppLocalization.text("待扣款", "Pending debit"),
                value: currency(pendingCents / 100)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "parallel"),
            state: .ready,
            windows: [],
            balance: balance,
            details: details,
            updatedAt: now
        )
    }

    private static func cookieHeader(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil,
              value.split(separator: ";").allSatisfy({ part in
                  let pair = part.split(separator: "=", maxSplits: 1).map {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  }
                  return pair.count == 2 && !pair[0].isEmpty && !pair[1].isEmpty
              }) else { return nil }
        return value
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

private nonisolated final class ParallelRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
