import Foundation
import SQLite3
import Testing
@testable import Yomi

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

        let scanner = LocalDailyUsageScanner()
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
        let restored = await scan(LocalDailyUsageScanner(), provider: provider, home: home, now: now)
        #expect(restored?.today?.tokens == 110)
    }

    @Test
    func independentSessionsWithEqualTokenVectorsBothCount() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeSession(id: "independent-a", count: 2, now: now.addingTimeInterval(-30), home: home)
        try writeSession(id: "independent-b", count: 2, now: now, home: home)

        let usage = await scan(LocalDailyUsageScanner(), provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 440)
    }

    @Test
    func explicitForkStillExcludesCopiedParentEvents() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writeSession(id: "parent", count: 2, now: now, home: home)
        try writeSession(id: "child", parentID: "parent", count: 3, now: now, home: home)

        let usage = await scan(LocalDailyUsageScanner(), provider: "codex", home: home, now: now)
        #expect(usage?.today?.tokens == 330)
    }

    @Test
    func originalOpusUsesItsFallbackPriceAfterDateNormalization() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let entry = claudeEntry(model: "claude-opus-4-20250514", input: 100, output: 10, now: now)
        try writeLines([entry], to: home.appending(path: ".claude/projects/sample/usage.jsonl"))

        let usage = await scan(LocalDailyUsageScanner(), provider: "claude", home: home, now: now)
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

        let usage = await scan(LocalDailyUsageScanner(), provider: "claude", home: home, now: now)
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
        let usage = await LocalDailyUsageScanner().scan(
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
        let scanner = LocalDailyUsageScanner()
        let usage = await scan(scanner, provider: "codex", home: home, now: now)
        let cost = try #require(usage?.today?.valueUSD)
        let standard = input == 250_000 ? 1.675 : 4.325
        #expect(abs(cost - standard * (tier == "default" ? 1 : 2)) < 1e-10)
        let restored = await scan(LocalDailyUsageScanner(), provider: "codex", home: home, now: now)
        #expect(restored?.today?.valueUSD == usage?.today?.valueUSD)
    }

    @Test(arguments: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    func familyFastPricingIncludesLongContext(model: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try writePricedSession(model: model, input: 300_000, now: now, home: home)
        let standard = await scan(LocalDailyUsageScanner(), provider: "codex", home: home, now: now)
        try writeTurnLog(
            "turn_id=priced websocket request: {\"type\":\"response.create\",\"model\":\"\(model)\",\"service_tier\":\"fast\"}",
            now: now, home: home
        )
        let fast = await scan(LocalDailyUsageScanner(), provider: "codex", home: home, now: now)
        let standardCost = try #require(standard?.today?.valueUSD)
        let fastCost = try #require(fast?.today?.valueUSD)
        #expect(abs(fastCost - standardCost * 2) < 1e-10)
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

    private func writeTurnLog(_ body: String, now: Date, home: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(home.appending(path: ".codex/logs_2.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
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
