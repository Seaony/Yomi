import CoreServices
import Foundation

@MainActor
final class CodingActivityMonitor {
    private let roots: [URL]
    private let latency: TimeInterval
    private let onActivity: @MainActor (Date) -> Void
    private var stream: FSEventStreamRef?
    private(set) var lastActivityAt: Date?

    var isRunning: Bool { stream != nil }

    init(
        roots: [URL]? = nil,
        latency: TimeInterval = 5,
        onActivity: @escaping @MainActor (Date) -> Void
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? (
            LocalDailyUsageScanner.claudeProjectRoots(homeDirectory: home)
                + LocalDailyUsageScanner.codexSessionRoots(homeDirectory: home)
        )
        self.latency = latency
        self.onActivity = onActivity
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        guard stream == nil else { return }
        let paths = roots.filter { root in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.map(\.path)
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            let writes = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
            )
            let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            guard let info, (0..<count).contains(where: {
                flags[$0] & file != 0 && flags[$0] & writes != 0
            }) else { return }
            // 回调只在主队列上执行，停止监听后不会继续改活动时间。
            MainActor.assumeIsolated {
                let monitor = Unmanaged<CodingActivityMonitor>.fromOpaque(info).takeUnretainedValue()
                guard monitor.isRunning else { return }
                let now = Date()
                monitor.lastActivityAt = now
                monitor.onActivity(now)
            }
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
