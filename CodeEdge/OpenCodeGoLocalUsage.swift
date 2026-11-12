import Foundation

enum OpenCodeGoLocalUsageReader {
    nonisolated static func enrich(_ usage: ProviderUsage, now: Date = Date()) -> ProviderUsage {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        guard let rows = readRows(since: start), !rows.isEmpty else { return usage }
        return enrich(usage, rows: rows, now: now)
    }

    nonisolated static func enrich(
        _ usage: ProviderUsage,
        rows: [OpenCodeGoLocalRow],
        now: Date
    ) -> ProviderUsage {
        var enriched = usage
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let today = rows.filter { $0.date >= todayStart && $0.date <= now }
        let last30Days = rows.filter { $0.date >= thirtyDayStart && $0.date <= now }
        enriched.today = tokenUsage(today)
        enriched.todayByModel = today.isEmpty ? [] : (
            enriched.today != nil && today.allSatisfy { $0.modelUsage != nil }
                ? ModelUsageBreakdown.merged(today.compactMap(\.modelUsage)) : nil
        )
        enriched.last30Days = tokenUsage(last30Days)
        enriched.last30DaysDaily = Dictionary(grouping: last30Days) { calendar.startOfDay(for: $0.date) }
            .compactMap { date, rows in
                tokenUsage(rows).map { DailyTokenUsagePoint(date: date, usage: $0) }
            }
            .sorted { $0.date < $1.date }
        enriched.todayDate = now
        enriched.todayRequests = nil
        enriched.last30DaysRequests = nil
        if !today.isEmpty {
            enriched.todayRequests = DailyRequestUsage(
                requests: today.reduce(0) { $0 + Int64($1.requestCount) },
                valueUSD: today.reduce(0) { $0 + $1.cost }
            )
        }
        if !last30Days.isEmpty {
            enriched.last30DaysRequests = DailyRequestUsage(
                requests: last30Days.reduce(0) { $0 + Int64($1.requestCount) },
                valueUSD: last30Days.reduce(0) { $0 + $1.cost }
            )
        }
        return enriched
    }

