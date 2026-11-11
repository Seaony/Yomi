import Foundation

// 每次采集独立记录实际经过的认证方式，不保存请求地址、头或正文。
nonisolated final class FetchDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    @TaskLocal static var current: FetchDiagnostics?
    @TaskLocal static var session: URLSession?
    private let lock = NSLock()
    private var sources: [String] = []
    private var lastStatus: Int?

    func note(_ source: String) {
        lock.withLock {
            if !sources.contains(source) { sources.append(source) }
        }
    }

    var source: String { lock.withLock { sources.isEmpty ? "None" : sources.joined(separator: "+") } }
    var httpStatus: Int? { lock.withLock { lastStatus } }

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
            lock.withLock { lastStatus = http.statusCode }
        }
    }
}
