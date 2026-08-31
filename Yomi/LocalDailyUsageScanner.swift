import Foundation

enum LocalDailyUsageScanner {
    private struct Tokens: Equatable {
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0

        var codexTotal: Int { input + output }
        var claudeTotal: Int { input + cacheRead + cacheWrite + output }
    }

    private struct ClaudeSample {
        let model: String
        let tokens: Tokens
        let cacheWrite1h: Int
    }

    private struct CodexTotalsTracker {
        private(set) var watermark: Tokens?
        private(set) var seen: [Tokens] = []
        private(set) var sawInterleavedTotals = false

        func contains(_ totals: Tokens) -> Bool {
            seen.contains(totals)
        }

        mutating func latchIfBelowWatermark(_ totals: Tokens) {
            guard let watermark else { return }
            if totals.input < watermark.input
                || totals.cacheRead < watermark.cacheRead
                || totals.output < watermark.output {
                sawInterleavedTotals = true
            }
        }

        mutating func commit(_ totals: Tokens) {
            raiseWatermark(to: totals)
            guard !seen.contains(totals) else { return }
            seen.append(totals)
            if seen.count > 64 {
                seen.removeFirst(seen.count - 64)
            }
        }

        mutating func raiseWatermark(to totals: Tokens) {
            watermark = maximum(watermark, totals)
        }
    }

    private struct CodexAccumulator {
        var countedTotals: Tokens?
        var rawTotalsBaseline: Tokens?
        var sawDivergentTotals = false
        var tracker = CodexTotalsTracker()

        mutating func apply(last: Tokens?, total: Tokens?) -> Tokens? {
            if let total {
                if tracker.contains(total) { return nil }
                let staleBaseline = tracker.watermark ?? rawTotalsBaseline
                if let staleBaseline, looksLikeStaleRegression(
                    current: total,
                    previous: staleBaseline,
                    last: last ?? Tokens()
                ) {
                    return nil
                }
                tracker.latchIfBelowWatermark(total)
            }

            let watermarkBaseline = tracker.watermark ?? rawTotalsBaseline
            defer {
                if let total { tracker.commit(total) }
            }

            func totalsDerivedDelta(to current: Tokens) -> Tokens {
                if tracker.sawInterleavedTotals {
                    return containedDelta(
                        watermark: watermarkBaseline,
                        counted: countedTotals,
                        current: current
                    )
                }
                if sawDivergentTotals {
                    return divergentDelta(
                        rawBaseline: watermarkBaseline,
                        countedBaseline: countedTotals,
                        current: current
                    )
                }
                return totalDelta(from: watermarkBaseline, to: current)
            }

            func commitDelta(_ delta: Tokens, rawBaseline: Tokens) {
                countedTotals = add(countedTotals ?? Tokens(), delta)
                rawTotalsBaseline = rawBaseline
                if rawTotalsBaseline != countedTotals {
                    sawDivergentTotals = true
                }
            }

            if let last {
                var delta = last
                if let total {
                    if tracker.sawInterleavedTotals {
                        delta = postLatchDelta(
                            watermark: watermarkBaseline,
                            counted: countedTotals,
                            current: total,
                            last: last
                        )
                    } else {
                        let fromTotal = totalDelta(from: watermarkBaseline, to: total)
                        if shouldPreferTotalDelta(
                            rawBaseline: watermarkBaseline,
                            current: total,
                            totalDelta: fromTotal,
                            lastDelta: last,
                            sawDivergentTotals: sawDivergentTotals
                        ) {
                            delta = fromTotal
                        }
                    }
                    commitDelta(delta, rawBaseline: total)
                } else {
                    countedTotals = add(countedTotals ?? Tokens(), delta)
                    rawTotalsBaseline = countedTotals
                    tracker.raiseWatermark(to: countedTotals ?? Tokens())
                }
                return delta
            }

            if let total {
                let delta = totalsDerivedDelta(to: total)
                commitDelta(delta, rawBaseline: total)
                return delta
            }
            return nil
        }
    }

    static func scan(
        providerID: ProviderID,
        now: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pricingCatalog: ModelPricingCatalog? = nil
    ) -> DailyTokenUsage? {
        switch providerID.rawValue {
        case "codex": scanCodex(now: now, homeDirectory: homeDirectory, pricingCatalog: pricingCatalog)
        case "claude": scanClaude(now: now, homeDirectory: homeDirectory, pricingCatalog: pricingCatalog)
        default: nil
        }
    }

