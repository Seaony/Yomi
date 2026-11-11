import Foundation

nonisolated enum UsageFreshness {
    static func isStale(
        updatedAt: Date?,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > max(15 * 60, 2 * refreshInterval)
    }

    static func updatedText(updatedAt: Date, now: Date, language: AppLanguage) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updatedAt)) / 60)
        return AppCopy(language: language).text("\(minutes) 分钟前更新", "Updated \(minutes) min ago")
    }
}
