import Darwin
import Foundation

actor LocalDailyUsageScanner {
    private static let codexGPT56PricingCutoff = Date(timeIntervalSince1970: 1_785_369_600)
    private static let codexGPT56SolPromotionCutoff = Date(timeIntervalSince1970: 1_787_270_400)
    private static let claudeFullContextPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)

    private enum RateResolution {
        case priced(ModelTokenRates)
        case unpriced
    }

    private struct Tokens: Codable, Equatable, Hashable {
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0

        var codexTotal: Int { input + output }
        var claudeTotal: Int { input + cacheRead + cacheWrite + output }
    }

    private struct ClaudeSample: Codable {
        let timestamp: Date
        let model: String
        let tokens: Tokens
        let cacheWrite1h: Int
        let isSidechain: Bool
    }

    private struct CodexEventKey: Codable, Hashable {
        let total: Tokens?
        let last: Tokens?
    }

    private struct CodexSample: Codable {
        let timestamp: Date
        let model: String?
        let tokens: Tokens
        let eventKey: CodexEventKey?
        let turnID: String?
    }

    private struct JSONLResumeState: Codable {
        var offset: UInt64 = 0
        var discardingOversizedLine = false
    }

    private struct JSONLReadResult {
        let resumeState: JSONLResumeState
        let observedFileSize: UInt64
    }

    private struct LogFile {
        let url: URL
        let size: UInt64
        let modificationNanoseconds: Int64
        let fileID: String
    }

    private struct LogTokenUsage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheWriteInputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheWriteInputTokens = "cache_write_input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct CodexLogLine: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let model: String?
            let modelName: String?
            let info: Info?
            let id: String?
            let sessionID: String?
            let sessionId: String?
            let turnID: String?
            let turnId: String?
            let forkedFromID: String?
            let parentThreadID: String?
            let parentSessionID: String?
            let source: Source?

            enum CodingKeys: String, CodingKey {
                case type
                case model
                case modelName = "model_name"
                case info
                case id
                case sessionID = "session_id"
                case sessionId
                case turnID = "turn_id"
                case turnId
                case forkedFromID = "forked_from_id"
                case parentThreadID = "parent_thread_id"
                case parentSessionID = "parent_session_id"
                case source
            }
        }

        struct Source: Decodable {
            let subagent: Subagent?
        }

        struct Subagent: Decodable {
            let threadSpawn: ThreadSpawn?

            enum CodingKeys: String, CodingKey {
                case threadSpawn = "thread_spawn"
            }
        }

        struct ThreadSpawn: Decodable {
            let parentThreadID: String?

            enum CodingKeys: String, CodingKey {
                case parentThreadID = "parent_thread_id"
            }
        }

        struct Info: Decodable {
            let model: String?
            let modelName: String?
            let lastTokenUsage: LogTokenUsage?
            let totalTokenUsage: LogTokenUsage?

            enum CodingKeys: String, CodingKey {
                case model
                case modelName = "model_name"
                case lastTokenUsage = "last_token_usage"
                case totalTokenUsage = "total_token_usage"
            }
        }
    }

    private struct ClaudeLogLine: Decodable {
        let type: String?
        let timestamp: String?
        let requestID: String?
        let isSidechain: Bool?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type
            case timestamp
            case requestID = "requestId"
            case isSidechain
            case message
        }

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?
            let outputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreation = "cache_creation"
            }
        }

        struct CacheCreation: Decodable {
            let ephemeral1hInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
            }
        }
    }

    private enum ClaudeLogProviderFilter {
        case all
        case vertexOnly
        case excludeVertex
    }

    private struct PeriodAccumulator {
        var tokens: Int64 = 0
        var valueUSD = 0.0
        var hasUnpricedTokens = false

        mutating func add(tokens: Int, valueUSD: Double?) {
            guard tokens > 0 else { return }
            self.tokens += Int64(tokens)
            if let valueUSD {
                self.valueUSD += valueUSD
            } else {
                hasUnpricedTokens = true
            }
        }

        var usage: DailyTokenUsage? {
            guard tokens > 0 else { return nil }
            return DailyTokenUsage(
                tokens: tokens,
                valueUSD: hasUnpricedTokens ? nil : valueUSD
            )
        }
    }

    private struct PeriodAccumulators {
        let todayStart: Date
        let last30DaysStart: Date
        let currentWeekStart: Date
        let end: Date
        var today = PeriodAccumulator()
        var last30Days = PeriodAccumulator()
        var currentWeek = PeriodAccumulator()
        var last30DaysDaily: [Date: PeriodAccumulator] = [:]

        mutating func add(timestamp: Date, tokens: Int, valueUSD: Double?) {
            guard timestamp < end else { return }
            if timestamp >= todayStart {
                today.add(tokens: tokens, valueUSD: valueUSD)
            }
            if timestamp >= last30DaysStart {
                last30Days.add(tokens: tokens, valueUSD: valueUSD)
                let day = Calendar.current.startOfDay(for: timestamp)
                last30DaysDaily[day, default: PeriodAccumulator()].add(
                    tokens: tokens,
                    valueUSD: valueUSD
                )
            }
            if timestamp >= currentWeekStart {
                currentWeek.add(tokens: tokens, valueUSD: valueUSD)
            }
        }

        var summary: LocalTokenUsageSummary? {
            let todayUsage = today.usage
            let last30DaysUsage = last30Days.usage
            let currentWeekUsage = currentWeek.usage
            guard todayUsage != nil || last30DaysUsage != nil || currentWeekUsage != nil else {
                return nil
            }
            return LocalTokenUsageSummary(
                today: todayUsage ?? DailyTokenUsage(tokens: 0, valueUSD: 0),
                last30Days: last30DaysUsage,
                currentWeek: currentWeekUsage,
                last30DaysDaily: last30DaysDaily.compactMap { date, accumulator in
                    accumulator.usage.map { DailyTokenUsagePoint(date: date, usage: $0) }
                }.sorted { $0.date < $1.date }
            )
        }
    }

    private struct CodexTotalsTracker: Codable {
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

    private struct CodexAccumulator: Codable {
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

    private struct CodexFileState: Codable {
        var size: UInt64 = 0
        var modificationNanoseconds: Int64 = 0
        var fileID = ""
        var resumeState = JSONLResumeState()
        var resumeFingerprint = Data()
        var sessionID: String?
        var parentID: String?
        var currentModel: String?
        var currentTurnID: String?
        var accumulator = CodexAccumulator()
        var samples: [CodexSample] = []
    }

    private struct ClaudeFileState: Codable {
        var size: UInt64 = 0
        var modificationNanoseconds: Int64 = 0
        var fileID = ""
        var resumeState = JSONLResumeState()
        var resumeFingerprint = Data()
        var keyedSamples: [String: ClaudeSample] = [:]
        var unkeyedSamples: [ClaudeSample] = []
    }

    private var codexFileStates: [String: CodexFileState] = [:]
    private var claudeFileStates: [String: ClaudeFileState] = [:]
    private var vertexFileStates: [String: ClaudeFileState] = [:]
    private var activeVertexCacheProvider: String?
    private var loadedProviders: Set<String> = []
    private let cacheStore = LocalUsageCacheStore()
    private let priorityTurnStore = CodexPriorityTurnStore()
    private let cacheEncoder = JSONEncoder()
    private let cacheDecoder = JSONDecoder()
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormatter = ISO8601DateFormatter()

    func scan(
        providerID: ProviderID,
        currentWeekStart: Date,
        now: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pricingCatalog: ModelPricingCatalog? = nil,
        allowVertexClaudeFallback: Bool = false
    ) -> LocalTokenUsageSummary? {
        let cacheProvider = switch providerID.rawValue {
        case "claude": "claude-filtered"
        case "vertexai": allowVertexClaudeFallback ? "vertexai-all" : "vertexai-only"
        default: providerID.rawValue
        }
        if providerID.rawValue == "vertexai", activeVertexCacheProvider != cacheProvider {
            vertexFileStates = [:]
            activeVertexCacheProvider = cacheProvider
        }
        loadCachedStatesIfNeeded(provider: cacheProvider)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let last30DaysStart = calendar.date(byAdding: .day, value: -29, to: todayStart)
        else { return nil }
        let periods = PeriodAccumulators(
            todayStart: todayStart,
            last30DaysStart: last30DaysStart,
            currentWeekStart: currentWeekStart,
            end: end
        )
        return switch providerID.rawValue {
        case "codex": scanCodex(
            periods: periods,
            homeDirectory: homeDirectory,
            pricingCatalog: pricingCatalog
        )
        case "claude": scanClaude(
            periods: periods,
            homeDirectory: homeDirectory,
            pricingCatalog: pricingCatalog,
            cacheProvider: cacheProvider,
            filter: .excludeVertex
        )
        case "vertexai": scanClaude(
            periods: periods,
            homeDirectory: homeDirectory,
            pricingCatalog: pricingCatalog,
            cacheProvider: cacheProvider,
            filter: allowVertexClaudeFallback ? .all : .vertexOnly
        )
        default: nil
        }
    }

    private func scanCodex(
        periods: PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?
    ) -> LocalTokenUsageSummary? {
        let files = Self.logFiles(
            modifiedSince: periods.last30DaysStart,
            below: Self.codexSessionRoots(homeDirectory: homeDirectory)
        )
        let currentPaths = Set(files.map { $0.url.path })
        let deletedPaths = Set(codexFileStates.keys).subtracting(currentPaths)
        var changedPaths: Set<String> = []
        for file in files where codexFileStates[file.url.path] == nil {
            guard let renamedPath = deletedPaths.first(where: { path in
                guard let state = codexFileStates[path] else { return false }
                return state.fileID == file.fileID
                    && state.size <= file.size
                    && !state.resumeFingerprint.isEmpty
                    && Self.resumeFingerprint(
                        for: file.url,
                        endingAt: state.resumeState.offset
                    ) == state.resumeFingerprint
            }), let state = codexFileStates[renamedPath] else { continue }
            codexFileStates[file.url.path] = state
            changedPaths.insert(file.url.path)
        }
        codexFileStates = codexFileStates.filter { currentPaths.contains($0.key) }

        for file in files {
            let path = file.url.path
            var state = codexFileStates[path] ?? CodexFileState()
            let previousSampleCount = state.samples.count
            state.samples.removeAll {
                $0.timestamp < periods.last30DaysStart || $0.timestamp >= periods.end
            }
            if state.samples.count != previousSampleCount {
                changedPaths.insert(path)
            }

            if state.fileID == file.fileID,
               state.size == file.size,
               state.modificationNanoseconds == file.modificationNanoseconds {
                codexFileStates[path] = state
                continue
            }
            if state.size > 0, !Self.canResume(
                file: file,
                fileID: state.fileID,
                previousSize: state.size,
                resumeState: state.resumeState,
                fingerprint: state.resumeFingerprint
            ) {
                state = CodexFileState()
            }

            let resumeState = state.resumeState
            let readResult = Self.readJSONLines(
                from: file.url,
                resumeState: resumeState,
                matchingAny: [
                    #""type":"session_meta""#,
                    #""type":"turn_context""#,
                    #""type":"task_started""#,
                    #""type":"token_count""#,
                ],
                as: CodexLogLine.self
            ) { line in
                if line.type == "session_meta", let payload = line.payload {
                    state.sessionID = payload.id
                        ?? payload.sessionID
                        ?? payload.sessionId
                        ?? state.sessionID
                    state.parentID = Self.codexParentID(payload) ?? state.parentID
                    return
                }
                if line.type == "turn_context", let payload = line.payload {
                    state.currentModel = payload.model ?? payload.modelName
                    return
                }
                if line.type == "event_msg", let payload = line.payload,
                   payload.type == "task_started" {
                    state.currentTurnID = payload.turnID ?? payload.turnId ?? payload.id
                    return
                }
                guard line.type == "event_msg",
                      let payload = line.payload,
                      payload.type == "token_count",
                      let info = payload.info,
                      let timestamp = date(line.timestamp)
                else { return }

                let model = info.model
                    ?? info.modelName
                    ?? payload.model
                    ?? state.currentModel
                let last = Self.tokenValues(info.lastTokenUsage)
                let cumulative = Self.tokenValues(info.totalTokenUsage)

                let delta = state.accumulator.apply(last: last, total: cumulative)

                guard let delta,
                      delta.codexTotal > 0,
                      timestamp >= periods.last30DaysStart,
                      timestamp < periods.end
                else { return }
                state.samples.append(CodexSample(
                    timestamp: timestamp,
                    model: model,
                    tokens: delta,
                    eventKey: cumulative == nil && last == nil
                        ? nil
                        : CodexEventKey(total: cumulative, last: last),
                    turnID: payload.turnID ?? payload.turnId ?? state.currentTurnID
                ))
            }
            state.resumeState = readResult.resumeState
            let latest = Self.fileMetadata(for: file.url) ?? file
            state.size = readResult.observedFileSize
            state.modificationNanoseconds = latest.modificationNanoseconds
            state.fileID = latest.fileID
            state.resumeFingerprint = Self.resumeFingerprint(
                for: file.url,
                endingAt: state.resumeState.offset
            )
            codexFileStates[path] = state
            changedPaths.insert(path)
        }
        persistCodexStates(changedPaths: changedPaths, deletedPaths: deletedPaths)

        let priorityTurns = priorityTurnStore.turnsByID(
            databaseURL: Self.codexHomeDirectory(homeDirectory: homeDirectory)
                .appending(path: "logs_2.sqlite"),
            since: periods.last30DaysStart
        )
        let sessions = Self.canonicalCodexSessions(codexFileStates)
        let droppedPrefixes = Self.replayedCodexPrefixes(sessions)
        var accumulated = periods
        var rateCache: [String: RateResolution] = [:]
        for (path, state) in sessions {
            let droppedCount = droppedPrefixes[path] ?? 0
            for sample in state.samples.dropFirst(droppedCount) {
                let priorityTurn = sample.turnID.flatMap { priorityTurns[$0] }
                let pricedModel = Self.codexPricedModel(sample: sample, priorityTurn: priorityTurn)
                let rates = pricedModel.flatMap { model -> ModelTokenRates? in
                    let era: String
                    if sample.timestamp < Self.codexGPT56PricingCutoff {
                        era = "pre-family-reduction"
                    } else if sample.timestamp < Self.codexGPT56SolPromotionCutoff {
                        era = "pre-sol-promotion"
                    } else {
                        era = "current"
                    }
                    let key = "\(era):\(model)"
                    if let cached = rateCache[key] {
                        if case let .priced(rates) = cached { return rates }
                        return nil
                    }
                    guard let rates = Self.codexRates(
                        for: model,
                        at: sample.timestamp,
                        catalog: pricingCatalog
                    ) else {
                        rateCache[key] = .unpriced
                        return nil
                    }
                    rateCache[key] = .priced(rates)
                    return rates
                }
                let valueUSD = rates.map { rates -> Double in
                    let base = Self.codexCost(tokens: sample.tokens, rates: rates)
                    guard priorityTurn != nil,
                          sample.tokens.input <= Self.codexFastInputTokenLimit,
                          let multiplier = pricedModel.flatMap(Self.codexFastMultiplier)
                    else { return base }
                    return base * multiplier
                }
                accumulated.add(
                    timestamp: sample.timestamp,
                    tokens: sample.tokens.codexTotal,
                    valueUSD: valueUSD
                )
            }
        }
        return accumulated.summary
    }

    private static func canonicalCodexSessions(
        _ states: [String: CodexFileState]
    ) -> [(path: String, state: CodexFileState)] {
        var selected: [String: (path: String, state: CodexFileState)] = [:]
        for (path, state) in states {
            let key = state.sessionID.map { "session:\($0)" }
                ?? "file:\(URL(fileURLWithPath: path).lastPathComponent)"
            let candidate = (path: path, state: state)
            guard let current = selected[key] else {
                selected[key] = candidate
                continue
            }
            if codexSession(candidate, isMoreCompleteThan: current) {
                selected[key] = candidate
            }
        }
        return selected.values.sorted { $0.path < $1.path }
    }

    private static func codexSession(
        _ candidate: (path: String, state: CodexFileState),
        isMoreCompleteThan current: (path: String, state: CodexFileState)
    ) -> Bool {
        if candidate.state.samples.count != current.state.samples.count {
            return candidate.state.samples.count > current.state.samples.count
        }
        let candidateLastDate = candidate.state.samples.last?.timestamp ?? .distantPast
        let currentLastDate = current.state.samples.last?.timestamp ?? .distantPast
        if candidateLastDate != currentLastDate {
            return candidateLastDate > currentLastDate
        }
        return candidate.state.size > current.state.size
    }

    private static func replayedCodexPrefixes(
        _ sessions: [(path: String, state: CodexFileState)]
    ) -> [String: Int] {
        let byID = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                session.state.sessionID.map { ($0, session) }
            }
        )
        var drops: [String: Int] = [:]

        for child in sessions {
            guard let parentID = child.state.parentID,
                  let parent = byID[parentID]
            else { continue }
            let count = matchingCodexPrefix(child.state.samples, parent.state.samples)
            if count > 0 { drops[child.path] = count }
        }

        for child in sessions where drops[child.path] == nil && child.state.samples.count >= 2 {
            var best = 0
            for parent in sessions
            where parent.path != child.path && parent.state.samples.count >= 2 {
                guard let childStart = child.state.samples.first?.timestamp,
                      let parentStart = parent.state.samples.first?.timestamp,
                      parentStart < childStart
                else { continue }
                best = max(best, matchingCodexPrefix(child.state.samples, parent.state.samples))
            }
            if best >= 2 { drops[child.path] = best }
        }
        return drops
    }

    private static func matchingCodexPrefix(
        _ lhs: [CodexSample],
        _ rhs: [CodexSample]
    ) -> Int {
        var count = 0
        while count < lhs.count,
              count < rhs.count,
              let left = lhs[count].eventKey,
              let right = rhs[count].eventKey,
              left == right {
            count += 1
        }
        return count
    }

    private static func codexParentID(_ payload: CodexLogLine.Payload) -> String? {
        payload.forkedFromID
            ?? payload.parentThreadID
            ?? payload.parentSessionID
            ?? payload.source?.subagent?.threadSpawn?.parentThreadID
    }

    private func scanClaude(
        periods: PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?,
        cacheProvider: String,
        filter: ClaudeLogProviderFilter
    ) -> LocalTokenUsageSummary? {
        let files = Self.logFiles(
            modifiedSince: periods.last30DaysStart,
            below: Self.claudeProjectRoots(homeDirectory: homeDirectory)
        )
        var fileStates = cacheProvider.hasPrefix("vertexai-") ? vertexFileStates : claudeFileStates
        let currentPaths = Set(files.map { $0.url.path })
        let deletedPaths = Set(fileStates.keys).subtracting(currentPaths)
        fileStates = fileStates.filter { currentPaths.contains($0.key) }
        var changedPaths: Set<String> = []

        for file in files {
            let path = file.url.path
            var state = fileStates[path] ?? ClaudeFileState()
            let previousKeyedCount = state.keyedSamples.count
            let previousUnkeyedCount = state.unkeyedSamples.count
            state.keyedSamples = state.keyedSamples.filter {
                $0.value.timestamp >= periods.last30DaysStart && $0.value.timestamp < periods.end
            }
            state.unkeyedSamples.removeAll {
                $0.timestamp < periods.last30DaysStart || $0.timestamp >= periods.end
            }
            if state.keyedSamples.count != previousKeyedCount
                || state.unkeyedSamples.count != previousUnkeyedCount {
                changedPaths.insert(path)
            }

            if state.fileID == file.fileID,
               state.size == file.size,
               state.modificationNanoseconds == file.modificationNanoseconds {
                fileStates[path] = state
                continue
            }
            if state.size > 0, !Self.canResume(
                file: file,
                fileID: state.fileID,
                previousSize: state.size,
                resumeState: state.resumeState,
                fingerprint: state.resumeFingerprint
            ) {
                state = ClaudeFileState()
            }

            let resumeState = state.resumeState
            let readResult = Self.readJSONLines(
                from: file.url,
                resumeState: resumeState,
                matchingAny: [#""type":"assistant""#],
                accepting: { value in
                    switch filter {
                    case .all: true
                    case .vertexOnly: VertexAILogClassifier.isVertexUsageEntry(value)
                    case .excludeVertex: !VertexAILogClassifier.isVertexUsageEntry(value)
                    }
                },
                as: ClaudeLogLine.self
            ) { line in
                guard line.type == "assistant",
                      let timestamp = date(line.timestamp),
                      timestamp >= periods.last30DaysStart,
                      timestamp < periods.end,
                      let message = line.message,
                      let model = message.model,
                      let usage = message.usage
                else { return }

                let tokens = Tokens(
                    input: max(0, usage.inputTokens ?? 0),
                    cacheRead: max(0, usage.cacheReadInputTokens ?? 0),
                    cacheWrite: max(0, usage.cacheCreationInputTokens ?? 0),
                    output: max(0, usage.outputTokens ?? 0)
                )
                guard tokens.claudeTotal > 0 else { return }

                let sample = ClaudeSample(
                    timestamp: timestamp,
                    model: model,
                    tokens: tokens,
                    cacheWrite1h: min(
                        tokens.cacheWrite,
                        max(0, usage.cacheCreation?.ephemeral1hInputTokens ?? 0)
                    ),
                    isSidechain: line.isSidechain ?? false
                )
                if let messageID = message.id, let requestID = line.requestID {
                    state.keyedSamples["\(messageID):\(requestID)"] = sample
                } else {
                    state.unkeyedSamples.append(sample)
                }
            }
            state.resumeState = readResult.resumeState
            let latest = Self.fileMetadata(for: file.url) ?? file
            state.size = readResult.observedFileSize
            state.modificationNanoseconds = latest.modificationNanoseconds
            state.fileID = latest.fileID
            state.resumeFingerprint = Self.resumeFingerprint(
                for: file.url,
                endingAt: state.resumeState.offset
            )
            fileStates[path] = state
            changedPaths.insert(path)
        }
        if cacheProvider.hasPrefix("vertexai-") {
            vertexFileStates = fileStates
        } else {
            claudeFileStates = fileStates
        }
        persistClaudeStates(
            provider: cacheProvider,
            states: fileStates,
            changedPaths: changedPaths,
            deletedPaths: deletedPaths
        )

        var keyedSamples: [String: (path: String, sample: ClaudeSample)] = [:]
        var unkeyedSamples: [ClaudeSample] = []
        for path in files.map({ $0.url.path }).sorted() {
            guard let state = fileStates[path] else { continue }
            for (key, sample) in state.keyedSamples {
                let candidate = (path: path, sample: sample)
                if let existing = keyedSamples[key] {
                    if Self.claudeCandidateWins(candidate, over: existing) {
                        keyedSamples[key] = candidate
                    }
                } else {
                    keyedSamples[key] = candidate
                }
            }
            unkeyedSamples.append(contentsOf: state.unkeyedSamples)
        }
        let samples = keyedSamples.values.map(\.sample) + unkeyedSamples
        guard !samples.isEmpty else { return nil }
        var accumulated = periods
        var rateCache: [String: RateResolution] = [:]
        for sample in samples {
            let era = sample.timestamp < Self.claudeFullContextPricingCutoff ? "historical" : "current"
            let key = "\(era):\(sample.model)"
            let rates: ModelTokenRates?
            if let cached = rateCache[key] {
                if case let .priced(value) = cached {
                    rates = value
                } else {
                    rates = nil
                }
            } else if let resolved = Self.claudeRates(
                for: sample.model,
                at: sample.timestamp,
                catalog: pricingCatalog
            ) {
                rateCache[key] = .priced(resolved)
                rates = resolved
            } else {
                rateCache[key] = .unpriced
                rates = nil
            }
            let valueUSD = rates.map { Self.claudeCost(sample: sample, rates: $0) }
            accumulated.add(
                timestamp: sample.timestamp,
                tokens: sample.tokens.claudeTotal,
                valueUSD: valueUSD
            )
        }
        return accumulated.summary
    }

    private static func logFiles(modifiedSince start: Date, below roots: [URL]) -> [LogFile] {
        var filesByPath: [String: LogFile] = [:]
        for root in roots {
            for file in filesModified(since: start, below: root) {
                filesByPath[file.url.standardizedFileURL.path] = file
            }
        }
        return filesByPath.values.sorted { $0.url.path < $1.url.path }
    }

    private static func codexHomeDirectory(homeDirectory: URL) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private static func codexSessionRoots(homeDirectory: URL) -> [URL] {
        let codexHome = codexHomeDirectory(homeDirectory: homeDirectory)
        return [
            codexHome.appending(path: "sessions", directoryHint: .isDirectory),
            codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
        ]
    }

    private static func claudeProjectRoots(homeDirectory: URL) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            let root = configured.hasPrefix("/")
                ? URL(fileURLWithPath: configured, isDirectory: true)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appending(path: configured, directoryHint: .isDirectory)
            return [root.appending(path: "projects", directoryHint: .isDirectory)]
        }

        var roots = [
            homeDirectory.appending(path: ".config/claude/projects", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory),
        ]
        roots.append(contentsOf: claudeDesktopProjectRoots(homeDirectory: homeDirectory))
        var seen: Set<String> = []
        return roots.compactMap {
            let standardized = $0.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static func claudeDesktopProjectRoots(homeDirectory: URL) -> [URL] {
        let applicationSupport = homeDirectory
            .appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory)
        let sessionRoots = ["local-agent-mode-sessions", "claude-code-sessions"].map {
            applicationSupport.appending(path: $0, directoryHint: .isDirectory)
        }
        let skipped = Set([".build", ".git", "build", "DerivedData", "node_modules", "outputs", "target"])
        var queue = sessionRoots.map { (url: $0, depth: 0) }
        var visited = Set(sessionRoots.map { $0.standardizedFileURL.path })
        var roots: [URL] = []
        var index = 0

        while index < queue.count {
            let current = queue[index]
            index += 1
            let projects = current.url.appending(path: ".claude/projects", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                roots.append(projects.standardizedFileURL)
            }

            guard current.depth < 4,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: current.url,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  )
            else { continue }
            for child in children where !skipped.contains(child.lastPathComponent) {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true
                else { continue }
                let standardized = child.standardizedFileURL
                guard visited.insert(standardized.path).inserted else { continue }
                queue.append((standardized, current.depth + 1))
            }
        }
        return roots
    }

    private static func filesModified(since start: Date, below root: URL) -> [LogFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { element -> LogFile? in
            guard let url = element as? URL,
                  url.pathExtension.lowercased() == "jsonl",
                  let file = fileMetadata(for: url),
                  TimeInterval(file.modificationNanoseconds) / 1_000_000_000 >= start.timeIntervalSince1970
            else { return nil }
            return file
        }
    }

    private static func readJSONLines<Value: Decodable>(
        from url: URL,
        resumeState initialState: JSONLResumeState,
        matchingAny patterns: [String],
        accepting predicate: ((Any) -> Bool)? = nil,
        as type: Value.Type,
        handle: (Value) -> Void
    ) -> JSONLReadResult {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            return JSONLReadResult(
                resumeState: initialState,
                observedFileSize: initialState.offset
            )
        }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: initialState.offset)
        } catch {
            return JSONLReadResult(
                resumeState: initialState,
                observedFileSize: initialState.offset
            )
        }

        let bytePatterns = patterns.map { Data($0.utf8) }
        let decoder = JSONDecoder()

        func process(_ line: Data.SubSequence) {
            guard bytePatterns.contains(where: { line.range(of: $0) != nil }) else { return }
            if let predicate {
                guard let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                      predicate(raw)
                else { return }
            }
            guard let value = try? decoder.decode(type, from: line) else { return }
            handle(value)
        }

        var state = initialState
        var observedFileSize = initialState.offset
        var pending = Data()
        let maximumLineBytes = 512 * 1024
        while autoreleasepool(invoking: { () -> Bool in
            guard var chunk = try? file.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                return false
            }
            observedFileSize += UInt64(chunk.count)
            if state.discardingOversizedLine {
                guard let newline = chunk.firstIndex(of: 0x0A) else {
                    state.offset += UInt64(chunk.count)
                    return true
                }
                let consumed = chunk.distance(from: chunk.startIndex, to: newline) + 1
                state.offset += UInt64(consumed)
                chunk.removeSubrange(chunk.startIndex...newline)
                state.discardingOversizedLine = false
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
                let consumed = pending.distance(from: pending.startIndex, to: lineStart)
                state.offset += UInt64(consumed)
                pending.removeSubrange(pending.startIndex..<lineStart)
            }
            if pending.count > maximumLineBytes {
                state.offset += UInt64(pending.count)
                pending.removeAll(keepingCapacity: true)
                state.discardingOversizedLine = true
            }
            return true
        }) {}
        if !state.discardingOversizedLine, !pending.isEmpty {
            let isRelevant = bytePatterns.contains(where: { pending.range(of: $0) != nil })
            let isComplete = autoreleasepool {
                if isRelevant {
                    if let predicate {
                        guard let raw = try? JSONSerialization.jsonObject(with: pending),
                              predicate(raw)
                        else { return true }
                    }
                    guard let value = try? decoder.decode(type, from: pending) else { return false }
                    handle(value)
                    return true
                }
                return (try? JSONSerialization.jsonObject(with: pending)) != nil
            }
            if isComplete { state.offset += UInt64(pending.count) }
        }
        return JSONLReadResult(
            resumeState: state,
            observedFileSize: observedFileSize
        )
    }

    private static func fileMetadata(for url: URL) -> LogFile? {
        var status = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &status, 0) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return nil }
        let modificationNanoseconds = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(status.st_mtimespec.tv_nsec)
        return LogFile(
            url: url,
            size: UInt64(max(0, status.st_size)),
            modificationNanoseconds: modificationNanoseconds,
            fileID: "\(status.st_dev):\(status.st_ino)"
        )
    }

    private static func canResume(
        file: LogFile,
        fileID: String,
        previousSize: UInt64,
        resumeState: JSONLResumeState,
        fingerprint: Data
    ) -> Bool {
        guard file.fileID == fileID,
              file.size > previousSize,
              resumeState.offset <= previousSize,
              resumeState.offset <= file.size,
              resumeState.offset == 0 || !fingerprint.isEmpty
        else { return false }
        return resumeFingerprint(for: file.url, endingAt: resumeState.offset) == fingerprint
    }

    private static func resumeFingerprint(for url: URL, endingAt offset: UInt64) -> Data {
        guard offset > 0,
              let file = try? FileHandle(forReadingFrom: url)
        else { return Data() }
        defer { try? file.close() }

        let byteCount = min(offset, 64)
        do {
            try file.seek(toOffset: offset - byteCount)
            return try file.read(upToCount: Int(byteCount)) ?? Data()
        } catch {
            return Data()
        }
    }

    private func loadCachedStatesIfNeeded(provider: String) {
        guard loadedProviders.insert(provider).inserted,
              let cacheStore
        else { return }

        var invalidPaths: Set<String> = []
        for record in cacheStore.records(provider: provider) {
            switch provider {
            case "codex":
                guard var state = try? cacheDecoder.decode(CodexFileState.self, from: record.payload) else {
                    invalidPaths.insert(record.path)
                    continue
                }
                state.fileID = record.fileID
                state.modificationNanoseconds = record.modificationNanoseconds
                state.size = record.size
                codexFileStates[record.path] = state
            case "claude-filtered":
                guard var state = try? cacheDecoder.decode(ClaudeFileState.self, from: record.payload) else {
                    invalidPaths.insert(record.path)
                    continue
                }
                state.fileID = record.fileID
                state.modificationNanoseconds = record.modificationNanoseconds
                state.size = record.size
                claudeFileStates[record.path] = state
            case "vertexai-only", "vertexai-all":
                guard var state = try? cacheDecoder.decode(ClaudeFileState.self, from: record.payload) else {
                    invalidPaths.insert(record.path)
                    continue
                }
                state.fileID = record.fileID
                state.modificationNanoseconds = record.modificationNanoseconds
                state.size = record.size
                vertexFileStates[record.path] = state
            default:
                return
            }
        }
        cacheStore.commit(provider: provider, records: [], deletingPaths: invalidPaths)
    }

    private func persistCodexStates(changedPaths: Set<String>, deletedPaths: Set<String>) {
        guard let cacheStore else { return }
        let records = changedPaths.compactMap { path -> LocalUsageCacheStore.Record? in
            guard let state = codexFileStates[path],
                  let payload = try? cacheEncoder.encode(state)
            else { return nil }
            return LocalUsageCacheStore.Record(
                path: path,
                fileID: state.fileID,
                modificationNanoseconds: state.modificationNanoseconds,
                size: state.size,
                payload: payload
            )
        }
        cacheStore.commit(provider: "codex", records: records, deletingPaths: deletedPaths)
    }

    private func persistClaudeStates(
        provider: String,
        states: [String: ClaudeFileState],
        changedPaths: Set<String>,
        deletedPaths: Set<String>
    ) {
        guard let cacheStore else { return }
        let records = changedPaths.compactMap { path -> LocalUsageCacheStore.Record? in
            guard let state = states[path],
                  let payload = try? cacheEncoder.encode(state)
            else { return nil }
            return LocalUsageCacheStore.Record(
                path: path,
                fileID: state.fileID,
                modificationNanoseconds: state.modificationNanoseconds,
                size: state.size,
                payload: payload
            )
        }
        cacheStore.commit(provider: provider, records: records, deletingPaths: deletedPaths)
    }

    private static func claudeCandidateWins(
        _ candidate: (path: String, sample: ClaudeSample),
        over existing: (path: String, sample: ClaudeSample)
    ) -> Bool {
        if candidate.sample.isSidechain != existing.sample.isSidechain {
            return existing.sample.isSidechain
        }
        let candidateIsSubagent = candidate.path.contains("/subagents/")
        let existingIsSubagent = existing.path.contains("/subagents/")
        if candidateIsSubagent != existingIsSubagent {
            return existingIsSubagent
        }
        return candidate.path < existing.path
    }

    private static func tokenValues(_ usage: LogTokenUsage?) -> Tokens? {
        guard let usage else { return nil }
        return Tokens(
            input: max(0, usage.inputTokens ?? 0),
            cacheRead: max(
                max(0, usage.cachedInputTokens ?? 0),
                max(0, usage.cacheReadInputTokens ?? 0)
            ),
            cacheWrite: max(0, usage.cacheWriteInputTokens ?? 0),
            output: max(0, usage.outputTokens ?? 0)
        )
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalDateFormatter.date(from: value) ?? dateFormatter.date(from: value)
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

    private static let codexFastInputTokenLimit = 272_000

    private static func codexPricedModel(
        sample: CodexSample,
        priorityTurn: CodexPriorityTurn?
    ) -> String? {
        guard let priorityTurn,
              let model = priorityTurn.model,
              codexFastMultiplier(for: model) != nil
        else { return sample.model }
        return model
    }

    private static func codexFastMultiplier(for model: String) -> Double? {
        switch normalizedCodexModel(model.lowercased()) {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    private static func codexCost(tokens: Tokens, rates: ModelTokenRates) -> Double {
        let totalInput = max(0, tokens.input)
        let cached = min(max(0, tokens.cacheRead), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, tokens.cacheWrite), remainingAfterCache)
        let uncached = remainingAfterCache - cacheWrite
        let aboveThreshold = rates.threshold.map { totalInput > $0 } ?? false
        let inputRate = aboveThreshold ? rates.inputAboveThreshold ?? rates.input : rates.input
        let cachedRate = (aboveThreshold ? rates.cacheReadAboveThreshold ?? rates.cacheRead : rates.cacheRead)
            ?? inputRate
        let cacheWriteRate = (aboveThreshold
            ? rates.cacheWriteAboveThreshold ?? rates.cacheWrite
            : rates.cacheWrite) ?? inputRate
        let outputRate = aboveThreshold ? rates.outputAboveThreshold ?? rates.output : rates.output
        let inputCost = Double(uncached) * inputRate
        let cacheCost = Double(cached) * cachedRate
        let cacheWriteCost = Double(cacheWrite) * cacheWriteRate
        let outputCost = Double(max(0, tokens.output)) * outputRate
        return inputCost + cacheCost + cacheWriteCost + outputCost
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
        at timestamp: Date,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        let model = normalizedCodexModel(rawModel.lowercased())
        if timestamp < codexGPT56PricingCutoff {
            if model == "gpt-5.6-terra" {
                return ModelTokenRates(
                    input: 2.5e-6, cacheRead: 2.5e-7, cacheWrite: 3.125e-6, output: 1.5e-5,
                    threshold: 272_000, inputAboveThreshold: 5e-6,
                    cacheReadAboveThreshold: 5e-7, cacheWriteAboveThreshold: 6.25e-6,
                    outputAboveThreshold: 2.25e-5
                )
            }
            if model == "gpt-5.6-luna" {
                return ModelTokenRates(
                    input: 1e-6, cacheRead: 1e-7, cacheWrite: 1.25e-6, output: 6e-6,
                    threshold: 272_000, inputAboveThreshold: 2e-6,
                    cacheReadAboveThreshold: 2e-7, cacheWriteAboveThreshold: 2.5e-6,
                    outputAboveThreshold: 9e-6
                )
            }
        }
        if model == "gpt-5.6-sol", timestamp < codexGPT56SolPromotionCutoff {
            return ModelTokenRates(
                input: 5e-6, cacheRead: 5e-7, cacheWrite: 6.25e-6, output: 3e-5,
                threshold: 272_000, inputAboveThreshold: 1e-5,
                cacheReadAboveThreshold: 1e-6, cacheWriteAboveThreshold: 1.25e-5,
                outputAboveThreshold: 4.5e-5
            )
        }
        if var rates = codexCatalogRates(for: rawModel, catalog: catalog) {
            if ["gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
                .contains(model) {
                rates.threshold = 272_000
            }
            return rates
        }
        return switch model {
        case "gpt-5.6-sol":
            ModelTokenRates(
                input: 4e-6, cacheRead: 4e-7, cacheWrite: 5e-6, output: 2e-5,
                threshold: 272_000, inputAboveThreshold: 8e-6,
                cacheReadAboveThreshold: 8e-7, cacheWriteAboveThreshold: 1e-5,
                outputAboveThreshold: 3e-5
            )
        case "gpt-5.5":
            ModelTokenRates(
                input: 5e-6, cacheRead: 5e-7, cacheWrite: 6.25e-6, output: 3e-5,
                threshold: 272_000, inputAboveThreshold: 1e-5,
                cacheReadAboveThreshold: 1e-6, cacheWriteAboveThreshold: 1.25e-5,
                outputAboveThreshold: 4.5e-5
            )
        case "gpt-5.6-terra":
            ModelTokenRates(
                input: 2e-6, cacheRead: 2e-7, cacheWrite: 2.5e-6, output: 1.2e-5,
                threshold: 272_000, inputAboveThreshold: 4e-6,
                cacheReadAboveThreshold: 4e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 1.8e-5
            )
        case "gpt-5.6-luna":
            ModelTokenRates(
                input: 2e-7, cacheRead: 2e-8, cacheWrite: 2.5e-7, output: 1.2e-6,
                threshold: 272_000, inputAboveThreshold: 4e-7,
                cacheReadAboveThreshold: 4e-8, cacheWriteAboveThreshold: 5e-7,
                outputAboveThreshold: 1.8e-6
            )
        case "gpt-5.4-mini":
            ModelTokenRates(input: 7.5e-7, cacheRead: 7.5e-8, cacheWrite: 7.5e-7, output: 4.5e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.4":
            ModelTokenRates(
                input: 2.5e-6, cacheRead: 2.5e-7, cacheWrite: 2.5e-6, output: 1.5e-5,
                threshold: 272_000, inputAboveThreshold: 5e-6,
                cacheReadAboveThreshold: 5e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 2.25e-5
            )
        case "gpt-5.3-codex-spark":
            ModelTokenRates(input: 0, cacheRead: 0, cacheWrite: 0, output: 0, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.3-codex", "gpt-5.2", "gpt-5.2-codex":
            ModelTokenRates(input: 1.75e-6, cacheRead: 1.75e-7, cacheWrite: 1.75e-6, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.1-codex-mini", "gpt-5-mini":
            ModelTokenRates(input: 2.5e-7, cacheRead: 2.5e-8, cacheWrite: 2.5e-7, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5-nano":
            ModelTokenRates(input: 5e-8, cacheRead: 5e-9, cacheWrite: 5e-8, output: 4e-7, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.4-nano":
            ModelTokenRates(input: 2e-7, cacheRead: 2e-8, cacheWrite: 2e-7, output: 1.25e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5-pro":
            ModelTokenRates(input: 1.5e-5, cacheRead: nil, cacheWrite: 1.5e-5, output: 1.2e-4, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.2-pro":
            ModelTokenRates(input: 2.1e-5, cacheRead: nil, cacheWrite: 2.1e-5, output: 1.68e-4, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.4-pro", "gpt-5.5-pro":
            ModelTokenRates(input: 3e-5, cacheRead: nil, cacheWrite: 3e-5, output: 1.8e-4, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5", "gpt-5-codex", "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max":
            ModelTokenRates(input: 1.25e-6, cacheRead: 1.25e-7, cacheWrite: 1.25e-6, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        default:
            nil
        }
    }

    private static func claudeRates(
        for rawModel: String,
        at timestamp: Date,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        let model = normalizedClaudeModel(rawModel.lowercased())
        let hasHistoricalLongContextPricing = model == "claude-opus-4-6"
            || model == "claude-sonnet-4-6"
        if timestamp < claudeFullContextPricingCutoff,
           hasHistoricalLongContextPricing {
            let input = model.contains("opus") ? 5e-6 : 3e-6
            let output = model.contains("opus") ? 2.5e-5 : 1.5e-5
            return ModelTokenRates(
                input: input, cacheRead: input / 10, cacheWrite: input * 1.25, output: output,
                threshold: 200_000, inputAboveThreshold: input * 2,
                cacheReadAboveThreshold: input / 5, cacheWriteAboveThreshold: input * 2.5,
                outputAboveThreshold: output * 1.5
            )
        }
        if let rates = claudeCatalogRates(for: rawModel, catalog: catalog) {
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

    private static func codexCatalogRates(
        for rawModel: String,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        guard let catalog else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let model = String(trimmed[trimmed.index(after: slash)...])
            let supportedProviders: Set<String> = [
                "deepseek", "kimi-coding", "kimi-for-coding", "openai",
                "opencode", "opencode-free", "opencode-go",
            ]
            guard supportedProviders.contains(provider) else { return nil }
            return catalog.rates(providerID: provider, modelID: model)
                ?? (provider == "kimi-coding"
                    ? catalog.rates(providerID: "kimi-for-coding", modelID: model)
                    : nil)
                ?? (provider == "opencode-free"
                    ? catalog.rates(providerID: "opencode", modelID: model)
                    : nil)
        }
        return catalog.rates(providerID: "openai", modelID: normalizedCodexModel(trimmed))
    }

    private static func claudeCatalogRates(
        for rawModel: String,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        guard let catalog else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let model = String(trimmed[trimmed.index(after: slash)...])
            let supportedProviders: Set<String> = [
                "anthropic", "openai", "google", "moonshot", "kimi-for-coding",
                "minimax", "deepseek",
            ]
            guard supportedProviders.contains(provider) else { return nil }
            return catalog.rates(providerID: provider, modelID: model)
        }
        return catalog.rates(providerID: "anthropic", modelID: normalizedClaudeModel(trimmed))
    }

    private static func normalizedCodexModel(_ model: String) -> String {
        var normalized = model
        if let slash = normalized.firstIndex(of: "/") {
            normalized = String(normalized[normalized.index(after: slash)...])
        }
        if normalized == "gpt-5.6" { return "gpt-5.6-sol" }
        if let dated = normalized.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(normalized[..<dated.lowerBound])
        }
        return normalized
    }

    private static func normalizedClaudeModel(_ model: String) -> String {
        var normalized = model
        if normalized.hasPrefix("anthropic.") {
            normalized.removeFirst("anthropic.".count)
        }
        if let lastDot = normalized.lastIndex(of: "."), normalized.contains("claude-") {
            let tail = String(normalized[normalized.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                normalized = tail
            }
        }
        if let version = normalized.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            normalized.removeSubrange(version)
        }
        if let date = normalized.range(of: #"-\d{8}$"#, options: .regularExpression) {
            normalized.removeSubrange(date)
        }
        return normalized
    }
}
