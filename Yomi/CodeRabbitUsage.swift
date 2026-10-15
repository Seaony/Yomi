import Foundation

nonisolated enum CodeRabbitUsageError: LocalizedError, Equatable {
    case cliNotFound
    case notLoggedIn
    case cliFailed(String)
    case timedOut
    case outputTooLarge
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            AppLocalization.text(
                "未找到 CodeRabbit CLI，请安装 coderabbit 或设置 CODERABBIT_CLI_PATH。",
                "CodeRabbit CLI was not found. Install coderabbit or set CODERABBIT_CLI_PATH."
            )
        case .notLoggedIn:
            AppLocalization.text(
                "尚未登录 CodeRabbit，请运行 coderabbit auth login。",
                "Not signed in to CodeRabbit. Run coderabbit auth login."
            )
        case let .cliFailed(message):
            AppLocalization.text("CodeRabbit CLI 执行失败：\(message)", "CodeRabbit CLI failed: \(message)")
        case .timedOut:
            AppLocalization.text("CodeRabbit CLI 请求超时。", "CodeRabbit CLI request timed out.")
        case .outputTooLarge:
            AppLocalization.text("CodeRabbit CLI 输出过长。", "CodeRabbit CLI output was too large.")
        case .parseFailed:
            AppLocalization.text(
                "无法从 CodeRabbit CLI 输出中读取审查次数或计费信息。",
                "Could not read review counts or billing information from CodeRabbit CLI output."
            )
        }
    }
}

nonisolated enum CodeRabbitUsageFetcher {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false
        private var overflowed = false

        func append(_ chunk: Data) {
            lock.withLock {
                if chunk.isEmpty { finished = true }
                guard !overflowed else { return }
                guard data.count + chunk.count <= 128 * 1024 else {
                    overflowed = true
                    return
                }
                data.append(chunk)
            }
        }

        func snapshot() -> (data: Data, finished: Bool, overflowed: Bool) {
            lock.withLock { (data, finished, overflowed) }
        }
    }

    static func fetch(
        configuredBinary: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let binary = resolveBinary(configuredBinary: configuredBinary, environment: environment) else {
            throw CodeRabbitUsageError.cliNotFound
        }
        var launchEnvironment = environment
        launchEnvironment["NO_COLOR"] = "1"
        let output = try await run(binary: binary, environment: launchEnvironment)
        return try parse(output, now: now)
    }

    static func parse(_ output: String, now: Date = Date()) throws -> ProviderUsage {
        let text = output.replacingOccurrences(of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, fields[label] == nil { fields[label] = value }
        }
        let reviews = fields["your reviews"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        guard reviews != nil || fields["usage billing"] != nil || fields["period resets"] != nil else {
            if looksSignedOut(text) { throw CodeRabbitUsageError.notLoggedIn }
            throw CodeRabbitUsageError.parseFailed
        }
        var details: [UsageDetail] = []
        if let reviews {
            details.append(UsageDetail(
                id: "coderabbit-reviews", label: AppLocalization.text("审查次数", "Reviews"), value: "\(reviews)"
            ))
        }
        if let billing = fields["usage billing"] {
            details.append(UsageDetail(
                id: "coderabbit-billing", label: AppLocalization.text("用量计费", "Usage billing"), value: billing
            ))
        }
        if let resets = fields["period resets"] {
            details.append(UsageDetail(
                id: "coderabbit-period-resets", label: AppLocalization.text("周期重置", "Period resets"), value: resets
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "coderabbit"), state: .ready, windows: [],
            plan: fields["plan"], details: details, updatedAt: now
        )
    }

    static func resolveBinary(configuredBinary: String?, environment: [String: String]) -> String? {
        let manager = FileManager.default
        let configured = configuredBinary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = environment["CODERABBIT_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit = [configured, override].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return manager.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/coderabbit" } + [
            "\(NSHomeDirectory())/.local/bin/coderabbit",
            "/opt/homebrew/bin/coderabbit",
            "/usr/local/bin/coderabbit",
        ]
        return candidates.first(where: manager.isExecutableFile)
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "not authenticated", "please log in", "auth login", "authentication required", "unauthorized", "no session found",
        ].contains { lower.contains($0) }
    }

    private static func run(binary: String, environment: [String: String]) async throws -> String {
        let task = Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let capture = Capture()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["usage"]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { capture.append($0.availableData) }
            defer {
                if process.isRunning { process.terminate() }
                output.fileHandleForReading.readabilityHandler = nil
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            }
            do { try process.run() } catch { throw CodeRabbitUsageError.cliFailed(error.localizedDescription) }
            try? output.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning || !capture.snapshot().finished {
                try Task.checkCancellation()
                if capture.snapshot().overflowed { throw CodeRabbitUsageError.outputTooLarge }
                if Date() >= deadline { throw CodeRabbitUsageError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
            process.waitUntilExit()
            let snapshot = capture.snapshot()
            guard !snapshot.overflowed else { throw CodeRabbitUsageError.outputTooLarge }
            let text = String(decoding: snapshot.data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                if looksSignedOut(text) { throw CodeRabbitUsageError.notLoggedIn }
                throw CodeRabbitUsageError.cliFailed(AppLocalization.text(
                    "退出码 \(process.terminationStatus)，请运行 coderabbit usage 查看详情。",
                    "Exit code \(process.terminationStatus). Run coderabbit usage for details."
                ))
            }
            return text
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
