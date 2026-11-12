import Foundation
import Testing
@testable import CodeEdge

struct UsageFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [899.0, 900.0, 900.001])
    func usesStrictFifteenMinuteBoundary(age: TimeInterval) {
        #expect(UsageFreshness.isStale(updatedAt: now.addingTimeInterval(-age), refreshInterval: 300, now: now)
                == (age > 900))
    }

    @Test(arguments: [1199.0, 1200.0, 1200.001])
    func respectsLongerRefreshInterval(age: TimeInterval) {
        #expect(UsageFreshness.isStale(updatedAt: now.addingTimeInterval(-age), refreshInterval: 600, now: now)
                == (age > 1200))
    }

    @Test
    func changingIntervalChangesTheSameDataFreshness() {
        let updatedAt = now.addingTimeInterval(-1201)
        #expect(UsageFreshness.isStale(updatedAt: updatedAt, refreshInterval: 300, now: now))
        #expect(!UsageFreshness.isStale(updatedAt: updatedAt, refreshInterval: 900, now: now))
    }

    @Test
    func absentOrFutureTimestampIsNotStale() {
        #expect(!UsageFreshness.isStale(updatedAt: nil, refreshInterval: 300, now: now))
        #expect(!UsageFreshness.isStale(updatedAt: now.addingTimeInterval(60), refreshInterval: 300, now: now))
    }

    @Test
    func advancesWithTimeWithoutARefresh() {
        let updatedAt = now.addingTimeInterval(-900)
        #expect(!UsageFreshness.isStale(updatedAt: updatedAt, refreshInterval: 300, now: now))
        #expect(UsageFreshness.isStale(updatedAt: updatedAt, refreshInterval: 300, now: now.addingTimeInterval(60)))
    }

    @Test
    func loadingOldCachedUsageDoesNotDim() {
        let usage = usage(state: .loading, updatedAt: now.addingTimeInterval(-3600))
        #expect(UsageFreshness.isStale(updatedAt: usage.updatedAt, refreshInterval: 300, now: now))
        #expect(!UsageFreshness.shouldDim(usage: usage, refreshInterval: 300, now: now))
    }

    @Test(arguments: [ProviderUsage.State.failed, .unavailable, .ready])
    func oldUsageDimsOutsideLoading(state: ProviderUsage.State) {
        let usage = usage(state: state, updatedAt: now.addingTimeInterval(-3600))
        #expect(UsageFreshness.shouldDim(usage: usage, refreshInterval: 300, now: now))
    }

    @Test(arguments: [ProviderUsage.State.loading, .failed, .unavailable, .ready])
    func freshUsageDoesNotDim(state: ProviderUsage.State) {
        let usage = usage(state: state, updatedAt: now.addingTimeInterval(-60))
        #expect(!UsageFreshness.shouldDim(usage: usage, refreshInterval: 300, now: now))
    }

    @Test(arguments: [ProviderUsage.State.loading, .failed, .unavailable, .ready])
    func usageWithoutTimestampDoesNotDim(state: ProviderUsage.State) {
        let usage = usage(state: state, updatedAt: nil)
        #expect(!UsageFreshness.shouldDim(usage: usage, refreshInterval: 300, now: now))
    }

    @Test
    func updateTextIsLocalizedAndUsesCompletedMinutes() {
        let updatedAt = now.addingTimeInterval(-959)
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .simplifiedChinese)
                == "15 分钟前更新")
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .english)
                == "Updated 15 min ago")
    }

    @Test(arguments: [
        (3599.0, "59 分钟前更新", "Updated 59 min ago"),
        (3600.0, "1 小时前更新", "Updated 1 hour ago"),
        (86399.0, "23 小时前更新", "Updated 23 hours ago"),
        (86400.0, "1 天前更新", "Updated 1 day ago"),
        (345599.0, "3 天前更新", "Updated 3 days ago"),
    ])
    func updateTextUsesCompletedHoursAndDays(age: TimeInterval, chinese: String, english: String) {
        let updatedAt = now.addingTimeInterval(-age)
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .simplifiedChinese) == chinese)
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .english) == english)
    }

    private func usage(state: ProviderUsage.State, updatedAt: Date?) -> ProviderUsage {
        ProviderUsage(
            id: ProviderID(rawValue: "codex"), state: state,
            windows: [UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.5)], updatedAt: updatedAt
        )
    }
}
