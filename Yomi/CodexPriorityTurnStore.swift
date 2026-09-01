import Darwin
import Foundation
import SQLite3

nonisolated struct CodexPriorityTurn {
    var model: String?
}

nonisolated final class CodexPriorityTurnStore {
    private struct Turn {
        var model: String?
        var epochSeconds: Int64
    }

    private var databaseFileID = ""
    private var lastRowID: Int64 = 0
    private var coverageSinceEpoch = Int64.max
    private var turns: [String: Turn] = [:]
    private var completedModels: [String: String] = [:]
    private var completedTurnOrder: [String] = []

    func turnsByID(databaseURL: URL, since: Date) -> [String: CodexPriorityTurn] {
        let sinceEpoch = Int64(since.timeIntervalSince1970)
        guard let fileID = Self.fileID(of: databaseURL) else {
            reset()
            return [:]
        }
        if fileID != databaseFileID || sinceEpoch < coverageSinceEpoch {
            reset()
            databaseFileID = fileID
            coverageSinceEpoch = sinceEpoch
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle
        else {
            if let handle { sqlite3_close_v2(handle) }
            return snapshot(since: sinceEpoch)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        guard let maxRowID = Self.maxRowID(db) else { return snapshot(since: sinceEpoch) }
        if maxRowID < lastRowID {
            lastRowID = 0
            turns.removeAll()
            completedModels.removeAll()
            completedTurnOrder.removeAll()
        }
        if maxRowID > lastRowID,
           ingest(db, afterRowID: lastRowID, sinceEpoch: coverageSinceEpoch) {
            lastRowID = maxRowID
        }
        turns = turns.filter { $0.value.epochSeconds >= sinceEpoch }
        return snapshot(since: sinceEpoch)
    }

    private func snapshot(since sinceEpoch: Int64) -> [String: CodexPriorityTurn] {
        var result: [String: CodexPriorityTurn] = [:]
        result.reserveCapacity(turns.count)
        for (turnID, turn) in turns where turn.epochSeconds >= sinceEpoch {
            result[turnID] = CodexPriorityTurn(model: completedModels[turnID] ?? turn.model)
        }
        return result
    }

    private func ingest(_ db: OpaquePointer, afterRowID: Int64, sinceEpoch: Int64) -> Bool {
        let sql = """
        SELECT id, ts, feedback_log_body
        FROM logs
        WHERE id > ? AND ts >= ?
          AND (feedback_log_body LIKE '%websocket request:%'
               OR feedback_log_body LIKE '%response.completed%'
               OR feedback_log_body LIKE '%service_tier: Some(Some("priority"))%')
        ORDER BY id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, afterRowID)
        sqlite3_bind_int64(statement, 2, sinceEpoch)

        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { return step == SQLITE_DONE }
            let epochSeconds = sqlite3_column_int64(statement, 1)
            guard let bodyText = sqlite3_column_text(statement, 2) else { continue }
            let body = String(cString: bodyText)
            if let completed = Self.parseCompletedRow(body) {
                storeCompletedModel(completed.model, turnID: completed.turnID)
                continue
            }
            guard let request = Self.parsePriorityRequestRow(body) else { continue }
            turns[request.turnID] = Turn(model: request.model, epochSeconds: epochSeconds)
        }
    }

    private func storeCompletedModel(_ model: String, turnID: String) {
        if completedModels[turnID] == nil {
            completedTurnOrder.append(turnID)
            if completedTurnOrder.count > 4096 {
                completedModels.removeValue(forKey: completedTurnOrder.removeFirst())
            }
        }
        completedModels[turnID] = model
    }

    private func reset() {
        databaseFileID = ""
        lastRowID = 0
        coverageSinceEpoch = .max
        turns.removeAll()
        completedModels.removeAll()
        completedTurnOrder.removeAll()
    }

    private static func parsePriorityRequestRow(_ body: String) -> (turnID: String, model: String?)? {
        guard let markerRange = body.range(of: "websocket request:") else {
            return parsePrioritySubmissionRow(body)
        }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["type"] as? String == "response.create",
              request["service_tier"] as? String == "priority"
        else { return nil }
        let turnID = value(named: "turn.id", in: prefix)
            ?? value(named: "turn_id", in: prefix)
            ?? request["turn_id"] as? String
        guard let turnID, !turnID.isEmpty else { return nil }
        return (turnID, request["model"] as? String)
    }

    private static func parsePrioritySubmissionRow(_ body: String) -> (turnID: String, model: String?)? {
        guard body.contains(#"service_tier: Some(Some("priority"))"#),
              let submissionRange = body.range(of: "Submission sub=Submission {"),
              let turnID = quotedValue(named: "id", in: String(body[submissionRange.upperBound...]))
        else { return nil }
        return (turnID, nil)
    }

    private static func parseCompletedRow(_ body: String) -> (turnID: String, model: String)? {
        guard let markerRange = body.range(of: "websocket event:") else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "response.completed",
              let response = event["response"] as? [String: Any],
              let model = response["model"] as? String,
              !model.isEmpty
        else { return nil }
        let turnID = value(named: "turn.id", in: prefix) ?? value(named: "turn_id", in: prefix)
        guard let turnID, !turnID.isEmpty else { return nil }
        return (turnID, model)
    }

    private static func value(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=") else { return nil }
        let candidate = text[range.upperBound...].prefix { character in
            !character.isWhitespace
                && character != ","
                && character != "]"
                && character != ")"
                && character != "}"
                && character != ":"
        }
        return candidate.isEmpty ? nil : String(candidate)
    }

    private static func quotedValue(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name): \"") else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let candidate = tail[..<end]
        return candidate.isEmpty ? nil : String(candidate)
    }

    private static func maxRowID(_ db: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT max(id) FROM logs", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func fileID(of url: URL) -> String? {
        var status = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &status, 0) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return nil }
        return "\(status.st_dev):\(status.st_ino)"
    }
}
