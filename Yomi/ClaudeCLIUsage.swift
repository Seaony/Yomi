import Darwin
import Foundation

nonisolated enum ClaudeUsageDataSource: String, Sendable, Equatable {
    case automatic
    case adminAPI
    case oauthAPI
    case webAPI
    case cli
}

nonisolated enum ClaudeUsageSourcePlanner {
    static func explicitSource(
        for source: ProviderSource,
        credential: String
    ) -> ClaudeUsageDataSource? {
        switch source {
        case .automatic:
            nil
        case .account:
            .oauthAPI
        case .token:
            credential.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("sk-ant-admin") ? .adminAPI : .oauthAPI
        case .cookie:
            .webAPI
        case .command:
            .cli
        case .endpoint:
            nil
        }
    }

    static func automaticAppOrder(
        hasOAuthCredentials: Bool,
        hasCLI: Bool,
        hasWebSession: Bool
    ) -> [ClaudeUsageDataSource] {
        [
            hasOAuthCredentials ? .oauthAPI : nil,
            hasCLI ? .cli : nil,
            hasWebSession ? .webAPI : nil,
        ].compactMap { $0 }
    }

    static func explicitOAuthAppOrder(hasCLI: Bool) -> [ClaudeUsageDataSource] {
        hasCLI ? [.oauthAPI, .cli] : [.oauthAPI]
    }
}

nonisolated enum ClaudeCLIUsageError: LocalizedError, Equatable {
    case cliNotFound
    case authenticationFailed(String)
    case commandFailed(String)
    case timedOut
    case parseFailed(String)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            AppLocalization.text(
                "未找到 Claude CLI，请先安装并登录 Claude Code",
                "Claude CLI was not found. Install Claude Code and sign in first."
            )
        case let .authenticationFailed(message):
            message
        case let .commandFailed(message):
            AppLocalization.text("Claude CLI 执行失败：\(message)", "Claude CLI failed: \(message)")
        case .timedOut:
            AppLocalization.text("Claude CLI 用量探测超时", "Claude CLI usage probe timed out")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Claude CLI 用量：\(message)", "Could not parse Claude CLI usage: \(message)")
        case .outputTooLarge:
            AppLocalization.text("Claude CLI 输出超过安全上限", "Claude CLI output exceeded the safe limit")
        }
    }
}

nonisolated struct ClaudeCLIUsageSnapshot: Sendable, Equatable {
    struct ScopedWeekly: Sendable, Equatable {
        let modelName: String
        let percentLeft: Int
        let resetDescription: String?
    }

    let sessionPercentLeft: Int
    let weeklyPercentLeft: Int?
    let sonnetPercentLeft: Int?
    let scopedWeekly: [ScopedWeekly]
    let sessionResetDescription: String?
    let weeklyResetDescription: String?
    let sonnetResetDescription: String?
    let accountEmail: String?
    let organization: String?
    let loginMethod: String?
}

