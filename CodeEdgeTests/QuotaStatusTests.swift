import Foundation
import Testing
@testable import CodeEdge

struct QuotaStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, -0.2, 0.06, 0.1, 1 - 0.9])
    func lowRemainingIsCriticalRegardlessOfPrediction(remaining: Double) {
        for prediction in [nil, pace(ready: false), pace(lasts: true), pace(lasts: false)] {
            #expect(QuotaStatus.evaluate(remainingFraction: remaining, pace: prediction) == .critical)
        }
    }

    @Test
    func readyForecastOverridesFallbackThresholds() {
        #expect(QuotaStatus.evaluate(remainingFraction: 0.84, pace: pace(lasts: true)) == .ok)
        #expect(QuotaStatus.evaluate(remainingFraction: 0.51, pace: pace(lasts: false)) == .fast)
        #expect(QuotaStatus.evaluate(remainingFraction: 0.97, pace: pace(lasts: true)) == .ok)
        #expect(QuotaStatus.evaluate(remainingFraction: 0.25, pace: pace(lasts: true)) == .ok)
        #expect(QuotaStatus.evaluate(remainingFraction: 0.99, pace: pace(lasts: false)) == .fast)
    }

    @Test(arguments: [(0.100001, QuotaStatus.fast), (0.25, .fast), (0.3, .fast),
                      (1 - 0.7, .fast), (0.300001, .ok), (0.84, .ok), (1, .ok)])
    func unavailableForecastUsesRemainingThresholds(remaining: Double, expected: QuotaStatus) {
        for prediction in [nil, pace(ready: false)] {
            #expect(QuotaStatus.evaluate(remainingFraction: remaining, pace: prediction) == expected)
        }
    }

    @Test
    func realWindowsUseExhaustionTimeRatherThanPaceStage() throws {
        for (used, remaining, expected) in [(0.49, 89 * 3_600.0, QuotaStatus.fast),
                                           (0.16, 4 * 3_600.0, .ok),
                                           (0.94, 89 * 3_600.0, .critical)] {
            let window = UsageWindow(id: "weekly", label: "Weekly", usedFraction: used,
                resetsAt: now.addingTimeInterval(remaining), detail: nil,
                windowMinutes: used == 0.16 ? 300 : 10_080)
            let prediction = try #require(UsagePace.evaluate(window: window, now: now))
            #expect(QuotaStatus.evaluate(remainingFraction: 1 - window.clampedFraction, pace: prediction) == expected)
            if expected == .fast {
                #expect(prediction.stage == .onTrack)
                #expect(prediction.etaSeconds.map { $0 < remaining } == true)
            }
        }
    }

    private func pace(ready: Bool = true, lasts: Bool = false) -> UsagePace {
        UsagePace(stage: .onTrack, deltaPercent: 0, expectedUsedPercent: 49,
                  actualUsedPercent: 49, predictionReady: ready,
                  etaSeconds: lasts ? nil : 24 * 3_600, willLastToReset: lasts)
    }
}
