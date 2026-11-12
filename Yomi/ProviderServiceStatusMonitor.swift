import Combine
import Foundation

@MainActor
final class ProviderServiceStatusMonitor: ObservableObject {
    typealias Fetcher = @Sendable (ProviderServiceStatusSource) async throws -> ProviderServiceStatus

    static let settingKey = "show-service-incidents"
    static let defaultEnabled = true

    @Published private(set) var statusByID: [ProviderID: ProviderServiceStatus] = [:]

    private struct Request: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let defaults: UserDefaults
    private let fetcher: Fetcher
    private var providerIDs: () -> [ProviderID] = { [] }
    private var usageInterval: () -> TimeInterval = { 300 }
    private var isRunning = false
    private var enabled: Bool
    private var generation = 0
    private var attemptedAtBySource: [ProviderServiceStatusSource: Date] = [:]
    private var inFlight: [ProviderServiceStatusSource: Request] = [:]
    private var pollTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        fetcher: @escaping Fetcher = { try await ProviderServiceStatusMonitor.fetchStatus($0) }
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        enabled = defaults.object(forKey: Self.settingKey) == nil
            ? Self.defaultEnabled : defaults.bool(forKey: Self.settingKey)
    }

    deinit {
        pollTask?.cancel()
        for request in inFlight.values { request.task.cancel() }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func start(providerIDs: @escaping () -> [ProviderID], usageInterval: @escaping () -> TimeInterval) {
        self.providerIDs = providerIDs
        self.usageInterval = usageInterval
        guard !isRunning else {
            providersDidChange()
            return
        }
        isRunning = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesDidChange() }
        }
        synchronizeEnabled()
        reconcileProviders()
        schedulePoll()
    }

    func stop() {
        isRunning = false
        cancelRequests()
        statusByID.removeAll()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        providerIDs = { [] }
        usageInterval = { 300 }
    }

    func providersDidChange() {
        guard isRunning else { return }
        synchronizeEnabled()
        reconcileProviders()
        schedulePoll()
    }

    func status(for providerID: ProviderID) -> ProviderServiceStatus? {
        guard isRunning, isEnabled, sourcesByProvider()[providerID] != nil else { return nil }
        return statusByID[providerID]
    }

    func refresh(now: Date = Date()) async {
        guard isRunning else { return }
        synchronizeEnabled()
        guard enabled else { return }
        reconcileProviders()
        let interval = max(300, usageInterval())
        let sources = Set(sourcesByProvider().values)
        var tasks: [Task<Void, Never>] = []
        for source in sources {
            if let request = inFlight[source] {
                tasks.append(request.task)
                continue
            }
            guard attemptedAtBySource[source].map({ now.timeIntervalSince($0) >= interval }) ?? true else { continue }
            // 成功和失败都占用同一个间隔，开关来回切换也不能绕过限频。
            attemptedAtBySource[source] = now
            let requestID = UUID()
            let requestGeneration = generation
            let fetcher = fetcher
            let task = Task { @MainActor [weak self] in
                let result = try? await fetcher(source)
                self?.finish(source: source, requestID: requestID, generation: requestGeneration,
                             status: result, cancelled: Task.isCancelled)
            }
            inFlight[source] = Request(id: requestID, task: task)
            tasks.append(task)
        }
        for task in tasks { await task.value }
        schedulePoll()
    }

    private var isEnabled: Bool {
        defaults.object(forKey: Self.settingKey) == nil
            ? Self.defaultEnabled : defaults.bool(forKey: Self.settingKey)
    }

    private func sourcesByProvider() -> [ProviderID: ProviderServiceStatusSource] {
        Dictionary(uniqueKeysWithValues: Set(providerIDs()).compactMap { id in
            ProviderServiceStatusSource.source(for: id).map { (id, $0) }
        })
    }

    private func preferencesDidChange() {
        guard isRunning else { return }
        synchronizeEnabled()
        reconcileProviders()
        schedulePoll()
    }

    private func synchronizeEnabled() {
        let current = isEnabled
        guard current != enabled else { return }
        enabled = current
        if !enabled {
            cancelRequests()
            statusByID.removeAll()
        }
    }

    private func reconcileProviders() {
        guard enabled else { return }
        let active = sourcesByProvider()
        let activeSources = Set(active.values)
        var knownBySource: [ProviderServiceStatusSource: ProviderServiceStatus] = [:]
        for (id, status) in statusByID {
            if let source = ProviderServiceStatusSource.source(for: id) { knownBySource[source] = status }
        }
        // 同源新增或切换 Provider 时复用当前提示，来源完全停用后就不再保留。
        var visible: [ProviderID: ProviderServiceStatus] = [:]
        for (id, source) in active { visible[id] = knownBySource[source] }
        if visible != statusByID { statusByID = visible }
        let cancelled = inFlight.keys.filter { !activeSources.contains($0) }
        for source in cancelled { inFlight.removeValue(forKey: source)?.task.cancel() }
    }

    private func finish(
        source: ProviderServiceStatusSource,
        requestID: UUID,
        generation: Int,
        status: ProviderServiceStatus?,
        cancelled: Bool
    ) {
        guard inFlight[source]?.id == requestID else { return }
        inFlight.removeValue(forKey: source)
        guard !cancelled, isRunning, enabled, isEnabled, self.generation == generation else { return }
        for (id, currentSource) in sourcesByProvider() where currentSource == source {
            // 请求失败就撤掉该来源的提示，不能把旧故障当作当前故障。
            statusByID[id] = status
        }
    }

    private func cancelRequests() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
    }

    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = nil
        guard isRunning, enabled, isEnabled else { return }
        let now = Date()
        let interval = max(300, usageInterval())
        let next = Set(sourcesByProvider().values).filter { inFlight[$0] == nil }.map { source in
            attemptedAtBySource[source]?.addingTimeInterval(interval) ?? now
        }.min()
        guard let next else { return }
        pollTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSince(now)))) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private nonisolated static func fetchStatus(_ source: ProviderServiceStatusSource) async throws -> ProviderServiceStatus {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await ProviderServiceStatusFetcher.fetch(source: source, session: session)
    }
}