    nonisolated static func parseRows(_ text: String) -> [OpenCodeGoLocalRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let milliseconds = Int64(fields[0]), milliseconds > 0,
                  let cost = Double(fields[1]), cost.isFinite, cost >= 0,
                  let requests = Int(fields[2])
            else { return nil }
            let counts = fields.count > 3
                ? try? JSONDecoder().decode(TokenCounts.self, from: Data(fields[3].utf8)) : nil
            let model = fields.count > 4 ? String(fields[4]) : ModelUsageBreakdown.unknownModel
            return OpenCodeGoLocalRow(
                date: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
                cost: cost,
                requestCount: max(1, requests),
                tokens: counts?.resolvedTotal,
                modelUsage: counts?.modelUsage(model: model, cost: cost)
            )
        }
    }

    private nonisolated static func tokenUsage(_ rows: [OpenCodeGoLocalRow]) -> DailyTokenUsage? {
        guard !rows.isEmpty else { return nil }
        var total: Int64 = 0
        for row in rows {
            guard let tokens = row.tokens else { return nil }
            let sum = total.addingReportingOverflow(tokens)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return DailyTokenUsage(tokens: total, valueUSD: rows.reduce(0) { $0 + $1.cost })
    }

    nonisolated static func readRows(
        since start: Date,
        database: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db")
    ) -> [OpenCodeGoLocalRow]? {
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        func hasTable(_ name: String) -> Bool {
            run(
                database: database,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)' LIMIT 1;"
            )?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        let hasMessage = hasTable("message")
        let hasV2 = hasTable("session_message")
        // 新版 OpenCode 把历史写进 session_message，可能只有新表，也可能新旧表并存。
        guard hasMessage || hasV2 else { return nil }
        let minimumMilliseconds = Int64((start.timeIntervalSince1970 * 1_000).rounded(.down))
        let sql = usageSQL(
            hasMessage: hasMessage,
            hasPart: hasMessage && hasTable("part"),
            hasV2: hasV2,
            since: minimumMilliseconds
        )
        guard let output = run(database: database, sql: sql) else { return nil }
        return parseRows(output)
    }

    // OpenCode CLI 的当前登录：新版存在 opencode.db 的 credential 表，旧版只有 auth.json 里的 API Key。
    nonisolated static func cliCredential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> String? {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        } ?? homeDirectory.appending(path: ".local/share", directoryHint: .isDirectory)
        let directory = dataHome.appending(path: "opencode", directoryHint: .isDirectory)
        let filename = environment["OPENCODE_DB"] ?? "opencode.db"
        guard filename != ":memory:" else { return nil }
        let database = filename.hasPrefix("/") ? URL(fileURLWithPath: filename) : directory.appending(path: filename)
        let authURL = directory.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return legacyCLICredential(authURL)
        }
        let hasTable = run(
            database: database,
            sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='credential' LIMIT 1;"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hasTable else { return nil }
        // 有 credential 表时不再回退旧的 auth.json，避免用上已经登出的旧密钥。
        guard hasTable == "1" else { return legacyCLICredential(authURL) }
        let sql = """
            SELECT integration_id, json_extract(value, '$.type'), json_extract(value, '$.key'),
              json_extract(value, '$.access'), json_extract(value, '$.expires')
            FROM credential
            WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode') AND json_valid(value)
            ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END
            LIMIT 2;
            """
        guard let output = run(database: database, sql: sql) else { return nil }
        let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard let first = rows.first, first.count == 5 else { return nil }
        // 同一来源有两个激活账号时无法判断用哪个，不随便挑。
        if rows.count > 1, rows[1].first == first[0] { return nil }
        switch first[1] {
        case "key":
            return cliToken(first[2])
        case "oauth":
            guard let expires = Double(first[4]), expires.isFinite, expires >= 0,
                  expires / 1_000 > now.timeIntervalSince1970 else { return nil }
            return cliToken(first[3])
        default:
            return nil
        }
    }

    private nonisolated static func legacyCLICredential(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              entry["type"] as? String == "api" else { return nil }
        return cliToken(entry["key"] as? String)
    }

    private nonisolated static func cliToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return value
    }

    private nonisolated static func run(database: URL, sql: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", database.path, sql]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private nonisolated static let providerMessagesSQL = """
        SELECT id AS messageID,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
          CASE WHEN json_type(data, '$.tokens') = 'object' THEN json_extract(data, '$.tokens') END AS tokens,
          COALESCE(json_extract(data, '$.modelID'), '') AS modelID
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
        """

    private nonisolated static let messageAndPartSQL = """
        WITH provider_messages AS (\(providerMessagesSQL)), provider_parts AS (
          SELECT
            CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
              AS createdMs,
            CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
            CASE WHEN json_type(p.data, '$.tokens') = 'object' THEN json_extract(p.data, '$.tokens') END
              AS tokens,
            m.messageID AS messageID,
            m.modelID AS modelID
          FROM part p
          JOIN provider_messages m ON m.messageID = p.message_id
          WHERE json_valid(p.data)
            AND json_extract(p.data, '$.type') = 'step-finish'
            AND json_type(p.data, '$.cost') IN ('integer', 'real')
        )
        SELECT * FROM provider_parts
        UNION ALL
        SELECT createdMs, cost, tokens, messageID, modelID
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (SELECT 1 FROM provider_parts p WHERE p.messageID = m.messageID)
        """

    private nonisolated static func usageSQL(
        hasMessage: Bool, hasPart: Bool, hasV2: Bool, since minimumMilliseconds: Int64
    ) -> String {
        let legacy = if !hasMessage {
            "SELECT NULL AS createdMs, NULL AS cost, NULL AS tokens, NULL AS messageID, NULL AS modelID WHERE 0"
        } else if hasPart {
            messageAndPartSQL
        } else {
            "SELECT createdMs, cost, tokens, messageID, modelID FROM (\(providerMessagesSQL)) WHERE hasCost"
        }
        // 同一条消息旧表已有可用金额时以旧表为准，避免新旧两份重复计算。
        let v2 = hasV2 ? """
            UNION ALL
            SELECT
              CAST(COALESCE(json_extract(s.data, '$.time.created'), s.time_created) AS INTEGER),
              CAST(json_extract(s.data, '$.cost') AS REAL),
              CASE WHEN json_type(s.data, '$.tokens') = 'object' THEN json_extract(s.data, '$.tokens') END,
              COALESCE(json_extract(s.data, '$.model.id'), '')
            FROM session_message s
            WHERE s.type IN ('assistant', 'compaction')
              AND json_valid(s.data)
              AND json_extract(s.data, '$.model.providerID') = 'opencode-go'
              AND json_type(s.data, '$.cost') IN ('integer', 'real')
              AND NOT EXISTS (
                SELECT 1 FROM legacy_usage m
                WHERE m.messageID = s.id AND m.createdMs > 0
                  AND m.cost BETWEEN 0 AND \(Double.greatestFiniteMagnitude)
              )
            """ : ""
        return """
        WITH legacy_usage AS (\(legacy))
        SELECT createdMs, cost, 1, tokens, modelID FROM (
          SELECT createdMs, cost, tokens, modelID FROM legacy_usage
          \(v2)
        )
        WHERE createdMs >= \(minimumMilliseconds);
        """
    }

    private nonisolated struct TokenCounts: Decodable {
        struct Cache: Decodable {
            let read: Int64?
            let write: Int64?
        }

        let total: Int64?
        let input: Int64?
        let output: Int64?
        let reasoning: Int64?
        let cache: Cache?

        func modelUsage(model: String, cost: Double) -> ModelTokenUsage? {
            guard let total = resolvedTotal else { return nil }
            let output = (output ?? 0).addingReportingOverflow(reasoning ?? 0)
            guard !output.overflow else { return nil }
            var row = ModelTokenUsage(
                model: model.isEmpty ? ModelUsageBreakdown.unknownModel : model,
                inputTokens: input ?? 0, cacheReadTokens: cache?.read ?? 0,
                cacheWriteTokens: cache?.write ?? 0, outputTokens: output.partialValue,
                inputIncludesCache: false, valueUSD: cost
            )
            if row.tokens != total { row.reportedTotalTokens = total }
            return row
        }

        var resolvedTotal: Int64? {
            let components = [input, output, reasoning, cache?.read, cache?.write]
            guard (components + [total]).allSatisfy({ ($0 ?? 0) >= 0 }) else { return nil }
            if let total { return total }
            var result: Int64 = 0
            for component in components {
                guard let component else { return nil }
                let sum = result.addingReportingOverflow(component)
                guard !sum.overflow else { return nil }
                result = sum.partialValue
            }
            return result
        }
    }
}

struct OpenCodeGoLocalRow: Equatable {
    let date: Date
    let cost: Double
    let requestCount: Int
    let tokens: Int64?
    var modelUsage: ModelTokenUsage? = nil
}
