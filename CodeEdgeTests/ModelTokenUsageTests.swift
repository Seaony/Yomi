import Foundation
import SQLite3
import Testing
@testable import CodeEdge

@Suite("Local model usage", .serialized)
struct ModelTokenUsageTests {
    private var now: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600) }

    @Test
    func codexGroupsModelsWithTheSameFastPricesAndPartialTotal() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try codexSession("a", model: "gpt-6.1-sol", input: 100, cached: 20, output: 10,
                         priority: true, home: home)
        try codexSession("b", model: "gpt-6.1-sol", input: 50, cached: 10, output: 5, home: home)
        try codexSession("unknown", model: "unpriced-model", input: 10, output: 1, home: home)
        let summary = try #require(await scan("codex", home: home))
        let rows = try #require(summary.todayByModel)
        #expect(rows.map(\.model) == ["gpt-6.1-sol", "unpriced-model"])
        #expect(rows[0].inputTokens == 150)
        #expect(rows[0].cacheReadTokens == 30)
        #expect(rows[0].outputTokens == 15)
        #expect(rows[0].inputIncludesCache)
        #expect(rows[0].tokens == 165)
        let expected = 2 * (80 * 2e-6 + 20 * 1e-7 + 10 * 1e-5)
            + (40 * 2e-6 + 10 * 1e-7 + 5 * 1e-5)
        #expect(abs(try #require(rows[0].valueUSD) - expected) < 1e-12)
        #expect(summary.today?.valueUSD == nil)
        #expect(rows[1].valueUSD == nil)
        try expectTotals(summary)
    }

    @Test
    func claudeAndVertexKeepTheirOwnModelsAndFourTokenCategories() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([
            claudeRow("regular", model: "claude-sonnet-4-5", input: 100, cached: 40, written: 20, output: 10),
            claudeRow("vertex", model: "claude-opus-4-5", input: 50, cached: 10, written: 5, output: 5,
                      vertex: true),
        ], to: home.appending(path: ".claude/projects/test/usage.jsonl"))
        let regular = try #require(await scan("claude", home: home))
        let vertex = try #require(await scan("vertexai", home: home))
        #expect(regular.todayByModel?.map(\.model) == ["claude-sonnet-4-5"])
        #expect(vertex.todayByModel?.map(\.model) == ["claude-opus-4-5"])
        #expect(regular.todayByModel?.first?.tokens == 170)
        #expect(regular.todayByModel?.first?.inputIncludesCache == false)
        #expect(vertex.todayByModel?.first?.tokens == 70)
        try expectTotals(regular)
        try expectTotals(vertex)
    }

    @Test
    func deepSeekCombinesCodexAndClaudeWithoutDoubleCountingCachedInput() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try codexSession("codex", model: "deepseek-chat", input: 100, cached: 20, output: 10, home: home)
        try write([
            claudeRow("claude", model: "deepseek-chat", input: 100, cached: 20, output: 10),
        ], to: home.appending(path: ".claude/projects/test/usage.jsonl"))
        try write([
            ["record": ["identity": ["createdAt": now.timeIntervalSince1970 * 1000],
                        "rows": ["tokenUsage": ["val": ["totals": ["uncachedInputTokens": 10,
                                                                  "cacheReadTokens": 2,
                                                                  "cacheWriteTokens": 1,
                                                                  "outputTokens": 3]]],
                                 "modelSelection": ["val": ["lastUsed": ["provider": "deepseek-official",
                                                                       "model": "deepseek-chat"]]]]]],
        ], to: home.appending(path: ".dsh/storages/session_projcache/sessions/test.json"))
        let summary = try #require(await scan("deepseek", home: home))
        let row = try #require(summary.todayByModel?.first)
        #expect(summary.todayByModel?.count == 1)
        #expect(!row.inputIncludesCache)
        #expect(row.inputTokens == 190)
        #expect(row.cacheReadTokens == 42)
        #expect(row.cacheWriteTokens == 1)
        #expect(row.outputTokens == 23)
        #expect(row.tokens == 256)
        try expectTotals(summary)
    }

    @Test
    func piKeepsReportedTotalsWithoutInventingInputTokens() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([
            ["type": "session", "id": "pi-test"],
            ["type": "message", "id": "m1", "timestamp": ISO8601DateFormatter().string(from: now),
             "message": ["role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-5",
                         "usage": ["input": 10, "cacheRead": 5, "output": 2, "totalTokens": 30]]],
        ], to: home.appending(path: ".pi/agent/sessions/test.jsonl"))
        let summary = try #require(await scan("pi", home: home))
        let row = try #require(summary.todayByModel?.first)
        #expect(row.inputTokens == 10)
        #expect(row.cacheReadTokens == 5)
        #expect(row.outputTokens == 2)
        #expect(row.reportedTotalTokens == 30)
        #expect(row.tokens == 30)
        #expect(row.valueUSD == nil)
        try expectTotals(summary)
    }

    @Test(arguments: [false, true])
    func openCodeDatabaseRowsRetainModelsAndCosts(withLegacy: Bool) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appending(path: "opencode.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TABLE session_message (id TEXT, type TEXT, time_created INTEGER, data TEXT)",
                            nil, nil, nil) == SQLITE_OK)
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        for (id, model, input, reasoning, cost) in [("a", "glm", 10, 2, 1.5), ("b", "glm", 20, 0, 2),
                                                 ("c", "minimax", 5, 1, 0.5)] {
            let json = """
            {"model":{"providerID":"opencode-go","id":"\(model)"},"cost":\(cost),\
            "tokens":{"input":\(input),"output":3,"reasoning":\(reasoning),"cache":{"read":4,"write":1}}}
            """
            let sql = "INSERT INTO session_message VALUES ('\(id)', 'assistant', \(milliseconds), '\(json)')"
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        let chargedWithoutTokens = """
        INSERT INTO session_message VALUES ('billed', 'assistant', \(milliseconds),
        '{"model":{"providerID":"opencode-go","id":"billed-only"},"cost":0.25,
        "tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """
        #expect(sqlite3_exec(handle, chargedWithoutTokens, nil, nil, nil) == SQLITE_OK)
        if withLegacy {
            #expect(sqlite3_exec(handle, "CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT)",
                                nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)",
                                nil, nil, nil) == SQLITE_OK)
            let message = """
            INSERT INTO message VALUES ('legacy', \(milliseconds), '{"providerID":"opencode-go",            "role":"assistant","modelID":"glm","cost":1}');
            """
            let part = """
            INSERT INTO part VALUES ('step', 'legacy', \(milliseconds), '{"type":"step-finish","cost":1,            "tokens":{"input":5,"output":2,"reasoning":0,"cache":{"read":1,"write":0}}}');
            """
            #expect(sqlite3_exec(handle, message, nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(handle, part, nil, nil, nil) == SQLITE_OK)
        }
        let rows = try #require(OpenCodeGoLocalUsageReader.readRows(since: now.addingTimeInterval(-60), database: database))
        let usage = OpenCodeGoLocalUsageReader.enrich(
            ProviderUsage(id: ProviderID(rawValue: "opencodego"), state: .ready, windows: []), rows: rows, now: now
        )
        let models = try #require(usage.todayByModel)
        #expect(models.map(\.model) == ["glm", "minimax", "billed-only"])
        let billedOnly = try #require(models.last)
        #expect(billedOnly.tokens == 0)
        #expect(billedOnly.inputTokens == 0)
        #expect(billedOnly.valueUSD == 0.25)
        #expect(models.map(\.tokens).reduce(0, +) == usage.today?.tokens)
        #expect(models.compactMap(\.valueUSD).reduce(0, +) == usage.today?.valueUSD)
        #expect(models.first?.outputTokens == (withLegacy ? 10 : 8))
    }

    @Test
    func displayRowsKeepTopFiveAndMergeTheRestWithoutLosingTotalsOrKnownPrices() throws {
        var rows = (1...7).map { index in
            ModelTokenUsage(model: "model-\(index)", inputTokens: Int64(index * 10), cacheReadTokens: 0,
                            cacheWriteTokens: 0, outputTokens: 0, inputIncludesCache: false,
                            valueUSD: Double(index))
        }
        rows[0].valueUSD = nil
        let display = ModelUsageBreakdown.displayRows(rows)
        #expect(display.count == 6)
        #expect(display.prefix(5).map(\.model) == ["model-7", "model-6", "model-5", "model-4", "model-3"])
        let other = try #require(display.last)
        #expect(other.model == ModelUsageBreakdown.otherModels)
        #expect(other.tokens == 30)
        #expect(other.valueUSD == nil)
        #expect(other.partialValueUSD == 2)
        #expect(display.map(\.tokens).reduce(0, +) == rows.map(\.tokens).reduce(0, +))
        #expect(abs(display.map { ModelUsageBreakdown.fraction($0, totalTokens: 280) }.reduce(0, +) - 1) < 1e-12)
    }

    @Test
    func existingSampleCacheRebuildsModelGroupsEvenAfterTheLogIsArchived() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try codexSession("cached", model: "gpt-6.1-sol", input: 100, cached: 20, output: 10, home: home)
        let original = try #require(await scan("codex", home: home))
        let log = home.appending(path: ".codex/sessions/cached.jsonl")
        try FileManager.default.moveItem(at: log, to: URL(fileURLWithPath: log.path + ".zst"))
        let restored = try #require(await scan("codex", home: home))
        #expect(restored.todayByModel == original.todayByModel)
        #expect(restored.today == original.today)
        #expect(restored.last30DaysDaily == original.last30DaysDaily)
        try expectTotals(restored)
    }

    @Test(arguments: ["codex", "claude"])
    func dailyModelGroupsSeparateDaysAndMatchToday(provider: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        if provider == "codex" {
            try codexSession("past", model: "gpt-6.1-sol", input: 100, cached: 20, output: 10,
                             at: yesterday, home: home)
            try codexSession("current-a", model: "gpt-6.1-sol", input: 50, output: 5, home: home)
            try codexSession("current-b", model: "unpriced-model", input: 10, output: 1, home: home)
        } else {
            try write([
                claudeRow("past", model: "claude-sonnet-4-5", input: 100, cached: 20, output: 10,
                          at: yesterday),
                claudeRow("current-a", model: "claude-sonnet-4-5", input: 50, output: 5),
                claudeRow("current-b", model: "unpriced-model", input: 10, output: 1),
            ], to: home.appending(path: ".claude/projects/test/usage.jsonl"))
        }
        let summary = try #require(await scan(provider, home: home))
        let daily = summary.last30DaysDaily
        #expect(daily.count == 2)
        #expect(daily.first?.date == Calendar.current.startOfDay(for: yesterday))
        #expect(daily.first?.models?.count == 1)
        #expect(daily.first?.models?.map(\.tokens).reduce(0, +) == (provider == "codex" ? 110 : 130))
        #expect(daily.last?.models == summary.todayByModel)
        #expect(daily.last?.usage == summary.today)
        for point in daily {
            #expect(point.models?.map(\.tokens).reduce(0, +) == point.usage.tokens)
        }
    }

    @Test
    func openCodeDailyModelsKeepDatesAndDoNotInventMissingBreakdowns() throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let older = try #require(Calendar.current.date(byAdding: .day, value: -2, to: now))
        func row(_ date: Date, model: String, tokens: Int64, cost: Double) -> OpenCodeGoLocalRow {
            OpenCodeGoLocalRow(date: date, cost: cost, requestCount: 1, tokens: tokens,
                               modelUsage: ModelTokenUsage(
                                   model: model, inputTokens: tokens, cacheReadTokens: 0, cacheWriteTokens: 0,
                                   outputTokens: 0, inputIncludesCache: false, valueUSD: cost
                               ))
        }
        let rows = [
            row(yesterday, model: "glm", tokens: 100, cost: 1),
            row(yesterday, model: "glm", tokens: 50, cost: 0.5),
            row(now, model: "minimax", tokens: 20, cost: 0.2),
            row(now, model: "glm", tokens: 10, cost: 0.1),
            OpenCodeGoLocalRow(date: older, cost: 0.3, requestCount: 1, tokens: 30),
        ]
        let usage = OpenCodeGoLocalUsageReader.enrich(
            ProviderUsage(id: ProviderID(rawValue: "opencodego"), state: .ready, windows: []),
            rows: rows, now: now
        )
        #expect(usage.last30DaysDaily.count == 3)
        #expect(usage.last30DaysDaily.first?.models == nil)
        let past = try #require(usage.last30DaysDaily.dropFirst().first)
        #expect(past.models?.map(\.model) == ["glm"])
        #expect(past.models?.first?.tokens == 150)
        #expect(past.models?.first?.valueUSD == 1.5)
        #expect(usage.last30DaysDaily.last?.models == usage.todayByModel)
        #expect(usage.last30DaysDaily.last?.usage == usage.today)
    }

    @Test
    func overviewDailyModelsMergeProvidersWithoutLosingUnattributedUsage() throws {
        let day = Calendar.current.startOfDay(for: now)
        let past = try #require(Calendar.current.date(byAdding: .day, value: -2, to: day))
        let missing = try #require(Calendar.current.date(byAdding: .day, value: -1, to: day))
        let first = ModelTokenUsage(model: "shared", inputTokens: 100, cacheReadTokens: 20,
                                   cacheWriteTokens: 0, outputTokens: 10, inputIncludesCache: true, valueUSD: 1)
        let second = ModelTokenUsage(model: "shared", inputTokens: 50, cacheReadTokens: 5,
                                    cacheWriteTokens: 0, outputTokens: 5, inputIncludesCache: false, valueUSD: 2)
        let unattributed = DailyTokenUsage(tokens: 30, valueUSD: nil, partialValueUSD: 0.5)
        let usages = [
            ProviderUsage(id: ProviderID(rawValue: "codex"), state: .ready, windows: [], today: first.usage,
                          last30DaysDaily: [.init(date: past, usage: first.usage, models: [first])],
                          updatedAt: now, todayByModel: [first]),
            ProviderUsage(id: ProviderID(rawValue: "claude"), state: .ready, windows: [], today: second.usage,
                          last30DaysDaily: [.init(date: past, usage: second.usage, models: [second])],
                          updatedAt: now, todayByModel: [second]),
            ProviderUsage(id: ProviderID(rawValue: "other"), state: .ready, windows: [], today: unattributed,
                          last30DaysDaily: [.init(date: past, usage: unattributed),
                                           .init(date: missing, usage: unattributed)], updatedAt: now),
        ]
        let daily = UsageStore.overviewDailyUsage(usages: usages, now: now)
        let combined = try #require(daily.first { $0.date == past })
        let models = try #require(combined.models)
        #expect(models.map(\.model) == ["shared", ModelUsageBreakdown.unknownModel])
        #expect(models[0].tokens == 170)
        #expect(models[0].inputTokens == 130)
        #expect(models[0].cacheReadTokens == 25)
        #expect(models[0].valueUSD == 3)
        #expect(models[1].usage == unattributed)
        #expect(models.map(\.tokens).reduce(0, +) == combined.usage.tokens)
        #expect(models.compactMap { $0.valueUSD ?? $0.partialValueUSD }.reduce(0, +)
                == combined.usage.partialValueUSD)
        #expect(daily.first { $0.date == missing }?.models == nil)
        #expect(daily.last?.models == UsageStore.overviewTodayByModel(usages: usages))
    }

    @Test
    func oldUsageCacheDecodesWithoutModelDataAndNewModelDataRoundTrips() throws {
        let old = try JSONDecoder().decode(ProviderUsage.self, from: Data(#"{"id":"codex","state":"ready","windows":[],"last30DaysDaily":[{"date":0,"usage":{"tokens":42,"valueUSD":1.25}}]}"#.utf8))
        #expect(old.todayByModel == nil)
        #expect(old.last30DaysDaily.first?.models == nil)
        #expect(old.last30DaysDaily.first?.usage.tokens == 42)
        var updated = old
        updated.todayByModel = [ModelTokenUsage(
            model: "test", inputTokens: 10, cacheReadTokens: 5, cacheWriteTokens: 0, outputTokens: 2,
            inputIncludesCache: false, valueUSD: nil, reportedTotalTokens: 30
        )]
        updated.last30DaysDaily[0].models = updated.todayByModel
        let restored = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(updated))
        #expect(restored.todayByModel == updated.todayByModel)
        #expect(restored.last30DaysDaily == updated.last30DaysDaily)
    }

    private func expectTotals(_ summary: LocalTokenUsageSummary) throws {
        let total = try #require(summary.today)
        let models = try #require(summary.todayByModel)
        #expect(models.map(\.tokens).reduce(0, +) == total.tokens)
        if let expected = total.valueUSD {
            #expect(models.allSatisfy { $0.valueUSD != nil })
            #expect(abs(models.compactMap(\.valueUSD).reduce(0, +) - expected) < 1e-12)
        } else if let expected = total.partialValueUSD {
            #expect(abs(models.compactMap { $0.valueUSD ?? $0.partialValueUSD }.reduce(0, +) - expected) < 1e-12)
        } else {
            #expect(models.allSatisfy { $0.valueUSD == nil && $0.partialValueUSD == nil })
        }
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "codeedge-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func scan(_ provider: String, home: URL) async -> LocalTokenUsageSummary? {
        await LocalDailyUsageScanner(cacheDirectory: home.appending(path: "cache")).scan(
            providerID: ProviderID(rawValue: provider), currentWeekStart: now.addingTimeInterval(-86400),
            now: now, homeDirectory: home
        )
    }

    private func codexSession(
        _ id: String, model: String, input: Int, cached: Int = 0, output: Int,
        priority: Bool = false, at date: Date? = nil, home: URL
    ) throws {
        try write([
            ["type": "session_meta", "payload": ["id": id]],
            ["type": "event_msg", "payload": ["type": "thread_settings_applied",
                                                   "thread_settings": ["service_tier": priority ? "priority" : "default"]]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": id]],
            ["type": "turn_context", "payload": ["model": model, "turn_id": id]],
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date ?? now),
             "payload": ["type": "token_count", "turn_id": id,
                         "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                       "output_tokens": output]]]],
        ], to: home.appending(path: ".codex/sessions/\(id).jsonl"))
    }

    private func claudeRow(
        _ id: String, model: String, input: Int, cached: Int = 0, written: Int = 0, output: Int,
        vertex: Bool = false, at date: Date? = nil
    ) -> [String: Any] {
        ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date ?? now),
         "metadata": ["provider": vertex ? "vertexai" : "anthropic"],
         "message": ["id": id, "model": model,
                     "usage": ["input_tokens": input, "cache_read_input_tokens": cached,
                               "cache_creation_input_tokens": written, "output_tokens": output]]]
    }

    private func write(_ rows: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file)
    }
}
