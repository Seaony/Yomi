import Foundation
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