    private static func scanCodex(
        now: Date,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?
    ) -> DailyTokenUsage? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let root = homeDirectory.appending(
            path: String(format: ".codex/sessions/%04d/%02d/%02d", year, month, day)
        )
        let files = filesModified(since: start, below: root)

        var totalTokens: Int64 = 0
        var totalCost = 0.0
        var hasUnpricedTokens = false

        for file in files {
            var currentModel: String?
            var accumulator = CodexAccumulator()
            readJSONLines(
                from: file,
                matchingAny: [#""type":"turn_context""#, #""type":"token_count""#]
            ) { object in
                let type = object["type"] as? String
                if type == "turn_context", let payload = object["payload"] as? [String: Any] {
                    currentModel = string(payload["model"]) ?? string(payload["model_name"])
                    return
                }
                guard type == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let timestamp = date(object["timestamp"])
                else { return }

                let model = string(info["model"])
                    ?? string(info["model_name"])
                    ?? string(payload["model"])
                    ?? currentModel
                let last = tokenValues(info["last_token_usage"])
                let cumulative = tokenValues(info["total_token_usage"])

                let delta = accumulator.apply(last: last, total: cumulative)

                guard timestamp >= start, timestamp < end, let delta, delta.codexTotal > 0 else { return }
                totalTokens += Int64(delta.codexTotal)
                if let model, let rates = codexRates(for: model, catalog: pricingCatalog) {
                    totalCost += codexCost(tokens: delta, rates: rates)
                } else {
                    hasUnpricedTokens = true
                }
            }
        }

        guard totalTokens > 0 else { return nil }
        return DailyTokenUsage(tokens: totalTokens, valueUSD: hasUnpricedTokens ? nil : totalCost)
    }

    private static func scanClaude(
        now: Date,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?
    ) -> DailyTokenUsage? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let root = homeDirectory.appending(path: ".claude/projects")
        let files = filesModified(since: start, below: root)

        var keyedSamples: [String: ClaudeSample] = [:]
        var unkeyedSamples: [ClaudeSample] = []
        for file in files {
            readJSONLines(
                from: file,
                matchingAny: [#""type":"assistant""#]
            ) { object in
                guard object["type"] as? String == "assistant",
                      let timestamp = date(object["timestamp"]),
                      timestamp >= start, timestamp < end,
                      let message = object["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usage = message["usage"] as? [String: Any]
                else { return }

                let tokens = Tokens(
                    input: integer(usage["input_tokens"]),
                    cacheRead: integer(usage["cache_read_input_tokens"]),
                    cacheWrite: integer(usage["cache_creation_input_tokens"]),
                    output: integer(usage["output_tokens"])
                )
                guard tokens.claudeTotal > 0 else { return }

                let cacheCreation = usage["cache_creation"] as? [String: Any]
                let sample = ClaudeSample(
                    model: model,
                    tokens: tokens,
                    cacheWrite1h: min(
                        tokens.cacheWrite,
                        integer(cacheCreation?["ephemeral_1h_input_tokens"])
                    )
                )
                if let messageID = message["id"] as? String,
                   let requestID = object["requestId"] as? String {
                    keyedSamples["\(messageID):\(requestID)"] = sample
                } else {
                    unkeyedSamples.append(sample)
                }
            }
        }

        let samples = Array(keyedSamples.values) + unkeyedSamples
        guard !samples.isEmpty else { return nil }
        var totalTokens: Int64 = 0
        var totalCost = 0.0
        var hasUnpricedTokens = false
        for sample in samples {
            totalTokens += Int64(sample.tokens.claudeTotal)
            if let rates = claudeRates(for: sample.model, catalog: pricingCatalog) {
                totalCost += claudeCost(sample: sample, rates: rates)
            } else {
                hasUnpricedTokens = true
            }
        }
        return DailyTokenUsage(tokens: totalTokens, valueUSD: hasUnpricedTokens ? nil : totalCost)
    }

    private static func filesModified(since start: Date, below root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { element -> URL? in
            guard let url = element as? URL,
                  url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= start
            else { return nil }
            return url
        }
    }

    private static func readJSONLines(
        from url: URL,
        matchingAny patterns: [String],
        handle: ([String: Any]) -> Void
    ) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        let bytePatterns = patterns.map { Data($0.utf8) }

        func process(_ line: Data.SubSequence) {
            guard bytePatterns.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return }
            handle(object)
        }

