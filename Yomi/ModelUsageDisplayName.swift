import Foundation

nonisolated func safeModelUsageName(_ model: String, language: AppLanguage) -> String {
    let copy = AppCopy(language: language)
    let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == ModelUsageBreakdown.otherModels { return copy.text("其他", "Other") }
    if KnownModelUsageNames.publicIDs.contains(value) { return value }
    let redacted = DiagnosticsRedactor.redact(value)
    let lower = value.lowercased()
    let sensitivePrefixes = ["sk-", "bearer", "secret", "token", "api-key", "api_key", "access-token", "access_token",
                             "refresh-token", "refresh_token", "auth", "cookie", "account", "acct-", "acct_",
                             "user-", "user_", "org-", "org_", "session", "password"]
    guard redacted == value,
          value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$"#, options: .regularExpression) != nil,
          !sensitivePrefixes.contains(where: lower.hasPrefix) else {
        return copy.text("未知模型", "Unknown model")
    }
    return redacted
}

private nonisolated enum KnownModelUsageNames {
    // 完整名称来自既有 Claude 定价常量和 models.dev 定价表，不放宽一般长串的脱敏规则。
    static let publicIDs: Set<String> = [
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5-20251101",
        "claude-opus-4-6-20260205",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-20250514",
        "claude-sonnet-4-20250514",
        "gpt-daybreak-blue-latest",
        "deep-research-max-preview-04-2026",
        "deep-research-preview-04-2026",
        "gemini-2.5-computer-use-preview-10-2025",
        "gemini-2.5-flash-preview-tts",
        "gemini-2.5-pro-preview-tts",
        "gemini-3-pro-image-preview",
        "gemini-3.1-flash-image-preview",
        "gemini-3.1-flash-lite-image",
        "gemini-3.1-flash-lite-preview",
        "gemini-3.1-flash-live-preview",
        "gemini-3.1-flash-tts-preview",
        "gemini-3.1-pro-preview-customtools",
        "gemini-3.5-live-translate-preview",
        "gemini-flash-lite-latest",
        "gemini-omni-flash-preview",
        "gemini-robotics-er-1.6-preview",
    ]
}
