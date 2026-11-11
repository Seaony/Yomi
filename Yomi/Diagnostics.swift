import Foundation
import os

nonisolated enum DiagnosticCategory: String, CaseIterable, Sendable {
    case refresh
    case provider
    case credentials
    case update
}

nonisolated enum DiagnosticsRedactor {
    static func redact(_ text: String) -> String {
        // 先去掉整段认证头，再处理散落的密钥和账号标识。
        let rules: [(String, String)] = [
            (#"(?im)\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=][^\r\n]*"#, "[认证信息已隐藏]"),
            (#"(?i)\bBearer\s+[^\s,;\"'<>]+"#, "Bearer [已隐藏]"),
            (#"(?i)\bsk-[a-z0-9_-]+"#, "[密钥已隐藏]"),
            (#"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[邮箱已隐藏]"),
            (#"(?i)[\"']?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|token|password|secret|session[_-]?(?:id|key|token)|(?:account|user|org(?:anization)?|customer)[_-]?id)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;}]+)"#, "[敏感字段已隐藏]"),
            (#"(?i)\b(?:account|user|organization|customer)\s+(?:id\s+)?['\"]?[a-z0-9_@.+-]+['\"]?"#, "[账号已隐藏]"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "[标识已隐藏]"),
            (#"https?://[^\s<>\"']+"#, "[网址已隐藏]"),
            (#"\b[A-Za-z0-9_+/=-]{24,}\b"#, "[凭据或标识已隐藏]"),
            (#"\b[0-9]{8,}\b"#, "[标识已隐藏]"),
        ]
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }
}

nonisolated struct DiagnosticsErrorSummary: Equatable, Sendable {
    let kind: String
    let httpStatus: Int?

    init(error: Error) {
        // 只取类型和分支名，不把错误正文或关联的字符串写进日志。
        let resolved = error
        let mirror = Mirror(reflecting: resolved)
        let branch = mirror.displayStyle == .enum ? mirror.children.first : nil
        let branchName = branch?.label.flatMap { label in
            label.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil
                ? label : nil
        }
        let typeName = (String(reflecting: type(of: resolved)).split(separator: ".").last.map(String.init) ?? "Error")
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        kind = DiagnosticsRedactor.redact(typeName + (branchName.map { "." + $0 } ?? ""))
        let extractedStatus: Int?
        if let branch, let branchName,
           ["requestFailed", "apiError", "httpError", "httpStatus", "serverError"].contains(branchName) {
            if let status = branch.value as? Int, (100...599).contains(status) {
                extractedStatus = status
            } else {
                let values = Mirror(reflecting: branch.value).children
                extractedStatus = values.first { child in
                    (child.label == "status" || child.label == "statusCode" || child.label == ".0")
                        && (child.value as? Int).map { (100...599).contains($0) } == true
                }?.value as? Int
            }
        } else {
            extractedStatus = nil
        }
        httpStatus = extractedStatus
    }
}

nonisolated struct ProviderDiagnosticResult: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case success
        case failed
    }

    var providerID: ProviderID
    var source: String
    var date: Date
    var duration: TimeInterval
    var outcome: Outcome
    var errorKind: String? = nil
    var httpStatus: Int? = nil
    var usedCache: Bool = false

    func summary(language: AppLanguage) -> String {
        let copy = AppCopy(language: language)
        let outcomeText = outcome == .success ? copy.text("成功", "Success") : copy.text("失败", "Failed")
        let error = errorKind.map { " · \(DiagnosticsRedactor.redact($0))" } ?? ""
        let status = httpStatus.map { " · HTTP \($0)" } ?? ""
        let cache = usedCache ? copy.text(" · 已回退缓存", " · Using cached data") : ""
        return "\(outcomeText)\(error)\(status)\(cache)"
    }

    fileprivate var logLine: String {
        let error = errorKind.map { " error=\($0)" } ?? ""
        let status = httpStatus.map { " http=\($0)" } ?? ""
        return "provider=\(providerID.rawValue) source=\(source) duration_ms=\(Int(max(0, duration) * 1000)) result=\(outcome.rawValue)\(error)\(status) cache=\(usedCache)"
    }
}

nonisolated final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    let directoryURL: URL
    private let lock = NSLock()
    private let maximumFileBytes: Int
    private let fileCount: Int
    private let systemLoggingEnabled: Bool
    private let loggers: [DiagnosticCategory: Logger]
    private var latestResults: [ProviderID: ProviderDiagnosticResult] = [:]

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Yomi", isDirectory: true),
        maximumFileBytes: Int = 512 * 1024,
        fileCount: Int = 4,
        systemLoggingEnabled: Bool = true
    ) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = max(256, maximumFileBytes)
        self.fileCount = max(1, fileCount)
        self.systemLoggingEnabled = systemLoggingEnabled
        let subsystem = Bundle.main.bundleIdentifier ?? "Yomi"
        loggers = Dictionary(uniqueKeysWithValues: DiagnosticCategory.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        })
    }

    func write(_ message: String, category: DiagnosticCategory, date: Date = Date()) {
        let safe = DiagnosticsRedactor.redact(message)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if systemLoggingEnabled {
            loggers[category]?.info("\(safe, privacy: .public)")
        }
        let timestamp = ISO8601DateFormatter().string(from: date)
        let line = "\(timestamp) [\(category.rawValue)] \(safe)\n"
        // 单条也有上限，异常错误文本不能把整份日志撑大。
        let data = Data((String(decoding: line.utf8.prefix(maximumFileBytes - 1), as: UTF8.self)
            + (line.utf8.count >= maximumFileBytes ? "\n" : "")).utf8.prefix(maximumFileBytes))
        lock.withLock { append(data) }
    }

    func record(_ result: ProviderDiagnosticResult) {
        var safe = result
        safe.source = DiagnosticsRedactor.redact(result.source)
        safe.errorKind = result.errorKind.map(DiagnosticsRedactor.redact)
        lock.withLock { latestResults[result.providerID] = safe }
        write(safe.logLine, category: .provider, date: result.date)
    }

    func latestResult(for providerID: ProviderID) -> ProviderDiagnosticResult? {
        lock.withLock { latestResults[providerID] }
    }

    func report(
        enabledProviders: [ProviderDescriptor],
        bundle: Bundle = .main,
        language: AppLanguage = AppLocalization.currentLanguage
    ) -> String {
        let copy = AppCopy(language: language)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = [
            "Yomi \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            copy.text("已启用的 Provider：", "Enabled providers:"),
        ]
        let results = lock.withLock { latestResults }
        for descriptor in enabledProviders {
            if let result = results[descriptor.id] {
                lines.append("\(ISO8601DateFormatter().string(from: result.date)) \(result.logLine)")
            } else {
                lines.append("provider=\(descriptor.id.rawValue) result=not-refreshed")
            }
        }
        lines.append(copy.text("最近日志：", "Recent logs:"))
        lines.append(recentLogText())
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n"))
    }

    func recentLogText(maximumBytes: Int = 32 * 1024) -> String {
        lock.withLock {
            var data = Data()
            for index in (0..<fileCount).reversed() {
                guard let content = try? Data(contentsOf: fileURL(index)) else { continue }
                data.append(content)
            }
            return DiagnosticsRedactor.redact(String(decoding: data.suffix(max(0, maximumBytes)), as: UTF8.self))
        }
    }

    private func fileURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent(index == 0 ? "yomi.log" : "yomi.\(index).log")
    }

    private func append(_ data: Data) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            let current = fileURL(0)
            let currentSize = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if currentSize + data.count > maximumFileBytes {
                try? manager.removeItem(at: fileURL(fileCount - 1))
                if fileCount > 1 {
                    for index in stride(from: fileCount - 2, through: 0, by: -1) {
                        if manager.fileExists(atPath: fileURL(index).path) {
                            try manager.moveItem(at: fileURL(index), to: fileURL(index + 1))
                        }
                    }
                }
            }
            if !manager.fileExists(atPath: current.path) {
                guard manager.createFile(atPath: current.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else { return }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 日志目录不可写时不影响取数，也不递归记录失败。
        }
    }
}
