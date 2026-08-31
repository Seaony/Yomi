import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var usageByID: [ProviderID: ProviderUsage] = [:]
    @Published private(set) var isRefreshing = false

    let preferences: ProviderPreferences
    private let collector: UsageCollector
    private let defaults: UserDefaults
    private let cacheKey = "usage-cache.v1"
    private var refreshLoop: Task<Void, Never>?
    private var preferenceObserver: AnyCancellable?

    var enabledProviders: [ProviderDescriptor] {
        let enabled = Set(preferences.configurations.filter(\.isEnabled).map(\.id))
        return ProviderCatalog.all.filter { enabled.contains($0.id) }
    }

    init(
        preferences: ProviderPreferences? = nil,
        collector: UsageCollector = UsageCollector(),
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences ?? .shared
        self.collector = collector
        self.defaults = defaults
        restoreCache()
        preferenceObserver = self.preferences.$configurations
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    deinit {
        refreshLoop?.cancel()
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                let storedInterval = self?.defaults.object(forKey: "refresh-interval") as? Double
                let resolvedInterval = max(60, storedInterval ?? 300)
                try? await Task.sleep(for: .seconds(resolvedInterval), tolerance: .seconds(20))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let jobs = enabledProviders.map { descriptor in
            let configuration = preferences.configuration(for: descriptor.id)
            let secret = preferences.secret(for: descriptor.id)
            return (descriptor, configuration, secret)
        }

        for job in jobs {
            usageByID[job.0.id] = ProviderUsage(
                id: job.0.id,
                state: .loading,
                windows: usageByID[job.0.id]?.windows ?? [],
                balance: usageByID[job.0.id]?.balance,
                plan: usageByID[job.0.id]?.plan,
                updatedAt: usageByID[job.0.id]?.updatedAt,
                message: nil
            )
        }

        await withTaskGroup(of: ProviderUsage.self) { group in
            let concurrencyLimit = 6
            var nextJobIndex = 0

            func submit(_ job: (ProviderDescriptor, ProviderConfiguration, String)) {
                let (descriptor, configuration, secret) = job
                group.addTask { [collector] in
                    do {
                        return try await collector.collect(
                            descriptor: descriptor,
                            configuration: configuration,
                            secret: secret
                        )
                    } catch {
                        return ProviderUsage(
                            id: descriptor.id,
                            state: .failed,
                            windows: [],
                            balance: nil,
                            plan: nil,
                            updatedAt: Date(),
                            message: error.localizedDescription
                        )
                    }
                }
            }

            while nextJobIndex < min(concurrencyLimit, jobs.count) {
                submit(jobs[nextJobIndex])
                nextJobIndex += 1
            }

            while let usage = await group.next() {
                if usage.state == .failed, var cached = usageByID[usage.id], !cached.windows.isEmpty {
                    cached.state = .unavailable
                    cached.message = usage.message
                    usageByID[usage.id] = cached
                } else {
                    usageByID[usage.id] = usage
                }

                if nextJobIndex < jobs.count {
                    submit(jobs[nextJobIndex])
                    nextJobIndex += 1
                }
            }
        }
        persistCache()
    }

    func usage(for id: ProviderID) -> ProviderUsage {
        usageByID[id] ?? ProviderUsage(
            id: id,
            state: .unavailable,
            windows: [],
            balance: nil,
            plan: nil,
            updatedAt: nil,
            message: "等待首次刷新"
        )
    }

    private func restoreCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([ProviderUsage].self, from: data) else { return }
        usageByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
    }

    private func persistCache() {
        let values = Array(usageByID.values).filter { !$0.windows.isEmpty }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}