nonisolated enum ClaudeCLIUsageFetcher {
    enum InvocationMode: Sendable, Equatable {
        case pty
        case direct
    }

    typealias Runner = @Sendable (
        _ binary: String,
        _ arguments: [String],
        _ mode: InvocationMode,
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) async throws -> String

    private struct LabelContext {
        let lines: [String]
        let normalizedLines: [String]

        init(_ text: String) {
            lines = text.components(separatedBy: .newlines)
            normalizedLines = lines.map(ClaudeCLIUsageFetcher.normalizeLabel)
        }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func isCancelled() -> Bool { lock.withLock { cancelled } }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var overflowed = false

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                guard !overflowed else { return }
                if data.count + chunk.count > 1_048_576 {
                    overflowed = true
                    return
                }
                data.append(chunk)
            }
        }

        func snapshot() -> (Data, Bool) {
            lock.withLock { (data, overflowed) }
        }
    }

    static let fixedDirectArguments = ["/usage"]

    static func launchArguments(sessionID: UUID) -> [String] {
        ["--allowed-tools", "", "--strict-mcp-config", "--session-id", sessionID.uuidString.lowercased()]
    }

    static func fetch(
        configuredBinary: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        runner: Runner? = nil
    ) async throws -> ProviderUsage {
        guard let binary = resolveBinary(
            configuredBinary: configuredBinary,
            environment: environment,
            homeDirectory: homeDirectory
        ) else {
            throw ClaudeCLIUsageError.cliNotFound
        }
        let launchEnvironment = scrubbedEnvironment(environment)
        let execute = runner ?? run

        let snapshot: ClaudeCLIUsageSnapshot
        do {
            snapshot = try await fetchSnapshot(
                binary: binary,
                environment: launchEnvironment,
                ptyTimeout: 24,
                execute: execute
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard shouldRetry(error) else { throw error }
            snapshot = try await fetchSnapshot(
                binary: binary,
                environment: launchEnvironment,
                ptyTimeout: 60,
                execute: execute
            )
        }
        return providerUsage(snapshot: snapshot, now: now)
    }

    static func fetchSnapshot(
        binary: String,
        environment: [String: String],
        ptyTimeout: TimeInterval,
        execute: Runner
    ) async throws -> ClaudeCLIUsageSnapshot {
        do {
            let output = try await execute(
                binary,
                launchArguments(sessionID: UUID()),
                .pty,
                ptyTimeout,
                environment
            )
            return try parse(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard shouldTryDirect(after: error) else { throw error }
            let directTimeout = min(max(ptyTimeout / 3, 6), 8)
            let output = try await execute(binary, fixedDirectArguments, .direct, directTimeout, environment)
            return try parse(output)
        }
    }

    static func resolveBinary(
        configuredBinary: String?,
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let configured = configuredBinary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return executablePath(configured, environment: environment, fileManager: fileManager)
        }
        if let override = environment["CLAUDE_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        if let path = executablePath("claude", environment: environment, fileManager: fileManager) {
            return path
        }
        let home = homeDirectory.path
        let known = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude",
        ]
        return known.first(where: fileManager.isExecutableFile)
    }

    static func scrubbedEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for key in result.keys where key.hasPrefix("ANTHROPIC_") {
            result.removeValue(forKey: key)
        }
        result["DISABLE_AUTOUPDATER"] = "1"
        result["TERM"] = "xterm-256color"
        return result
    }

    static func parse(_ rawText: String, statusText: String? = nil) throws -> ClaudeCLIUsageSnapshot {
        let clean = stripANSI(rawText)
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCLIUsageError.timedOut
        }
        if let error = terminalError(clean) {
            throw error
        }
        let panel = latestUsagePanel(clean) ?? clean
        if isStillLoading(panel) {
            throw ClaudeCLIUsageError.parseFailed("Claude CLI /usage is still loading usage data.")
        }
        if isSubscriptionNoticeOnly(panel) {
            throw ClaudeCLIUsageError.parseFailed(
                "Claude CLI /usage returned a subscription notice without session quota data."
            )
        }

        let context = LabelContext(panel)
        var sessionLeft = extractPercent(label: "Current session", context: context)
        let weeklyLeft = extractPercent(label: "Current week (all models)", context: context)
        let sonnetLabels = [
            "Current week (Opus)",
            "Current week (Sonnet only)",
            "Current week (Sonnet)",
        ]
        let sonnetLeft = sonnetLabels.lazy.compactMap { extractPercent(label: $0, context: context) }.first

        if sessionLeft == nil, context.normalizedLines.contains(where: { $0.contains("currentsession") }) {
            sessionLeft = allPercents(panel).first
        }
        guard let sessionLeft else {
            throw ClaudeCLIUsageError.parseFailed("Missing Current session.")
        }

        let weeklyModels = Set(context.lines.compactMap(weeklyModelName).map(normalizeLabel))
        let hasWeekly = weeklyModels.contains(where: isAllModels)
        let sonnetModels = Set(sonnetLabels.compactMap(weeklyModelName).map(normalizeLabel))
        let hasSonnet = !weeklyModels.isDisjoint(with: sonnetModels)
        let status = stripANSI(statusText ?? "")
        let identityText = clean + "\n" + status

        return ClaudeCLIUsageSnapshot(
            sessionPercentLeft: sessionLeft,
            weeklyPercentLeft: weeklyLeft,
            sonnetPercentLeft: sonnetLeft,
            scopedWeekly: scopedWeekly(context),
            sessionResetDescription: extractReset(label: "Current session", context: context),
            weeklyResetDescription: hasWeekly
                ? extractReset(label: "Current week (all models)", context: context)
                : nil,
            sonnetResetDescription: hasSonnet
                ? sonnetLabels.lazy.compactMap { extractReset(label: $0, context: context) }.first
                : nil,
            accountEmail: firstMatch(#"(?i)(?:Account|Email):\s+([^\s@]+@[^\s@]+)"#, in: identityText),
            organization: firstMatch(#"(?i)(?:Org|Organization):\s*([^\r\n]+)"#, in: identityText),
            loginMethod: firstMatch(#"(?i)Login\s+method:\s*([^\r\n]+)"#, in: identityText)
        )
    }

    static func providerUsage(snapshot: ClaudeCLIUsageSnapshot, now: Date) -> ProviderUsage {
        func window(
            id: String,
            label: String,
            percentLeft: Int,
            reset: String?,
            expectedWindow: TimeInterval
        ) -> UsageWindow {
            UsageWindow(
                id: id,
                label: label,
                usedFraction: Double(100 - percentLeft) / 100,
                resetsAt: parseResetDate(reset, now: now, expectedWindow: expectedWindow),
                detail: reset
            )
        }

        var windows = [window(
            id: "claude-session",
            label: AppLocalization.text("会话", "Session"),
            percentLeft: snapshot.sessionPercentLeft,
            reset: snapshot.sessionResetDescription,
            expectedWindow: 5 * 60 * 60
        )]
        if let left = snapshot.weeklyPercentLeft {
            windows.append(window(
                id: "claude-weekly",
                label: AppLocalization.text("每周", "Weekly"),
                percentLeft: left,
                reset: snapshot.weeklyResetDescription,
                expectedWindow: 7 * 24 * 60 * 60
            ))
        }
        if let left = snapshot.sonnetPercentLeft {
            windows.append(window(
                id: "claude-sonnet",
                label: "Sonnet",
                percentLeft: left,
                reset: snapshot.sonnetResetDescription,
                expectedWindow: 7 * 24 * 60 * 60
            ))
        }
        let additional = snapshot.scopedWeekly.map { scoped in
            window(
                id: "claude-weekly-scoped-\(slug(scoped.modelName))",
                label: scoped.modelName.lowercased().hasSuffix("only")
                    ? scoped.modelName
                    : "\(scoped.modelName) only",
                percentLeft: scoped.percentLeft,
                reset: scoped.resetDescription ?? snapshot.weeklyResetDescription,
                expectedWindow: 7 * 24 * 60 * 60
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "claude"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            plan: nil,
            details: [],
            updatedAt: now
        )
    }

    private static func executablePath(
        _ value: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        if value.contains("/") {
            return fileManager.isExecutableFile(atPath: value) ? value : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + value
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if case ClaudeCLIUsageError.timedOut = error { return true }
        if case let ClaudeCLIUsageError.parseFailed(message) = error {
            return message.lowercased().contains("still loading")
        }
        return false
    }

    private static func shouldTryDirect(after error: Error) -> Bool {
        if case ClaudeCLIUsageError.timedOut = error { return true }
        if case let ClaudeCLIUsageError.parseFailed(message) = error {
            let lower = message.lowercased()
            return lower.contains("still loading") || lower.contains("could not load usage data")
        }
        return false
    }

    private static func run(
        binary: String,
        arguments: [String],
        mode: InvocationMode,
        timeout: TimeInterval,
        environment: [String: String]
    ) async throws -> String {
        let cancellation = CancellationState()
        let task = Task.detached(priority: .utility) {
            try runSync(
                binary: binary,
                arguments: arguments,
                mode: mode,
                timeout: timeout,
                environment: environment,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runSync(
        binary: String,
        arguments: [String],
        mode: InvocationMode,
        timeout: TimeInterval,
        environment: [String: String],
        cancellation: CancellationState
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let capture = Capture()
        let readHandle: FileHandle
        var inputHandle: FileHandle?

        switch mode {
        case .pty:
            var master: Int32 = -1
            var slave: Int32 = -1
            var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else {
                throw ClaudeCLIUsageError.commandFailed("openpty failed")
            }
            readHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            inputHandle = readHandle
        case .direct:
            let output = Pipe()
            readHandle = output.fileHandleForReading
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
        }
        readHandle.readabilityHandler = { capture.append($0.availableData) }

        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            readHandle.readabilityHandler = nil
            throw ClaudeCLIUsageError.commandFailed(error.localizedDescription)
        }

        if mode == .pty {
            usleep(2_000_000)
            try? inputHandle?.write(contentsOf: Data("/usage\r".utf8))
        }
        let deadline = Date().addingTimeInterval(timeout)
        var completionSeenAt: Date?
        var lastEnterAt = Date()
        while process.isRunning, Date() < deadline {
            if cancellation.isCancelled() {
                terminate(process)
                throw CancellationError()
            }
            let (data, overflowed) = capture.snapshot()
            if overflowed {
                terminate(process)
                throw ClaudeCLIUsageError.outputTooLarge
            }
            if mode == .pty {
                let text = stripANSI(String(decoding: data, as: UTF8.self))
                let normalized = normalizeLabel(text)
                if normalized.contains("doyoutrustthefilesinthisfolder") {
                    try? inputHandle?.write(contentsOf: Data("y\r".utf8))
                } else if normalized.contains("quickcheck")
                    || normalized.contains("readytocodehere")
                    || normalized.contains("pressentertocontinue")
                    || normalized.contains("showplanusagelimits") {
                    try? inputHandle?.write(contentsOf: Data("\r".utf8))
                }
                if usageComplete(text) || normalized.contains("failedtoloadusagedata")
                    || isSubscriptionNoticeOnly(text) {
                    completionSeenAt = completionSeenAt ?? Date()
                    if Date().timeIntervalSince(completionSeenAt!) >= 2 { break }
                }
                if Date().timeIntervalSince(lastEnterAt) >= 0.8 {
                    try? inputHandle?.write(contentsOf: Data("\r".utf8))
                    lastEnterAt = Date()
                }
            }
            usleep(60_000)
        }

        let timedOut = process.isRunning && completionSeenAt == nil
        terminate(process)
        process.waitUntilExit()
        usleep(20_000)
        readHandle.readabilityHandler = nil
        let (data, overflowed) = capture.snapshot()
        try? readHandle.close()
        if overflowed { throw ClaudeCLIUsageError.outputTooLarge }
        if timedOut && data.isEmpty { throw ClaudeCLIUsageError.timedOut }
        let output = String(decoding: data, as: UTF8.self)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ClaudeCLIUsageError.timedOut
        }
        return output
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let group = getpgid(pid)
        if group == pid, group > 0, group != getpgrp() {
            _ = kill(-group, SIGTERM)
        } else {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            if group == pid, group > 0, group != getpgrp() { _ = kill(-group, SIGKILL) }
            _ = kill(pid, SIGKILL)
        }
    }

    private static func usageComplete(_ text: String) -> Bool {
        let context = LabelContext(text)
        return extractPercent(label: "Current session", context: context) != nil
    }

    private static func terminalError(_ text: String) -> ClaudeCLIUsageError? {
        let lower = text.lowercased()
        let compact = normalizeLabel(text)
        if lower.contains("token_expired") || lower.contains("token has expired") {
            return .authenticationFailed("Claude CLI token expired. Run `claude login` to refresh.")
        }
        if lower.contains("authentication_error") || lower.contains("not authenticated")
            || lower.contains("unauthorized") || lower.contains("run /login") {
            return .authenticationFailed("Claude CLI authentication error. Run `claude login`.")
        }
        if lower.contains("rate_limit_error") || lower.contains("rate limited") || compact.contains("ratelimited") {
            return .parseFailed("Claude CLI usage endpoint is rate limited right now. Please try again later.")
        }
        if lower.contains("failed to load usage data") || compact.contains("failedtoloadusagedata") {
            return .parseFailed("Claude CLI could not load usage data. Open the CLI and retry `/usage`.")
        }
        return nil
    }

    private static func isStillLoading(_ text: String) -> Bool {
        let normalized = normalizeLabel(text)
        return normalized.contains("loadingusage") && !usageComplete(text)
    }

    private static func isSubscriptionNoticeOnly(_ text: String) -> Bool {
        let normalized = normalizeLabel(text)
        guard normalized.contains("currentlyusingyoursubscription"),
              normalized.contains("claudecodeusage") else { return false }
        return !normalized.contains("currentsession") && !normalized.contains("currentweek")
    }

    private static func latestUsagePanel(_ text: String) -> String? {
        guard let settings = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else { return nil }
        let tail = String(text[settings.lowerBound...])
        let lower = tail.lowercased()
        guard lower.contains("usage") else { return nil }
        let hasQuota = lower.contains("%")
            && ["used", "left", "remaining", "available"].contains(where: lower.contains)
        return hasQuota || lower.contains("loading usage") ? tail : nil
    }

    private static func extractPercent(label: String, context: LabelContext) -> Int? {
        extractPercent(label: label, context: context, fuzzy: false)
            ?? extractPercent(label: label, context: context, fuzzy: true)
    }

    private static func extractPercent(label: String, context: LabelContext, fuzzy: Bool) -> Int? {
        let normalizedLabel = normalizeLabel(label)
        for index in context.lines.indices where matches(
            line: context.lines[index],
            normalizedLine: context.normalizedLines[index],
            label: label,
            normalizedLabel: normalizedLabel,
            fuzzy: fuzzy
        ) {
            for candidate in context.lines.dropFirst(index).prefix(12) {
                if crossesBoundary(candidate, label: label, normalizedLabel: normalizedLabel, fuzzy: fuzzy) { break }
                if let percent = percentLeft(candidate) { return percent }
            }
        }
        return nil
    }

    private static func extractReset(label: String, context: LabelContext) -> String? {
        extractReset(label: label, context: context, fuzzy: false)
            ?? extractReset(label: label, context: context, fuzzy: true)
    }

    private static func extractReset(label: String, context: LabelContext, fuzzy: Bool) -> String? {
        let normalizedLabel = normalizeLabel(label)
        for index in context.lines.indices where matches(
            line: context.lines[index],
            normalizedLine: context.normalizedLines[index],
            label: label,
            normalizedLabel: normalizedLabel,
            fuzzy: fuzzy
        ) {
            for candidate in context.lines.dropFirst(index).prefix(14) {
                if crossesBoundary(candidate, label: label, normalizedLabel: normalizedLabel, fuzzy: fuzzy) { break }
                if let reset = resetDescription(candidate) { return reset }
            }
        }
        return nil
    }

    private static func scopedWeekly(_ context: LabelContext) -> [ClaudeCLIUsageSnapshot.ScopedWeekly] {
        var result: [ClaudeCLIUsageSnapshot.ScopedWeekly] = []
        var indexByModel: [String: Int] = [:]
        for (index, line) in context.lines.enumerated() {
            guard let model = weeklyModelName(line) else { continue }
            let normalized = normalizeLabel(model)
            guard !normalized.isEmpty, !isAllModels(normalized),
                  normalized != "opus", normalized != "sonnet", normalized != "sonnetonly" else { continue }
            var percent: Int?
            var reset: String?
            for candidate in context.lines.dropFirst(index).prefix(14) {
                if crossesBoundary(candidate, label: line, normalizedLabel: normalizeLabel(line), fuzzy: false) { break }
                percent = percent ?? percentLeft(candidate)
                reset = reset ?? resetDescription(candidate)
            }
            guard let percent else { continue }
            let usage = ClaudeCLIUsageSnapshot.ScopedWeekly(
                modelName: model,
                percentLeft: percent,
                resetDescription: reset
            )
            if let existing = indexByModel[normalized] {
                result[existing] = usage
            } else {
                indexByModel[normalized] = result.count
                result.append(usage)
            }
        }
        return result
    }

    private static func matches(
        line: String,
        normalizedLine: String,
        label: String,
        normalizedLabel: String,
        fuzzy: Bool
    ) -> Bool {
        guard let expected = weeklyModelName(label) else { return normalizedLine.contains(normalizedLabel) }
        guard let actual = weeklyModelName(line) else { return false }
        let expectedNormalized = normalizeLabel(expected)
        let actualNormalized = normalizeLabel(actual)
        if fuzzy, isAllModels(expectedNormalized) { return isAllModels(actualNormalized) }
        return expectedNormalized == actualNormalized
    }

    private static func crossesBoundary(
        _ line: String,
        label: String,
        normalizedLabel: String,
        fuzzy: Bool
    ) -> Bool {
        let normalizedLine = normalizeLabel(line)
        guard normalizedLine.hasPrefix("current") else { return false }
        guard let expected = weeklyModelName(label) else { return !normalizedLine.contains(normalizedLabel) }
        guard let actual = weeklyModelName(line) else { return true }
        let expectedNormalized = normalizeLabel(expected)
        let actualNormalized = normalizeLabel(actual)
        if fuzzy, isAllModels(expectedNormalized) { return !isAllModels(actualNormalized) }
        return expectedNormalized != actualNormalized
    }

    private static func percentLeft(_ line: String) -> Int? {
        if line.contains("|"), ["opus", "sonnet", "haiku", "default"].contains(where: line.lowercased().contains) {
            return nil
        }
        guard let value = firstMatch(#"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#, in: line).flatMap(Double.init)
        else { return nil }
        let clamped = min(max(value, 0), 100)
        let lower = line.lowercased()
        if ["used", "spent", "consumed"].contains(where: lower.contains) {
            return Int((100 - clamped).rounded())
        }
        if ["left", "remaining", "available"].contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return nil
    }

    private static func allPercents(_ text: String) -> [Int] {
        let normalized = normalizeLabel(text)
        guard normalized.contains("currentsession") || normalized.contains("currentweek"),
              ["used", "left", "remaining", "available"].contains(where: normalized.contains)
        else { return [] }
        return text.components(separatedBy: .newlines).compactMap(percentLeft)
    }

    private static func weeklyModelName(_ text: String) -> String? {
        firstMatch(#"(?i)current\s*week\s*\(([^)]+)\)"#, in: text)
    }

    private static func resetDescription(_ line: String) -> String? {
        guard let range = line.range(of: #"(?i)\bresets?\b"#, options: .regularExpression)
            ?? line.range(of: #"\b(?:Reset|Resets)(?=[A-Z0-9])"#, options: .regularExpression)
        else { return nil }
        var result = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        result = result.replacingOccurrences(
            of: #"(?i)\b([A-Za-z]{3}\s+\d{1,2})\s+t\s+(\d)"#,
            with: "$1 at $2",
            options: .regularExpression
        )
        let opens = result.count(where: { $0 == "(" })
        let closes = result.count(where: { $0 == ")" })
        if opens > closes { result.append(")") }
        return result
    }

    static func parseResetDate(
        _ text: String?,
        now: Date,
        expectedWindow: TimeInterval
    ) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        var timezone = TimeZone.current
        if let range = raw.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
            let identifier = String(raw[range]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            if let parsed = TimeZone(identifier: identifier) { timezone = parsed }
            raw.removeSubrange(range)
        }
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        formatter.defaultDate = calendar.startOfDay(for: now)

        for format in ["MMM d, yyyy, h:mma", "MMM d, yyyy, h:mm a", "MMM d, yyyy, HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        let horizon = now.addingTimeInterval(expectedWindow)
        for format in ["MMM d, h:mma", "MMM d, h:mm a", "MMM d h:mma", "MMM d h:mm a", "MMM d, ha", "MMM d ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: raw) else { continue }
            var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components) {
                if date >= now || now.timeIntervalSince(date) <= expectedWindow { return date }
                if let next = calendar.date(byAdding: .year, value: 1, to: date), next <= horizon { return next }
                return date
            }
        }
        for format in ["h:mma", "h:mm a", "HH:mm", "ha", "h a"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: raw) else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.hour = time.hour
            day.minute = time.minute
            day.second = 0
            if let date = calendar.date(from: day) {
                return date >= now ? date : calendar.date(byAdding: .day, value: 1, to: date)
            }
        }
        return nil
    }

    private static func normalizeLabel(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func isAllModels(_ text: String) -> Bool {
        text == "allmodels" || editDistance(text, "allmodels") <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.unicodeScalars)
        let right = Array(rhs.unicodeScalars)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var row = Array(0...right.count)
        for leftIndex in 1...left.count {
            var diagonal = row[0]
            row[0] = leftIndex
            for rightIndex in 1...right.count {
                let deletion = row[rightIndex] + 1
                let insertion = row[rightIndex - 1] + 1
                let substitution = diagonal + (left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1)
                diagonal = row[rightIndex]
                row[rightIndex] = min(deletion, insertion, substitution)
            }
        }
        return row[right.count]
    }

    private static func slug(_ value: String) -> String {
        var result = value.lowercased().replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ) else { return nil }
        let index = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "\r", with: "\n")
    }
}
