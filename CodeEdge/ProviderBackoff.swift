import Foundation

nonisolated struct ProviderBackoffState: Codable, Equatable, Sendable {
    var consecutiveRateLimits: Int
    var retryAt: Date
}

nonisolated enum ProviderBackoffPolicy {
    struct Plan: Equatable, Sendable {
        var dueProviderIDs: Set<ProviderID>
        var nextDeadline: Date?
        var attemptedRetries: [String: Date]
    }

    static func plan(
        stateByID: [String: ProviderBackoffState],
        enabledProviderIDs: Set<ProviderID>,
        attemptedRetries: [String: Date],
        now: Date
    ) -> Plan {
        var dueProviderIDs: Set<ProviderID> = []
        var nextDeadline: Date?
        var attempted = attemptedRetries
        for (id, state) in stateByID {
            let providerID = ProviderID(rawValue: id)
            guard enabledProviderIDs.contains(ProviderID(rawValue: id)),
                  attempted[id] != state.retryAt else { continue }
            if state.retryAt <= now {
                dueProviderIDs.insert(providerID)
                // 排队前记住当前截止点，失败仍保留旧状态时不会反复重试。
                attempted[id] = state.retryAt
            } else {
                nextDeadline = min(nextDeadline ?? state.retryAt, state.retryAt)
            }
        }
        return Plan(dueProviderIDs: dueProviderIDs, nextDeadline: nextDeadline, attemptedRetries: attempted)
    }

    static func updating(
        previous: ProviderBackoffState?,
        httpStatus: Int?,
        retryAfter: String?,
        succeeded: Bool,
        now: Date
    ) -> ProviderBackoffState? {
        // 备用来源成功也算成功，不能因为之前的 429 留下退避。
        if succeeded { return nil }
        guard httpStatus == 429 else { return previous }
        let count = min(5, max(0, previous?.consecutiveRateLimits ?? 0)) + 1
        let fallbackSeconds = min(900, 60 * pow(2, Double(count - 1)))
        let retryAt = retryAfter.flatMap { retryAfterDate($0, now: now) }
            ?? now.addingTimeInterval(fallbackSeconds)
        return ProviderBackoffState(consecutiveRateLimits: min(5, count), retryAt: retryAt)
    }

    static func canRefresh(
        state: ProviderBackoffState?,
        now: Date,
        isManual: Bool
    ) -> Bool {
        isManual || state.map { now >= $0.retryAt } ?? true
    }

    static func remaining(state: ProviderBackoffState?, now: Date) -> TimeInterval {
        max(0, state?.retryAt.timeIntervalSince(now) ?? 0)
    }

    static func retryAfterDate(_ value: String, now: Date) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
            let deadline = now.addingTimeInterval(seconds)
            return deadline.timeIntervalSince1970.isFinite ? deadline : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let deadline = formatter.date(from: trimmed) else { return nil }
        return max(now, deadline)
    }
}
