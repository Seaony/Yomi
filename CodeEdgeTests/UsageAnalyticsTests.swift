import Foundation
import Testing
@testable import CodeEdge

struct UsageAnalyticsTests {
    @Test
    func dailyActiveUsesCalendarDaysRatherThanElapsedHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59))!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!

        #expect(UsageAnalytics.shouldSendDailyActive(lastSent: nil, now: beforeMidnight, calendar: calendar))
        #expect(!UsageAnalytics.shouldSendDailyActive(lastSent: beforeMidnight, now: beforeMidnight, calendar: calendar))
        #expect(UsageAnalytics.shouldSendDailyActive(lastSent: beforeMidnight, now: afterMidnight, calendar: calendar))
        #expect(!UsageAnalytics.shouldSendDailyActive(lastSent: afterMidnight, now: evening, calendar: calendar))
        #expect(UsageAnalytics.shouldSendDailyActive(lastSent: afterMidnight, now: nextDay, calendar: calendar))
    }
}
