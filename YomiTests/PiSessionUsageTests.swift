import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct PiSessionUsageTests {
    private static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private static func assistant(
        id: String, provider: String? = nil, model: String? = nil, at date: Date, usage: [String: Any]
    ) -> String {
        var message: [String: Any] = ["role": "assistant", "usage": usage, "timestamp": date.timeIntervalSince1970 * 1000]
        if let provider { message["provider"] = provider }
        if let model { message["model"] = model }
        return line(["type": "message", "id": id, "message": message])
    }

    @Test
    func parsesUsageAndFollowsModelChanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = [
            Self.line(["type": "session", "id": "session-a"]),
            Self.line(["type": "model_change", "provider": "anthropic", "modelId": "claude-sonnet-4-5"]),
            Self.assistant(id: "m1", at: now, usage: ["input": 10, "cacheRead": 20, "cacheWrite": 5, "output": 3]),
            Self.line(["type": "message", "id": "u1", "message": ["role": "user", "usage": ["input": 99]]]),
            Self.assistant(id: "m2", provider: "openai-codex", model: "gpt-5.5", at: now, usage: ["input_tokens": "7", "output_tokens": 1, "total_tokens": 12]),
            Self.assistant(id: "m3", at: now, usage: ["input": -1, "output": 1]),
            "not-json",
        ].joined(separator: "\n")

        let file = PiSessionUsageReader.parse(Data(text.utf8))

        #expect(file.sessionID == "session-a")
        #expect(file.entries.map(\.entryID) == ["m1", "m2"])
        #expect(file.entries.first?.backend == "anthropic")
        #expect(file.entries.first?.model == "claude-sonnet-4-5")
        #expect(file.entries.first?.totalTokens == 38)
        #expect(file.entries.first?.countsMatchTotal == true)
        // 直接给出的总数更大时以它为准，但不再按分项计价。
        #expect(file.entries.last?.totalTokens == 12)
        #expect(file.entries.last?.countsMatchTotal == false)
        #expect(file.entries.first?.timestamp == now)
    }

    @Test
    func forkedSessionHistoryCountsOnce() {
        let entry = PiSessionUsageEntry(
            entryID: "m1", timestamp: Date(), backend: "anthropic", model: "claude-sonnet-4-5",
            inputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, cacheWrite1hTokens: 0, outputTokens: 1, totalTokens: 2
        )
        let unkeyed = PiSessionUsageEntry(
            entryID: nil, timestamp: Date(), backend: "anthropic", model: "claude-sonnet-4-5",
            inputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, cacheWrite1hTokens: 0, outputTokens: 1, totalTokens: 2
        )
        let files = [
            PiSessionFileUsage(sessionID: "s", entries: [entry, unkeyed]),
            PiSessionFileUsage(sessionID: "s", entries: [entry, unkeyed]),
            PiSessionFileUsage(sessionID: "other", entries: [entry]),
        ]

        #expect(PiSessionUsageReader.deduplicated(files).count == 4)
    }

    @Test
    func sessionRootsHonorEnvironmentAndSettings() throws {
        let home = URL(fileURLWithPath: "/tmp/pi-home", isDirectory: true)
        let custom = PiSessionUsageReader.sessionRoots(
            homeDirectory: home, environment: ["PI_CODING_AGENT_DIR": "~/agent", "XDG_DATA_HOME": "/data"]
        ).map(\.path)
        // 自定义代理目录同时作用于 OMP，并且不再读 XDG 目录。
        #expect(custom == ["/tmp/pi-home/agent/sessions"])

        let defaults = PiSessionUsageReader.sessionRoots(homeDirectory: home, environment: ["PI_CODING_AGENT_DIR": "relative"])
            .map(\.path)
        #expect(defaults.first == "/tmp/pi-home/.pi/agent/sessions")
    }

    @Test
    func ompProfilesAreDiscoveredUnlessOneIsSelected() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in [".omp/profiles/work/sessions", ".omp/profiles/old/agent/sessions", ".omp/profiles/empty"] {
            try FileManager.default.createDirectory(at: temporary.appending(path: directory), withIntermediateDirectories: true)
        }
        // 临时目录在 /private/var 下，先换成真实路径再比较。
        let home = URL(fileURLWithPath: realpath(temporary.path, nil).map { String(cString: $0) } ?? temporary.path)

        let discovered = PiSessionUsageReader.sessionRoots(homeDirectory: home, environment: ["XDG_DATA_HOME": "/nonexistent"])
            .map { $0.path.replacingOccurrences(of: home.path, with: "~") }
        #expect(discovered == [
            "~/.pi/agent/sessions", "~/.omp/agent/sessions", "/nonexistent/omp/sessions",
            "~/.omp/profiles/old/agent/sessions", "~/.omp/profiles/work/sessions",
        ])

        let selected = PiSessionUsageReader.sessionRoots(homeDirectory: home, environment: ["OMP_PROFILE": "work"])
            .map { $0.path.replacingOccurrences(of: home.path, with: "~") }
        #expect(selected == ["~/.pi/agent/sessions", "~/.omp/profiles/work/sessions"])

        let invalid = PiSessionUsageReader.sessionRoots(homeDirectory: home, environment: ["OMP_PROFILE": "../x"])
        #expect(invalid.count == 1)

        // 显式选 default 只读默认目录，不再把其他 profile 算进来。
        for key in ["OMP_PROFILE", "PI_PROFILE"] {
            let explicitDefault = PiSessionUsageReader.sessionRoots(
                homeDirectory: home, environment: [key: "default", "XDG_DATA_HOME": "/nonexistent"]
            ).map { $0.path.replacingOccurrences(of: home.path, with: "~") }
            #expect(explicitDefault == ["~/.pi/agent/sessions", "~/.omp/agent/sessions", "/nonexistent/omp/sessions"])
        }

        // 配置目录可以就是主目录本身。
        let homeConfig = PiSessionUsageReader.sessionRoots(
            homeDirectory: home, environment: ["PI_CONFIG_DIR": ".", "XDG_DATA_HOME": "/nonexistent"]
        ).map { $0.path.replacingOccurrences(of: home.path, with: "~") }
        #expect(homeConfig == ["~/.pi/agent/sessions", "~/agent/sessions", "/nonexistent/omp/sessions"])
    }

    @Test
    func unreadableOMPProfilesKeepPreviousTotals() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        let profiles = home.appending(path: ".omp/profiles")
        let directory = profiles.appending(path: "work/sessions")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profiles.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let session = Self.assistant(
            id: "m1", provider: "anthropic", model: "claude-sonnet-4-5", at: now.addingTimeInterval(-60),
            usage: ["input": 10, "output": 5]
        ) + "\n"
        try Data(session.utf8).write(to: directory.appending(path: "a.jsonl"))
        let scanner = LocalDailyUsageScanner()
        func scan() async -> Int64? {
            await scanner.scan(
                providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
                homeDirectory: home
            )?.today?.tokens
        }
        #expect(await scan() == 15)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profiles.path)
        #expect(await scan() == 15)
    }

    @Test
    func unreadableDirectoryKeepsPreviousTotals() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        let directory = home.appending(path: ".pi/agent/sessions")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let session = Self.assistant(
            id: "m1", provider: "anthropic", model: "claude-sonnet-4-5", at: now.addingTimeInterval(-60),
            usage: ["input": 10, "output": 5]
        ) + "\n"
        try Data(session.utf8).write(to: directory.appending(path: "a.jsonl"))
        let scanner = LocalDailyUsageScanner()
        func scan() async -> Int64? {
            await scanner.scan(
                providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
                homeDirectory: home
            )?.today?.tokens
        }
        #expect(await scan() == 15)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        #expect(await scan() == 15)
    }

    @Test
    func bedrockPricingNeedsTheFullRegionalModelID() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: ".pi/agent/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let session = Self.assistant(
            id: "m1", provider: "amazon-bedrock", model: "eu.anthropic.claude-sonnet-4-6", at: now.addingTimeInterval(-60),
            usage: ["input": 1000, "output": 100]
        ) + "\n"
        try Data(session.utf8).write(to: directory.appending(path: "a.jsonl"))
        func catalog(_ model: String) throws -> ModelPricingCatalog {
            try JSONDecoder().decode(ModelPricingCatalog.self, from: Data(
                #"{"amazon-bedrock":{"models":{"\#(model)":{"id":"\#(model)","cost":{"input":3,"output":15}}}}}"#.utf8
            ))
        }

        let generic = await LocalDailyUsageScanner().scan(
            providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
            homeDirectory: home, pricingCatalog: try catalog("claude-sonnet-4-6")
        )
        #expect(generic?.today?.tokens == 1100)
        #expect(generic?.today?.valueUSD == nil)

        let regional = await LocalDailyUsageScanner().scan(
            providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
            homeDirectory: home, pricingCatalog: try catalog("eu.anthropic.claude-sonnet-4-6")
        )
        #expect(abs((regional?.today?.valueUSD ?? 0) - (1000 * 3e-6 + 100 * 15e-6)) < 1e-12)
    }

    @Test
    func scannerTotalsTokensAndPricesKnownBackends() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let session = [
            Self.line(["type": "session", "id": "pi-session"]),
            Self.assistant(
                id: "m1", provider: "anthropic", model: "claude-sonnet-4-5", at: now.addingTimeInterval(-60),
                usage: ["input": 1000, "cacheRead": 2000, "cacheWrite": 400, "output": 100]
            ),
        ].joined(separator: "\n") + "\n"
        try Data(session.utf8).write(to: directory.appending(path: "a.jsonl"))
        // 分叉出的会话文件带着同一条历史，不能重复计算。
        try Data(session.utf8).write(to: directory.appending(path: "b.jsonl"))

        let scanner = LocalDailyUsageScanner()
        let priced = await scanner.scan(
            providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
            homeDirectory: home
        )
        #expect(priced?.today?.tokens == 3500)
        #expect(abs((priced?.today?.valueUSD ?? 0) - 0.0066) < 0.000_000_1)

        let unknown = Self.assistant(
            id: "m2", provider: "openrouter", model: "x/y", at: now.addingTimeInterval(-30), usage: ["input": 5, "output": 5]
        )
        try Data((session + unknown + "\n").utf8).write(to: directory.appending(path: "c.jsonl"))
        let mixed = await scanner.scan(
            providerID: ProviderID(rawValue: "pi"), currentWeekStart: now.addingTimeInterval(-86_400), now: now,
            homeDirectory: home
        )
        #expect(mixed?.today?.tokens == 3510)
        #expect(mixed?.today?.valueUSD == nil)
    }
}
