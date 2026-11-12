import Foundation

// 每次采集只保留取到用量的来源；请求地址、认证头和正文都不保存。
nonisolated final class FetchDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    @TaskLocal static var current: FetchDiagnostics?
    @TaskLocal static var session: URLSession?
    private let lock = NSLock()
    private var lastObservedSource: String?
    private var lastStrategySource: String?
    private var successfulSource: String?
    private var lastStatus: Int?
    private var rateLimitObservation: ProviderRateLimitObservation?

    func note(_ source: String) {
        lock.withLock { lastObservedSource = Self.safeSource(source) }
    }

    func beginStrategy(_ source: String) {
        lock.withLock {
            lastStrategySource = Self.safeSource(source)
            lastObservedSource = lastStrategySource
            successfulSource = nil
            lastStatus = nil
        }
    }

    func finishSuccess(source: String? = nil) {
        lock.withLock {
            successfulSource = source.map(Self.safeSource)
                ?? successfulSource ?? lastStrategySource ?? lastObservedSource ?? "Local"
        }
    }

    var source: String {
        lock.withLock { successfulSource ?? lastStrategySource ?? lastObservedSource ?? "None" }
    }

    var failureSource: String {
        lock.withLock { lastStrategySource ?? lastObservedSource ?? "None" }
    }

    var httpStatus: Int? { lock.withLock { lastStatus } }
    var rateLimit: ProviderRateLimitObservation? { lock.withLock { rateLimitObservation } }

    static func data(
        for request: URLRequest,
        session: URLSession,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        let trace = current
        let result = try await session.data(for: request, delegate: delegate)
        // 使用原会话和代理，只在解析前补记响应，隔离会话也能保留限流信息。
        trace?.record(request: request, response: result.1)
        return result
    }

    private static func safeSource(_ value: String) -> String {
        ["API", "OAuth", "Cookie", "CLI", "Local API", "Local", "None"].contains(value) ? value : "None"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for transaction in metrics.transactionMetrics {
            record(request: transaction.request, response: transaction.response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let request = task.currentRequest { record(request: request, response: task.response) }
    }

    func record(request: URLRequest, response: URLResponse?) {
        let source: String
        if request.value(forHTTPHeaderField: "Cookie") != nil {
            source = "Cookie"
        } else if let auth = request.value(forHTTPHeaderField: "Authorization"),
                  auth.lowercased().hasPrefix("bearer ") {
            let value = auth.dropFirst(7)
            source = value.hasPrefix("sk-ant-oat") || value.hasPrefix("eyJ")
                || request.url?.path.contains("/wham/") == true ? "OAuth" : "API"
        } else {
            source = "API"
        }
        note(source)
        if let http = response as? HTTPURLResponse {
            lock.withLock {
                lastStatus = http.statusCode
                if http.statusCode == 429, rateLimitObservation?.retryAfter == nil {
                    // 后续可选请求也限流时，保留首次返回的重试时间。
                    rateLimitObservation = ProviderRateLimitObservation(
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    )
                }
            }
        }
    }
}

nonisolated struct ProviderRateLimitObservation: Equatable, Sendable {
    let retryAfter: String?
}
