import Foundation
import Testing
@testable import Yomi

struct LocalUsageCacheStoreTests {
    @Test
    func isolatedCachesRetainPersistenceWithoutSharingRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(LocalUsageCacheStore(directoryURL: directory.appending(path: "first")))
        let second = try #require(LocalUsageCacheStore(directoryURL: directory.appending(path: "second")))
        first.commit(provider: "codex", records: [
            .init(path: "/fixture/session.jsonl", fileID: "fixture", modificationNanoseconds: 1,
                  size: 1, payload: Data("fixture".utf8)),
        ], deletingPaths: [])
        #expect(first.records(provider: "codex").count == 1)
        #expect(second.records(provider: "codex").isEmpty)
        let restored = try #require(LocalUsageCacheStore(directoryURL: directory.appending(path: "first")))
        #expect(restored.records(provider: "codex").count == 1)
    }

}
