import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol QuotaNotificationCenter {
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliver(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemQuotaNotificationCenter: NSObject, QuotaNotificationCenter, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(QuotaNotificationController.foregroundPresentationOptions())
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func deliver(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class QuotaNotificationController: ObservableObject {
    nonisolated enum Keys {
        static let lowQuotaEnabled = "quota-alerts.low-quota-enabled"
        static let depletedEnabled = "quota-alerts.depleted-enabled"
        static let resetEnabled = "quota-alerts.reset-enabled"
        static let thresholds = "quota-alerts.thresholds"
        static let mutedProviderIDs = "quota-alerts.muted-provider-ids"
        static let states = "quota-alerts.states.v1"
        static let authorizationRequested = "quota-alerts.authorization-requested"
        static let authorizationGranted = "quota-alerts.authorization-granted"
    }

    static let thresholdChoices = [50, 20, 10, 5]

    @Published private(set) var authorizationDenied = false
    @Published private(set) var permissionError: String?
    @Published private(set) var requestingAuthorization = false

    private let defaults: UserDefaults
    private let center: any QuotaNotificationCenter
    private let language: () -> AppLanguage
    private let now: () -> Date
    private var states: [String: QuotaNotificationPolicy.State]
    private var freshProviders: Set<ProviderID> = []

    init(
        defaults: UserDefaults = .standard,
        center: (any QuotaNotificationCenter)? = nil,
        language: @escaping () -> AppLanguage = { AppLocalization.currentLanguage },
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.center = center ?? SystemQuotaNotificationCenter()
        self.language = language
        self.now = now
        states = defaults.data(forKey: Keys.states).flatMap {
            try? JSONDecoder().decode([String: QuotaNotificationPolicy.State].self, from: $0)
        } ?? [:]
        authorizationDenied = defaults.bool(forKey: Keys.authorizationRequested)
            && !defaults.bool(forKey: Keys.authorizationGranted)
    }

    var settings: QuotaNotificationPolicy.Settings {
        QuotaNotificationPolicy.Settings(
            lowQuotaEnabled: defaults.bool(forKey: Keys.lowQuotaEnabled),
            depletedEnabled: defaults.bool(forKey: Keys.depletedEnabled),
            resetEnabled: defaults.bool(forKey: Keys.resetEnabled),
            thresholds: selectedThresholds
        )
    }

    var selectedThresholds: [Int] {
        let saved = defaults.array(forKey: Keys.thresholds) as? [Int] ?? [50, 20]
        return QuotaNotificationPolicy.Settings(thresholds: saved).activeThresholds
    }

    func setThresholds(_ thresholds: [Int]) {
        objectWillChange.send()
        defaults.set(QuotaNotificationPolicy.Settings(thresholds: thresholds).activeThresholds,
                     forKey: Keys.thresholds)
    }

    func isMuted(_ providerID: ProviderID) -> Bool {
        (defaults.stringArray(forKey: Keys.mutedProviderIDs) ?? []).contains(providerID.rawValue)
    }

    func setMuted(_ muted: Bool, for providerID: ProviderID) {
        var identifiers = Set(defaults.stringArray(forKey: Keys.mutedProviderIDs) ?? [])
        if muted { identifiers.insert(providerID.rawValue) } else { identifiers.remove(providerID.rawValue) }
        objectWillChange.send()
        defaults.set(identifiers.sorted(), forKey: Keys.mutedProviderIDs)
    }

    // 只能从设置里开启提醒的动作调用，启动和刷新不会进入这里。
    func requestAuthorizationIfNeeded() async {
        guard !requestingAuthorization else { return }
        if defaults.bool(forKey: Keys.authorizationRequested) {
            await refreshAuthorizationStatus()
            return
        }
        requestingAuthorization = true
        permissionError = nil
        defer { requestingAuthorization = false }
        do {
            let granted = try await center.requestAuthorization()
            defaults.set(true, forKey: Keys.authorizationRequested)
            defaults.set(granted, forKey: Keys.authorizationGranted)
            authorizationDenied = !granted
        } catch {
            permissionError = AppLocalization.text(
                "无法申请通知权限，请稍后重新开启提醒。",
                "Unable to request notification access. Try enabling alerts again later.", language: language()
            )
        }
    }

    func refreshAuthorizationStatus() async {
        guard defaults.bool(forKey: Keys.authorizationRequested) else { return }
        updateAuthorizationStatus(await center.authorizationStatus())
    }

    private func updateAuthorizationStatus(_ status: UNAuthorizationStatus) {
        let allowed = status == .authorized || status == .provisional
        defaults.set(allowed, forKey: Keys.authorizationGranted)
        authorizationDenied = status == .denied
        if allowed { permissionError = nil }
    }

    func process(usage: ProviderUsage, revision: Int) async {
        guard usage.state == .ready else { return }
        var activeSettings = settings
        if isMuted(usage.id) {
            activeSettings.lowQuotaEnabled = false
            activeSettings.depletedEnabled = false
            activeSettings.resetEnabled = false
        }
        let first = freshProviders.insert(usage.id).inserted
        let reduction = QuotaNotificationPolicy.reduce(
            usage: usage, previous: states[usage.id.rawValue], revision: revision,
            isFirstRefresh: first, settings: activeSettings, now: now()
        )
        var nextStates = states
        nextStates[usage.id.rawValue] = reduction.state
        do {
            let data = try JSONEncoder().encode(nextStates)
            defaults.set(data, forKey: Keys.states)
            // 先落盘再提交系统通知，重启不能重新发送已经消费的档位。
            guard defaults.synchronize() else {
                permissionError = AppLocalization.text(
                    "无法保存提醒记录，本次通知已跳过。",
                    "Unable to save alert history. This notification was skipped.", language: language()
                )
                return
            }
            states = nextStates
        } catch {
            permissionError = AppLocalization.text(
                "无法保存提醒记录，本次通知已跳过。",
                "Unable to save alert history. This notification was skipped.", language: language()
            )
            return
        }
        guard !reduction.events.isEmpty else { return }
        let status = await center.authorizationStatus()
        updateAuthorizationStatus(status)
        guard status == .authorized || status == .provisional else { return }
        for event in reduction.events {
            guard !isMuted(usage.id) else { break }
            let currentSettings = settings
            let enabled: Bool
            switch event.kind {
            case .lowQuota: enabled = currentSettings.lowQuotaEnabled
            case .depleted: enabled = currentSettings.depletedEnabled
            case .reset: enabled = currentSettings.resetEnabled
            }
            guard enabled else { continue }
            guard let content = Self.content(for: event, usage: usage, language: language()) else { continue }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await center.deliver(request)
            } catch {
                permissionError = AppLocalization.text(
                    "无法发送通知，请检查系统设置中的通知权限。",
                    "Unable to send alerts. Check notification access in System Settings.", language: language()
                )
            }
        }
    }

    nonisolated static func foregroundPresentationOptions() -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    static func content(
        for event: QuotaNotificationPolicy.Event,
        usage: ProviderUsage,
        language: AppLanguage
    ) -> UNMutableNotificationContent? {
        guard let provider = ProviderCatalog.byID[event.providerID] else { return nil }
        let copy = AppCopy(language: language)
        let content = UNMutableNotificationContent()
        let title: String
        switch event.kind {
        case .lowQuota: title = copy.text("\(provider.name) 额度不足", "\(provider.name) quota is low")
        case .depleted: title = copy.text("\(provider.name) 额度已用完", "\(provider.name) quota is depleted")
        case .reset: title = copy.text("\(provider.name) 额度已重置", "\(provider.name) quota has reset")
        }
        let window = safeWindowName(for: event.windowID, usage: usage, language: language)
        let remaining = Int(min(100, max(0, event.remainingPercent)).rounded())
        let reset = event.resetsAt.map { date in
            let formatted = date.formatted(.dateTime.locale(language.locale).month(.abbreviated).day().hour().minute())
            return copy.text("重置时间 \(formatted)", "Resets \(formatted)")
        } ?? copy.text("未提供重置时间", "Reset time unavailable")
        content.title = DiagnosticsRedactor.redact(title)
        content.body = DiagnosticsRedactor.redact(copy.text(
            "\(window) · 剩余 \(remaining)% · \(reset)", "\(window) · \(remaining)% left · \(reset)"
        ))
        content.threadIdentifier = "quota-\(provider.id.rawValue)"
        return content
    }

    private static func safeWindowName(for id: String, usage: ProviderUsage, language: AppLanguage) -> String {
        let windows = usage.windows + usage.additionalWindows
        let index = windows.firstIndex { $0.id == id }
        let rawLabel = index.map { windows[$0].label } ?? ""
        if let known = AppCopy(language: language).knownUsageLabel(rawLabel) { return known }
        let label = rawLabel.lowercased()
        let known: [String: (String, String)] = [
            "session": ("会话", "Session"), "会话": ("会话", "Session"),
            "5-hour": ("5 小时", "5-hour"), "5 小时": ("5 小时", "5-hour"),
            "weekly": ("每周", "Weekly"), "每周": ("每周", "Weekly"),
            "7-day": ("7 天", "7-day"), "daily": ("每日", "Daily"), "每日": ("每日", "Daily"),
            "monthly": ("每月", "Monthly"), "每月": ("每月", "Monthly"),
            "30-day": ("30 天", "30-day"), "30 天": ("30 天", "30-day"),
            "sonnet": ("Sonnet", "Sonnet"), "opus": ("Opus", "Opus"), "haiku": ("Haiku", "Haiku"),
            "gemini pro": ("Gemini Pro", "Gemini Pro"), "gemini flash": ("Gemini Flash", "Gemini Flash"),
        ]
        if let names = known[label] { return language == .simplifiedChinese ? names.0 : names.1 }
        let number = (index ?? 0) + 1
        return AppLocalization.text("额度窗口 \(number)", "Quota window \(number)", language: language)
    }
}
