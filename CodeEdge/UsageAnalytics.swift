import Foundation
import TelemetryDeck

@MainActor
final class UsageAnalytics {
    static let shared = UsageAnalytics()
    static let settingKey = "share-anonymous-usage-statistics"
    private static let lastActiveKey = "analytics-last-active-date"

    private var configuration: TelemetryDeck.Config?
    private var timer: Timer?

    func start() {
        guard configuration == nil else { return }
        let config = TelemetryDeck.Config(
            appID: "A29C7F53-8D08-4D6F-B63B-FE4FDA57B9E0", namespace: "com.mameya"
        )
        config.sendSignalsInDebugConfiguration = true
        config.sessionStatsEnabled = false
        config.urlSession = URLSession(configuration: .ephemeral)
        let enabled = UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
        config.analyticsDisabled = !enabled
        if !enabled { config.urlSession.invalidateAndCancel() }
        configuration = config
        TelemetryDeck.initialize(config: config)
        log(enabled: enabled)
        checkDailyActive()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDailyActive() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let configuration else { return }
        configuration.analyticsDisabled = !enabled
        // SDK 的开关只拦新信号；取消专用会话，已排队的信号也不能继续联网。
        if enabled {
            configuration.urlSession = URLSession(configuration: .ephemeral)
        } else {
            configuration.urlSession.invalidateAndCancel()
        }
        log(enabled: enabled)
        if enabled { checkDailyActive() }
    }

    private func checkDailyActive() {
        guard let configuration, !configuration.analyticsDisabled else { return }
        let now = Date()
        let lastSent = UserDefaults.standard.object(forKey: Self.lastActiveKey) as? Date
        guard Self.shouldSendDailyActive(lastSent: lastSent, now: now) else { return }
        TelemetryDeck.signal("App.dailyActive")
        UserDefaults.standard.set(now, forKey: Self.lastActiveKey)
    }

    nonisolated static func shouldSendDailyActive(
        lastSent: Date?, now: Date, calendar: Calendar = .current
    ) -> Bool {
        guard let lastSent else { return true }
        return !calendar.isDate(lastSent, inSameDayAs: now)
    }

    private func log(enabled: Bool) {
        DiagnosticLog.shared.write("Anonymous usage statistics: \(enabled ? "enabled" : "disabled")", category: .app)
    }
}
