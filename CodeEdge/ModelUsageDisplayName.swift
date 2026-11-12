import Foundation

nonisolated func safeModelUsageName(_ model: String, language: AppLanguage) -> String {
    limitedModelUsageName(fullModelUsageName(model, language: language))
}

nonisolated func compactModelUsageName(_ model: String, language: AppLanguage) -> String {
    let fullName = fullModelUsageName(model, language: language)
    let lastSegment = fullName.components(separatedBy: "/").last ?? fullName
    let name = lastSegment.replacingOccurrences(of: #"-[0-9]{8}$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return limitedModelUsageName(fullModelUsageName(name, language: language))
}

nonisolated func fullModelUsageName(_ model: String, language: AppLanguage) -> String {
    let copy = AppCopy(language: language)
    let value = model.components(separatedBy: .controlCharacters).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return copy.text("未知模型", "Unknown model") }
    if value == ModelUsageBreakdown.otherModels { return copy.text("其他", "Other") }
    return value
}

private nonisolated func limitedModelUsageName(_ value: String) -> String {
    return value.count > 96 ? String(value.prefix(95)) + "…" : value
}
