import Foundation

nonisolated enum ResetBoundaryRefreshPolicy {
    struct Boundary: Hashable, Sendable {
        var providerID: ProviderID
        var resetsAt: Date
    }

    struct Plan: Equatable, Sendable {
        var dueProviderIDs: Set<ProviderID>
        var nextDeadline: Date?
        var attemptedBoundaries: Set<Boundary>
        var lastTriggeredAtByProvider: [ProviderID: Date]
    }

    static func plan(
        usages: [ProviderUsage],
        attemptedBoundaries: Set<Boundary>,
        lastTriggeredAtByProvider: [ProviderID: Date] = [:],
        now: Date
    ) -> Plan {
        var attempted = attemptedBoundaries
        var lastTriggered = lastTriggeredAtByProvider
        var dueProviderIDs: Set<ProviderID> = []
        var nextDeadline: Date?
        var pendingByProvider: [ProviderID: Set<Date>] = [:]
        for usage in usages {
            guard let updatedAt = usage.updatedAt else { continue }
            for window in usage.windows + usage.additionalWindows {
                // 滚动额度满额时可能把重置写成“现在”，不能靠它触发下一轮。
                guard let resetsAt = window.resetsAt, resetsAt > updatedAt else { continue }
                let boundary = Boundary(providerID: usage.id, resetsAt: resetsAt)
                guard !attempted.contains(boundary) else { continue }
                pendingByProvider[usage.id, default: []].insert(resetsAt)
            }
        }
        for (providerID, resets) in pendingByProvider {
            let dueResets = resets.filter { $0 <= now }
            let canTrigger = lastTriggered[providerID].map { now.timeIntervalSince($0) >= 60 } ?? true
            if !dueResets.isEmpty && canTrigger {
                dueProviderIDs.insert(providerID)
                lastTriggered[providerID] = now
                // 同次到期的窗口只取数一次，失败后也不重复排队。
                for resetsAt in dueResets {
                    attempted.insert(Boundary(providerID: providerID, resetsAt: resetsAt))
                }
            }
            for resetsAt in resets {
                guard !attempted.contains(Boundary(providerID: providerID, resetsAt: resetsAt)) else { continue }
                let deadline = lastTriggered[providerID].map { max(resetsAt, $0.addingTimeInterval(60)) } ?? resetsAt
                nextDeadline = min(nextDeadline ?? deadline, deadline)
            }
        }
        return Plan(dueProviderIDs: dueProviderIDs, nextDeadline: nextDeadline, attemptedBoundaries: attempted,
                    lastTriggeredAtByProvider: lastTriggered)
    }
}
