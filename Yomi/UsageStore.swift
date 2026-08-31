import CodexBarCore
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var providers: [ProviderUsage]
    @Published private(set) var configurations: [ProviderConfig]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private let defaults: UserDefaults
    private let cacheKey = "usage.snapshot.v2"
    private let configurationStore: CodexBarConfigStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yomi", isDirectory: true)
            .appendingPathComponent("providers.json")
        configurationStore = CodexBarConfigStore(fileURL: supportURL)

        let loaded = (try? configurationStore.load()) ?? CodexBarConfig.makeDefault()
        configurations = loaded.normalized().providers
        providers = Self.initialProviders(defaults: defaults)
        lastRefresh = providers.compactMap(\.updatedAt).max()
        registerInitialDefaults()
    }

    deinit {
        refreshTask?.cancel()
        refreshTimer?.invalidate()
    }

    var enabledProviders: [ProviderUsage] {
        providers.filter { isEnabled($0.definition) }
    }

    func start() {
        refresh()
        scheduleTimer()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        let enabled = ProviderDefinitions.all.filter(isEnabled)
        let configurations = configurations

        refreshTask = Task { [weak self] in
            var results: [ProviderUsage] = []
            for batchStart in stride(from: 0, to: enabled.count, by: 6) {
                let batch = Array(enabled[batchStart..<min(batchStart + 6, enabled.count)])
                let batchResults = await withTaskGroup(
                    of: ProviderUsage.self,
                    returning: [ProviderUsage].self)
                { group in
                    for definition in batch {
                        let configuration = configurations.first(where: { $0.id.rawValue == definition.id })
                        group.addTask {
                            await ProviderUsageClient.fetch(
                                definition,
                                configuration: configuration,
                                allConfigurations: configurations)
                        }
                    }
                    var values: [ProviderUsage] = []
                    for await value in group {
                        values.append(value)
                    }
                    return values
                }
                results.append(contentsOf: batchResults)
            }
            guard let self, !Task.isCancelled else { return }
            apply(results: results, enabled: enabled)
            isRefreshing = false
            refreshTask = nil
        }
    }

    func setEnabled(_ enabled: Bool, for definition: ProviderDefinition) {
        defaults.set(enabled, forKey: definition.defaultsKey)
        refreshTask?.cancel()
        refreshTask = nil
        refresh()
    }

    func updateConfiguration(_ configuration: ProviderConfig) throws {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        try configurationStore.save(CodexBarConfig(providers: configurations))
        refreshTask?.cancel()
        refreshTask = nil
        refresh()
    }

    func preferencesDidChange() {
        scheduleTimer()
        refreshTask?.cancel()
        refreshTask = nil
        refresh()
    }

    func usage(for definition: ProviderDefinition) -> ProviderUsage {
        providers.first(where: { $0.id == definition.id }) ?? .loading(definition)
    }

    func configuration(for definition: ProviderDefinition) -> ProviderConfig? {
        configurations.first(where: { $0.id.rawValue == definition.id })
    }

    func isEnabled(_ definition: ProviderDefinition) -> Bool {
        defaults.bool(forKey: definition.defaultsKey)
    }

    private func registerInitialDefaults() {
        var values: [String: Any] = [:]
        for definition in ProviderDefinitions.all {
            values[definition.defaultsKey] = ["claude", "codex", "gemini"].contains(definition.id)
        }
        values["refresh.interval.minutes"] = 5.0
        defaults.register(defaults: values)
    }

    private func apply(results: [ProviderUsage], enabled: [ProviderDefinition]) {
        var next: [ProviderUsage] = []
        for definition in ProviderDefinitions.all {
            guard enabled.contains(definition) else {
                next.append(usage(for: definition))
                continue
            }
            guard var incoming = results.first(where: { $0.id == definition.id }) else {
                next.append(usage(for: definition))
                continue
            }
            if incoming.windows.isEmpty,
               let previous = providers.first(where: { $0.id == definition.id }),
               !previous.windows.isEmpty
            {
                incoming.windows = previous.windows
                incoming.balanceText = previous.balanceText
                incoming.updatedAt = previous.updatedAt
            }
            next.append(incoming)
        }
        providers = next
        lastRefresh = Date()
        persistSuccessfulSnapshots()
    }

    private func persistSuccessfulSnapshots() {
        let snapshots = providers.filter { !$0.windows.isEmpty || $0.balanceText != nil }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let configured = defaults.double(forKey: "refresh.interval.minutes")
        let minutes = configured > 0 ? configured : 5
        refreshTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refreshTimer?.tolerance = min(30, minutes * 6)
    }

    private static func initialProviders(defaults: UserDefaults) -> [ProviderUsage] {
        guard let data = defaults.data(forKey: "usage.snapshot.v2"),
              let cached = try? JSONDecoder().decode([ProviderUsage].self, from: data)
        else {
            return ProviderDefinitions.all.map(ProviderUsage.loading)
        }
        return ProviderDefinitions.all.map { definition in
            cached.first(where: { $0.id == definition.id }) ?? .loading(definition)
        }
    }
}
