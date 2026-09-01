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
    private let cacheKey = "usage-cache.v2"
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
                self?.objectWillChange.send()
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

    func refresh(providerID: ProviderID? = nil) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = enabledProviders.filter { providerID == nil || $0.id == providerID }
        let jobs = providers.map { descriptor in
            let configuration = preferences.configuration(for: descriptor.id)
            let secret = preferences.secret(for: descriptor.id)
            return (descriptor, configuration, secret)
        }
        let allowVertexClaudeFallback = !enabledProviders.contains { $0.id.rawValue == "claude" }

        var loadingUsage = usageByID
        for job in jobs {
            loadingUsage[job.0.id] = ProviderUsage(
                id: job.0.id,
                state: .loading,
                windows: loadingUsage[job.0.id]?.windows ?? [],
                additionalWindows: loadingUsage[job.0.id]?.additionalWindows ?? [],
                balance: loadingUsage[job.0.id]?.balance,
                plan: loadingUsage[job.0.id]?.plan,
                today: loadingUsage[job.0.id]?.today,
                last30Days: loadingUsage[job.0.id]?.last30Days,
                weeklyEstimate: loadingUsage[job.0.id]?.weeklyEstimate,
                providerCost: loadingUsage[job.0.id]?.providerCost,
                details: loadingUsage[job.0.id]?.details ?? [],
                commandCodeSubscriptionEnrichmentUnavailable:
                    loadingUsage[job.0.id]?.commandCodeSubscriptionEnrichmentUnavailable ?? false,
                commandCodeHasSubscriptionPlan:
                    loadingUsage[job.0.id]?.commandCodeHasSubscriptionPlan ?? false,
                commandCodeMonthlyGrantDepleted:
                    loadingUsage[job.0.id]?.commandCodeMonthlyGrantDepleted ?? false,
                updatedAt: loadingUsage[job.0.id]?.updatedAt,
                message: nil
            )
        }
        usageByID = loadingUsage
        var refreshedUsage = loadingUsage

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
                            secret: secret,
                            allowVertexClaudeFallback: allowVertexClaudeFallback,
                            allowBrowserCookieImport: providerID != nil
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
                let resolvedUsage = Self.commandCodeUsageResolvingDepletionOnEnrichmentFailure(
                    current: usage,
                    previous: refreshedUsage[usage.id]
                )
                if resolvedUsage.state == .failed,
                   var cached = refreshedUsage[resolvedUsage.id],
                   !cached.windows.isEmpty {
                    if let descriptor = ProviderCatalog.byID[usage.id] {
                        cached = await collector.enrichLocalMetadata(
                            to: cached,
                            descriptor: descriptor,
                            allowVertexClaudeFallback: allowVertexClaudeFallback
                        )
                    }
                    cached.state = .unavailable
                    cached.message = resolvedUsage.message
                    refreshedUsage[resolvedUsage.id] = cached
                } else {
                    refreshedUsage[resolvedUsage.id] = resolvedUsage
                }

                if nextJobIndex < jobs.count {
                    submit(jobs[nextJobIndex])
                    nextJobIndex += 1
                }
            }
        }
        usageByID = refreshedUsage
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
            message: AppLocalization.text("等待首次刷新", "Waiting for the first refresh")
        )
    }

    private func restoreCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([ProviderUsage].self, from: data) else { return }
        let sanitized = cached.map(Self.sanitizeCachedUsage)
        usageByID = Dictionary(uniqueKeysWithValues: sanitized.map { ($0.id, $0) })
    }

    private static func sanitizeCachedUsage(_ usage: ProviderUsage) -> ProviderUsage {
        guard usage.id.rawValue == "codex" else { return usage }
        var sanitized = usage
        let weekly = (sanitized.windows + sanitized.additionalWindows)
            .first { $0.label == "Weekly" }
        sanitized.windows = weekly.map { [$0] } ?? []
        sanitized.additionalWindows = []
        return sanitized
    }

    nonisolated static func commandCodeUsageResolvingDepletionOnEnrichmentFailure(
        current: ProviderUsage,
        previous: ProviderUsage?
    ) -> ProviderUsage {
        guard current.id.rawValue == "commandcode" else { return current }
        let previousMonthly = previous?.windows.first { $0.id == "commandcode-monthly" }
        let previousProvesPaidDepletion = previous?.commandCodeHasSubscriptionPlan == true
            || (previous?.commandCodeSubscriptionEnrichmentUnavailable == true
                && previous?.commandCodeMonthlyGrantDepleted == true
                && previousMonthly?.clampedFraction == 1)
        guard current.commandCodeSubscriptionEnrichmentUnavailable,
              current.commandCodeMonthlyGrantDepleted,
              previousProvesPaidDepletion,
              var depleted = previousMonthly else { return current }
        depleted.usedFraction = 1
        var resolved = current
        if let index = resolved.windows.firstIndex(where: { $0.id == "commandcode-monthly" }) {
            resolved.windows[index] = depleted
        } else {
            resolved.windows.append(depleted)
        }
        return resolved
    }

    private func persistCache() {
        let values = Array(usageByID.values).filter { !$0.windows.isEmpty }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}
