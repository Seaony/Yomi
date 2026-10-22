import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var usageByID: [ProviderID: ProviderUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private var magpieClaudeAccounts: [MagpieClaudeAccount] = []

    let preferences: ProviderPreferences
    private let collector: UsageCollector
    private let defaults: UserDefaults
    private let cacheKey = "usage-cache.v3"
    private var refreshLoop: Task<Void, Never>?
    private var preferenceObserver: AnyCancellable?
    private var credentialObserver: AnyCancellable?
    private var usageRevisions: [ProviderID: Int] = [:]
    private var pendingFullRefresh: Bool?
    private var pendingProviderIDs: [ProviderID: Bool] = [:]

    private struct CachedUsage: Codable {
        let usage: ProviderUsage
        let revision: Int
    }

    private enum RefreshRequest {
        case all(Bool)
        case provider(ProviderID, Bool)

        var providerID: ProviderID? {
            switch self {
            case .all: nil
            case let .provider(id, _): id
            }
        }

        var allowBrowserCookieImport: Bool {
            switch self {
            case let .all(allowed), let .provider(_, allowed): allowed
            }
        }
    }

    var enabledProviders: [ProviderDescriptor] {
        let enabled = Set(preferences.configurations.filter(\.isEnabled).map(\.id))
        return ProviderCatalog.all.filter { enabled.contains($0.id) }
    }

    var displayedProviders: [ProviderDescriptor] {
        enabledProviders.flatMap { descriptor in
            descriptor.id.rawValue == "claude" && usesMagpieClaudeAccounts
                ? magpieClaudeAccounts.map(\.descriptor)
                : [descriptor]
        }
    }

    private var usesMagpieClaudeAccounts: Bool {
        let configuration = preferences.configuration(for: ProviderID(rawValue: "claude"))
        return !magpieClaudeAccounts.isEmpty
            && (configuration.source == .automatic || configuration.source == .account)
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
        credentialObserver = self.preferences.usageInvalidated
            .sink { [weak self] id in
                guard let self else { return }
                self.usageByID.removeValue(forKey: id)
                self.usageRevisions.removeValue(forKey: id)
                if id.rawValue == "claude" {
                    self.magpieClaudeAccounts = []
                    self.usageByID = self.usageByID.filter { !$0.key.isMagpieClaudeAccount }
                    self.usageRevisions = self.usageRevisions.filter { !$0.key.isMagpieClaudeAccount }
                }
                self.persistCache()
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

    func refresh(providerID: ProviderID? = nil, allowBrowserCookieImport: Bool = false) async {
        let request = providerID.map { RefreshRequest.provider($0, allowBrowserCookieImport) }
            ?? .all(allowBrowserCookieImport)
        guard !isRefreshing else {
            enqueue(request)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var nextRequest: RefreshRequest? = request
        while let currentRequest = nextRequest {
            let scope = BrowserCookieAccess.Scope(allowInteraction: currentRequest.allowBrowserCookieImport)
            await BrowserCookieAccess.$scope.withValue(scope) {
                await performRefresh(
                    providerID: currentRequest.providerID,
                    allowBrowserCookieImport: currentRequest.allowBrowserCookieImport
                )
            }
            nextRequest = dequeueRefresh()
        }
    }

    private func enqueue(_ request: RefreshRequest) {
        switch request {
        case let .all(allowed):
            pendingFullRefresh = (pendingFullRefresh ?? false) || allowed
        case let .provider(id, allowed):
            pendingProviderIDs[id] = (pendingProviderIDs[id] ?? false) || allowed
        }
    }

    private func dequeueRefresh() -> RefreshRequest? {
        if let allowed = pendingFullRefresh {
            pendingFullRefresh = nil
            return .all(allowed)
        }
        guard let (id, allowed) = pendingProviderIDs.first else { return nil }
        pendingProviderIDs.removeValue(forKey: id)
        return .provider(id, allowed)
    }

    private func performRefresh(providerID: ProviderID?, allowBrowserCookieImport: Bool) async {
        let claudeID = ProviderID(rawValue: "claude")
        if providerID == nil || providerID?.catalogID == claudeID {
            let configuration = preferences.configuration(for: claudeID)
            if configuration.isEnabled,
               configuration.source == .automatic || configuration.source == .account,
               preferences.secret(for: claudeID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let accounts = try? MagpieClaudeAccounts.accounts() {
                    magpieClaudeAccounts = accounts
                }
            } else {
                magpieClaudeAccounts = []
            }
            let accountIDs = Set(magpieClaudeAccounts.map(\.id))
            usageByID = usageByID.filter { !$0.key.isMagpieClaudeAccount || accountIDs.contains($0.key) }
            usageRevisions = usageRevisions.filter { !$0.key.isMagpieClaudeAccount || accountIDs.contains($0.key) }
        }
        let magpieDescriptors = usesMagpieClaudeAccounts ? magpieClaudeAccounts.map(\.descriptor) : []
        let requestedID = providerID?.isMagpieClaudeAccount == true && !usesMagpieClaudeAccounts
            ? claudeID : providerID
        let providers = (enabledProviders + magpieDescriptors).filter {
            requestedID == nil || $0.id == requestedID
                || (requestedID == claudeID && $0.id.isMagpieClaudeAccount)
        }
        let preferences = preferences
        let jobs = providers.map { descriptor in
            (descriptor, preferences.configuration(for: descriptor.id.catalogID))
        }
        let revisions = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.id, preferences.usageRevision(for: $0.id.catalogID))
        })
        let claudeLocalStatisticsOnly = usesMagpieClaudeAccounts
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
                codexResetCredits: loadingUsage[job.0.id]?.codexResetCredits,
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

        await withTaskGroup(of: (ProviderUsage, Int).self) { group in
            let concurrencyLimit = 6
            var nextJobIndex = 0

            func submit(_ job: (ProviderDescriptor, ProviderConfiguration)) {
                let (descriptor, configuration) = job
                let revision = revisions[descriptor.id]!
                group.addTask { [collector] in
                    do {
                        if descriptor.id.isMagpieClaudeAccount {
                            return (try await collector.collectMagpieClaudeUsage(for: descriptor.id), revision)
                        }
                        if descriptor.id.rawValue == "claude", claudeLocalStatisticsOnly {
                            // 本地日志没有账号标识，只计入总览一次。
                            let usage = await collector.enrichLocalMetadata(
                                to: ProviderUsage(id: descriptor.id, state: .ready, windows: [], updatedAt: Date()),
                                descriptor: descriptor
                            )
                            return (usage, revision)
                        }
                        let secret = try await MainActor.run {
                            guard revision == preferences.usageRevision(for: descriptor.id) else {
                                throw CancellationError()
                            }
                            return preferences.secret(for: descriptor.id)
                        }
                        let usage = try await collector.collect(
                            descriptor: descriptor,
                            configuration: configuration,
                            secret: secret,
                            allowVertexClaudeFallback: allowVertexClaudeFallback,
                            allowBrowserCookieImport: allowBrowserCookieImport,
                            usageRevision: revision
                        )
                        return (usage, revision)
                    } catch {
                        return (ProviderUsage(
                            id: descriptor.id,
                            state: .failed,
                            windows: [],
                            balance: nil,
                            plan: nil,
                            updatedAt: Date(),
                            message: error.localizedDescription
                        ), revision)
                    }
                }
            }

            while nextJobIndex < min(concurrencyLimit, jobs.count) {
                submit(jobs[nextJobIndex])
                nextJobIndex += 1
            }

            while let (usage, revision) = await group.next() {
                if revision == preferences.usageRevision(for: usage.id.catalogID) {
                    let resolvedUsage = Self.commandCodeUsageResolvingDepletionOnEnrichmentFailure(
                        current: usage,
                        previous: refreshedUsage[usage.id]
                    )
                    if resolvedUsage.state == .failed,
                       var cached = refreshedUsage[resolvedUsage.id],
                       Self.hasCacheableData(cached) {
                        if cached.id.rawValue == "zai" {
                            cached = Self.sanitizeCachedUsage(cached)
                        }
                        if let descriptor = ProviderCatalog.byID[usage.id] {
                            cached = await collector.enrichLocalMetadata(
                                to: cached,
                                descriptor: descriptor,
                                allowVertexClaudeFallback: allowVertexClaudeFallback
                            )
                        }
                        cached.codexResetCredits = nil
                        cached.state = .unavailable
                        cached.message = resolvedUsage.message
                        refreshedUsage[resolvedUsage.id] = cached
                    } else {
                        refreshedUsage[resolvedUsage.id] = resolvedUsage
                    }

                    if revision == preferences.usageRevision(for: usage.id.catalogID) {
                        usageByID[usage.id] = refreshedUsage[usage.id]
                        usageRevisions[usage.id] = revision
                    }
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
        var usage = Self.usageForCurrentDay(usageByID[id] ?? ProviderUsage(
            id: id,
            state: .unavailable,
            windows: [],
            balance: nil,
            plan: nil,
            updatedAt: nil,
            message: AppLocalization.text("等待首次刷新", "Waiting for the first refresh")
        ))
        if id.rawValue == "claude", usesMagpieClaudeAccounts {
            let accounts = magpieClaudeAccounts.map { self.usage(for: $0.id) }
            if accounts.contains(where: { $0.state == .loading }) {
                usage.state = .loading
                usage.message = nil
            } else if accounts.contains(where: { $0.state != .ready }) {
                usage.state = .unavailable
                usage.message = AppLocalization.text(
                    "部分 Claude 账号用量未能刷新", "Usage could not be refreshed for some Claude accounts"
                )
            }
        }
        return usage
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
              let cached = try? JSONDecoder().decode([CachedUsage].self, from: data) else { return }
        let current = cached.filter { $0.revision == preferences.usageRevision(for: $0.usage.id.catalogID) }
        usageRevisions = Dictionary(uniqueKeysWithValues: current.map { ($0.usage.id, $0.revision) })
        let sanitized = current.map { Self.sanitizeCachedUsage($0.usage) }
        usageByID = Dictionary(uniqueKeysWithValues: sanitized.map { ($0.id, $0) })
    }

    private static func sanitizeCachedUsage(_ usage: ProviderUsage) -> ProviderUsage {
        var sanitized = usage
        sanitized.state = .unavailable
        if sanitized.id.rawValue == "zai" {
            let latestReset = Date().addingTimeInterval(5 * 60 * 60 + 60)
            for index in sanitized.windows.indices {
                if sanitized.windows[index].label == "5-hour",
                   let reset = sanitized.windows[index].resetsAt,
                   reset > latestReset {
                    sanitized.windows[index].resetsAt = nil
                }
            }
        }
        if sanitized.id.rawValue == "opencodego" {
            if sanitized.todayRequests == nil,
               let today = sanitized.today, let cost = today.valueUSD {
                sanitized.todayRequests = DailyRequestUsage(requests: today.tokens, valueUSD: cost)
                sanitized.today = nil
            }
            if sanitized.last30DaysRequests == nil,
               let last30Days = sanitized.last30Days, let cost = last30Days.valueUSD {
                sanitized.last30DaysRequests = DailyRequestUsage(requests: last30Days.tokens, valueUSD: cost)
                sanitized.last30Days = nil
            }
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
        let values = usageByID.values.compactMap { usage -> CachedUsage? in
            guard Self.hasCacheableData(usage), let revision = usageRevisions[usage.id],
                  revision == preferences.usageRevision(for: usage.id.catalogID) else { return nil }
            return CachedUsage(usage: usage, revision: revision)
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}
