import Darwin
import Foundation

actor LocalDailyUsageScanner {
    private static let codexGPT56PricingCutoff = Date(timeIntervalSince1970: 1_785_369_600)
    private static let codexGPT56SolPromotionCutoff = Date(timeIntervalSince1970: 1_787_270_400)
    private static let codexAutoReviewFreeCutoff = Date(timeIntervalSince1970: 1_791_270_000)
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
        let sequence: Int
        let timestamp: Date
        let model: String?
        let tokens: Tokens
        var eventKey: CodexEventKey?
        let turnID: String?
        let responseID: String?
        let priority: Bool?
        // 恢复 turn 时切回标准档后的请求，日志库里同一 turn 的 Fast 记录不能把它改成 Fast。
        var confirmedStandard: Bool?
    }

    private struct CodexMirrorKey: Codable, Hashable {
        let turnID: String?
        let usage: Tokens?
        let total: Tokens?
        let timestamp: Date?
    }

    private struct CodexObservation: Codable {
        enum Advance: String, Codable {
            case unknown, bounded, exact, intervening
        }

        let turnID: String?
        let usage: Tokens
        let total: Tokens?
        let timestamp: Date
        let sequence: Int?
        let responseID: String?
        let advance: Advance
        var isReplay = false

        var snapshot: CodexMirrorKey {
            CodexMirrorKey(turnID: turnID, usage: usage, total: total, timestamp: timestamp)
        }

        var adjacentKeys: Set<CodexMirrorKey> {
            var keys: Set<CodexMirrorKey> = [
                CodexMirrorKey(turnID: turnID, usage: usage, total: nil, timestamp: timestamp),
            ]
            if let total {
                keys.insert(CodexMirrorKey(turnID: turnID, usage: usage, total: total, timestamp: nil))
            }
            return keys
        }

        func matches(_ other: Self, allowDelayed: Bool) -> Bool {
            if !adjacentKeys.isDisjoint(with: other.adjacentKeys) { return true }
            guard let turnID, !turnID.isEmpty, turnID == other.turnID,
                  usage == other.usage, advance != .intervening, !isReplay, !other.isReplay
            else { return false }
            return abs(timestamp.timeIntervalSince(other.timestamp)) <= 5
                || (allowDelayed && timestamp >= other.timestamp && advance == .exact && other.advance == .exact)
        }

        static func advance(total: Tokens?, previous: Tokens?, usage: Tokens) -> Advance {
            guard let total, let previous else { return .unknown }
            let delta = [
                total.input - previous.input, total.cacheRead - previous.cacheRead,
                total.cacheWrite - previous.cacheWrite, total.output - previous.output,
            ]
            let expected = [usage.input, usage.cacheRead, usage.cacheWrite, usage.output]
            if delta == expected { return .exact }
            return zip(delta, expected).contains { $0 > $1 } ? .intervening : .bounded
        }
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
        let ordinal: Int?
        let usage: LogTokenUsage?
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
            let creatorAccountID: String?
            let source: Source?
            let threadID: String?
            let responseID: String?
            let usage: LogTokenUsage?
            let threadTokenUsage: LogTokenUsage?
            let turnTokenUsage: LogTokenUsage?
            let threadSettings: ThreadSettings?
            let subagentHistoryStartOrdinal: Int?

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
                case creatorAccountID = "creator_account_id"
                case source
                case threadID = "thread_id"
                case responseID = "response_id"
                case usage
                case threadTokenUsage = "thread_token_usage"
                case turnTokenUsage = "turn_token_usage"
                case threadSettings = "thread_settings"
                case subagentHistoryStartOrdinal = "subagent_history_start_ordinal"
            }
        }

        struct ThreadSettings: Decodable {
            let serviceTier: String?

            enum CodingKeys: String, CodingKey {
                case serviceTier = "service_tier"
            }
        }

        struct Source: Decodable {
            let subagent: Subagent?

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if (try? value.decode(String.self)) != nil {
                    subagent = nil
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    subagent = try? container.decodeIfPresent(Subagent.self, forKey: .subagent)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case subagent
            }
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
        let snakeRequestID: String?
        let sessionID: String?
        let snakeSessionID: String?
        let isSidechain: Bool?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type
            case timestamp
            case requestID = "requestId"
            case snakeRequestID = "request_id"
            case sessionID = "sessionId"
            case snakeSessionID = "session_id"
            case isSidechain
            case message
        }

        // 桌面版 Cowork 的 audit.jsonl 和内嵌会话各存一份，两种写法都要认才能只计一次。
        var dedupeKey: String? {
            guard let messageID = message?.id else { return nil }
            if let requestID = requestID ?? snakeRequestID {
                return "\(messageID):\(requestID)"
            }
            guard !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sessionID = sessionID ?? snakeSessionID,
                  !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return "session:\(sessionID):\(messageID)"
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
        var hasPricedTokens = false

        mutating func add(tokens: Int, valueUSD: Double?) {
            guard tokens > 0 else { return }
            self.tokens += Int64(tokens)
            if let valueUSD {
                self.valueUSD += valueUSD
                hasPricedTokens = true
            } else {
                hasUnpricedTokens = true
            }
        }

        var usage: DailyTokenUsage? {
            guard tokens > 0 else { return nil }
            return DailyTokenUsage(
                tokens: tokens,
                valueUSD: hasUnpricedTokens ? nil : valueUSD,
                partialValueUSD: hasUnpricedTokens && hasPricedTokens ? valueUSD : nil
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
        var todayModels: [String: ModelTokenUsage] = [:]

        mutating func add(
            timestamp: Date, tokens: Int, valueUSD: Double?,
            model: String?, counts: Tokens, inputIncludesCache: Bool
        ) {
            guard timestamp < end else { return }
            if timestamp >= todayStart {
                today.add(tokens: tokens, valueUSD: valueUSD)
                if tokens > 0 {
                    var row = ModelTokenUsage(
                        model: model ?? ModelUsageBreakdown.unknownModel,
                        inputTokens: Int64(counts.input), cacheReadTokens: Int64(counts.cacheRead),
                        cacheWriteTokens: Int64(counts.cacheWrite), outputTokens: Int64(counts.output),
                        inputIncludesCache: inputIncludesCache, valueUSD: valueUSD
                    )
                    if row.tokens != Int64(tokens) { row.reportedTotalTokens = Int64(tokens) }
                    ModelUsageBreakdown.add(row, to: &todayModels)
                }
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
                }.sorted { $0.date < $1.date },
                todayByModel: ModelUsageBreakdown.sorted(Array(todayModels.values))
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
        static let currentParserVersion = 3

        var parserVersion = currentParserVersion
        var size: UInt64 = 0
        var modificationNanoseconds: Int64 = 0
        var fileID = ""
        var resumeState = JSONLResumeState()
        var resumeFingerprint = Data()
        var sessionID: String?
        var requestSessionID: String?
        var subagentHistoryStartOrdinal: Int?
        var parentID: String?
        var hasSessionMetadata = false
        var hasCreatorAccount = false
        var currentModel: String?
        var currentTurnID: String?
        var startedTurnID: String?
        var threadPriority: Bool?
        var turnPriorities: [String: Bool] = [:]
        var resumedStandardTurns: Set<String> = []
        var turnModels: [String: String] = [:]
        var nextSequence = 0
        var responseIDs: Set<String> = []
        var mirroredResponses: [CodexMirrorKey: String] = [:]
        var legacySequences: [CodexMirrorKey: Int] = [:]
        var pendingLedger: CodexObservation?
        var pendingLegacy: CodexObservation?
        var lastLedgerTotal: Tokens?
        var lastLegacyTotal: Tokens?
        var accumulator = CodexAccumulator()
        var samples: [CodexSample] = []

        mutating func clearPendingMirrors() {
            pendingLedger = nil
            pendingLegacy = nil
        }

        mutating func appendSample(
            timestamp: Date, model: String?, tokens: Tokens, eventKey: CodexEventKey?,
            turnID: String?, responseID: String? = nil, range: Range<Date>
        ) -> Int {
            let sequence = nextSequence
            nextSequence += 1
            guard range.contains(timestamp), tokens.codexTotal > 0 else { return sequence }
            samples.append(CodexSample(
                sequence: sequence, timestamp: timestamp, model: model, tokens: tokens,
                eventKey: eventKey, turnID: turnID, responseID: responseID,
                priority: turnPriorities[turnID ?? ""],
                confirmedStandard: resumedStandardTurns.contains(turnID ?? "") ? true : nil
            ))
            return sequence
        }

        mutating func acceptLedger(_ payload: CodexLogLine.Payload, timestamp: Date, range: Range<Date>) {
            guard let threadID = payload.threadID, !threadID.isEmpty,
                  let responseID = payload.responseID, !responseID.isEmpty,
                  let usage = requestTokens(payload.usage),
                  let total = requestTokens(payload.threadTokenUsage), isAtLeast(total, usage)
            else { return }
            let owned = threadID == sessionID
                && (payload.sessionID == nil || payload.sessionID == (requestSessionID ?? sessionID))
            let turnID = payload.turnID ?? payload.turnId ?? currentTurnID
            let replay = responseIDs.contains(responseID)
            var observation = CodexObservation(
                turnID: turnID, usage: usage, total: total, timestamp: timestamp,
                sequence: nil, responseID: responseID,
                advance: owned && !replay
                    ? CodexObservation.advance(total: total, previous: lastLedgerTotal, usage: usage) : .unknown,
                isReplay: replay || !owned
            )
            if replay, let pendingLedger, pendingLedger.responseID == responseID,
               pendingLedger.snapshot == observation.snapshot {
                observation = pendingLedger
            }
            var keys = [observation.snapshot, CodexMirrorKey(
                turnID: turnID, usage: usage, total: nil, timestamp: timestamp
            )]
            if let turnTotal = requestTokens(payload.turnTokenUsage), isAtLeast(turnTotal, usage) {
                keys.append(CodexMirrorKey(turnID: turnID, usage: usage, total: turnTotal, timestamp: timestamp))
            }
            let sequence = keys.compactMap { legacySequences[$0] }.first
                ?? pendingLegacy.flatMap { legacy in
                    observation.matches(legacy, allowDelayed: false) ? legacy.sequence : nil
                }
            let legacy = sequence.flatMap { sequence in samples.first { $0.sequence == sequence } }
            if let sequence {
                samples.removeAll { $0.sequence == sequence }
                keys.append(contentsOf: legacySequences.filter { $0.value == sequence }.map(\.key))
                legacySequences = legacySequences.filter { $0.value != sequence }
            }
            clearPendingMirrors()
            if sequence == nil { pendingLedger = observation }
            for key in keys { mirroredResponses[key] = responseID }
            guard !replay else { return }
            responseIDs.insert(responseID)
            guard owned else { return }
            lastLedgerTotal = total
            let model = payload.model ?? payload.modelName
                ?? turnID.flatMap { turnModels[$0] }
                ?? (turnID == currentTurnID ? currentModel : nil)
            _ = appendSample(
                timestamp: timestamp, model: model, tokens: usage,
                eventKey: legacy?.eventKey ?? CodexEventKey(total: total, last: usage),
                turnID: turnID, responseID: responseID, range: range
            )
        }

        mutating func acceptLegacy(_ payload: CodexLogLine.Payload, timestamp: Date, range: Range<Date>) {
            guard let info = payload.info else { return }
            let last = tokenValues(info.lastTokenUsage)
            let total = tokenValues(info.totalTokenUsage)
            let turnID = payload.turnID ?? payload.turnId ?? currentTurnID
            let rawKey = CodexMirrorKey(turnID: turnID, usage: last, total: total, timestamp: timestamp)
            if let owner = mirroredResponses[rawKey], owner != pendingLedger?.responseID { return }
            // 镜像不再加一遍，但旧计数器仍要更新。
            let delta = accumulator.apply(last: last, total: total)
            guard let usage = last ?? delta else { clearPendingMirrors(); return }
            let observation = CodexObservation(
                turnID: turnID, usage: usage, total: total, timestamp: timestamp,
                sequence: nil, responseID: nil,
                advance: CodexObservation.advance(total: total, previous: lastLegacyTotal, usage: usage)
            )
            var owner = mirroredResponses[rawKey] ?? mirroredResponses[observation.snapshot]
            let ledger = pendingLedger
            if let ledger, owner == nil || owner == ledger.responseID,
               observation.matches(ledger, allowDelayed: true) {
                owner = ledger.responseID
                if let owner {
                    mirroredResponses[rawKey] = owner
                    mirroredResponses[observation.snapshot] = owner
                    if let index = samples.firstIndex(where: { $0.responseID == owner }) {
                        samples[index].eventKey = CodexEventKey(total: total, last: last)
                    }
                }
            }
            if owner == nil || (owner == ledger?.responseID && ledger?.isReplay == false) {
                lastLegacyTotal = total ?? lastLegacyTotal
            }
            clearPendingMirrors()
            guard owner == nil, let delta, delta.codexTotal > 0 else { return }
            let sequence = appendSample(
                timestamp: timestamp,
                model: info.model ?? info.modelName ?? payload.model ?? turnID.flatMap { turnModels[$0] }
                    ?? currentModel,
                tokens: delta, eventKey: CodexEventKey(total: total, last: last), turnID: turnID, range: range
            )
            legacySequences[rawKey] = sequence
            legacySequences[observation.snapshot] = sequence
            pendingLegacy = CodexObservation(
                turnID: turnID, usage: usage, total: total, timestamp: timestamp,
                sequence: sequence, responseID: nil, advance: observation.advance
            )
        }

        private func requestTokens(_ usage: LogTokenUsage?) -> Tokens? {
            guard let usage, let input = usage.inputTokens, let output = usage.outputTokens,
                  input >= 0, output >= 0, !input.addingReportingOverflow(output).overflow,
                  let tokens = tokenValues(usage), tokens.cacheRead <= input,
                  (usage.cachedInputTokens ?? 0) >= 0, (usage.cacheReadInputTokens ?? 0) >= 0
            else { return nil }
            return tokens
        }
    }

    private struct ClaudeFileState: Codable {
        static let currentParserVersion = 3

        var parserVersion = currentParserVersion
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
    // Pi 会话文件按大小和修改时间缓存解析结果，没变的文件不重复读取。
    private var piFileCache: [String: (size: UInt64, modified: Int64, usage: PiSessionFileUsage)] = [:]
    private var activeVertexCacheProvider: String?
    private var loadedProviders: Set<String> = []
    private let cacheDirectory: URL?
    private lazy var cacheStore = LocalUsageCacheStore(directoryURL: cacheDirectory)
    private let priorityTurnStore = CodexPriorityTurnStore()
    private let cacheEncoder = JSONEncoder()
    private let cacheDecoder = JSONDecoder()
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormatter = ISO8601DateFormatter()

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
    }

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
        var periods = PeriodAccumulators(
            todayStart: todayStart,
            last30DaysStart: last30DaysStart,
            currentWeekStart: currentWeekStart,
            end: end
        )
        switch providerID.rawValue {
        case "codex":
            scanCodex(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog,
                modelFilter: { !Self.isDeepSeekModel($0) }
            )
        case "claude":
            scanClaude(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog,
                cacheProvider: cacheProvider,
                filter: .excludeVertex,
                modelFilter: { !Self.isDeepSeekModel($0) }
            )
        case "vertexai":
            scanClaude(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog,
                cacheProvider: cacheProvider,
                filter: allowVertexClaudeFallback ? .all : .vertexOnly,
                modelFilter: { !Self.isDeepSeekModel($0) }
            )
        case "deepseek":
            loadCachedStatesIfNeeded(provider: "codex")
            loadCachedStatesIfNeeded(provider: "claude-filtered")
            scanDeepSeekHarness(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog
            )
            scanCodex(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog,
                modelFilter: Self.isDeepSeekModel
            )
            scanClaude(
                periods: &periods,
                homeDirectory: homeDirectory,
                pricingCatalog: pricingCatalog,
                cacheProvider: "claude-filtered",
                filter: .excludeVertex,
                modelFilter: Self.isDeepSeekModel
            )
        case "pi":
            scanPi(periods: &periods, homeDirectory: homeDirectory, pricingCatalog: pricingCatalog)
        default:
            return nil
        }
        return periods.summary
    }

    private func scanCodex(
        periods: inout PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?,
        modelFilter: (String?) -> Bool
    ) {
        let (files, isRetained) = Self.logFiles(
            modifiedSince: periods.last30DaysStart,
            below: Self.codexSessionRoots(homeDirectory: homeDirectory)
        )
        // Codex 会把旧会话压缩成 .jsonl.zst 并删掉原文件，已算过的用量要保留，不读压缩内容。
        let currentPaths = Set(files.map { $0.url.path })
            .union(codexFileStates.keys.filter { Self.isArchivedCodexRollout($0) || isRetained($0) })
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
        // 保留下来但本轮不读的会话也要按窗口裁剪，否则和 fork 子会话的前缀对不齐会重复计数。
        let filePaths = Set(files.map { $0.url.path })
        for (path, var state) in codexFileStates where !filePaths.contains(path) {
            let previousSampleCount = state.samples.count
            state.samples.removeAll {
                $0.timestamp < periods.last30DaysStart || $0.timestamp >= periods.end
            }
            if state.samples.count != previousSampleCount {
                codexFileStates[path] = state
                changedPaths.insert(path)
            }
        }

        for file in files {
            let path = file.url.path
            var state = codexFileStates[path] ?? CodexFileState()
            // 归档期间保留的旧版本结果，原文件恢复后要按当前版本重算。
            if state.parserVersion != CodexFileState.currentParserVersion {
                state = CodexFileState()
            }
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
                    #""session_meta""#,
                    #""turn_context""#,
                    #""task_started""#,
                    #""token_count""#,
                    #""token_usage_record""#,
                    #""thread_settings_applied""#,
                    #""usage""#,
                ],
                as: CodexLogLine.self
            ) { line in
                if line.type == "session_meta", let payload = line.payload {
                    let sessionID = payload.id ?? payload.sessionID ?? payload.sessionId
                    if state.hasSessionMetadata {
                        if let sessionID, sessionID == state.sessionID {
                            state.parentID = state.parentID ?? Self.codexParentID(payload)
                            state.requestSessionID = state.requestSessionID ?? payload.sessionID ?? payload.sessionId
                            state.clearPendingMirrors()
                            state.lastLedgerTotal = nil
                            state.lastLegacyTotal = nil
                        }
                        return
                    }
                    state.hasSessionMetadata = true
                    state.sessionID = payload.id
                        ?? payload.sessionID
                        ?? payload.sessionId
                        ?? state.sessionID
                    state.requestSessionID = payload.sessionID ?? payload.sessionId ?? state.sessionID
                    state.subagentHistoryStartOrdinal = payload.subagentHistoryStartOrdinal
                    state.parentID = Self.codexParentID(payload) ?? state.parentID
                    state.hasCreatorAccount = payload.creatorAccountID?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    return
                }
                if let boundary = state.subagentHistoryStartOrdinal, let ordinal = line.ordinal,
                   ordinal < boundary { return }
                if line.usage != nil {
                    state.clearPendingMirrors()
                    return
                }
                if line.type == "turn_context", let payload = line.payload {
                    state.clearPendingMirrors()
                    state.currentModel = payload.model ?? payload.modelName
                    if let turnID = payload.turnID ?? payload.turnId {
                        state.currentTurnID = turnID
                        // 恢复同一个 turn 时不会再有 task_started，按当前线程档位刷新，之前的请求不受影响。
                        if let priority = state.threadPriority,
                           state.startedTurnID == nil || state.startedTurnID == turnID {
                            if priority != (state.turnPriorities[turnID] == true) {
                                if priority {
                                    state.resumedStandardTurns.remove(turnID)
                                } else {
                                    state.resumedStandardTurns.insert(turnID)
                                }
                            }
                            state.turnPriorities[turnID] = priority
                        }
                    }
                    if let turnID = state.currentTurnID, let model = state.currentModel {
                        state.turnModels[turnID] = model
                    }
                    return
                }
                if line.type == "event_msg", let payload = line.payload,
                   payload.type == "thread_settings_applied" {
                    state.threadPriority = payload.threadSettings?.serviceTier == "priority"
                    return
                }
                if line.type == "event_msg", let payload = line.payload,
                   payload.type == "task_started" {
                    state.clearPendingMirrors()
                    state.currentTurnID = payload.turnID ?? payload.turnId ?? payload.id
                    state.startedTurnID = state.currentTurnID
                    state.turnPriorities[state.currentTurnID ?? ""] = state.threadPriority
                    return
                }
                guard let payload = line.payload, let timestamp = date(line.timestamp)
                else { return }
                let range = periods.last30DaysStart..<periods.end
                if line.type == "token_usage_record" {
                    state.acceptLedger(payload, timestamp: timestamp, range: range)
                } else if line.type == "event_msg", payload.type == "token_count" {
                    state.acceptLegacy(payload, timestamp: timestamp, range: range)
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
        var rateCache: [String: RateResolution] = [:]
        for (path, state) in sessions {
            let droppedCount = droppedPrefixes[path] ?? 0
            for sample in state.samples.dropFirst(droppedCount) {
                let priorityTurn = sample.turnID.flatMap { priorityTurns[$0] }
                let pricedModel = Self.codexPricedModel(sample: sample, priorityTurn: priorityTurn)
                guard modelFilter(pricedModel ?? sample.model) else { continue }
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
                let isIncludedAutoReview = state.hasCreatorAccount
                    && sample.timestamp >= Self.codexAutoReviewFreeCutoff
                    && sample.model.map { Self.normalizedCodexModel($0.lowercased()) } == "codex-auto-review"
                let valueUSD = isIncludedAutoReview ? 0 : rates.map { rates -> Double in
                    let base = Self.codexCost(tokens: sample.tokens, rates: rates)
                    guard (priorityTurn != nil && sample.confirmedStandard != true) || sample.priority == true,
                          let multiplier = pricedModel.flatMap({
                              Self.codexFastMultiplier(for: $0, inputTokens: sample.tokens.input)
                          })
                    else { return base }
                    return base * multiplier
                }
                periods.add(
                    timestamp: sample.timestamp,
                    tokens: sample.tokens.codexTotal,
                    valueUSD: valueUSD,
                    model: pricedModel ?? sample.model, counts: sample.tokens, inputIncludesCache: true
                )
            }
        }
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

        return drops
    }

    private static func matchingCodexPrefix(
        _ lhs: [CodexSample],
        _ rhs: [CodexSample]
    ) -> Int {
        var count = 0
        while count < lhs.count,
              count < rhs.count,
              lhs[count].responseID == nil || lhs[count].responseID == rhs[count].responseID,
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
        periods: inout PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?,
        cacheProvider: String,
        filter: ClaudeLogProviderFilter,
        modelFilter: (String?) -> Bool
    ) {
        let (files, isRetained) = Self.logFiles(
            modifiedSince: periods.last30DaysStart,
            below: Self.claudeProjectRoots(homeDirectory: homeDirectory)
        )
        var fileStates = cacheProvider.hasPrefix("vertexai-") ? vertexFileStates : claudeFileStates
        let currentPaths = Set(files.map { $0.url.path }).union(fileStates.keys.filter(isRetained))
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
                if let key = line.dedupeKey {
                    state.keyedSamples[key] = sample
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
        for path in fileStates.keys.sorted() {
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
        guard !samples.isEmpty else { return }
        var rateCache: [String: RateResolution] = [:]
        for sample in samples {
            guard modelFilter(sample.model) else { continue }
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
            periods.add(
                timestamp: sample.timestamp,
                tokens: sample.tokens.claudeTotal,
                valueUSD: valueUSD,
                model: sample.model, counts: sample.tokens, inputIncludesCache: false
            )
        }
    }

    private static func logFiles(
        modifiedSince start: Date, below roots: [URL]
    ) -> (files: [LogFile], isRetained: (String) -> Bool) {
        var filesByPath: [String: LogFile] = [:]
        var unreadableRoots: [String] = []
        for root in roots {
            guard let files = filesModified(since: start, below: root) else {
                // 遍历结果可能是真实路径（如 /private/var），两种写法都要匹配。
                unreadableRoots.append(root.standardizedFileURL.path + "/")
                unreadableRoots.append(realPath(of: root) + "/")
                continue
            }
            for file in files {
                filesByPath[file.url.standardizedFileURL.path] = file
            }
        }
        // 读不了的目录本轮不动，其下已有的统计原样保留。
        let isRetained = { (path: String) in unreadableRoots.contains { path.hasPrefix($0) } }
        return (filesByPath.values.sorted { $0.url.path < $1.url.path }, isRetained)
    }

    private static func isArchivedCodexRollout(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".jsonl"), !FileManager.default.fileExists(atPath: path) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + ".zst", isDirectory: &isDirectory)
            && !isDirectory.boolValue
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
            // Cowork 会话把用量写在 audit.jsonl，作为单个文件加入统计。
            let audit = current.url.appending(path: "audit.jsonl")
            if let values = try? audit.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true {
                roots.append(audit.standardizedFileURL)
            }

            guard current.depth < 4 else { continue }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            } catch {
                // 读不了的会话目录作为扫描入口交给后面判断，其下已有统计才会保留，不会被当作删除。
                if !isMissingFileError(error) { roots.append(current.url.standardizedFileURL) }
                continue
            }
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

    private static func filesModified(since start: Date, below root: URL) -> [LogFile]? {
        if root.pathExtension.lowercased() == "jsonl" {
            guard let file = fileMetadata(for: root),
                  TimeInterval(file.modificationNanoseconds) / 1_000_000_000 >= start.timeIntervalSince1970
            else { return [] }
            return [file]
        }
        // 目录读不了不能当成空目录，否则已有统计会被当作删除；上层目录没权限时 fileExists 也会返回 false。
        var status = stat()
        guard root.path.withCString({ fstatat(AT_FDCWD, $0, &status, 0) }) == 0 else { return errno == ENOENT || errno == ENOTDIR ? [] : nil }
        guard access(root.path, R_OK | X_OK) == 0 else { return nil }
        var unreadable = false
        // 入口目录本身是符号链接时系统不会进去遍历，先解析成真实目录；子目录里的链接仍然不跟随。
        guard let enumerator = FileManager.default.enumerator(
            at: root.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                let missing = isMissingFileError(error)
                if !missing { unreadable = true }
                return missing
            }
        ) else { return nil }

        let files = enumerator.compactMap { element -> LogFile? in
            guard let url = element as? URL,
                  url.pathExtension.lowercased() == "jsonl",
                  let file = fileMetadata(for: url),
                  TimeInterval(file.modificationNanoseconds) / 1_000_000_000 >= start.timeIntervalSince1970
            else { return nil }
            return file
        }
        return unreadable ? nil : files
    }

    // 目录本身没权限时解析不了，从最近一个能解析的上级目录拼出真实路径。
    private static func realPath(of url: URL) -> String {
        var current = url.standardizedFileURL
        var suffix: [String] = []
        while current.path != "/" {
            if let real = realpath(current.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + suffix.reversed()).joined(separator: "/")
            }
            suffix.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
        return url.standardizedFileURL.path
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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
                        guard let raw = try? JSONSerialization.jsonObject(with: pending) else { return false }
                        guard predicate(raw) else { return true }
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
                guard var state = try? cacheDecoder.decode(CodexFileState.self, from: record.payload),
                      state.parserVersion == CodexFileState.currentParserVersion
                        || Self.isArchivedCodexRollout(record.path)
                else {
                    invalidPaths.insert(record.path)
                    continue
                }
                state.fileID = record.fileID
                state.modificationNanoseconds = record.modificationNanoseconds
                state.size = record.size
                codexFileStates[record.path] = state
            case "claude-filtered":
                guard var state = try? cacheDecoder.decode(ClaudeFileState.self, from: record.payload),
                      state.parserVersion == ClaudeFileState.currentParserVersion
                else {
                    invalidPaths.insert(record.path)
                    continue
                }
                state.fileID = record.fileID
                state.modificationNanoseconds = record.modificationNanoseconds
                state.size = record.size
                claudeFileStates[record.path] = state
            case "vertexai-only", "vertexai-all":
                guard var state = try? cacheDecoder.decode(ClaudeFileState.self, from: record.payload),
                      state.parserVersion == ClaudeFileState.currentParserVersion
                else {
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

    private static func codexFastMultiplier(for model: String, inputTokens: Int = 0) -> Double? {
        let model = normalizedCodexModel(model.lowercased())
        if inputTokens > codexFastInputTokenLimit,
           model != "gpt-6-astra", model != "gpt-6.1-sol" {
            return nil
        }
        return switch model {
        case "gpt-6-astra", "gpt-6.1-sol": 2
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
        let bundled = codexBundledRates(for: model)
        guard var rates = codexCatalogRates(for: rawModel, catalog: catalog) else { return bundled }
        guard let bundled else { return rates }
        if rates.threshold == nil {
            rates.threshold = bundled.threshold
            rates.inputAboveThreshold = bundled.inputAboveThreshold
            rates.cacheReadAboveThreshold = bundled.cacheReadAboveThreshold
            rates.cacheWriteAboveThreshold = bundled.cacheWriteAboveThreshold
            rates.outputAboveThreshold = bundled.outputAboveThreshold
        } else {
            rates.cacheReadAboveThreshold = rates.cacheReadAboveThreshold
                ?? rates.cacheRead ?? rates.inputAboveThreshold ?? rates.input
            rates.cacheWriteAboveThreshold = rates.cacheWriteAboveThreshold
                ?? rates.cacheWrite ?? rates.inputAboveThreshold ?? rates.input
        }
        rates.cacheRead = rates.cacheRead ?? bundled.cacheRead
        rates.cacheWrite = rates.cacheWrite ?? bundled.cacheWrite
        return rates
    }

    private static func codexBundledRates(for model: String) -> ModelTokenRates? {
        return switch model {
        case "gpt-6.1-sol":
            ModelTokenRates(
                input: 2e-6, cacheRead: 1e-7, cacheWrite: 2.5e-6, output: 1e-5,
                threshold: 272_000, inputAboveThreshold: 4e-6,
                cacheReadAboveThreshold: 2e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 1.5e-5
            )
        case "gpt-6-sol":
            ModelTokenRates(
                input: 2e-6, cacheRead: 2e-7, cacheWrite: 2.5e-6, output: 1e-5,
                threshold: 272_000, inputAboveThreshold: 4e-6,
                cacheReadAboveThreshold: 4e-7, cacheWriteAboveThreshold: 5e-6,
                outputAboveThreshold: 1.5e-5
            )
        case "gpt-6-luna":
            ModelTokenRates(
                input: 1e-7, cacheRead: 1e-8, cacheWrite: 1.25e-7, output: 5e-7,
                threshold: 272_000, inputAboveThreshold: 2e-7,
                cacheReadAboveThreshold: 2e-8, cacheWriteAboveThreshold: 2.5e-7,
                outputAboveThreshold: 7.5e-7
            )
        case "gpt-6-astra":
            ModelTokenRates(
                input: 1e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5, output: 5e-5,
                threshold: 272_000, inputAboveThreshold: 2e-5,
                cacheReadAboveThreshold: 2e-6, cacheWriteAboveThreshold: 2.5e-5,
                outputAboveThreshold: 7.5e-5
            )
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
            ModelTokenRates(input: 3e-5, cacheRead: nil, cacheWrite: nil, output: 1.8e-4, threshold: 272_000, inputAboveThreshold: 6e-5, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: 2.7e-4)
        case "gpt-5.6-cyber":
            ModelTokenRates(input: 1.25e-5, cacheRead: 1.25e-6, cacheWrite: 1.5625e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        case "gpt-5.5-cyber":
            ModelTokenRates(input: 1.25e-5, cacheRead: 1.25e-6, cacheWrite: nil, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
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
        if hasHistoricalLongContextPricing {
            let input = model == "claude-opus-4-6" ? 5e-6 : 3e-6
            let output = model == "claude-opus-4-6" ? 2.5e-5 : 1.5e-5
            return ModelTokenRates(input: input, cacheRead: input / 10, cacheWrite: input * 1.25, output: output, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if let rates = claudeCatalogRates(for: rawModel, catalog: catalog) {
            return rates
        }
        if model == "claude-fable-5" || model == "claude-mythos-5" {
            return ModelTokenRates(input: 1e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if model == "claude-mythos-5-1" {
            return ModelTokenRates(input: 1e-5, cacheRead: 2.5e-7, cacheWrite: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if model == "claude-haiku-4-5" {
            return ModelTokenRates(input: 1e-6, cacheRead: 1e-7, cacheWrite: 1.25e-6, output: 5e-6, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if ["claude-sonnet-4", "claude-sonnet-4-5"].contains(model) {
            return ModelTokenRates(
                input: 3e-6, cacheRead: 3e-7, cacheWrite: 3.75e-6, output: 1.5e-5,
                threshold: model.contains("4-5") || model == "claude-sonnet-4" ? 200_000 : nil,
                inputAboveThreshold: 6e-6, cacheReadAboveThreshold: 6e-7,
                cacheWriteAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5
            )
        }
        if model == "claude-opus-4" || model == "claude-opus-4-1" {
            return ModelTokenRates(input: 1.5e-5, cacheRead: 1.5e-6, cacheWrite: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cacheReadAboveThreshold: nil, cacheWriteAboveThreshold: nil, outputAboveThreshold: nil)
        }
        if ["claude-opus-4-5", "claude-opus-4-7", "claude-opus-4-8"].contains(model) {
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
                ?? (provider == "openai"
                    ? catalog.rates(providerID: provider, modelID: normalizedCodexModel(model))
                    : nil)
                ?? (provider == "kimi-coding"
                    ? catalog.rates(providerID: "kimi-for-coding", modelID: model)
                    : nil)
                ?? (provider == "opencode-free"
                    ? catalog.rates(providerID: "opencode", modelID: model)
                    : nil)
        }
        return catalog.rates(providerID: "openai", modelID: trimmed)
            ?? catalog.rates(providerID: "openai", modelID: normalizedCodexModel(trimmed))
    }

    private static func isDeepSeekModel(_ rawModel: String?) -> Bool {
        guard let rawModel else { return false }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return false }
        if let slash = model.firstIndex(of: "/") {
            return String(model[..<slash]) == "deepseek"
        }
        return model == "deepseek" || model.hasPrefix("deepseek-")
    }

    private func scanDeepSeekHarness(
        periods: inout PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?
    ) {
        let sessions = DeepSeekHarnessUsageReader.sessions(
            homeDirectory: homeDirectory,
            modifiedSince: periods.last30DaysStart
        )
        for session in sessions {
            let rates = pricingCatalog?.rates(
                providerID: "deepseek",
                modelID: session.model
            )
            periods.add(
                timestamp: session.timestamp,
                tokens: session.tokens,
                valueUSD: rates.map { Self.deepSeekHarnessCost(session, rates: $0) },
                model: session.model,
                counts: Tokens(input: session.uncachedInputTokens, cacheRead: session.cacheReadTokens,
                               cacheWrite: session.cacheWriteTokens, output: session.outputTokens),
                inputIncludesCache: false
            )
        }
    }

    private func scanPi(
        periods: inout PeriodAccumulators,
        homeDirectory: URL,
        pricingCatalog: ModelPricingCatalog?
    ) {
        var files: [(path: String, usage: PiSessionFileUsage)] = []
        let roots = PiSessionUsageReader.sessionRoots(
            homeDirectory: homeDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        for root in roots {
            guard let rootFiles = Self.filesModified(since: periods.last30DaysStart, below: root) else {
                // 目录暂时读不了时沿用上次的解析结果，不能当成空目录把已有统计丢掉。
                let prefixes = [root.standardizedFileURL.path, Self.realPath(of: root)].map { $0 + "/" }
                files += piFileCache.filter { entry in prefixes.contains { entry.key.hasPrefix($0) } }
                    .map { ($0.key, $0.value.usage) }
                continue
            }
            for file in rootFiles {
                let path = file.url.path
                if let cached = piFileCache[path],
                   cached.size == file.size,
                   cached.modified == file.modificationNanoseconds {
                    files.append((path, cached.usage))
                    continue
                }
                guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
                let usage = PiSessionUsageReader.parse(data)
                piFileCache[path] = (file.size, file.modificationNanoseconds, usage)
                files.append((path, usage))
            }
        }
        let livePaths = Set(files.map(\.path))
        piFileCache = piFileCache.filter { livePaths.contains($0.key) }
        let entries = PiSessionUsageReader.deduplicated(files.sorted { $0.path < $1.path }.map(\.usage))
        for entry in entries {
            periods.add(
                timestamp: entry.timestamp,
                tokens: entry.totalTokens,
                valueUSD: Self.piCost(entry, catalog: pricingCatalog),
                model: entry.model,
                counts: Tokens(input: entry.inputTokens, cacheRead: entry.cacheReadTokens,
                               cacheWrite: entry.cacheWriteTokens, output: entry.outputTokens),
                inputIncludesCache: false
            )
        }
    }

    // 与 CodexBar 一致：openai-codex 按 Codex 价格、anthropic 按 Claude 价格、Bedrock 按目录里的 Bedrock 价格，其他后端不计价。
    private static func piCost(_ entry: PiSessionUsageEntry, catalog: ModelPricingCatalog?) -> Double? {
        guard entry.countsMatchTotal else { return nil }
        let tokens = Tokens(
            input: entry.inputTokens,
            cacheRead: entry.cacheReadTokens,
            cacheWrite: entry.cacheWriteTokens,
            output: entry.outputTokens
        )
        let sample = ClaudeSample(
            timestamp: entry.timestamp,
            model: entry.model,
            tokens: tokens,
            cacheWrite1h: entry.cacheWrite1hTokens,
            isSidechain: false
        )
        switch entry.backend {
        case "openai-codex":
            guard let rates = codexRates(for: entry.model, at: entry.timestamp, catalog: catalog) else { return nil }
            // Pi 把输入、缓存读、缓存写分开记，Codex 计价要求缓存部分包含在输入里。
            var codexTokens = tokens
            codexTokens.input = entry.inputTokens + entry.cacheReadTokens + entry.cacheWriteTokens
            return codexCost(tokens: codexTokens, rates: rates)
        case "anthropic":
            guard let rates = claudeRates(for: entry.model, at: entry.timestamp, catalog: catalog) else { return nil }
            return claudeCost(sample: sample, rates: rates)
        case "amazon-bedrock":
            // Bedrock 价格按区域区分，必须完整模型 ID 精确匹配。
            guard let rates = catalog?.rates(providerID: "amazon-bedrock", modelID: entry.model, exactModelID: true)
            else { return nil }
            return claudeCost(sample: sample, rates: rates)
        default:
            return nil
        }
    }

    private static func deepSeekHarnessCost(
        _ usage: DeepSeekHarnessSessionUsage,
        rates: ModelTokenRates
    ) -> Double {
        Double(usage.uncachedInputTokens) * rates.input
            + Double(usage.cacheReadTokens) * (rates.cacheRead ?? rates.input)
            + Double(usage.cacheWriteTokens) * (rates.cacheWrite ?? rates.input)
            + Double(usage.outputTokens) * rates.output
    }

    private static func claudeCatalogRates(
        for rawModel: String,
        catalog: ModelPricingCatalog?
    ) -> ModelTokenRates? {
        guard let catalog else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = trimmed.firstIndex(of: "/") {
            if let rates = codexCatalogRates(for: trimmed, catalog: catalog) { return rates }
            let provider = String(trimmed[..<slash])
            let model = String(trimmed[trimmed.index(after: slash)...])
            let supportedProviders: Set<String> = [
                "anthropic", "openai", "google", "moonshot", "kimi-for-coding",
                "minimax", "deepseek",
            ]
            guard supportedProviders.contains(provider) else { return nil }
            return catalog.rates(providerID: provider, modelID: model)
                ?? (provider == "kimi-for-coding" && model == "k3[1m]"
                    ? catalog.rates(providerID: provider, modelID: "k3")
                    : nil)
        }
        let model = normalizedClaudeModel(trimmed)
        let preferredProviders: [String]?
        if model.hasPrefix("claude-") {
            preferredProviders = ["anthropic"]
        } else if ["gpt-", "chatgpt-", "text-embedding-"].contains(where: model.hasPrefix)
            || ["o1", "o3", "o4"].contains(where: { model == $0 || model.hasPrefix("\($0)-") }) {
            preferredProviders = ["openai"]
        } else if ["gemini-", "gemma-", "deep-research-", "veo-", "lyria-"].contains(where: model.hasPrefix) {
            preferredProviders = ["google"]
        } else if ["kimi-for-coding", "k3", "k3[1m]"].contains(model) || model.hasPrefix("k3-") {
            preferredProviders = ["kimi-for-coding"]
        } else if model.hasPrefix("kimi-") || model.hasPrefix("moonshot-") {
            preferredProviders = ["moonshot", "kimi-for-coding"]
        } else if model.hasPrefix("minimax-") {
            preferredProviders = ["minimax"]
        } else if model.hasPrefix("deepseek-") {
            preferredProviders = ["deepseek"]
        } else {
            preferredProviders = nil
        }
        var matches: [ModelTokenRates] = []
        for provider in preferredProviders ?? ["anthropic", "openai", "google", "moonshot", "kimi-for-coding", "minimax", "deepseek"] {
            if let rates = catalog.rates(providerID: provider, modelID: model)
                ?? (provider == "kimi-for-coding" && model == "k3[1m]"
                    ? catalog.rates(providerID: provider, modelID: "k3")
                    : nil) {
                if preferredProviders != nil { return rates }
                matches.append(rates)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalizedCodexModel(_ model: String) -> String {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("openai/") {
            normalized.removeFirst("openai/".count)
        }
        if normalized == "gpt-5.6" { return "gpt-5.6-sol" }
        if normalized == "gpt-reserve" { return "gpt-5.6-luna" }
        if normalized == "gpt-daybreak-blue-latest" { return "gpt-5.6-sol" }
        if normalized == "gpt-daybreak-red-latest" { return "gpt-5.6-cyber" }
        if let dated = normalized.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(normalized[..<dated.lowerBound])
            if codexBundledRates(for: base) != nil { return base }
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
