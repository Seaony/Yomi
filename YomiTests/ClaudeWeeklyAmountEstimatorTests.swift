import Foundation
import Testing
@testable import Yomi

struct ClaudeWeeklyAmountEstimatorTests {
    private let firstReset = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func estimatesFullAmountFromTheFirstCycleObservation() throws {
        var estimator = ClaudeWeeklyAmountEstimator()

        let amount = estimator.estimate(
            currentCostUSD: 220,
            usedFraction: 0.10,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        #expect(try #require(amount) == 2_200)
    }

    @Test
    func coldStartPriorPreventsLowUsageFromExploding() throws {
        var estimator = ClaudeWeeklyAmountEstimator()

        let amount = estimator.estimate(
            currentCostUSD: 175,
            usedFraction: 0.01,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        #expect(try #require(amount) == 2_200)
    }

    @Test
    func waitsForAFullPercentagePointBeforeAddingAnIncrementalSample() throws {
        var estimator = ClaudeWeeklyAmountEstimator()
        _ = estimator.estimate(
            currentCostUSD: 20,
            usedFraction: 0.01,
            resetAt: firstReset,
            plan: nil
        )

        let unchangedPercent = estimator.estimate(
            currentCostUSD: 120,
            usedFraction: 0.01,
            resetAt: firstReset,
            plan: nil
        )
        let nextPercent = estimator.estimate(
            currentCostUSD: 140,
            usedFraction: 0.02,
            resetAt: firstReset,
            plan: nil
        )

        #expect(try #require(unchangedPercent) == 2_000)
        #expect(try #require(nextPercent) == 2_000)
    }

    @Test
    func weightedMedianRejectsASmallOutlier() throws {
        var estimator = ClaudeWeeklyAmountEstimator()
        _ = estimator.estimate(
            currentCostUSD: 200,
            usedFraction: 0.10,
            resetAt: firstReset,
            plan: "Max 20x"
        )
        _ = estimator.estimate(
            currentCostUSD: 202,
            usedFraction: 0.11,
            resetAt: firstReset,
            plan: "Max 20x"
        )
        let amount = estimator.estimate(
            currentCostUSD: 382,
            usedFraction: 0.20,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        #expect(try #require(amount) == 2_000)
    }

    @Test
    func carriesAQualifiedEstimateIntoTheNextCycle() throws {
        var estimator = ClaudeWeeklyAmountEstimator()
        _ = estimator.estimate(
            currentCostUSD: 240,
            usedFraction: 0.12,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        let amount = estimator.estimate(
            currentCostUSD: 100,
            usedFraction: 0.01,
            resetAt: firstReset.addingTimeInterval(7 * 24 * 60 * 60),
            plan: "Max 20x"
        )

        #expect(try #require(amount) == 2_000)
    }

    @Test
    func changingPlansDoesNotReuseThePreviousEstimate() throws {
        var estimator = ClaudeWeeklyAmountEstimator()
        _ = estimator.estimate(
            currentCostUSD: 240,
            usedFraction: 0.12,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        let amount = estimator.estimate(
            currentCostUSD: 10,
            usedFraction: 0.01,
            resetAt: firstReset,
            plan: "Max 5x"
        )

        #expect(try #require(amount) == 770)
    }

    @Test
    func stateRoundTripsThroughPersistence() throws {
        var estimator = ClaudeWeeklyAmountEstimator()
        _ = estimator.estimate(
            currentCostUSD: 200,
            usedFraction: 0.10,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        let data = try JSONEncoder().encode(estimator)
        var restored = try JSONDecoder().decode(ClaudeWeeklyAmountEstimator.self, from: data)
        let amount = restored.estimate(
            currentCostUSD: 400,
            usedFraction: 0.20,
            resetAt: firstReset,
            plan: "Max 20x"
        )

        #expect(try #require(amount) == 2_000)
    }
}
