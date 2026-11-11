import Foundation
import Testing
@testable import Yomi

struct AdaptiveRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        (-1.0, 120.0, AdaptiveRefreshPolicy.Reason.recentInteraction),
        (0, 120, .recentInteraction),
        (300, 120, .recentInteraction),
        (301, 300, .warm),
        (3600, 300, .warm),
        (3601, 900, .idle),
        (14399, 900, .idle),
        (14400, 1800, .longIdle),
    ])
    func followsInteractionDecisionTable(age: TimeInterval, interval: TimeInterval, reason: AdaptiveRefreshPolicy.Reason) {
        let result = decision(interaction: now.addingTimeInterval(-age))
        #expect(result.interval == interval)
        #expect(result.reason == reason)
    }

    @Test
    func missingInteractionUsesLongIdleInterval() {
        #expect(decision(interaction: nil) == .init(interval: 1800, reason: .longIdle))
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func thermalConstraintOverridesRecentActivity(thermal: ProcessInfo.ThermalState) {
        let result = decision(interaction: now, coding: now, thermal: thermal)
        #expect(result == .init(interval: 1800, reason: .constrained))
    }

    @Test
    func lowPowerOverridesAllActivity() {
        #expect(decision(interaction: now, coding: now, lowPower: true)
            == .init(interval: 1800, reason: .constrained))
    }

    @Test
    func fairThermalStateDoesNotSlowRecentInteraction() {
        #expect(decision(interaction: now, thermal: .fair).interval == 120)
    }

    @Test
    func codingActivityCapsSlowIntervalsOnly() {
        #expect(decision(interaction: nil, coding: now) == .init(interval: 300, reason: .codingActivity))
        #expect(decision(interaction: now, coding: now) == .init(interval: 120, reason: .recentInteraction))
        #expect(decision(interaction: now.addingTimeInterval(-500), coding: now) == .init(interval: 300, reason: .warm))
        #expect(decision(interaction: nil, coding: now.addingTimeInterval(-299)).interval == 300)
        #expect(decision(interaction: nil, coding: now.addingTimeInterval(-300)).interval == 1800)
        #expect(decision(interaction: nil, coding: now.addingTimeInterval(60)).interval == 300)
    }

    private func decision(
        interaction: Date?,
        coding: Date? = nil,
        lowPower: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> AdaptiveRefreshPolicy.Decision {
        AdaptiveRefreshPolicy().nextDelay(for: .init(
            now: now, lastInteractionAt: interaction, lastCodingActivityAt: coding,
            lowPowerModeEnabled: lowPower, thermalState: thermal
        ))
    }
}
