import Foundation

nonisolated enum ResetBoundaryRefreshPolicy {
    struct Boundary: Hashable, Sendable {
        var providerID: ProviderID
        var windowID: String
        var resetsAt: Date
    }

    struct Plan: Equatable, Sendable {
        var dueProviderIDs: Set<ProviderID>
        var nextDeadline: Date?
        var attemptedBoundaries: Set<Boundary>
    }

    static func plan(
        usages: [ProviderUsage],
        attemptedBoundaries: Set<Boundary>,
        now: Date
    ) -> Plan {
        var attempted = attemptedBoundaries
        var dueProviderIDs: Set<ProviderID> = []
        var nextDeadline: Date?
        for usage in usages {
            guard let updatedAt = usage.updatedAt else { continue }
            for window in usage.windows + usage.additionalWindows {
                // 滚动额度满额时可能把重置写成“现在”，不能靠它触发下一轮。
                guard let resetsAt = window.resetsAt, resetsAt > updatedAt else { continue }
                let boundary = Boundary(providerID: usage.id, windowID: window.id, resetsAt: resetsAt)
                guard !attempted.contains(boundary) else { continue }
                if resetsAt <= now {
                    dueProviderIDs.insert(usage.id)
                    // 先记住这次边界，取数失败后仍显示旧窗口时不会反复排队。
                    attempted.insert(boundary)
                } else {
                    nextDeadline = min(nextDeadline ?? resetsAt, resetsAt)
                }
            }
        }
        return Plan(dueProviderIDs: dueProviderIDs, nextDeadline: nextDeadline, attemptedBoundaries: attempted)
    }
}
