import Foundation
import Testing
@testable import Yomi

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
    func updateTextIsLocalizedAndUsesCompletedMinutes() {
        let updatedAt = now.addingTimeInterval(-959)
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .simplifiedChinese)
                == "15 分钟前更新")
        #expect(UsageFreshness.updatedText(updatedAt: updatedAt, now: now, language: .english)
                == "Updated 15 min ago")
    }
}
