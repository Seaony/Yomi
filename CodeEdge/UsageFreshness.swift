import Foundation

nonisolated enum UsageFreshness {
    static func refreshInterval(for selectedInterval: TimeInterval) -> TimeInterval {
        selectedInterval == 0 ? 1800 : selectedInterval
    }

    static func isStale(
        updatedAt: Date?,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > max(15 * 60, 2 * Self.refreshInterval(for: refreshInterval))
    }

    static func shouldDim(
        usage: ProviderUsage,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        usage.state != .loading && isStale(updatedAt: usage.updatedAt, refreshInterval: refreshInterval, now: now)
    }

    static func updatedText(updatedAt: Date, now: Date, language: AppLanguage) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updatedAt)) / 60)
        let copy = AppCopy(language: language)
        if minutes >= 24 * 60 {
            let days = minutes / (24 * 60)
            return copy.text("\(days) 天前更新", "Updated \(days) \(days == 1 ? "day" : "days") ago")
        }
        if minutes >= 60 {
            let hours = minutes / 60
            return copy.text("\(hours) 小时前更新", "Updated \(hours) \(hours == 1 ? "hour" : "hours") ago")
        }
        return copy.text("\(minutes) 分钟前更新", "Updated \(minutes) min ago")
    }
}
