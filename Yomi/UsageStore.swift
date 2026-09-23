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
    private var pendingFullRefresh = false
    private var pendingProviderIDs: Set<ProviderID> = []

    private enum RefreshRequest {
        case all
        case provider(ProviderID)

        var providerID: ProviderID? {
            switch self {
            case .all: nil
            case let .provider(id): id
            }
        }
    }

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
        let request = providerID.map(RefreshRequest.provider) ?? .all
        guard !isRefreshing else {
            enqueue(request)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var nextRequest: RefreshRequest? = request
        while let currentRequest = nextRequest {
            await performRefresh(providerID: currentRequest.providerID)
            nextRequest = dequeueRefresh()
        }
    }

    private func enqueue(_ request: RefreshRequest) {
        switch request {
        case .all:
            pendingFullRefresh = true
        case let .provider(id):
            pendingProviderIDs.insert(id)
        }
    }

    private func dequeueRefresh() -> RefreshRequest? {
        if pendingFullRefresh {
            pendingFullRefresh = false
            return .all
        }
        guard let id = pendingProviderIDs.first else { return nil }
        pendingProviderIDs.remove(id)
        return .provider(id)
    }

    private func performRefresh(providerID: ProviderID?) async {
        let providers = enabledProviders.filter { providerID == nil || $0.id == providerID }
        let preferences = preferences
        let jobs = providers.map { descriptor in
            (descriptor, preferences.configuration(for: descriptor.id))
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
                todayDate: loadingUsage[job.0.id]?.todayDate,
                todayRequests: loadingUsage[job.0.id]?.todayRequests,
                last30DaysRequests: loadingUsage[job.0.id]?.last30DaysRequests,
                last30Days: loadingUsage[job.0.id]?.last30Days,
                last30DaysDaily: loadingUsage[job.0.id]?.last30DaysDaily ?? [],
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

            func submit(_ job: (ProviderDescriptor, ProviderConfiguration)) {
                let (descriptor, configuration) = job
                group.addTask { [collector] in
                    do {
                        let secret = preferences.secret(for: descriptor.id)
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
                   Self.hasCacheableData(cached) {
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

                usageByID[usage.id] = refreshedUsage[usage.id]

                if nextJobIndex < jobs.count {
                    submit(jobs[nextJobIndex])
                    nextJobIndex += 1
                }
            }
        }
        persistCache()
    }

    func usage(for id: ProviderID) -> ProviderUsage {
        Self.usageForCurrentDay(usageByID[id] ?? ProviderUsage(
            id: id,
            state: .unavailable,
            windows: [],
            balance: nil,
            plan: nil,
            updatedAt: nil,
            message: AppLocalization.text("等待首次刷新", "Waiting for the first refresh")
        ))
    }

    nonisolated static func usageForCurrentDay(
        _ usage: ProviderUsage,
        now: Date = Date()
    ) -> ProviderUsage {
        guard let todayDate = usage.todayDate ?? usage.updatedAt,
              Calendar.current.isDate(todayDate, inSameDayAs: now) else {
            var resolved = usage
            resolved.today = nil
            resolved.todayRequests = nil
            return resolved
        }
        return usage
    }

    var overviewUsage: ProviderUsage {
        let usages = enabledProviders.map { usage(for: $0.id) }
        let today = Self.combinedUsage(usages.compactMap {
            $0.today ?? $0.todayRequests.map { DailyTokenUsage(tokens: 0, valueUSD: $0.valueUSD) }
        })
        let daily = Self.overviewDailyUsage(usages: usages)
        let last30Days = Self.combinedLast30DaysUsage(usages)
        let isFullRefresh = !enabledProviders.isEmpty
            && enabledProviders.allSatisfy { usage(for: $0.id).state == .loading }
        let hasUsage = today != nil || last30Days != nil || !daily.isEmpty
        let hasStaleUsage = usages.contains { $0.state == .unavailable || $0.state == .failed }
        return ProviderUsage(
            id: ProviderCatalog.overview.id,
            state: isFullRefresh ? .loading : (hasUsage && !hasStaleUsage ? .ready : .unavailable),
            windows: [],
            today: today,
            last30Days: last30Days,
            last30DaysDaily: daily,
            updatedAt: hasStaleUsage
                ? usages.compactMap(\.updatedAt).min()
                : usages.compactMap(\.updatedAt).max(),
            message: hasUsage
                ? (hasStaleUsage ? AppLocalization.text("部分 Provider 数据未能刷新", "Some provider data could not be refreshed") : nil)
                : AppLocalization.text("等待首次用量数据", "Waiting for usage data")
        )
    }

    private nonisolated static func combinedUsage(_ usages: [DailyTokenUsage]) -> DailyTokenUsage? {
        guard !usages.isEmpty else { return nil }
        let tokens = usages.reduce(Int64.zero) { $0 + $1.tokens }
        let hasUnpricedTokens = usages.contains { $0.tokens > 0 && $0.valueUSD == nil }
        let valueUSD = hasUnpricedTokens
            ? nil
            : usages.reduce(0.0) { $0 + ($1.valueUSD ?? 0) }
        return DailyTokenUsage(tokens: tokens, valueUSD: valueUSD)
    }

    nonisolated static func combinedLast30DaysUsage(
        _ usages: [ProviderUsage]
    ) -> DailyTokenUsage? {
        combinedUsage(usages.compactMap { usage in
            usage.last30Days
                ?? usage.last30DaysRequests.map { DailyTokenUsage(tokens: 0, valueUSD: $0.valueUSD) }
                ?? combinedUsage(usage.last30DaysDaily.map(\.usage))
        })
    }

    nonisolated static func overviewDailyUsage(
        usages: [ProviderUsage],
        now: Date = Date()
    ) -> [DailyTokenUsagePoint] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -29, to: todayStart) else {
            return []
        }
        var valuesByDay: [Date: [ProviderID: [DailyTokenUsage]]] = [:]
        for usage in usages {
            for point in usage.last30DaysDaily {
                let day = calendar.startOfDay(for: point.date)
                guard day >= start, day <= todayStart else { continue }
                valuesByDay[day, default: [:]][usage.id, default: []].append(point.usage)
            }
            let current = usageForCurrentDay(usage, now: now)
            if let today = current.today
                ?? current.todayRequests.map({ DailyTokenUsage(tokens: 0, valueUSD: $0.valueUSD) }) {
                valuesByDay[todayStart, default: [:]][usage.id] = [today]
            }
        }
        guard !valuesByDay.isEmpty else { return [] }
        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let providerBreakdown = (valuesByDay[date] ?? [:]).compactMap {
                providerID,
                usages -> ProviderTokenUsageBreakdown? in
                combinedUsage(usages).map {
                    ProviderTokenUsageBreakdown(providerID: providerID, usage: $0)
                }
            }.sorted { lhs, rhs in
                if lhs.usage.tokens != rhs.usage.tokens {
                    return lhs.usage.tokens > rhs.usage.tokens
                }
                return lhs.providerID.rawValue < rhs.providerID.rawValue
            }
            return DailyTokenUsagePoint(
                date: date,
                usage: combinedUsage(providerBreakdown.map(\.usage))
                    ?? DailyTokenUsage(tokens: 0, valueUSD: 0),
                providerBreakdown: providerBreakdown
            )
        }
    }

    private func restoreCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([ProviderUsage].self, from: data) else { return }
        let sanitized = cached.map(Self.sanitizeCachedUsage)
        usageByID = Dictionary(uniqueKeysWithValues: sanitized.map { ($0.id, $0) })
    }

    private static func sanitizeCachedUsage(_ usage: ProviderUsage) -> ProviderUsage {
        var sanitized = usage
        sanitized.state = .unavailable
        if sanitized.id.rawValue == "opencodego" {
            if sanitized.todayRequests == nil,
               let today = sanitized.today, let cost = today.valueUSD {
                sanitized.todayRequests = DailyRequestUsage(requests: today.tokens, valueUSD: cost)
            }
            if sanitized.last30DaysRequests == nil,
               let last30Days = sanitized.last30Days, let cost = last30Days.valueUSD {
                sanitized.last30DaysRequests = DailyRequestUsage(requests: last30Days.tokens, valueUSD: cost)
            }
            sanitized.today = nil
            sanitized.last30Days = nil
        }
        guard usage.id.rawValue == "codex" else { return sanitized }
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

    nonisolated static func hasCacheableData(_ usage: ProviderUsage) -> Bool {
        !usage.windows.isEmpty
            || !usage.additionalWindows.isEmpty
            || usage.balance != nil
            || usage.plan != nil
            || usage.today != nil
            || usage.todayRequests != nil
            || usage.last30DaysRequests != nil
            || usage.last30Days != nil
            || !usage.last30DaysDaily.isEmpty
            || usage.weeklyEstimate != nil
            || usage.providerCost != nil
            || !usage.details.isEmpty
    }

    private func persistCache() {
        let values = Array(usageByID.values).filter(Self.hasCacheableData)
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}
