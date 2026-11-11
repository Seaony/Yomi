import Foundation

nonisolated struct DailyBillProviderGroup: Equatable, Sendable, Identifiable {
    var providerID: ProviderID
    var models: [ModelTokenUsage]
    var usage: DailyTokenUsage

    var id: ProviderID { providerID }
}

nonisolated struct DailyBillData: Equatable, Sendable {
    var day: Date
    var issuedAt: Date
    var providers: [DailyBillProviderGroup]
    var totalUsage: DailyTokenUsage
    // 已扣除缓存读取的新输入；缓存写入仍计在这里。
    var inputTokens: Int64?
    var outputTokens: Int64?
    var cacheReadTokens: Int64?
    var cacheHitRate: Double?
    var hasCompleteTokenBreakdown: Bool
    var consecutiveDays: Int
    var consecutiveDaysCapped: Bool
    var previousActiveDayAverageUSD: Double?
    var comparisonToDailyAverage: Double?
}

nonisolated enum DailyBill {
    static func calculate(
        usages: [ProviderUsage],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyBillData {
        let today = calendar.startOfDay(for: now)
        // 模型明细只由本地统计填写；没有明细的接口金额不能混进账单。
        let localUsages = usages.filter { $0.todayByModel != nil }
        let providers = localUsages.compactMap { usage -> DailyBillProviderGroup? in
            guard let date = usage.todayDate ?? usage.updatedAt,
                  calendar.isDate(date, inSameDayAs: now) else { return nil }
            let models = (usage.todayByModel ?? []).filter {
                $0.tokens > 0 || ($0.valueUSD ?? $0.partialValueUSD ?? 0) > 0
            }.sorted {
                let left = $0.valueUSD ?? $0.partialValueUSD ?? 0
                let right = $1.valueUSD ?? $1.partialValueUSD ?? 0
                return left == right ? $0.model < $1.model : left > right
            }
            guard !models.isEmpty else { return nil }
            return DailyBillProviderGroup(
                providerID: usage.id,
                models: models,
                usage: combinedUsage(models.map(\.usage))
            )
        }.sorted {
            let left = $0.usage.valueUSD ?? $0.usage.partialValueUSD ?? 0
            let right = $1.usage.valueUSD ?? $1.usage.partialValueUSD ?? 0
            return left == right ? $0.providerID.rawValue < $1.providerID.rawValue : left > right
        }
        let total = combinedUsage(providers.map(\.usage))
        let models = providers.flatMap(\.models)
        let hasCompleteBreakdown = models.allSatisfy { model in
            let components = model.inputTokens + model.outputTokens
                + (model.inputIncludesCache ? 0 : model.cacheReadTokens + model.cacheWriteTokens)
            return model.reportedTotalTokens == nil || model.reportedTotalTokens == components
        }
        // Codex 的输入已含缓存；Claude 的读写缓存要补进输入分母，只有读缓存算命中。
        let effectiveInput = hasCompleteBreakdown ? models.reduce(Int64.zero) {
            $0 + $1.inputTokens + ($1.inputIncludesCache ? 0 : $1.cacheReadTokens + $1.cacheWriteTokens)
        } : nil
        let output = hasCompleteBreakdown ? models.reduce(Int64.zero) { $0 + $1.outputTokens } : nil
        let cacheRead = hasCompleteBreakdown ? models.reduce(Int64.zero) { $0 + $1.cacheReadTokens } : nil
        let input = effectiveInput.flatMap { effective in cacheRead.map { effective - $0 } }
        let cacheHitRate: Double?
        if let effectiveInput, effectiveInput > 0, let cacheRead {
            cacheHitRate = Double(cacheRead) / Double(effectiveInput)
        } else {
            cacheHitRate = nil
        }

        var history: [Date: [DailyTokenUsage]] = [:]
        let earliest = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        for usage in localUsages {
            for point in usage.last30DaysDaily {
                let day = calendar.startOfDay(for: point.date)
                guard day >= earliest, day < today else { continue }
                history[day, default: []].append(point.usage)
            }
        }
        let historicalDays = history.mapValues(combinedUsage)
        let activeHistory = historicalDays.values.filter { $0.tokens > 0 }
        let average: Double?
        if !activeHistory.isEmpty, activeHistory.allSatisfy({ $0.valueUSD != nil }) {
            average = activeHistory.reduce(0) { $0 + ($1.valueUSD ?? 0) } / Double(activeHistory.count)
        } else {
            average = nil
        }
        let comparison: Double?
        if let average, average > 0, let value = total.valueUSD {
            comparison = value / average
        } else {
            comparison = nil
        }

        var consecutiveDays = 0
        if total.tokens > 0 {
            for offset in 0..<30 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                      offset == 0 || (historicalDays[day]?.tokens ?? 0) > 0 else { break }
                consecutiveDays += 1
            }
        }
        return DailyBillData(
            day: today,
            issuedAt: now,
            providers: providers,
            totalUsage: total,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheHitRate: cacheHitRate,
            hasCompleteTokenBreakdown: hasCompleteBreakdown,
            consecutiveDays: consecutiveDays,
            consecutiveDaysCapped: consecutiveDays == 30,
            previousActiveDayAverageUSD: average,
            comparisonToDailyAverage: comparison
        )
    }

    private static func combinedUsage(_ usages: [DailyTokenUsage]) -> DailyTokenUsage {
        let tokens = usages.reduce(Int64.zero) { $0 + $1.tokens }
        let hasUnpricedTokens = usages.contains { $0.tokens > 0 && $0.valueUSD == nil }
        let values = usages.compactMap { $0.valueUSD ?? $0.partialValueUSD }
        return DailyTokenUsage(
            tokens: tokens,
            valueUSD: hasUnpricedTokens ? nil : values.reduce(0, +),
            partialValueUSD: hasUnpricedTokens && !values.isEmpty ? values.reduce(0, +) : nil
        )
    }
}