        var pending = Data()
        var discardingOversizedLine = false
        let maximumLineBytes = 512 * 1024
        while var chunk = try? file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if discardingOversizedLine {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                chunk.removeSubrange(chunk.startIndex...newline)
                discardingOversizedLine = false
            }
            pending.append(chunk)
            var lineStart = pending.startIndex
            while lineStart < pending.endIndex,
                  let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<newline]
                if line.count <= maximumLineBytes {
                    process(line)
                }
                lineStart = pending.index(after: newline)
            }
            if lineStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<lineStart)
            }
            if pending.count > maximumLineBytes {
                pending.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }
        if !discardingOversizedLine, !pending.isEmpty {
            process(pending[pending.startIndex..<pending.endIndex])
        }
    }

    private static func tokenValues(_ value: Any?) -> Tokens? {
        guard let usage = value as? [String: Any] else { return nil }
        return Tokens(
            input: integer(usage["input_tokens"]),
            cacheRead: max(
                integer(usage["cached_input_tokens"]),
                integer(usage["cache_read_input_tokens"])
            ),
            cacheWrite: integer(usage["cache_write_input_tokens"]),
            output: integer(usage["output_tokens"])
        )
    }

    private static func integer(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return parsed
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }

    private static func isAtLeast(_ lhs: Tokens, _ rhs: Tokens) -> Bool {
        lhs.input >= rhs.input
            && lhs.cacheRead >= rhs.cacheRead
            && lhs.cacheWrite >= rhs.cacheWrite
            && lhs.output >= rhs.output
    }

    private static func subtract(_ lhs: Tokens, _ rhs: Tokens) -> Tokens {
        Tokens(
            input: max(0, lhs.input - rhs.input),
            cacheRead: max(0, lhs.cacheRead - rhs.cacheRead),
            cacheWrite: max(0, lhs.cacheWrite - rhs.cacheWrite),
            output: max(0, lhs.output - rhs.output)
        )
    }

    private static func add(_ lhs: Tokens, _ rhs: Tokens) -> Tokens {
        Tokens(
            input: lhs.input + rhs.input,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output
        )
    }

    private static func maximum(_ lhs: Tokens?, _ rhs: Tokens) -> Tokens {
        guard let lhs else { return rhs }
        return Tokens(
            input: max(lhs.input, rhs.input),
            cacheRead: max(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: max(lhs.cacheWrite, rhs.cacheWrite),
            output: max(lhs.output, rhs.output)
        )
    }

    private static func minimum(_ lhs: Tokens, _ rhs: Tokens) -> Tokens {
        Tokens(
            input: min(lhs.input, rhs.input),
            cacheRead: min(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: min(lhs.cacheWrite, rhs.cacheWrite),
            output: min(lhs.output, rhs.output)
        )
    }

    private static func totalDelta(from baseline: Tokens?, to current: Tokens) -> Tokens {
        subtract(current, baseline ?? Tokens())
    }

    private static func divergentDelta(
        rawBaseline: Tokens?,
        countedBaseline: Tokens?,
        current: Tokens
    ) -> Tokens {
        let raw = rawBaseline ?? Tokens()
        let counted = countedBaseline ?? Tokens()
        func component(raw: Int, counted: Int, current: Int) -> Int {
            current >= raw ? max(0, current - raw) : max(0, current - counted)
        }
        return Tokens(
            input: component(raw: raw.input, counted: counted.input, current: current.input),
            cacheRead: component(raw: raw.cacheRead, counted: counted.cacheRead, current: current.cacheRead),
            cacheWrite: component(raw: raw.cacheWrite, counted: counted.cacheWrite, current: current.cacheWrite),
            output: component(raw: raw.output, counted: counted.output, current: current.output)
        )
    }

    private static func containedDelta(
        watermark: Tokens?,
        counted: Tokens?,
        current: Tokens
    ) -> Tokens {
        let watermark = watermark ?? Tokens()
        let counted = counted ?? Tokens()
        func component(watermark: Int, counted: Int, current: Int) -> Int {
            if current >= watermark {
                return max(0, current - max(watermark, counted))
            }
            return max(0, current - counted)
        }
        return Tokens(
            input: component(watermark: watermark.input, counted: counted.input, current: current.input),
            cacheRead: component(
                watermark: watermark.cacheRead,
                counted: counted.cacheRead,
                current: current.cacheRead
            ),
            cacheWrite: component(
                watermark: watermark.cacheWrite,
                counted: counted.cacheWrite,
                current: current.cacheWrite
            ),
            output: component(watermark: watermark.output, counted: counted.output, current: current.output)
        )
    }

    private static func postLatchDelta(
        watermark: Tokens?,
        counted: Tokens?,
        current: Tokens,
        last: Tokens?
    ) -> Tokens {
        let contained = containedDelta(watermark: watermark, counted: counted, current: current)
        guard let last else { return contained }
        return minimum(last, contained)
    }

    private static func shouldPreferTotalDelta(
        rawBaseline: Tokens?,
        current: Tokens,
        totalDelta: Tokens,
        lastDelta: Tokens,
        sawDivergentTotals: Bool
    ) -> Bool {
        guard !sawDivergentTotals, let rawBaseline else { return false }
        return isAtLeast(current, rawBaseline) && isAtMost(totalDelta, lastDelta)
    }

    private static func isAtMost(_ lhs: Tokens, _ rhs: Tokens) -> Bool {
        lhs.input <= rhs.input
            && lhs.cacheRead <= rhs.cacheRead
            && lhs.cacheWrite <= rhs.cacheWrite
            && lhs.output <= rhs.output
    }

    private static func looksLikeStaleRegression(
        current: Tokens,
        previous: Tokens,
        last: Tokens
    ) -> Bool {
        guard current.input < previous.input
            || current.cacheRead < previous.cacheRead
            || current.output < previous.output
        else { return false }
        let previousTotal = previous.input + previous.output + previous.cacheRead
        let currentTotal = current.input + current.output + current.cacheRead
        let lastTotal = last.input + last.output + last.cacheRead
        if previousTotal <= 0 || currentTotal <= 0 || lastTotal <= 0 { return false }
        return currentTotal * 100 >= previousTotal * 98
            || currentTotal + lastTotal * 2 >= previousTotal
    }

    private static func codexCost(tokens: Tokens, rates: ModelTokenRates) -> Double {
        let cached = min(tokens.cacheRead, tokens.input)
        let uncached = max(0, tokens.input - cached)
        let aboveThreshold = rates.threshold.map { tokens.input > $0 } ?? false
        let inputRate = aboveThreshold ? rates.inputAboveThreshold ?? rates.input : rates.input
        let cachedRate = (aboveThreshold ? rates.cacheReadAboveThreshold ?? rates.cacheRead : rates.cacheRead)
            ?? inputRate
        let outputRate = aboveThreshold ? rates.outputAboveThreshold ?? rates.output : rates.output
        let inputCost = Double(uncached) * inputRate
        let cacheCost = Double(cached) * cachedRate
        let outputCost = Double(tokens.output) * outputRate
        return inputCost + cacheCost + outputCost
    }

    private static func claudeCost(sample: ClaudeSample, rates: ModelTokenRates) -> Double {
        let tokens = sample.tokens
        let cacheWrite1h = min(tokens.cacheWrite, sample.cacheWrite1h)
        let cacheWrite5m = tokens.cacheWrite - cacheWrite1h
        let contextTokens = tokens.input + tokens.cacheRead + tokens.cacheWrite
        let aboveThreshold = rates.threshold.map { contextTokens > $0 } ?? false
        let inputRate = aboveThreshold ? rates.inputAboveThreshold ?? rates.input : rates.input
        let readRate = (aboveThreshold ? rates.cacheReadAboveThreshold ?? rates.cacheRead : rates.cacheRead)
            ?? inputRate
        let writeRate = (aboveThreshold ? rates.cacheWriteAboveThreshold ?? rates.cacheWrite : rates.cacheWrite)
            ?? inputRate
        let outputRate = aboveThreshold ? rates.outputAboveThreshold ?? rates.output : rates.output
        let inputCost = Double(tokens.input) * inputRate
        let readCost = Double(tokens.cacheRead) * readRate
        let write5mCost = Double(cacheWrite5m) * writeRate
        let write1hCost = Double(cacheWrite1h) * inputRate * 2
        let outputCost = Double(tokens.output) * outputRate
        return inputCost + readCost + write5mCost + write1hCost + outputCost
    }

    private static func codexRates(
        for rawModel: String,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        let model = rawModel.lowercased()
        if var rates = catalog?.rates(providerID: "openai", modelID: normalizedCodexModel(model)) {
            if ["gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
                .contains(normalizedCodexModel(model)) {
                rates.threshold = 272_000
            }
            return rates
        }
        return switch model {
        case let value where value.contains("gpt-5.6-sol"),
             let value where value.contains("gpt-5.5"):
            ModelTokenRates(
                input: 5e-6, cacheRead: 5e-7, cacheWrite: 6.25e-6, output: 3e-5,
                threshold: 272_000, inputAboveThreshold: 1e-5,
                cacheReadAboveThreshold: 1e-6, cacheWriteAboveThreshold: 1.25e-5,
                outputAboveThreshold: 4.5e-5
            )
        case let value where value.contains("gpt-5.6-terra"):
            ModelTokenRates(
                input: 2e-6, cacheRead: 2e-7, cacheWrite: 2.5e-6, output: 1.2e-5,
                threshold: 272_000, inputAboveThreshold: 4e-6,
                cacheReadAboveThreshold: 4e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 1.8e-5
            )
        case let value where value.contains("gpt-5.6-luna"):
            ModelTokenRates(
                input: 2e-7, cacheRead: 2e-8, cacheWrite: 2.5e-7, output: 1.2e-6,
                threshold: 272_000, inputAboveThreshold: 4e-7,
                cacheReadAboveThreshold: 4e-8, cacheWriteAboveThreshold: 5e-7,
                outputAboveThreshold: 1.8e-6
            )
        case let value where value.contains("gpt-5.4-mini"):
            ModelTokenRates(input: 7.5e-7, cacheRead: 7.5e-8, cacheWrite: 7.5e-7, output: 4.5e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case let value where value.contains("gpt-5.4"):
            ModelTokenRates(
                input: 2.5e-6, cacheRead: 2.5e-7, cacheWrite: 2.5e-6, output: 1.5e-5,
                threshold: 272_000, inputAboveThreshold: 5e-6,
                cacheReadAboveThreshold: 5e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 2.25e-5
            )
        case let value where value.contains("gpt-5.3"),
             let value where value.contains("gpt-5.2"):
            ModelTokenRates(input: 1.75e-6, cacheRead: 1.75e-7, cacheWrite: 1.75e-6, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case let value where value.contains("gpt-5.1-mini"),
             let value where value.contains("gpt-5-mini"):
            ModelTokenRates(input: 2.5e-7, cacheRead: 2.5e-8, cacheWrite: 2.5e-7, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case let value where value.contains("gpt-5"):
            ModelTokenRates(input: 1.25e-6, cacheRead: 1.25e-7, cacheWrite: 1.25e-6, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        default:
            nil
        }
    }

    private static func claudeRates(
        for rawModel: String,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        let model = rawModel.lowercased()
        if let rates = catalog?.rates(providerID: "anthropic", modelID: model) {
            return rates
        }
        if model.contains("fable") {
            return ModelTokenRates(input: 1e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if model.contains("haiku") {
            return ModelTokenRates(input: 1e-6, cacheRead: 1e-7, cacheWrite: 1.25e-6, output: 5e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if model.contains("sonnet") {
            return ModelTokenRates(
                input: 3e-6, cacheRead: 3e-7, cacheWrite: 3.75e-6, output: 1.5e-5,
                threshold: model.contains("4-5") || model.contains("4-20250514") ? 200_000 : nil,
                inputAboveThreshold: 6e-6, cacheReadAboveThreshold: 6e-7,
                cacheWriteAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5
            )
        }
        if model.contains("opus-4-20250514") || model.contains("opus-4-1") {
            return ModelTokenRates(input: 1.5e-5, cacheRead: 1.5e-6, cacheWrite: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if model.contains("opus") {
            return ModelTokenRates(input: 5e-6, cacheRead: 5e-7, cacheWrite: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        return nil
    }

    private static func normalizedCodexModel(_ model: String) -> String {
        if model == "gpt-5.6" { return "gpt-5.6-sol" }
        if let dated = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(model[..<dated.lowerBound])
        }
        return model
    }
}
