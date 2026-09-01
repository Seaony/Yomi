import Foundation
import SQLite3

nonisolated final class LocalUsageCacheStore {
    struct Record {
        let path: String
        let fileID: String
        let modificationNanoseconds: Int64
        let size: UInt64
        let payload: Data
    }

    private let database: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "Yomi/local-usage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for stale in ["usage-v1.sqlite", "usage-v1.sqlite-wal", "usage-v1.sqlite-shm"] {
            try? FileManager.default.removeItem(at: root.appending(path: stale))
        }
        let url = root.appending(path: "usage-v2.sqlite")

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle
        else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        database = handle

        guard execute("PRAGMA journal_mode=WAL"),
              execute("PRAGMA synchronous=NORMAL"),
              sqlite3_busy_timeout(database, 5_000) == SQLITE_OK,
              execute(Self.schema)
        else {
            sqlite3_close_v2(database)
            return nil
        }
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func records(provider: String) -> [Record] {
        let sql = """
        SELECT path, file_id, modification_ns, size, payload
        FROM file_cache
        WHERE provider = ?
        """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(provider, at: 1, to: statement)

        var records: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = text(statement, at: 0),
                  let fileID = text(statement, at: 1),
                  let payload = data(statement, at: 4)
            else { continue }
            records.append(Record(
                path: path,
                fileID: fileID,
                modificationNanoseconds: sqlite3_column_int64(statement, 2),
                size: UInt64(max(0, sqlite3_column_int64(statement, 3))),
                payload: payload
            ))
        }
        return records
    }

    func commit(provider: String, records: [Record], deletingPaths: Set<String>) {
        guard !records.isEmpty || !deletingPaths.isEmpty,
              execute("BEGIN IMMEDIATE")
        else { return }

        var succeeded = true
        if !deletingPaths.isEmpty {
            let sql = "DELETE FROM file_cache WHERE provider = ? AND path = ?"
            guard let statement = prepare(sql) else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for path in deletingPaths {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(provider, at: 1, to: statement)
                bind(path, at: 2, to: statement)
                if sqlite3_step(statement) != SQLITE_DONE {
                    succeeded = false
                    break
                }
            }
        }

        if succeeded, !records.isEmpty {
            let sql = """
            INSERT INTO file_cache (
                provider, path, file_id, modification_ns, size, payload, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, path) DO UPDATE SET
                file_id = excluded.file_id,
                modification_ns = excluded.modification_ns,
                size = excluded.size,
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """
            guard let statement = prepare(sql) else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(provider, at: 1, to: statement)
                bind(record.path, at: 2, to: statement)
                bind(record.fileID, at: 3, to: statement)
                sqlite3_bind_int64(statement, 4, record.modificationNanoseconds)
                sqlite3_bind_int64(statement, 5, Int64(clamping: record.size))
                bind(record.payload, at: 6, to: statement)
                sqlite3_bind_int64(statement, 7, updatedAt)
                if sqlite3_step(statement) != SQLITE_DONE {
                    succeeded = false
                    break
                }
            }
        }

        _ = execute(succeeded ? "COMMIT" : "ROLLBACK")
    }

    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private func text(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, at index: Int32) -> Data? {
        guard let value = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS file_cache (
        provider TEXT NOT NULL,
        path TEXT NOT NULL,
        file_id TEXT NOT NULL,
        modification_ns INTEGER NOT NULL,
        size INTEGER NOT NULL,
        payload BLOB NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (provider, path)
    ) WITHOUT ROWID;
    """
}
