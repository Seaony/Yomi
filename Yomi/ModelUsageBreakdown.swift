import Foundation

nonisolated enum ModelUsageBreakdown {
    static let unknownModel = "__unknown__"
    static let otherModels = "__other__"

    static func merged(_ rows: [ModelTokenUsage]) -> [ModelTokenUsage] {
        var byModel: [String: ModelTokenUsage] = [:]
        for row in rows where row.tokens > 0 || row.valueUSD != nil || row.partialValueUSD != nil {
            add(row, to: &byModel)
        }
        return sorted(Array(byModel.values))
    }

    static func displayRows(_ rows: [ModelTokenUsage], topCount: Int = 5) -> [ModelTokenUsage] {
        let rows = merged(rows)
        let count = max(0, topCount)
        guard rows.count > count else { return rows }
        let other = rows.dropFirst(count).map { row in
            var copy = row
            copy.model = otherModels
            return copy
        }
        return Array(rows.prefix(count)) + merged(other)
    }

    static func fraction(_ row: ModelTokenUsage, totalTokens: Int64) -> Double {
        guard totalTokens > 0 else { return 0 }
        return Double(row.tokens) / Double(totalTokens)
    }

    static func add(_ row: ModelTokenUsage, to byModel: inout [String: ModelTokenUsage]) {
        var row = row
        let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
        row.model = model.isEmpty ? unknownModel : model
        guard let previous = byModel[row.model] else {
            byModel[row.model] = row
            return
        }
        byModel[row.model] = combined(previous, row)
    }

    static func sorted(_ rows: [ModelTokenUsage]) -> [ModelTokenUsage] {
        rows.sorted {
            $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens
        }
    }

    private static func combined(_ first: ModelTokenUsage, _ second: ModelTokenUsage) -> ModelTokenUsage {
        var first = first
        var second = second
        let total = first.tokens + second.tokens
        // 同一模型可能同时由 Codex 和 Claude 记录，合并前统一缓存是否已包含在输入中的口径。
        if first.inputIncludesCache != second.inputIncludesCache {
            first = excludingCachedInput(first)
            second = excludingCachedInput(second)
        }
        let fullyPriced = first.valueUSD != nil && second.valueUSD != nil
        let knownCosts = [first.valueUSD ?? first.partialValueUSD, second.valueUSD ?? second.partialValueUSD]
            .compactMap { $0 }
        let cost = knownCosts.reduce(0, +)
        var result = ModelTokenUsage(
            model: first.model,
            inputTokens: first.inputTokens + second.inputTokens,
            cacheReadTokens: first.cacheReadTokens + second.cacheReadTokens,
            cacheWriteTokens: first.cacheWriteTokens + second.cacheWriteTokens,
            outputTokens: first.outputTokens + second.outputTokens,
            inputIncludesCache: first.inputIncludesCache,
            valueUSD: fullyPriced ? cost : nil,
            partialValueUSD: !fullyPriced && !knownCosts.isEmpty ? cost : nil
        )
        if result.tokens != total { result.reportedTotalTokens = total }
        return result
    }

    private static func excludingCachedInput(_ row: ModelTokenUsage) -> ModelTokenUsage {
        guard row.inputIncludesCache else { return row }
        var result = row
        result.inputTokens = max(0, row.inputTokens - row.cacheReadTokens - row.cacheWriteTokens)
        result.inputIncludesCache = false
        if result.tokens != row.tokens { result.reportedTotalTokens = row.tokens }
        return result
    }
}
