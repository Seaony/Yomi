import Foundation

nonisolated struct DeepSeekHarnessSessionUsage: Sendable, Equatable {
    let timestamp: Date
    let model: String
    let uncachedInputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int

    var tokens: Int {
        uncachedInputTokens + cacheReadTokens + cacheWriteTokens + outputTokens
    }
}

nonisolated enum DeepSeekHarnessUsageReader {
    static let providerID = "deepseek-official"

    private struct Document: Decodable {
        let record: Record

        struct Record: Decodable {
            let identity: Identity
            let rows: Rows
        }

        struct Identity: Decodable {
            let createdAt: Double?
        }

        struct Rows: Decodable {
            let tokenUsage: TokenUsage?
            let modelSelection: ModelSelection?
            let sessionListMetadata: SessionListMetadata?
        }

        struct TokenUsage: Decodable {
            let val: Value?

            struct Value: Decodable {
                let totals: Totals?
            }

            struct Totals: Decodable {
                let uncachedInputTokens: Int?
                let outputTokens: Int?
                let cacheReadTokens: Int?
                let cacheWriteTokens: Int?
            }
        }

        struct ModelSelection: Decodable {
            let val: Value?

            struct Value: Decodable {
                let lastUsed: Route?
            }

            struct Route: Decodable {
                let provider: String?
                let model: String?
            }
        }

        struct SessionListMetadata: Decodable {
            let val: Value?

            struct Value: Decodable {
                let lastPromptAt: Double?
            }
        }
    }

    static func sessions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        modifiedSince: Date
    ) -> [DeepSeekHarnessSessionUsage] {
        let root = homeDirectory
            .appending(path: ".dsh")
            .appending(path: "storages")
            .appending(path: "session_projcache")
            .appending(path: "sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard url.pathExtension == "json",
                  let modifiedAt = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  modifiedAt >= modifiedSince,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return session(from: data)
        }
    }

    static func session(from data: Data) -> DeepSeekHarnessSessionUsage? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              let totals = document.record.rows.tokenUsage?.val?.totals,
              let route = document.record.rows.modelSelection?.val?.lastUsed,
              route.provider == providerID,
              let model = route.model
        else { return nil }
        let milliseconds = document.record.rows.sessionListMetadata?.val?.lastPromptAt
            ?? document.record.identity.createdAt
        guard let milliseconds, milliseconds > 0 else { return nil }
        return DeepSeekHarnessSessionUsage(
            timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
            model: model,
            uncachedInputTokens: max(0, totals.uncachedInputTokens ?? 0),
            cacheReadTokens: max(0, totals.cacheReadTokens ?? 0),
            cacheWriteTokens: max(0, totals.cacheWriteTokens ?? 0),
            outputTokens: max(0, totals.outputTokens ?? 0)
        )
    }
}
