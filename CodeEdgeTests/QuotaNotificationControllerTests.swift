import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import CodeEdge

@MainActor
struct QuotaNotificationControllerTests {
    private let provider = ProviderID(rawValue: "claude")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func foregroundNotificationsStayVisibleWithoutAddingSound() {
        let options = QuotaNotificationController.foregroundPresentationOptions()
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(!options.contains(.sound))
    }

    @Test
    func startsDisabledWithoutAskingOrCheckingSystemPermissions() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let center = RecordingQuotaNotificationCenter()
        let controller = QuotaNotificationController(defaults: defaults, center: center)
        await controller.refreshAuthorizationStatus()
        #expect(!controller.settings.lowQuotaEnabled)
        #expect(!controller.settings.depletedEnabled)
        #expect(!controller.settings.resetEnabled)
        #expect(controller.selectedThresholds == [50, 20])
        await controller.process(usage: usage(0.1), revision: 0)
        await controller.process(usage: usage(0.9), revision: 0)
        #expect(center.authorizationRequests == 0)
        #expect(center.statusQueries == 0)
        #expect(center.delivered.isEmpty)
    }

    @Test
    func onlyExplicitPermissionActionRequestsAndDenialDoesNotReprompt() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let center = RecordingQuotaNotificationCenter()
        center.permissionGranted = false
        center.status = .denied
        let controller = QuotaNotificationController(defaults: defaults, center: center)
        await controller.requestAuthorizationIfNeeded()
        await controller.requestAuthorizationIfNeeded()
        #expect(center.authorizationRequests == 1)
        #expect(controller.authorizationDenied)
        let restored = QuotaNotificationController(defaults: defaults, center: center)
        #expect(restored.authorizationDenied)
        await restored.requestAuthorizationIfNeeded()
        #expect(center.authorizationRequests == 1)
    }

    @Test
    func explicitPermissionFailureUsesSafeCopyAndCanBeRetriedByUser() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let center = RecordingQuotaNotificationCenter()
        center.requestError = NSError(domain: "private.person@example.com", code: 1)
        let controller = QuotaNotificationController(defaults: defaults, center: center, language: { .english })
        await controller.requestAuthorizationIfNeeded()
        #expect(controller.permissionError?.contains("Unable to request") == true)
        #expect(controller.permissionError?.contains("private") == false)
        center.requestError = nil
        await controller.requestAuthorizationIfNeeded()
        #expect(center.authorizationRequests == 2)
        #expect(controller.permissionError == nil)
    }

    @Test
    func writesDeduplicationBeforeDeliveryAndRestoresItAcrossRestart() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        defaults.set(true, forKey: QuotaNotificationController.Keys.lowQuotaEnabled)
        let center = RecordingQuotaNotificationCenter()
        center.beforeDelivery = { _ in
            let data = defaults.data(forKey: QuotaNotificationController.Keys.states)
            let states = data.flatMap {
                try? JSONDecoder().decode([String: QuotaNotificationPolicy.State].self, from: $0)
            }
            #expect(states?["claude"]?.windows["session"]?.firedThresholds == [50, 20])
        }
        let controller = QuotaNotificationController(defaults: defaults, center: center)
        await controller.process(usage: usage(0.1), revision: 0)
        await controller.process(usage: usage(0.9), revision: 0)
        #expect(center.delivered.count == 1)
        #expect(center.authorizationRequests == 0)
        let restored = QuotaNotificationController(defaults: defaults, center: center)
        await restored.process(usage: usage(0.9), revision: 0)
        await restored.process(usage: usage(0.1), revision: 0)
        await restored.process(usage: usage(0.9), revision: 0)
        #expect(center.delivered.count == 1)
        #expect(center.statusQueries == 1)
    }

    @Test
    func firstSuccessfulSampleAfterFailedStartupStillDoesNotNotify() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        defaults.set(true, forKey: QuotaNotificationController.Keys.lowQuotaEnabled)
        let center = RecordingQuotaNotificationCenter()
        let first = QuotaNotificationController(defaults: defaults, center: center)
        await first.process(usage: usage(0.1), revision: 0)
        let restarted = QuotaNotificationController(defaults: defaults, center: center)
        await restarted.process(usage: usage(1, state: .unavailable), revision: 0)
        await restarted.process(usage: usage(0.9), revision: 0)
        await restarted.process(usage: usage(0.95), revision: 0)
        #expect(center.delivered.isEmpty)
        #expect(center.statusQueries == 0)
    }

    @Test
    func providerMuteIsIndependentAndDoesNotQueueOldThresholds() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        defaults.set(true, forKey: QuotaNotificationController.Keys.lowQuotaEnabled)
        let center = RecordingQuotaNotificationCenter()
        let controller = QuotaNotificationController(defaults: defaults, center: center)
        controller.setMuted(true, for: provider)
        #expect(controller.isMuted(provider))
        #expect(!controller.isMuted(ProviderID(rawValue: "codex")))
        await controller.process(usage: usage(0.1), revision: 0)
        await controller.process(usage: usage(0.9), revision: 0)
        controller.setMuted(false, for: provider)
        await controller.process(usage: usage(0.95), revision: 0)
        #expect(center.delivered.isEmpty)
        #expect(!controller.isMuted(provider))
    }

    @Test
    func systemPermissionRestorationIsRecognizedWithoutRequestingAgain() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        defaults.set(true, forKey: QuotaNotificationController.Keys.lowQuotaEnabled)
        let center = RecordingQuotaNotificationCenter()
        center.permissionGranted = false
        center.status = .denied
        let controller = QuotaNotificationController(defaults: defaults, center: center)
        await controller.requestAuthorizationIfNeeded()
        await controller.process(usage: usage(0.1), revision: 0)
        await controller.process(usage: usage(0.6), revision: 0)
        #expect(controller.authorizationDenied)
        #expect(center.delivered.isEmpty)
        center.status = .authorized
        await controller.refreshAuthorizationStatus()
        #expect(!controller.authorizationDenied)
        #expect(defaults.bool(forKey: QuotaNotificationController.Keys.authorizationGranted))
        await controller.requestAuthorizationIfNeeded()
        await controller.process(usage: usage(0.9), revision: 0)
        #expect(!controller.authorizationDenied)
        #expect(center.delivered.count == 1)
        #expect(center.authorizationRequests == 1)
    }

    @Test
    func selectedThresholdsAreSanitizedAndSaved() throws {
        let (defaults, suite) = try makeDefaults()
        defer { TestUserDefaultsCleanup.cleanup(defaults, suiteName: suite) }
        let controller = QuotaNotificationController(defaults: defaults, center: RecordingQuotaNotificationCenter())
        controller.setThresholds([20, 20, 10, 0, -1, 100])
        #expect(controller.selectedThresholds == [20, 10])
        #expect(controller.settings.thresholds == [20, 10])
        #expect(defaults.array(forKey: QuotaNotificationController.Keys.thresholds) as? [Int] == [20, 10])
    }

    @Test(arguments: ["Total", "Third Party", "Request quota", "Credits", "Bonus", "Overage",
                      "Gemini Models", "Claude and GPT models"])
    func fixedExistingWindowNamesStayRecognizable(label: String) throws {
        let sample = ProviderUsage(id: provider, state: .ready, windows: [
            UsageWindow(id: "fixed-window", label: label, usedFraction: 0.9),
        ])
        let event = QuotaNotificationPolicy.Event(providerID: provider, windowID: "fixed-window", kind: .lowQuota,
                                                  remainingPercent: 10, resetsAt: nil, threshold: 20)
        let content = try #require(QuotaNotificationController.content(for: event, usage: sample, language: .english))
        #expect(content.body.contains(label))
        #expect(!content.body.contains("Quota window"))
    }

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func notificationCopyUsesOnlyFixedSafeNamesAndNeverIncludesAccountData(language: AppLanguage) throws {
        let secret = "private.person@example.com"
        let windowID = "account-private-id"
        let sample = ProviderUsage(
            id: provider, state: .ready,
            windows: [
                UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.1),
                UsageWindow(id: windowID, label: "Bearer private-secret \(secret)", usedFraction: 0.9),
            ], plan: secret, message: "Cookie: private-cookie"
        )
        let event = QuotaNotificationPolicy.Event(
            providerID: provider, windowID: windowID, kind: .lowQuota,
            remainingPercent: 10, resetsAt: now.addingTimeInterval(18_000), threshold: 20
        )
        let content = try #require(QuotaNotificationController.content(for: event, usage: sample, language: language))
        let text = content.title + content.body + content.threadIdentifier
        #expect(text.contains("Claude"))
        #expect(text.contains("10%"))
        #expect(text.contains(language == .simplifiedChinese ? "额度窗口 2" : "Quota window 2"))
        #expect(!text.contains("private"))
        #expect(!text.contains("account-private-id"))
        #expect(content.userInfo.isEmpty)
        let known = QuotaNotificationPolicy.Event(providerID: provider, windowID: "weekly", kind: .reset,
                                                  remainingPercent: 90, resetsAt: nil)
        let knownContent = try #require(QuotaNotificationController.content(for: known, usage: sample, language: language))
        #expect(knownContent.body.contains(language == .simplifiedChinese ? "每周" : "Weekly"))
        #expect(knownContent.body.contains(language == .simplifiedChinese ? "未提供重置时间" : "Reset time unavailable"))
    }

    private func usage(_ used: Double, state: ProviderUsage.State = .ready) -> ProviderUsage {
        ProviderUsage(id: provider, state: state, windows: [
            UsageWindow(id: "session", label: "Session", usedFraction: used,
                        resetsAt: now.addingTimeInterval(18_000)),
        ])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "quota-notifications-test-\(UUID().uuidString)"
        return (try #require(TestUserDefaults(suiteName: suite)), suite)
    }
}

@MainActor
private final class RecordingQuotaNotificationCenter: QuotaNotificationCenter {
    var authorizationRequests = 0
    var statusQueries = 0
    var permissionGranted = true
    var status = UNAuthorizationStatus.authorized
    var requestError: Error?
    var delivered: [UNNotificationRequest] = []
    var beforeDelivery: ((UNNotificationRequest) -> Void)?

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if let requestError { throw requestError }
        return permissionGranted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusQueries += 1
        return status
    }

    func deliver(_ request: UNNotificationRequest) async throws {
        beforeDelivery?(request)
        delivered.append(request)
    }
}
