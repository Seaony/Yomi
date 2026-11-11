import Foundation
import Testing
@testable import Yomi

struct UsagePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func aheadPacePredictsExhaustionBeforeReset() throws {
        let pace = try #require(UsagePace.evaluate(window: window(used: 0.75, remaining: 9_000), now: now))
        #expect(pace.predictionReady)
        #expect(pace.expectedUsedPercent == 50)
        #expect(pace.actualUsedPercent == 75)
        #expect(pace.deltaPercent == 25)
        #expect(pace.stage == .farAhead)
        #expect(pace.etaSeconds == 3_000)
        #expect(!pace.willLastToReset)
        #expect(pace.expectedRemainingFraction == 0.5)
    }

    @Test
    func behindPaceLastsUntilReset() throws {
        let pace = try #require(UsagePace.evaluate(window: window(used: 0.25, remaining: 9_000), now: now))
        #expect(pace.stage == .farBehind)
        #expect(pace.deltaPercent == -25)
        #expect(pace.etaSeconds == nil)
        #expect(pace.willLastToReset)
    }

    @Test
    func projectedExhaustionExactlyAtResetLastsUntilReset() throws {
        let pace = try #require(UsagePace.evaluate(window: window(used: 0.5, remaining: 9_000), now: now))
        #expect(pace.stage == .onTrack)
        #expect(pace.deltaPercent == 0)
        #expect(pace.etaSeconds == nil)
        #expect(pace.willLastToReset)
    }

    @Test
    func earlyWindowOnlyHasATimeMarker() throws {
        let pace = try #require(UsagePace.evaluate(window: window(used: 0.2, remaining: 16_801), now: now))
        #expect(pace.expectedUsedPercent > 0)
        #expect(!pace.predictionReady)
        #expect(pace.etaSeconds == nil)
        #expect(!pace.willLastToReset)
        let ready = try #require(UsagePace.evaluate(window: window(used: 0.2, remaining: 16_800), now: now))
        #expect(ready.predictionReady)
        #expect(ready.etaSeconds != nil)
    }

    @Test
    func exactStartDoesNotInventARate() throws {
        let empty = try #require(UsagePace.evaluate(window: window(used: 0, remaining: 18_000), now: now))
        #expect(empty.expectedUsedPercent == 0)
        #expect(!empty.predictionReady)
        #expect(empty.etaSeconds == nil)
        #expect(UsagePace.evaluate(window: window(used: 0.1, remaining: 18_000), now: now) == nil)
    }

    @Test
    func nearResetStillUsesRemainingTime() throws {
        let behind = try #require(UsagePace.evaluate(window: window(used: 0.99, remaining: 5), now: now))
        #expect(behind.willLastToReset)
        let ahead = try #require(UsagePace.evaluate(window: window(used: 0.9999, remaining: 5), now: now))
        let eta = try #require(ahead.etaSeconds)
        #expect(eta > 0 && eta < 5)
        #expect(!ahead.willLastToReset)
    }

    @Test
    func unusedAndExhaustedWindowsHaveClearOutcomes() throws {
        let unused = try #require(UsagePace.evaluate(window: window(used: 0, remaining: 9_000), now: now))
        #expect(unused.willLastToReset)
        #expect(unused.etaSeconds == nil)
        let exhausted = try #require(UsagePace.evaluate(window: window(used: 1.2, remaining: 9_000), now: now))
        #expect(exhausted.actualUsedPercent == 100)
        #expect(exhausted.etaSeconds == 0)
        #expect(!exhausted.willLastToReset)
    }

    @Test
    func missingOrInvalidWindowMetadataHasNoPace() {
        var value = window(used: 0.5, remaining: 9_000)
        value.windowMinutes = nil
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.windowMinutes = 0
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.windowMinutes = -1
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.windowMinutes = 300
        value.resetsAt = nil
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.resetsAt = now
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.resetsAt = now.addingTimeInterval(-1)
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.resetsAt = now.addingTimeInterval(18_001)
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
        value.resetsAt = now.addingTimeInterval(9_000)
        value.usedFraction = .nan
        #expect(UsagePace.evaluate(window: value, now: now) == nil)
    }

    @Test
    func stageRangesMatchTheReference() throws {
        let samples: [(Double, UsagePace.Stage)] = [
            (0, .onTrack), (2, .onTrack), (-2, .onTrack),
            (4, .slightlyAhead), (-4, .slightlyBehind),
            (6, .slightlyAhead), (-6, .slightlyBehind),
            (9, .ahead), (-9, .behind), (12, .ahead), (-12, .behind),
            (13, .farAhead), (-13, .farBehind),
        ]
        for (delta, stage) in samples {
            let value = delta == 6
                ? window(used: 0.5, remaining: 10_080)
                : window(used: (50 + delta) / 100, remaining: 9_000)
            let pace = try #require(UsagePace.evaluate(window: value, now: now))
            #expect(pace.stage == stage)
        }
    }

    @Test @MainActor
    func oldUsageCacheWithoutDurationStillRestores() throws {
        let suite = "usage-pace-cache-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldCache = Data(#"[{"usage":{"id":"codex","state":"ready","windows":[{"id":"codex-weekly","label":"Weekly","usedFraction":0.5}]},"revision":0}]"#.utf8)
        defaults.set(oldCache, forKey: "usage-cache.v3")
        let store = UsageStore(preferences: ProviderPreferences(defaults: defaults), defaults: defaults)
        let restored = try #require(store.usage(for: ProviderID(rawValue: "codex")).windows.first)
        #expect(restored.windowMinutes == nil)
        #expect(restored.usedFraction == 0.5)
        let newWindow = window(used: 0.3, remaining: 9_000)
        let roundTrip = try JSONDecoder().decode(UsageWindow.self, from: JSONEncoder().encode(newWindow))
        #expect(roundTrip.windowMinutes == 300)
    }

    private func window(used: Double, remaining: TimeInterval) -> UsageWindow {
        UsageWindow(id: "session", label: "Session", usedFraction: used,
                    resetsAt: now.addingTimeInterval(remaining), windowMinutes: 300)
    }
}
