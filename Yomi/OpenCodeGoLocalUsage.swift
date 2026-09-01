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
        if !today.isEmpty {
            enriched.today = DailyTokenUsage(
                tokens: today.reduce(0) { $0 + Int64($1.requestCount) },
                valueUSD: today.reduce(0) { $0 + $1.cost }
            )
        }
        if !last30Days.isEmpty {
            enriched.last30Days = DailyTokenUsage(
                tokens: last30Days.reduce(0) { $0 + Int64($1.requestCount) },
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
                requestCount: max(1, requests)
            )
        }
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
          1
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
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
        ), part_counts AS (
          SELECT m.messageID, COUNT(*) AS requestCount
          FROM provider_messages m
          JOIN part p ON p.message_id = m.messageID
          WHERE json_valid(p.data)
            AND json_extract(p.data, '$.type') = 'step-finish'
          GROUP BY m.messageID
        )
        SELECT m.createdMs, m.cost, COALESCE(p.requestCount, 1)
        FROM provider_messages m
        LEFT JOIN part_counts p ON p.messageID = m.messageID
        WHERE m.hasCost AND m.createdMs >= \(minimumMilliseconds)
        UNION ALL
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER),
          CAST(json_extract(p.data, '$.cost') AS REAL),
          1
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE NOT m.hasCost
          AND json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
          AND CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            >= \(minimumMilliseconds);
        """
    }
}

struct OpenCodeGoLocalRow: Equatable {
    let date: Date
    let cost: Double
    let requestCount: Int
}
