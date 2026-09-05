import Foundation

nonisolated struct ClaudeWeeklyAmountEstimator: Codable, Equatable, Sendable {
    private struct Sample: Codable, Equatable, Sendable {
        let amountUSD: Double
        let weight: Double
    }

    private static let minimumUsageFraction = 0.01
    private static let minimumDeltaFraction = 0.01
    private static let reusableCycleEvidence = 0.10
    private static let priorWeight = 0.10
    private static let fractionComparisonTolerance = 1e-9
    private static let resetTolerance: TimeInterval = 5 * 60
    private static let maximumSamples = 32

    private var cycleResetAt: Date?
    private var plan: String?
    private var anchorCostUSD: Double?
    private var anchorUsedFraction: Double?
    private var samples: [Sample] = []
    private var observedFraction = 0.0
    private(set) var estimatedAmountUSD: Double?

    mutating func estimate(
        currentCostUSD: Double,
        usedFraction: Double,
        resetAt: Date,
        plan newPlan: String?
    ) -> Double? {
        guard currentCostUSD.isFinite,
              currentCostUSD >= 0,
              usedFraction.isFinite,
              (0...1).contains(usedFraction)
        else { return estimatedAmountUSD }

        let normalizedPlan = newPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planChanged = plan != nil && normalizedPlan != nil && plan != normalizedPlan
        let sameCycle = cycleResetAt.map {
            abs($0.timeIntervalSince(resetAt)) <= Self.resetTolerance
        } ?? false

        if !sameCycle || planChanged {
            let reusableEstimate = !planChanged && observedFraction >= Self.reusableCycleEvidence
                ? estimatedAmountUSD
                : nil
            let seedEstimate = reusableEstimate ?? Self.coldStartEstimate(for: normalizedPlan)
            cycleResetAt = resetAt
            plan = normalizedPlan ?? plan
            anchorCostUSD = currentCostUSD
            anchorUsedFraction = usedFraction
            samples = seedEstimate.map {
                [Sample(amountUSD: $0, weight: Self.priorWeight)]
            } ?? []
            observedFraction = usedFraction
            addSample(costUSD: currentCostUSD, fraction: usedFraction)
            updateEstimate()
            return estimatedAmountUSD
        }

        plan = normalizedPlan ?? plan
        observedFraction = max(observedFraction, usedFraction)
        guard let anchorCostUSD, let anchorUsedFraction else {
            self.anchorCostUSD = currentCostUSD
            self.anchorUsedFraction = usedFraction
            addSample(costUSD: currentCostUSD, fraction: usedFraction)
            updateEstimate()
            return estimatedAmountUSD
        }

        let costDelta = currentCostUSD - anchorCostUSD
        let fractionDelta = usedFraction - anchorUsedFraction
        if costDelta < 0 || fractionDelta < 0 {
            self.anchorCostUSD = currentCostUSD
            self.anchorUsedFraction = usedFraction
        } else if fractionDelta + Self.fractionComparisonTolerance >= Self.minimumDeltaFraction {
            addSample(costUSD: costDelta, fraction: fractionDelta)
            self.anchorCostUSD = currentCostUSD
            self.anchorUsedFraction = usedFraction
        }

        updateEstimate()
        return estimatedAmountUSD
    }

    private mutating func addSample(costUSD: Double, fraction: Double) {
        guard fraction >= Self.minimumUsageFraction else { return }
        let amountUSD = costUSD / fraction
        guard amountUSD.isFinite, amountUSD > 0 else { return }
        samples.append(Sample(amountUSD: amountUSD, weight: fraction))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    private mutating func updateEstimate() {
        let validSamples = samples.filter {
            $0.amountUSD.isFinite && $0.amountUSD > 0 && $0.weight.isFinite && $0.weight > 0
        }
        guard !validSamples.isEmpty else { return }

        let ordered = validSamples.sorted { $0.amountUSD < $1.amountUSD }
        let midpoint = ordered.reduce(0) { $0 + $1.weight } / 2
        var accumulatedWeight = 0.0
        for sample in ordered {
            accumulatedWeight += sample.weight
            if accumulatedWeight >= midpoint {
                estimatedAmountUSD = sample.amountUSD
                return
            }
        }
    }

    private static func coldStartEstimate(for plan: String?) -> Double? {
        let words = plan?
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init) ?? []
        guard words.contains("max") else { return nil }
        if words.contains("20x") { return 2_200 }
        if words.contains("5x") { return 770 }
        return nil
    }
}
