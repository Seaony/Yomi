import Foundation
import Testing
@testable import Yomi

struct DailyBillTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var now: Date { Date(timeIntervalSince1970: 1_794_403_800) }

    @Test
    func groupsAndModelsAreSortedByCostAndTotalsMatchRows() {
        let codex = provider("codex", models: [
            model("small", input: 10, output: 5, cost: 1),
            model("large", input: 40, output: 20, cost: 5),
        ])
        let claude = provider("claude", models: [model("opus", input: 60, output: 30, cost: 10)])
        let bill = calculate([codex, claude])

        #expect(bill.providers.map(\.providerID.rawValue) == ["claude", "codex"])
        #expect(bill.providers[1].models.map(\.model) == ["large", "small"])
        #expect(bill.totalUsage.tokens == 165)
        #expect(bill.totalUsage.valueUSD == 16)
        #expect(bill.totalUsage.tokens == bill.providers.reduce(0) { $0 + $1.usage.tokens })
        #expect(bill.totalUsage.valueUSD == bill.providers.reduce(0) { $0 + ($1.usage.valueUSD ?? 0) })
        #expect(bill.inputTokens == 110)
        #expect(bill.outputTokens == 55)
        #expect(bill.totalUsage.tokens == (bill.inputTokens ?? 0) + (bill.outputTokens ?? 0))
        #expect(bill.day == calendar.startOfDay(for: now))
        #expect(bill.issuedAt == now)
    }

    @Test
    func sortingUsesKnownPartialCostAndStableNamesForTies() {
        var partial = model("partly-priced", input: 10, cost: nil)
        partial.partialValueUSD = 4
        let bill = calculate([
            provider("zeta", models: [model("known", input: 10, cost: 1)]),
            provider("alpha", models: [model("z-model", input: 10, cost: nil),
                                        model("a-model", input: 10, cost: nil), partial]),
        ])
        #expect(bill.providers.map(\.providerID.rawValue) == ["alpha", "zeta"])
        #expect(bill.providers[0].models.map(\.model) == ["partly-priced", "a-model", "z-model"])
        #expect(bill.totalUsage.valueUSD == nil)
        #expect(bill.totalUsage.partialValueUSD == 5)
        #expect(bill.totalUsage.tokens == 40)
    }

    @Test
    func unknownPricesKeepKnownAmountsWithoutInventingAnExactTotal() {
        let known = provider("claude", models: [model("known", input: 100, cost: 2)])
        let unknown = provider("pi", models: [model("unknown", input: 200, cost: nil)])
        let mixed = calculate([known, unknown])
        #expect(mixed.totalUsage.tokens == 300)
        #expect(mixed.totalUsage.valueUSD == nil)
        #expect(mixed.totalUsage.partialValueUSD == 2)

        let onlyUnknown = calculate([unknown])
        #expect(onlyUnknown.totalUsage.valueUSD == nil)
        #expect(onlyUnknown.totalUsage.partialValueUSD == nil)
        #expect(onlyUnknown.totalUsage.tokens == 200)
    }

    @Test
    func normalizesDifferentInputCacheSemantics() throws {
        let codex = model("codex", input: 100, cacheRead: 40, output: 20,
                          inputIncludesCache: true, cost: 1)
        let claude = model("claude", input: 100, cacheRead: 50, cacheWrite: 25, output: 30,
                           inputIncludesCache: false, cost: 2)
        let bill = calculate([provider("codex", models: [codex]), provider("claude", models: [claude])])
        #expect(bill.inputTokens == 275)
        #expect(bill.outputTokens == 50)
        #expect(bill.cacheReadTokens == 90)
        #expect(bill.totalUsage.tokens == 325)
        #expect(bill.hasCompleteTokenBreakdown)
        #expect(abs(try #require(bill.cacheHitRate) - 90.0 / 275.0) < 1e-12)
    }

    @Test
    func cacheWritesAreInputButDoNotCountAsHits() {
        let bill = calculate([provider("claude", models: [
            model("sonnet", input: 0, cacheWrite: 80, output: 20, inputIncludesCache: false, cost: 1),
        ])])
        #expect(bill.inputTokens == 80)
        #expect(bill.totalUsage.tokens == 100)
        #expect(bill.cacheHitRate == 0)
        #expect(calculate([provider("pi", models: [model("output-only", output: 20, cost: 1)])]).cacheHitRate == nil)
    }

    @Test
    func reportedTotalsWithoutCompleteComponentsDoNotInventTokenParts() {
        var incomplete = model("reported-total", input: 0, output: 0, cost: 2)
        incomplete.reportedTotalTokens = 70
        let complete = model("complete", input: 10, output: 5, cost: 1)
        let bill = calculate([provider("pi", models: [incomplete, complete])])
        #expect(bill.totalUsage.tokens == 85)
        #expect(bill.totalUsage.valueUSD == 3)
        #expect(!bill.hasCompleteTokenBreakdown)
        #expect(bill.inputTokens == nil)
        #expect(bill.outputTokens == nil)
        #expect(bill.cacheReadTokens == nil)
        #expect(bill.cacheHitRate == nil)

        incomplete.reportedTotalTokens = 0
        let zero = calculate([provider("pi", models: [incomplete, complete])])
        #expect(zero.hasCompleteTokenBreakdown)
        #expect(zero.inputTokens == 10)
        #expect(zero.outputTokens == 5)
    }

    @Test
    func streakCountsBackFromTodayAndStopsAtTheFirstGap() {
        let usage = provider("codex", models: [model("gpt", input: 10, cost: 1)], history: [
            point(daysAgo: 1, tokens: 10, cost: 1),
            point(daysAgo: 2, tokens: 10, cost: 1),
            point(daysAgo: 4, tokens: 10, cost: 1),
        ])
        #expect(calculate([usage]).consecutiveDays == 3)
        #expect(!calculate([usage]).consecutiveDaysCapped)
        let inactiveToday = provider("codex", models: [], history: [point(daysAgo: 1, tokens: 10, cost: 1)])
        #expect(calculate([inactiveToday]).consecutiveDays == 0)
    }

    @Test
    func streakCombinesProvidersAndCapsAtThirtyDays() {
        let first = provider("codex", models: [model("gpt", input: 10, cost: 1)], history:
            (1...35).filter { $0.isMultiple(of: 2) }.map { point(daysAgo: $0, tokens: 10, cost: 1) })
        let second = provider("claude", models: [], history:
            (1...35).filter { !$0.isMultiple(of: 2) }.map { point(daysAgo: $0, tokens: 10, cost: 1) })
        let bill = calculate([first, second])
        #expect(bill.consecutiveDays == 30)
        #expect(bill.consecutiveDaysCapped)
    }

    @Test
    func dailyAverageUsesActivePastDaysAndExcludesTodayAndOutOfRangeDates() {
        let codex = provider("codex", models: [model("gpt", input: 10, cost: 12)], history: [
            point(daysAgo: 0, tokens: 10, cost: 999),
            point(daysAgo: 1, tokens: 10, cost: 2),
            point(daysAgo: 2, tokens: 0, cost: 0),
            point(daysAgo: 30, tokens: 10, cost: 8),
            point(daysAgo: 31, tokens: 10, cost: 999),
            point(daysAgo: -1, tokens: 10, cost: 999),
        ])
        let claude = provider("claude", models: [], history: [point(daysAgo: 1, tokens: 10, cost: 2)])
        let bill = calculate([codex, claude])
        #expect(bill.previousActiveDayAverageUSD == 6)
        #expect(bill.comparisonToDailyAverage == 2)
    }

    @Test
    func unknownHistoryDoesNotBecomeAnExactAverageAndFreeHistoryDoesNotDivideByZero() {
        let unknown = provider("codex", models: [model("gpt", input: 10, cost: 2)], history: [
            point(daysAgo: 1, tokens: 10, cost: nil, partial: 1),
            point(daysAgo: 2, tokens: 10, cost: 2),
        ])
        #expect(calculate([unknown]).previousActiveDayAverageUSD == nil)
        #expect(calculate([unknown]).comparisonToDailyAverage == nil)

        let free = provider("codex", models: [model("gpt", input: 10, cost: 2)], history: [
            point(daysAgo: 1, tokens: 10, cost: 0),
        ])
        #expect(calculate([free]).previousActiveDayAverageUSD == 0)
        #expect(calculate([free]).comparisonToDailyAverage == nil)
        #expect(calculate([provider("codex", models: [model("gpt", input: 10, cost: 2)])]).comparisonToDailyAverage == nil)
    }

    @Test
    func unknownTodayKeepsExactHistoricalAverageButDoesNotInventComparison() {
        let usage = provider("pi", models: [model("unknown", input: 10, cost: nil)], history: [
            point(daysAgo: 1, tokens: 10, cost: 2),
        ])
        let bill = calculate([usage])
        #expect(bill.previousActiveDayAverageUSD == 2)
        #expect(bill.comparisonToDailyAverage == nil)
    }

    @Test
    func ignoresRemoteCostsAndStaleModelRowsButKeepsLocalHistory() {
        var remote = provider("cursor", models: [model("remote", input: 500, cost: 500)], history: [
            point(daysAgo: 1, tokens: 500, cost: 500),
        ])
        remote.todayByModel = nil
        remote.today = DailyTokenUsage(tokens: 500, valueUSD: 500)
        remote.providerCost = ProviderCostSummary(used: 500, limit: 1000, currencyCode: "USD")
        var stale = provider("claude", models: [model("old", input: 100, cost: 100)], history: [
            point(daysAgo: 1, tokens: 10, cost: 1),
        ])
        stale.todayDate = date(daysAgo: 1)
        let current = provider("codex", models: [model("gpt", input: 10, cost: 2)])
        let bill = calculate([remote, stale, current])
        #expect(bill.providers.map(\.providerID.rawValue) == ["codex"])
        #expect(bill.totalUsage.tokens == 10)
        #expect(bill.totalUsage.valueUSD == 2)
        #expect(bill.consecutiveDays == 2)
        #expect(bill.previousActiveDayAverageUSD == 1)
    }

    @Test
    func emptyBillHasNoHistoryComparisonOrCacheRate() {
        let bill = calculate([])
        #expect(bill.providers.isEmpty)
        #expect(bill.totalUsage.tokens == 0)
        #expect(bill.totalUsage.valueUSD == 0)
        #expect(bill.consecutiveDays == 0)
        #expect(!bill.consecutiveDaysCapped)
        #expect(bill.cacheHitRate == nil)
        #expect(bill.previousActiveDayAverageUSD == nil)
        #expect(bill.comparisonToDailyAverage == nil)
    }

    @Test
    func calendarDaysRemainConsecutiveAcrossDaylightSavingChange() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(dstCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let yesterday = try #require(dstCalendar.date(byAdding: .day, value: -1, to: date))
        let dayBefore = try #require(dstCalendar.date(byAdding: .day, value: -2, to: date))
        var usage = provider("codex", models: [model("gpt", input: 10, cost: 1)])
        usage.todayDate = date
        usage.last30DaysDaily = [
            DailyTokenUsagePoint(date: yesterday, usage: DailyTokenUsage(tokens: 10, valueUSD: 1)),
            DailyTokenUsagePoint(date: dayBefore, usage: DailyTokenUsage(tokens: 10, valueUSD: 1)),
        ]
        let bill = DailyBill.calculate(usages: [usage], now: date, calendar: dstCalendar)
        #expect(bill.consecutiveDays == 3)
        #expect(bill.previousActiveDayAverageUSD == 1)
    }

    @Test
    func openCodeHistoryWithoutUsageTodayStillContributesToStreakAndAverage() throws {
        let localCalendar = Calendar.current
        let localNow = localCalendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let yesterday = try #require(localCalendar.date(byAdding: .day, value: -1, to: localNow))
        let openCode = OpenCodeGoLocalUsageReader.enrich(
            ProviderUsage(id: ProviderID(rawValue: "opencodego"), state: .ready, windows: []),
            rows: [.init(date: yesterday, cost: 2, requestCount: 1, tokens: 10)], now: localNow
        )
        #expect(openCode.todayByModel == [])
        var current = provider("codex", models: [model("gpt", input: 10, cost: 1)])
        current.todayDate = localNow
        current.updatedAt = localNow
        let bill = DailyBill.calculate(usages: [current, openCode], now: localNow, calendar: localCalendar)
        #expect(bill.consecutiveDays == 2)
        #expect(bill.previousActiveDayAverageUSD == 2)
        #expect(bill.comparisonToDailyAverage == 0.5)
        #expect(bill.providers.map(\.providerID.rawValue) == ["codex"])
    }

    private func calculate(_ usages: [ProviderUsage]) -> DailyBillData {
        DailyBill.calculate(usages: usages, now: now, calendar: calendar)
    }

    private func provider(
        _ id: String,
        models: [ModelTokenUsage],
        history: [DailyTokenUsagePoint] = []
    ) -> ProviderUsage {
        ProviderUsage(id: ProviderID(rawValue: id), state: .ready, windows: [],
                      todayDate: now, last30DaysDaily: history, updatedAt: now, todayByModel: models)
    }

    private func model(
        _ name: String,
        input: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        output: Int64 = 0,
        inputIncludesCache: Bool = true,
        cost: Double?
    ) -> ModelTokenUsage {
        ModelTokenUsage(model: name, inputTokens: input, cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite, outputTokens: output,
                        inputIncludesCache: inputIncludesCache, valueUSD: cost)
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }

    private func point(daysAgo: Int, tokens: Int64, cost: Double?, partial: Double? = nil) -> DailyTokenUsagePoint {
        DailyTokenUsagePoint(date: date(daysAgo: daysAgo),
                            usage: DailyTokenUsage(tokens: tokens, valueUSD: cost, partialValueUSD: partial))
    }
}
