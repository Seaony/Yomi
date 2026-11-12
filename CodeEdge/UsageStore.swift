import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var usageByID: [ProviderID: ProviderUsage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var backoffByID: [String: ProviderBackoffState] = [:]

    let notifications: QuotaNotificationController
    let preferences: ProviderPreferences
    let serviceStatusMonitor: ProviderServiceStatusMonitor
    private let collector: any UsageCollecting
    private let defaults: UserDefaults
    private let now: () -> Date
    private let powerState: () -> (lowPower: Bool, thermal: ProcessInfo.ThermalState)
    private let cacheKey = "usage-cache.v3"
    private var refreshLoop: Task<Void, Never>?
    private var isStarted = false
    private var refreshSettingsObserver: AnyCancellable?
    private var powerStateObservers: [AnyCancellable] = []
    private var observedRefreshInterval: TimeInterval?
    private var codingActivityMonitor: CodingActivityMonitor?
    private(set) var lastRefreshAt: Date?
    private(set) var nextRefreshAt: Date?
    private(set) var scheduledRefreshInterval: TimeInterval?
    private(set) var lastInteractionAt: Date?
    private(set) var lastCodingActivityAt: Date?
    private var deadlineRefreshTask: Task<Void, Never>?
    private var attemptedResetBoundaries: Set<ResetBoundaryRefreshPolicy.Boundary> = []
    private var lastResetTriggeredAtByProvider: [ProviderID: Date] = [:]
    private var attemptedBackoffRetries: [String: Date] = [:]
    private let backoffKey = "provider-backoff.v1"
    private var preferenceObserver: AnyCancellable?
    private var credentialObserver: AnyCancellable?
    private var serviceStatusObserver: AnyCancellable?
    private var usageRevisions: [ProviderID: Int] = [:]
    private var pendingFullRefresh: RefreshRequest?
    private var pendingProviderIDs: [ProviderID: RefreshRequest] = [:]

    private struct CachedUsage: Codable {
        let usage: ProviderUsage
        let revision: Int
    }

    private struct RefreshRequest {
        var providerID: ProviderID?
        var allowBrowserCookieImport: Bool
        var isManual: Bool
        var resetBoundaries: Set<ResetBoundaryRefreshPolicy.Boundary> = []
    }

    var enabledProviders: [ProviderDescriptor] {
        let enabled = Set(preferences.configurations.filter(\.isEnabled).map(\.id))
        return ProviderCatalog.all.filter { enabled.contains($0.id) }
    }

    init(
        preferences: ProviderPreferences? = nil,
        collector: any UsageCollecting = UsageCollector(),
        defaults: UserDefaults = .standard,
        serviceStatusMonitor: ProviderServiceStatusMonitor? = nil,
        now: @escaping () -> Date = Date.init,
        powerState: @escaping () -> (lowPower: Bool, thermal: ProcessInfo.ThermalState) = {
            (ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState)
        }
    ) {
        self.preferences = preferences ?? .shared
        self.collector = collector
        self.defaults = defaults
        self.now = now
        self.powerState = powerState
        self.notifications = QuotaNotificationController(defaults: defaults)
        self.serviceStatusMonitor = serviceStatusMonitor ?? ProviderServiceStatusMonitor(defaults: defaults)
        backoffByID = defaults.data(forKey: backoffKey).flatMap {
            try? JSONDecoder().decode([String: ProviderBackoffState].self, from: $0)
        } ?? [:]
        restoreCache()
        preferenceObserver = self.preferences.$configurations
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.serviceStatusMonitor.providersDidChange()
                }
            }
        credentialObserver = self.preferences.usageInvalidated
            .sink { [weak self] id in
                guard let self else { return }
                self.usageByID.removeValue(forKey: id)
                self.usageRevisions.removeValue(forKey: id)
                self.persistCache()
            }
        serviceStatusObserver = self.serviceStatusMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        refreshLoop?.cancel()
        deadlineRefreshTask?.cancel()
    }

    #if DEBUG
    /// 生成产品截图时直接填入演示数据，发布版本不包含。
    func showPreviewUsage(_ usages: [ProviderUsage]) {
        usageByID = Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) })
    }
    #endif

    var currentRefreshInterval: TimeInterval {
        let selected = defaults.double(forKey: "refresh-interval")
        return selected == 0 ? 0 : max(60, selected)
    }

    var freshnessRefreshInterval: TimeInterval {
        UsageFreshness.refreshInterval(for: currentRefreshInterval)
    }

    var serviceStatusRefreshInterval: TimeInterval {
        currentRefreshInterval == 0 ? AdaptiveRefreshPolicy.nominalIntervalForHeuristics : currentRefreshInterval
    }

    func noteInteraction(at date: Date = Date()) {
        lastInteractionAt = date
        rescheduleRefresh(onlyIfShorter: true)
    }

    func noteCodingActivity(at date: Date = Date()) {
        lastCodingActivityAt = date
        rescheduleRefresh(onlyIfShorter: true)
    }

    func serviceStatus(for id: ProviderID) -> ProviderServiceStatus? {
        serviceStatusMonitor.status(for: id)
    }

    func backoffDescription(for id: ProviderID, now: Date = Date(), language: AppLanguage) -> String? {
        let remaining = ProviderBackoffPolicy.remaining(state: backoffByID[id.rawValue], now: now)
        guard remaining > 0 else { return nil }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return AppCopy(language: language).text("限流中，\(minutes) 分钟后重试", "Rate limited. Retry in \(minutes) min")
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observedRefreshInterval = currentRefreshInterval
        refreshSettingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.observedRefreshInterval != self.currentRefreshInterval else { return }
                self.observedRefreshInterval = self.currentRefreshInterval
                self.synchronizeCodingActivityMonitor()
                self.objectWillChange.send()
                self.rescheduleRefresh(force: true)
            }
        powerStateObservers = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification].map { name in
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rescheduleRefresh() }
        }
        synchronizeCodingActivityMonitor()
        serviceStatusMonitor.start(
            providerIDs: { [weak self] in self?.enabledProviders.map(\.id) ?? [] },
            usageInterval: { [weak self] in self?.serviceStatusRefreshInterval ?? 300 }
        )
        Task { [weak self] in await self?.refresh() }
    }

    private func synchronizeCodingActivityMonitor() {
        if currentRefreshInterval == 0 {
            if codingActivityMonitor == nil {
                codingActivityMonitor = CodingActivityMonitor { [weak self] date in
                    self?.noteCodingActivity(at: date)
                }
            }
            codingActivityMonitor?.start()
        } else {
            codingActivityMonitor?.stop()
            codingActivityMonitor = nil
        }
    }

    private func rescheduleRefresh(force: Bool = false, onlyIfShorter: Bool = false) {
        guard isStarted, !isRefreshing, let lastRefreshAt else { return }
        let date = now()
        let selected = currentRefreshInterval
        let decision: AdaptiveRefreshPolicy.Decision?
        if selected == 0 {
            let power = powerState()
            decision = AdaptiveRefreshPolicy().nextDelay(for: .init(
                now: date, lastInteractionAt: lastInteractionAt, lastCodingActivityAt: lastCodingActivityAt,
                lowPowerModeEnabled: power.lowPower, thermalState: power.thermal
            ))
        } else {
            decision = nil
        }
        let interval = decision?.interval ?? selected
        if let scheduledRefreshInterval, nextRefreshAt != nil, !force {
            if interval == scheduledRefreshInterval { return }
            if onlyIfShorter, interval > scheduledRefreshInterval { return }
        }
        refreshLoop?.cancel()
        let deadline = lastRefreshAt.addingTimeInterval(interval)
        let delay = max(0, deadline.timeIntervalSince(date))
        scheduledRefreshInterval = interval
        nextRefreshAt = deadline
        let mode = decision.map { decision in
            // 长单词会被通用脱敏规则当作凭据，排期原因用短名称。
            let reason: String
            switch decision.reason {
            case .recentInteraction: reason = "recent"
            case .codingActivity: reason = "coding"
            default: reason = decision.reason.rawValue
            }
            return "mode=auto reason=\(reason)"
        } ?? "mode=fixed"
        DiagnosticLog.shared.write("\(mode) delay=\(Int(ceil(delay)))s", category: .refresh)
        refreshLoop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(20)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshLoop = nil
            self.nextRefreshAt = nil
            await self.refresh()
        }
    }

    private func scheduleDeadlineRefresh() {
        deadlineRefreshTask?.cancel()
        deadlineRefreshTask = nil
        let now = Date()
        let usages = enabledProviders.compactMap { usageByID[$0.id] }
        let plan = ResetBoundaryRefreshPolicy.plan(
            usages: usages, attemptedBoundaries: attemptedResetBoundaries,
            lastTriggeredAtByProvider: lastResetTriggeredAtByProvider, now: now
        )
        let newResetBoundaries = plan.attemptedBoundaries.subtracting(attemptedResetBoundaries)
        attemptedResetBoundaries = plan.attemptedBoundaries
        let retries = ProviderBackoffPolicy.plan(
            stateByID: backoffByID, enabledProviderIDs: Set(enabledProviders.map(\.id)),
            attemptedRetries: attemptedBackoffRetries, now: now
        )
        attemptedBackoffRetries = retries.attemptedRetries
        let ids = plan.dueProviderIDs.union(retries.dueProviderIDs)
        if !ids.isEmpty {
            deadlineRefreshTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.deadlineRefreshTask = nil
                for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
                    guard !Task.isCancelled else { return }
                    let boundaries: Set<ResetBoundaryRefreshPolicy.Boundary> = retries.dueProviderIDs.contains(id)
                        ? [] : Set(newResetBoundaries.filter { $0.providerID == id })
                    await self.refresh(RefreshRequest(providerID: id, allowBrowserCookieImport: false,
                                                      isManual: false, resetBoundaries: boundaries))
                }
                self.scheduleDeadlineRefresh()
            }
            return
        }
        guard let next = [plan.nextDeadline, retries.nextDeadline].compactMap({ $0 }).min() else { return }
        deadlineRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            self.deadlineRefreshTask = nil
            self.scheduleDeadlineRefresh()
        }
    }

    private func persistBackoff() {
        guard let data = try? JSONEncoder().encode(backoffByID) else { return }
        defaults.set(data, forKey: backoffKey)
    }

    func refresh(providerID: ProviderID? = nil, allowBrowserCookieImport: Bool = false, isManual: Bool = false) async {
        if isManual || allowBrowserCookieImport { lastInteractionAt = now() }
        let request = RefreshRequest(providerID: providerID, allowBrowserCookieImport: allowBrowserCookieImport,
                                     isManual: isManual || allowBrowserCookieImport)
        await refresh(request)
    }

    private func refresh(_ request: RefreshRequest) async {
        guard !isRefreshing else {
            enqueue(request)
            return
        }
        isRefreshing = true
        var resetsPeriodicSchedule = false
        defer {
            isRefreshing = false
            if resetsPeriodicSchedule {
                lastRefreshAt = now()
                refreshLoop?.cancel()
                refreshLoop = nil
                nextRefreshAt = nil
            }
            rescheduleRefresh()
        }

        var nextRequest: RefreshRequest? = request
        while let currentRequest = nextRequest {
            // 自动模式手动刷过单张卡片后，从这次完成时间排，避免马上又全量请求一次。
            if currentRequest.providerID == nil || (currentRequest.isManual && currentRefreshInterval == 0) {
                resetsPeriodicSchedule = true
            }
            let scope = BrowserCookieAccess.Scope(allowInteraction: currentRequest.allowBrowserCookieImport)
            await BrowserCookieAccess.$scope.withValue(scope) {
                await performRefresh(
                    providerID: currentRequest.providerID,
                    allowBrowserCookieImport: currentRequest.allowBrowserCookieImport,
                    isManual: currentRequest.isManual,
                    resetBoundaries: currentRequest.resetBoundaries
                )
            }
            nextRequest = dequeueRefresh()
        }
    }

    private func enqueue(_ request: RefreshRequest) {
        if let id = request.providerID {
            var pending = pendingProviderIDs[id] ?? request
            pending.allowBrowserCookieImport = pending.allowBrowserCookieImport || request.allowBrowserCookieImport
            pending.isManual = pending.isManual || request.isManual
            pending.resetBoundaries.formUnion(request.resetBoundaries)
            pendingProviderIDs[id] = pending
        } else {
            var pending = pendingFullRefresh ?? request
            pending.allowBrowserCookieImport = pending.allowBrowserCookieImport || request.allowBrowserCookieImport
            pending.isManual = pending.isManual || request.isManual
            pending.resetBoundaries.formUnion(request.resetBoundaries)
            pendingFullRefresh = pending
        }
    }

    private func dequeueRefresh() -> RefreshRequest? {
        if let request = pendingFullRefresh {
            pendingFullRefresh = nil
            return request
        }
        guard let (id, request) = pendingProviderIDs.first else { return nil }
        pendingProviderIDs.removeValue(forKey: id)
        return request
    }

    private func performRefresh(providerID: ProviderID?, allowBrowserCookieImport: Bool, isManual: Bool,
                                resetBoundaries: Set<ResetBoundaryRefreshPolicy.Boundary>) async {
        if let providerID, !resetBoundaries.isEmpty {
            let now = Date()
            if !isManual, let last = lastResetTriggeredAtByProvider[providerID], now.timeIntervalSince(last) < 60 {
                attemptedResetBoundaries.subtract(resetBoundaries)
                scheduleDeadlineRefresh()
                return
            }
            // 真正开始取数时才记时间，排队等待不能缩短两次请求的间隔。
            lastResetTriggeredAtByProvider[providerID] = now
        }
        DiagnosticLog.shared.write("Refresh started", category: .refresh)
        let requested = enabledProviders.filter { providerID == nil || $0.id == providerID }
        let now = Date()
        let providers = requested.filter { descriptor in
            let allowed = ProviderBackoffPolicy.canRefresh(
                state: backoffByID[descriptor.id.rawValue], now: now, isManual: isManual
            )
            if !allowed {
                var cached = usage(for: descriptor.id)
                cached.state = .unavailable
                cached.message = backoffDescription(for: descriptor.id, now: now, language: AppLocalization.currentLanguage)
                usageByID[descriptor.id] = cached
            }
            return allowed
        }
        let preferences = preferences
        let jobs = providers.map { descriptor in
            (descriptor, preferences.configuration(for: descriptor.id))
        }
        let revisions = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.id, preferences.usageRevision(for: $0.id))
        })
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
                message: nil,
                todayByModel: loadingUsage[job.0.id]?.todayByModel
            )
        }
        usageByID = loadingUsage
        var refreshedUsage = loadingUsage

        await withTaskGroup(of: (ProviderUsage, Int, ProviderDiagnosticResult, ProviderRateLimitObservation?).self) { group in
            let concurrencyLimit = 6
            var nextJobIndex = 0

            func submit(_ job: (ProviderDescriptor, ProviderConfiguration)) {
                let (descriptor, configuration) = job
                let revision = revisions[descriptor.id]!
                group.addTask { [collector] in
                    let started = Date()
                    let trace = FetchDiagnostics()
                    do {
                        let secret = try await MainActor.run {
                            guard revision == preferences.usageRevision(for: descriptor.id) else {
                                throw CancellationError()
                            }
                            return preferences.secret(for: descriptor.id)
                        }
                        let usage = try await FetchDiagnostics.$current.withValue(trace) {
                            try await collector.collect(
                                descriptor: descriptor,
                                configuration: configuration,
                                secret: secret,
                                allowVertexClaudeFallback: allowVertexClaudeFallback,
                                allowBrowserCookieImport: allowBrowserCookieImport,
                                usageRevision: revision
                            )
                        }
                        return (usage, revision, ProviderDiagnosticResult(
                            providerID: descriptor.id, source: usage.diagnosticSource ?? "Local",
                            date: Date(), duration: Date().timeIntervalSince(started),
                            outcome: usage.state == .ready ? .success : .failed,
                            errorKind: usage.state == .ready ? nil : "Provider.\(usage.state.rawValue)",
                            httpStatus: usage.state == .ready ? nil : trace.httpStatus
                        ), trace.rateLimit)
                    } catch {
                        let summary = DiagnosticsErrorSummary(error: error)
                        return (ProviderUsage(
                            id: descriptor.id,
                            state: .failed,
                            windows: [],
                            balance: nil,
                            plan: nil,
                            updatedAt: Date(),
                            message: error.localizedDescription
                        ), revision, ProviderDiagnosticResult(
                            providerID: descriptor.id, source: trace.failureSource,
                            date: Date(), duration: Date().timeIntervalSince(started), outcome: .failed,
                            errorKind: summary.kind, httpStatus: summary.httpStatus ?? trace.httpStatus
                        ), trace.rateLimit)
                    }
                }
            }

            while nextJobIndex < min(concurrencyLimit, jobs.count) {
                submit(jobs[nextJobIndex])
                nextJobIndex += 1
            }

            while let (usage, revision, diagnostic, rateLimit) = await group.next() {
                if revision == preferences.usageRevision(for: usage.id) {
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

                    if revision == preferences.usageRevision(for: usage.id) {
                        let key = usage.id.rawValue
                        let previousBackoff = backoffByID[key]
                        let finishedAt = Date()
                        var backoff = ProviderBackoffPolicy.updating(
                            previous: previousBackoff,
                            httpStatus: rateLimit == nil ? diagnostic.httpStatus : 429,
                            retryAfter: rateLimit?.retryAfter,
                            succeeded: resolvedUsage.state == .ready, now: finishedAt
                        )
                        if let previousBackoff, attemptedBackoffRetries[key] == previousBackoff.retryAt,
                           let deadline = backoff?.retryAt, deadline <= finishedAt, rateLimit != nil {
                            // 已经立即重试过，再遇到零等待的 429 就按指数退避，避免请求循环。
                            backoff = ProviderBackoffPolicy.updating(
                                previous: previousBackoff, httpStatus: 429, retryAfter: nil,
                                succeeded: false, now: finishedAt
                            )
                        }
                        backoffByID[key] = backoff
                        if backoffByID[key] != previousBackoff { persistBackoff() }
                        var result = diagnostic
                        result.usedCache = refreshedUsage[usage.id]?.state == .unavailable
                        DiagnosticLog.shared.record(result)
                        usageByID[usage.id] = refreshedUsage[usage.id]
                        usageRevisions[usage.id] = revision
                        if let finalUsage = refreshedUsage[usage.id] {
                            await notifications.process(usage: finalUsage, revision: revision)
                        }
                    }
                }

                if nextJobIndex < jobs.count {
                    submit(jobs[nextJobIndex])
                    nextJobIndex += 1
                }
            }
        }
        persistCache()
        scheduleDeadlineRefresh()
        DiagnosticLog.shared.write("Refresh finished", category: .refresh)
    }

    func usage(for id: ProviderID) -> ProviderUsage {
        Self.usageForCurrentDay(usageByID[id] ?? ProviderUsage(
            id: id,
            state: .unavailable,
            windows: [],
            balance: nil,
            plan: nil,
            updatedAt: nil,
            message: nil
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
            resolved.todayByModel = nil
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
        // 有未计价的部分时，把各项已计价的金额加起来，供界面显示“至少多少”。
        let pricedValues = usages.compactMap { $0.valueUSD ?? $0.partialValueUSD }
        let partialValueUSD = hasUnpricedTokens && !pricedValues.isEmpty ? pricedValues.reduce(0, +) : nil
        return DailyTokenUsage(tokens: tokens, valueUSD: valueUSD, partialValueUSD: partialValueUSD)
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
        // 旧版本按 Magpie 账号单独缓存的 Claude 条目已不再使用，恢复时丢掉。
        let current = cached.filter {
            !$0.usage.id.rawValue.hasPrefix("claude-magpie-")
                && $0.revision == preferences.usageRevision(for: $0.usage.id)
        }
        usageRevisions = Dictionary(uniqueKeysWithValues: current.map { ($0.usage.id, $0.revision) })
        let sanitized = current.map { Self.sanitizeCachedUsage($0.usage) }
        usageByID = Dictionary(uniqueKeysWithValues: sanitized.map { ($0.id, $0) })
    }

    private static func sanitizeCachedUsage(_ usage: ProviderUsage) -> ProviderUsage {
        var sanitized = usage
        sanitized.state = .unavailable
        if sanitized.id.rawValue == "claude" {
            sanitized.plan = sanitized.plan.map(UsageParser.renamedClaudePlan)
        }
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
        let windows = sanitized.windows + sanitized.additionalWindows
        let weekly = windows.first { $0.label == "Weekly" } ?? windows.first { $0.label == "30-day" }
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
                  revision == preferences.usageRevision(for: usage.id) else { return nil }
            return CachedUsage(usage: usage, revision: revision)
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}
