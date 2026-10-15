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
            return OpenCodeGoLocalRow(
                date: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
                cost: cost,
                requestCount: max(1, requests),
                tokens: fields.count > 3
                    ? (try? JSONDecoder().decode(TokenCounts.self, from: Data(fields[3].utf8)))?.resolvedTotal
                    : nil
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

    private nonisolated static func readRows(since start: Date) -> [OpenCodeGoLocalRow]? {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        let hasPart = run(
            database: database,
            sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='part' LIMIT 1;"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let minimumMilliseconds = Int64((start.timeIntervalSince1970 * 1_000).rounded(.down))
        let sql = hasPart
            ? messageAndPartSQL(since: minimumMilliseconds)
            : messageSQL(since: minimumMilliseconds)
        guard let output = run(database: database, sql: sql) else { return nil }
        return parseRows(output)
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

    private nonisolated static func messageSQL(since minimumMilliseconds: Int64) -> String {
        """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER),
          CAST(json_extract(data, '$.cost') AS REAL),
          1,
          CASE WHEN json_type(data, '$.tokens') = 'object' THEN json_extract(data, '$.tokens') END
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
          AND json_type(data, '$.cost') IN ('integer', 'real')
          AND CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER)
            >= \(minimumMilliseconds);
        """
    }

    private nonisolated static func messageAndPartSQL(since minimumMilliseconds: Int64) -> String {
        """
        WITH provider_messages AS (
          SELECT id AS messageID,
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost,
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
            CASE WHEN json_type(data, '$.tokens') = 'object' THEN json_extract(data, '$.tokens') END AS tokens
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
        )
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER),
          CAST(json_extract(p.data, '$.cost') AS REAL),
          1,
          CASE WHEN json_type(p.data, '$.tokens') = 'object' THEN json_extract(p.data, '$.tokens') END
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
          AND CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            >= \(minimumMilliseconds)
        UNION ALL
        SELECT m.createdMs, m.cost, 1, m.tokens
        FROM provider_messages m
        WHERE m.hasCost AND m.createdMs >= \(minimumMilliseconds)
          AND NOT EXISTS (
            SELECT 1 FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          );
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
}
