import Foundation
import Testing
@testable import CodeEdge

@MainActor
struct CodingActivityMonitorTests {
    @Test
    func reportsNewFilesAndAppendWritesInsideSessionDirectories() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var activities: [Date] = []
        let monitor = CodingActivityMonitor(roots: [directory], latency: 0.1) {
            activities.append($0)
        }
        defer { monitor.stop() }
        monitor.start()
        #expect(monitor.isRunning)

        let nested = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("session.jsonl")
        let createdAt = Date()
        try Data("first\n".utf8).write(to: file)
        await waitUntil { activities.last.map { $0 >= createdAt } == true }
        #expect(activities.last.map { $0 >= createdAt } == true)
        #expect(monitor.lastActivityAt == activities.last)

        let appendedAt = Date()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("next\n".utf8))
        try handle.close()
        await waitUntil { activities.last.map { $0 >= appendedAt } == true }
        #expect(activities.last.map { $0 >= appendedAt } == true)
        #expect(monitor.lastActivityAt == activities.last)
    }

    @Test
    func skipsMissingDirectoriesAndStopsReceivingWrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        var activities: [Date] = []
        let monitor = CodingActivityMonitor(roots: [missing], latency: 0.1) {
            activities.append($0)
        }
        monitor.start()
        #expect(!monitor.isRunning)
        #expect(monitor.lastActivityAt == nil)

        let runningMonitor = CodingActivityMonitor(roots: [directory, missing], latency: 0.1) {
            activities.append($0)
        }
        runningMonitor.start()
        #expect(runningMonitor.isRunning)
        runningMonitor.stop()
        #expect(!runningMonitor.isRunning)
        try Data("stopped\n".utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        try await Task.sleep(for: .seconds(1))
        #expect(activities.isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEdge-coding-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
