import Foundation
import SQLite3
import Testing
@testable import CodeEdge

@Suite("Local usage scanning", .serialized)
struct LocalDailyUsageScannerTests {
    @Test(arguments: ["claude", "vertexai"])
    func incompleteRecordIsRetriedAfterAppendingItsTail(provider: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let file = home.appending(path: ".claude/projects/sample/usage.jsonl")
        let entry = claudeEntry(model: "claude-sonnet-4-6", input: 100, output: 10, now: now, provider: provider)
        let data = try JSONSerialization.data(withJSONObject: entry)
        try data.dropLast().write(to: file)

        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        let incomplete = await scan(scanner, provider: provider, home: home, now: now)
        #expect(incomplete == nil)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data.suffix(1) + Data([0x0A]))
        try handle.close()

        let completed = await scan(scanner, provider: provider, home: home, now: now)
        #expect(completed?.today?.tokens == 110)
        let repeated = await scan(scanner, provider: provider, home: home, now: now)
        #expect(repeated?.today?.tokens == 110)
        let restored = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: provider, home: home, now: now)
        #expect(restored?.today?.tokens == 110)
    }

    @Test
    func independentSessionsWithEqualTokenVectorsBothCount() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeSession(id: "independent-a", count: 2, now: now.addingTimeInterval(-30), home: home)
        try writeSession(id: "independent-b", count: 2, now: now, home: home)

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 440)
    }

    @Test
    func explicitForkStillExcludesCopiedParentEvents() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeSession(id: "parent", count: 2, now: now, home: home)
        try writeSession(id: "child", parentID: "parent", count: 3, now: now, home: home)

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 330)
    }

    @Test
    func originalOpusUsesItsFallbackPriceAfterDateNormalization() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let entry = claudeEntry(model: "claude-opus-4-20250514", input: 100, output: 10, now: now)
        try writeLines([entry], to: home.appending(path: ".claude/projects/sample/usage.jsonl"))

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "claude", home: home, now: now)
        let cost = try #require(usage?.today?.valueUSD)
        #expect(abs(cost - 0.00225) < 1e-10)
    }

    @Test
    func originalSonnetUsesLongContextFallbackRates() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let entry = claudeEntry(model: "claude-sonnet-4-20250514", input: 200_001, output: 10, now: now)
        try writeLines([entry], to: home.appending(path: ".claude/projects/sample/usage.jsonl"))

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "claude", home: home, now: now)
        let cost = try #require(usage?.today?.valueUSD)
        #expect(abs(cost - (200_001 * 6e-6 + 10 * 2.25e-5)) < 1e-10)
    }

    @Test(arguments: [250_000, 272_000, 272_001], [false, true])
    func astraPricingUsesOfficialContextThreshold(input: Int, withCatalog: Bool) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writePricedSession(model: "gpt-6-astra", input: input, now: now, home: home)
        let catalog = try withCatalog ? JSONDecoder().decode(ModelPricingCatalog.self, from: Data(#"""
        {"openai":{"models":{"gpt-6-astra":{"id":"gpt-6-astra","cost":{
          "input":10,"cache_read":1,"cache_write":12.5,"output":50,
          "context_over_200k":{"input":20,"cache_read":2,"cache_write":25,"output":75}
        }}}}}
        """#.utf8)) : nil
        let usage = await LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")).scan(
            providerID: ProviderID(rawValue: "codex"), currentWeekStart: now.addingTimeInterval(-86400),
            now: now, homeDirectory: home, pricingCatalog: catalog
        )
        let cost = try #require(usage?.today?.valueUSD)
        let inputCost = Double(input - 110_000) * 1e-5 + 100_000 * 1e-6 + 10_000 * 1.25e-5
        let expected = inputCost * (input > 272_000 ? 2 : 1) + 1_000 * 5e-5 * (input > 272_000 ? 1.5 : 1)
        #expect(abs(cost - expected) < 1e-10)
    }

    @Test(arguments: ["priority", "fast", "default"], [250_000, 300_000])
    func astraFastPricingIncludesLongContext(tier: String, input: Int) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writePricedSession(model: "gpt-6-astra", input: input, now: now, home: home)
        try writeTurnLog(
            "turn_id=priced websocket request: {\"type\":\"response.create\",\"model\":\"gpt-6-astra\",\"service_tier\":\"\(tier)\"}",
            now: now, home: home
        )
        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        let usage = await scan(scanner, provider: "codex", home: home, now: now)
        let cost = try #require(usage?.today?.valueUSD)
        let standard = input == 250_000 ? 1.675 : 4.325
        #expect(abs(cost - standard * (tier == "default" ? 1 : 2)) < 1e-10)
        let restored = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        #expect(restored?.today?.valueUSD == usage?.today?.valueUSD)
    }

    @Test(arguments: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    func familyFastPricingIncludesLongContext(model: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writePricedSession(model: model, input: 300_000, now: now, home: home)
        let standard = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        try writeTurnLog(
            "turn_id=priced websocket request: {\"type\":\"response.create\",\"model\":\"\(model)\",\"service_tier\":\"fast\"}",
            now: now, home: home
        )
        let fast = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        let standardCost = try #require(standard?.today?.valueUSD)
        let fastCost = try #require(fast?.today?.valueUSD)
        #expect(abs(fastCost - standardCost) < 1e-10)
    }

    @Test(arguments: ["gpt-6.1-sol", "openai/gpt-6.1-sol"], [250_000, 272_000, 272_001])
    func solFastPricingIncludesLongContext(model: String, input: Int) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writePricedSession(model: model, input: input, now: now, home: home)
        let standard = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        try writeTurnLog(
            "turn_id=priced websocket request: {\"type\":\"response.create\",\"model\":\"\(model)\",\"service_tier\":\"fast\"}",
            now: now, home: home
        )
        let fast = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        let standardCost = try #require(standard?.today?.valueUSD)
        let fastCost = try #require(fast?.today?.valueUSD)
        #expect(abs(fastCost - standardCost * 2) < 1e-10)
    }

    @Test(arguments: [0, 6, 10], [false, true])
    func resumedTurnContextsRefreshTheTierWithoutRepricingEarlierRequests(
        prefixCount: Int, withPriorityLog: Bool
    ) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        func record(_ type: String, _ payload: [String: Any], second: Int) -> [String: Any] {
            ["type": type, "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(second) - 60)),
             "payload": payload]
        }
        func settings(_ tier: String, second: Int) -> [String: Any] {
            record("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier]],
                   second: second)
        }
        func context(second: Int) -> [String: Any] {
            record("turn_context", ["model": "gpt-6.1-sol", "turn_id": "resumed-turn"], second: second)
        }
        func usage(second: Int) -> [String: Any] {
            record("event_msg", ["type": "token_count", "turn_id": "resumed-turn", "info": ["last_token_usage": [
                "input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 100,
            ]]], second: second)
        }
        let records = [
            record("session_meta", ["id": "synthetic-resumed-tier"], second: 0),
            settings("default", second: 1),
            record("event_msg", ["type": "task_started", "turn_id": "resumed-turn"], second: 2),
            context(second: 3), usage(second: 4), settings("priority", second: 5),
            context(second: 6), usage(second: 7), settings("default", second: 8),
            context(second: 9), usage(second: 10),
        ]
        let file = home.appending(path: ".codex/sessions/resumed-tier.jsonl")
        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        if prefixCount > 0 {
            try writeLines(Array(records.prefix(prefixCount)), to: file)
            _ = await scan(scanner, provider: "codex", home: home, now: now)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            for row in records.dropFirst(prefixCount) {
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([0x0A]))
            }
            try handle.close()
        } else {
            try writeLines(records, to: file)
        }
        if withPriorityLog {
            try writeTurnLog(
                "turn_id=resumed-turn websocket request: {\"type\":\"response.create\",\"model\":\"gpt-6.1-sol\",\"service_tier\":\"priority\"}",
                now: now, home: home
            )
        }
        let usage = await scan(scanner, provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 3300)
        // 日志库按 turn 记录 Fast，恢复后确认切回标准档的最后一次请求仍按标准价计。
        #expect(try abs(#require(usage?.today?.valueUSD) - (withPriorityLog ? 0.0074 : 0.00592)) < 1e-12)
    }

    @Test
    func archivedCodexRolloutKeepsItsCountedUsageOnce() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeSession(id: "archived", count: 2, now: now, home: home)
        let file = home.appending(path: ".codex/sessions/archived.jsonl")
        let original = try Data(contentsOf: file)

        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        #expect(await scan(scanner, provider: "codex", home: home, now: now)?.today?.tokens == 220)
        try FileManager.default.moveItem(at: file, to: home.appending(path: ".codex/sessions/archived.jsonl.zst"))
        #expect(await scan(scanner, provider: "codex", home: home, now: now)?.today?.tokens == 220)
        #expect(await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)?.today?.tokens == 220)

        try original.write(to: file)
        #expect(await scan(scanner, provider: "codex", home: home, now: now)?.today?.tokens == 220)
    }

    @Test(arguments: [".codex/sessions/2026", ".codex"])
    func unreadableSessionDirectoryKeepsItsUsage(lockedPath: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try FileManager.default.createDirectory(
            at: home.appending(path: ".codex/sessions/2026"), withIntermediateDirectories: true
        )
        try writeSession(id: "2026/locked", count: 2, now: now, home: home)
        let directory = home.appending(path: lockedPath)

        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        let before = await scan(scanner, provider: "codex", home: home, now: now)?.today?.tokens
        #expect(before == 220)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let locked = await scan(scanner, provider: "codex", home: home, now: now)?.today?.tokens
        #expect(locked == 220)
    }

    @Test(arguments: [("claude-mythos-5", 1e-6), ("claude-mythos-5-1", 2.5e-7)])
    func mythosUsesBundledRates(model: String, cacheReadRate: Double) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        var entry = claudeEntry(model: model, input: 100, output: 10, now: now)
        entry["message"] = ["id": "message", "model": model, "usage": [
            "input_tokens": 100, "cache_read_input_tokens": 1_000,
            "cache_creation_input_tokens": 40, "output_tokens": 10,
        ]]
        try writeLines([entry], to: home.appending(path: ".claude/projects/sample/usage.jsonl"))

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "claude", home: home, now: now)
        let cost = try #require(usage?.today?.valueUSD)
        #expect(abs(cost - (100 * 1e-5 + 1_000 * cacheReadRate + 40 * 1.25e-5 + 10 * 5e-5)) < 1e-12)
    }

    @Test
    func symlinkedClaudeProjectsRootIsScannedOnceWithoutNestedLinks() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let fileManager = FileManager.default
        let physical = home.appending(path: "physical-projects")
        try fileManager.moveItem(at: home.appending(path: ".claude/projects"), to: physical)
        try writeLines(
            [claudeEntry(model: "claude-sonnet-4-5", input: 100, output: 10, now: now)],
            to: physical.appending(path: "sample/usage.jsonl")
        )
        // 子目录里指向外部的链接不跟随。
        let outside = home.appending(path: "outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        var external = claudeEntry(model: "claude-sonnet-4-5", input: 900, output: 90, now: now)
        external["requestId"] = "outside-request"
        external["message"] = ["id": "outside-message", "model": "claude-sonnet-4-5",
                               "usage": ["input_tokens": 900, "output_tokens": 90]]
        try writeLines([external], to: outside.appending(path: "outside.jsonl"))
        try fileManager.createSymbolicLink(at: physical.appending(path: "nested-link"), withDestinationURL: outside)
        // 两个默认目录都链接到同一个真实目录时只算一次。
        try fileManager.createSymbolicLink(at: home.appending(path: ".claude/projects"), withDestinationURL: physical)
        try fileManager.createDirectory(at: home.appending(path: ".config/claude"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: home.appending(path: ".config/claude/projects"), withDestinationURL: physical
        )

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "claude", home: home, now: now)
        #expect(usage?.today?.tokens == 110)
    }

    @Test
    func symlinkedCodexSessionRootsAreScannedOnce() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let fileManager = FileManager.default
        try writeSession(id: "linked", count: 2, now: now, home: home)
        let physical = home.appending(path: "physical-sessions")
        try fileManager.moveItem(at: home.appending(path: ".codex/sessions"), to: physical)
        try fileManager.createSymbolicLink(at: home.appending(path: ".codex/sessions"), withDestinationURL: physical)
        try fileManager.createSymbolicLink(
            at: home.appending(path: ".codex/archived_sessions"), withDestinationURL: physical
        )

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 220)
    }

    @Test
    func coworkAuditAndTranscriptCountOnce() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let session = home.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions/s1")
        let projects = session.appending(path: ".claude/projects/p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        var transcript = claudeEntry(model: "claude-sonnet-4-5", input: 100, output: 10, now: now)
        transcript["requestId"] = "req-1"
        var audit = transcript
        audit.removeValue(forKey: "requestId")
        audit["request_id"] = "req-1"
        var unrelated = claudeEntry(model: "claude-sonnet-4-5", input: 200, output: 20, now: now)
        unrelated.removeValue(forKey: "requestId")
        unrelated["session_id"] = "s1"
        unrelated["message"] = ["id": "message-2", "model": "claude-sonnet-4-5",
                                "usage": ["input_tokens": 200, "output_tokens": 20]]
        var unrelatedCopy = unrelated
        unrelatedCopy.removeValue(forKey: "session_id")
        unrelatedCopy["sessionId"] = "s1"
        let result: [String: Any] = ["type": "result", "usage": ["input_tokens": 9_999, "output_tokens": 9_999]]
        try writeLines([audit, unrelated, result], to: session.appending(path: "audit.jsonl"))
        try writeLines([transcript, unrelatedCopy], to: projects.appending(path: "transcript.jsonl"))

        let usage = await scan(LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")), provider: "claude", home: home, now: now)
        #expect(usage?.today?.tokens == 330)
    }

    @Test
    func archivedParentIsTrimmedWithItsForkAcrossDays() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let firstNow = Date()
        let oldest = firstNow.addingTimeInterval(-29 * 86400)
        func row(_ index: Int, at date: Date) -> [String: Any] {
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date), "payload": [
                "type": "token_count", "turn_id": "fork",
                "info": [
                    "last_token_usage": ["input_tokens": 100, "output_tokens": 10],
                    "total_token_usage": ["input_tokens": index * 100, "output_tokens": index * 10],
                ],
            ]]
        }
        let shared = [row(1, at: oldest), row(2, at: firstNow.addingTimeInterval(-60))]
        let parent = home.appending(path: ".codex/sessions/parent.jsonl")
        try writeLines([["type": "session_meta", "payload": ["id": "parent"]]] + shared, to: parent)
        try writeLines(
            [["type": "session_meta", "payload": ["id": "child", "forked_from_id": "parent"]]] + shared
                + [row(3, at: firstNow.addingTimeInterval(-30))],
            to: home.appending(path: ".codex/sessions/child.jsonl")
        )

        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        #expect(await scan(scanner, provider: "codex", home: home, now: firstNow)?.last30Days?.tokens == 330)
        try FileManager.default.moveItem(at: parent, to: home.appending(path: ".codex/sessions/parent.jsonl.zst"))
        let later = await scan(scanner, provider: "codex", home: home, now: firstNow.addingTimeInterval(2 * 86400))
        #expect(later?.last30Days?.tokens == 220)
    }

    @Test
    func unreadableCoworkSessionsKeepTheirUsage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let sessions = home.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions")
        try FileManager.default.createDirectory(at: sessions.appending(path: "s1"), withIntermediateDirectories: true)
        var entry = claudeEntry(model: "claude-sonnet-4-5", input: 100, output: 10, now: now)
        entry.removeValue(forKey: "requestId")
        entry["request_id"] = "req-1"
        try writeLines([entry], to: sessions.appending(path: "s1/audit.jsonl"))

        let scanner = LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache"))
        #expect(await scan(scanner, provider: "claude", home: home, now: now)?.today?.tokens == 110)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sessions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path) }
        #expect(await scan(scanner, provider: "claude", home: home, now: now)?.today?.tokens == 110)
    }

    @Test(arguments: ["priority", "fast"])
    func submissionTierIsRecognized(tier: String) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeTurnLog(
            "Submission sub=Submission { id: \"priced\", service_tier: Some(Some(\"\(tier)\")) }",
            now: now, home: home
        )
        let turns = CodexPriorityTurnStore().turnsByID(
            databaseURL: home.appending(path: ".codex/logs_2.sqlite"), since: now.addingTimeInterval(-86400)
        )
        #expect(turns["priced"] != nil)
    }

    @Test
    func walDatabaseWithoutSidecarsStillReadsPriorityTurns() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeTurnLog(
            "turn_id=priced websocket request: {\"type\":\"response.create\",\"model\":\"gpt-5.4\",\"service_tier\":\"priority\"}",
            now: now, home: home, wal: true
        )
        let database = home.appending(path: ".codex/logs_2.sqlite")
        // 系统 SQLite 默认保留 -wal 文件，删掉以模拟 Codex 退出后只剩主文件的情况。
        try? FileManager.default.removeItem(atPath: database.path + "-wal")
        try? FileManager.default.removeItem(atPath: database.path + "-shm")
        #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))
        let turns = CodexPriorityTurnStore().turnsByID(databaseURL: database, since: now.addingTimeInterval(-86400))
        #expect(turns["priced"]?.model == "gpt-5.4")
    }

    private func writePricedSession(model: String, input: Int, now: Date, home: URL) throws {
        try writeLines([
            ["type": "session_meta", "payload": ["id": "priced"]],
            ["type": "turn_context", "payload": ["model": model]],
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
             "payload": ["type": "token_count", "turn_id": "priced", "info": [
                "last_token_usage": ["input_tokens": input, "cached_input_tokens": 100_000,
                                     "cache_write_input_tokens": 10_000, "output_tokens": 1_000],
             ]]],
        ], to: home.appending(path: ".codex/sessions/priced.jsonl"))
    }

    private func writeTurnLog(_ body: String, now: Date, home: URL, wal: Bool = false) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(home.appending(path: ".codex/logs_2.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        if wal {
            #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(database, "CREATE TABLE logs (id INTEGER PRIMARY KEY, ts INTEGER, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK)
        let escaped = body.replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(database, "INSERT INTO logs VALUES (1, \(Int64(now.timeIntervalSince1970)), '\(escaped)')", nil, nil, nil) == SQLITE_OK)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "yomi-scanner-\(UUID().uuidString)")
        for path in [".claude/projects/sample", ".codex/sessions"] {
            try FileManager.default.createDirectory(at: home.appending(path: path), withIntermediateDirectories: true)
        }
        return home
    }

    private func scan(
        _ scanner: LocalDailyUsageScanner,
        provider: String,
        home: URL,
        now: Date
    ) async -> LocalTokenUsageSummary? {
        await scanner.scan(
            providerID: ProviderID(rawValue: provider),
            currentWeekStart: now.addingTimeInterval(-7 * 24 * 60 * 60),
            now: now,
            homeDirectory: home
        )
    }

    private func claudeEntry(
        model: String,
        input: Int,
        output: Int,
        now: Date,
        provider: String = "claude"
    ) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            "requestId": "request",
            "metadata": ["provider": provider],
            "message": [
                "id": "message", "model": model,
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
    }

    private func writeSession(
        id: String,
        parentID: String? = nil,
        count: Int,
        now: Date,
        home: URL
    ) throws {
        var metadata = ["id": id]
        metadata["forked_from_id"] = parentID
        var rows: [[String: Any]] = [["type": "session_meta", "payload": metadata]]
        for index in 1...count {
            rows.append([
                "type": "event_msg",
                "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(index) - 60)),
                "payload": [
                    "type": "token_count", "turn_id": id,
                    "info": [
                        "last_token_usage": ["input_tokens": 100, "output_tokens": 10],
                        "total_token_usage": ["input_tokens": index * 100, "output_tokens": index * 10],
                    ],
                ],
            ])
        }
        try writeLines(rows, to: home.appending(path: ".codex/sessions/\(id).jsonl"))
    }

    private func writeLines(_ rows: [[String: Any]], to file: URL) throws {
        var data = Data()
        for row in rows {
            data += try JSONSerialization.data(withJSONObject: row)
            data.append(0x0A)
        }
        try data.write(to: file)
    }
}
