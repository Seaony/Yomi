import Foundation

nonisolated struct PiSessionUsageEntry: Sendable, Equatable {
    let entryID: String?
    let timestamp: Date
    /// Pi 记录的后端名称（小写），例如 openai-codex、anthropic、amazon-bedrock。
    let backend: String
    let model: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cacheWrite1hTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    /// 只有分项加起来等于总数时才能按分项计价。
    var countsMatchTotal: Bool {
        totalTokens == inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens
    }
}

nonisolated struct PiSessionFileUsage: Sendable, Equatable {
    let sessionID: String?
    let entries: [PiSessionUsageEntry]
}

// 读取 Pi / OMP 编码代理在本机保存的会话日志，逻辑对齐 CodexBar 的 PiSessionCostScanner。
nonisolated enum PiSessionUsageReader {
    static func sessionRoots(homeDirectory: URL, environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let directory = path(environment["PI_CODING_AGENT_SESSION_DIR"], home: homeDirectory) {
            roots.append(directory)
        } else if let agent = path(environment["PI_CODING_AGENT_DIR"], home: homeDirectory) {
            roots.append(agent.appending(path: "sessions", directoryHint: .isDirectory))
        } else {
            let agent = homeDirectory.appending(path: ".pi/agent", directoryHint: .isDirectory)
            let configured = (try? Data(contentsOf: agent.appending(path: "settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { path($0["sessionDir"] as? String, home: homeDirectory) }
            roots.append(configured ?? agent.appending(path: "sessions", directoryHint: .isDirectory))
        }
        roots += ompSessionRoots(homeDirectory: homeDirectory, environment: environment)
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    // OMP（oh-my-pi）的目录规则对齐 CodexBar 的 OMPSessionRootResolver：
    // 指定了 profile 只读该 profile；否则读默认目录，并把磁盘上所有 profile 一起算上。
    private static func ompSessionRoots(homeDirectory: URL, environment: [String: String]) -> [URL] {
        let configName = environment["PI_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = configName?.isEmpty == false ? configName! : ".omp"
        // 配置目录只能是主目录下的相对路径，越界时不读。
        guard !name.hasPrefix("/") else { return [] }
        let configRoot = homeDirectory.appending(path: name, directoryHint: .isDirectory)
        guard configRoot.standardizedFileURL.path.hasPrefix(homeDirectory.standardizedFileURL.path + "/") else { return [] }
        let customAgent = path(environment["PI_CODING_AGENT_DIR"], home: homeDirectory)
        let dataHome = path(environment["XDG_DATA_HOME"], home: homeDirectory)
            ?? homeDirectory.appending(path: ".local/share", directoryHint: .isDirectory)

        func layouts(in profile: URL) -> [URL] {
            ["sessions", "agent/sessions"]
                .map { profile.appending(path: $0, directoryHint: .isDirectory) }
                .filter(isDirectory)
        }

        let rawProfile = (environment["OMP_PROFILE"] ?? environment["PI_PROFILE"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawProfile.isEmpty, rawProfile != "default" {
            // profile 名称不合法时不读，避免拼出意外的路径。
            guard rawProfile.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
                  !rawProfile.hasSuffix(".") else { return [] }
            let found = [configRoot, dataHome.appending(path: "omp", directoryHint: .isDirectory)]
                .flatMap { layouts(in: $0.appending(path: "profiles/\(rawProfile)", directoryHint: .isDirectory)) }
            return found.isEmpty
                ? [configRoot.appending(path: "profiles/\(rawProfile)/agent/sessions", directoryHint: .isDirectory)]
                : found
        }

        var roots = [(customAgent ?? configRoot.appending(path: "agent", directoryHint: .isDirectory))
            .appending(path: "sessions", directoryHint: .isDirectory)]
        var profileParents = [configRoot.appending(path: "profiles", directoryHint: .isDirectory)]
        if customAgent == nil {
            roots.append(dataHome.appending(path: "omp/sessions", directoryHint: .isDirectory))
            profileParents.append(dataHome.appending(path: "omp/profiles", directoryHint: .isDirectory))
        }
        for parent in profileParents {
            let profiles = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            // 与 CodexBar 一致，最多读 64 个 profile 目录。
            roots += profiles.sorted { $0.path < $1.path }.flatMap(layouts).prefix(64)
        }
        return roots
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func parse(_ data: Data) -> PiSessionFileUsage {
        var sessionID: String?
        var context: (backend: String, model: String?)?
        var entries: [PiSessionUsageEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "session":
                sessionID = sessionID ?? identifier(object["id"] ?? object["sessionId"] ?? object["session_id"])
            case "model_change":
                context = text(object["provider"]).map { ($0.lowercased(), text(object["modelId"])) }
            case "message":
                guard let message = object["message"] as? [String: Any],
                      message["role"] as? String == "assistant" else { continue }
                // 消息自带的后端和模型优先，否则沿用最近一次切换的模型。
                let explicitBackend = (text(message["provider"]) ?? text(object["provider"]))?.lowercased()
                guard let backend = explicitBackend ?? context?.backend else { continue }
                let explicitModel = [message["model"], object["model"], message["modelId"], object["modelId"]]
                    .lazy.compactMap(text).first
                guard let model = explicitModel ?? (context?.backend == backend ? context?.model : nil),
                      let timestamp = date(message["timestamp"]) ?? date(object["timestamp"]),
                      let usage = message["usage"] as? [String: Any],
                      let entry = entry(usage, backend: backend, model: model, timestamp: timestamp, id: identifier(object["id"]))
                else { continue }
                entries.append(entry)
            default:
                continue
            }
        }
        return PiSessionFileUsage(sessionID: sessionID, entries: entries)
    }

    /// 分叉的会话会复制历史记录，同一会话里相同 id 的消息只算一次。
    static func deduplicated(_ files: [PiSessionFileUsage]) -> [PiSessionUsageEntry] {
        var seen: [String: Set<String>] = [:]
        var result: [PiSessionUsageEntry] = []
        for file in files {
            for entry in file.entries {
                if let sessionID = file.sessionID, let entryID = entry.entryID {
                    guard seen[sessionID, default: []].insert(entryID).inserted else { continue }
                }
                result.append(entry)
            }
        }
        return result
    }

    private static func entry(
        _ usage: [String: Any], backend: String, model: String, timestamp: Date, id: String?
    ) -> PiSessionUsageEntry? {
        var hasCounter = false
        // 第一个出现的写法生效；没有记为 0，值不合法返回 nil，整条丢弃避免算错。
        func read(_ values: [Any?]) -> Int? {
            guard let value = values.lazy.compactMap({ $0 }).first else { return 0 }
            hasCounter = true
            return count(value)
        }
        func read(_ keys: [String]) -> Int? { read(keys.map { usage[$0] }) }
        let cttl = usage["cttl"] as? [String: Any]
        guard let input = read(["input", "inputTokens", "input_tokens", "promptTokens", "prompt_tokens"]),
              let cacheRead = read([
                  "cacheRead", "cacheReadTokens", "cache_read", "cache_read_tokens",
                  "cacheReadInputTokens", "cache_read_input_tokens",
              ]),
              let cacheWrite = read([
                  "cacheWrite", "cacheWriteTokens", "cache_write", "cache_write_tokens",
                  "cacheCreationTokens", "cache_creation_tokens",
                  "cacheCreationInputTokens", "cache_creation_input_tokens",
              ]),
              let cacheWrite1h = read([
                  usage["cacheWrite1h"], usage["cache_write_1h"], cttl?["ephemeral1h"], cttl?["ephemeral_1h"],
              ]),
              let output = read(["output", "outputTokens", "output_tokens", "completionTokens", "completion_tokens"]),
              let directTotal = read(["totalTokens", "total_tokens", "tokenCount", "token_count", "tokens"])
        else { return nil }
        let (partial, overflowA) = input.addingReportingOverflow(cacheRead)
        let (partial2, overflowB) = partial.addingReportingOverflow(cacheWrite)
        let (derived, overflowC) = partial2.addingReportingOverflow(output)
        guard hasCounter, cacheWrite1h <= cacheWrite, !overflowA, !overflowB, !overflowC else { return nil }
        let total = max(directTotal, derived)
        guard total > 0 else { return nil }
        return PiSessionUsageEntry(
            entryID: id, timestamp: timestamp, backend: backend, model: model,
            inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            cacheWrite1hTokens: cacheWrite1h, outputTokens: output, totalTokens: total
        )
    }

    private static func count(_ value: Any) -> Int? {
        let raw: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            raw = number.stringValue
        } else if let string = value as? String {
            raw = string
        } else {
            return nil
        }
        if let integer = Int(raw) { return integer >= 0 ? integer : nil }
        guard let number = Double(raw), number.isFinite, number >= 0 else { return nil }
        return Int(exactly: number.rounded())
    }

    private static func date(_ value: Any?) -> Date? {
        let raw: Double
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            raw = number.doubleValue
        case let string as String:
            guard let numeric = Double(string) else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: string)
            }
            raw = numeric
        default:
            return nil
        }
        guard raw.isFinite else { return nil }
        // 毫秒时间戳转成秒。
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = text(value), value.utf8.count <= 1024 else { return nil }
        return value
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // 只接受绝对路径和 ~ 开头的路径；图形界面应用没有可靠的工作目录。
    private static func path(_ value: String?, home: URL) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") {
            return home.appending(path: String(value.dropFirst(2)), directoryHint: .isDirectory)
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}
