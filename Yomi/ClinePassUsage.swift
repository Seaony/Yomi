import CoreFoundation
import Foundation

nonisolated enum ClinePassUsageError: LocalizedError {
    case missingCredentials
    case authenticationRejected

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未找到 ClinePass 凭据，请添加 API Key 或运行 cline auth 登录",
                "ClinePass credentials not found. Add an API key or run cline auth to sign in."
            )
        case .authenticationRejected:
            AppLocalization.text(
                "ClinePass 凭据已失效，请检查 API Key 或运行 cline auth 重新登录",
                "ClinePass credentials were rejected. Check your API key or run cline auth to sign in again."
            )
        }
    }
}

nonisolated enum ClinePassUsageFetcher {
    struct Credential: Sendable {
        let token: String
        let isOAuth: Bool
    }

    static let usageURL = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!

    static func fetch(
        apiKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let credential = resolvedCredential(apiKey: apiKey, environment: environment) else {
            throw ClinePassUsageError.missingCredentials
        }
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ClinePassUsageError.authenticationRejected
        }
        guard http.statusCode == 200 else { throw UsageCollectionError.requestFailed(http.statusCode) }
        return try parse(data, isOAuth: credential.isOAuth, now: now)
    }

    static func resolvedCredential(apiKey: String?, environment: [String: String]) -> Credential? {
        for raw in [apiKey, environment["CLINE_API_KEY"], environment["CLINEPASS_API_KEY"]] {
            if let token = cleaned(raw) { return Credential(token: token, isOAuth: false) }
        }
        guard let data = try? Data(contentsOf: providersFileURL(environment: environment)) else { return nil }
        return fileCredential(data)
    }

    static func providersFileURL(environment: [String: String]) -> URL {
        let home = cleaned(environment["HOME"]).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        func path(_ key: String) -> URL? {
            guard let value = cleaned(environment[key]) else { return nil }
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            return URL(fileURLWithPath: value)
        }
        if let file = path("CLINE_PROVIDER_SETTINGS_PATH") { return file }
        let directory = path("CLINE_DATA_DIR")
            ?? (path("CLINE_DIR") ?? home.appendingPathComponent(".cline")).appendingPathComponent("data")
        return directory.appendingPathComponent("settings/providers.json")
    }

    static func fileCredential(_ data: Data) -> Credential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let cline = providers["cline"] as? [String: Any],
              let settings = cline["settings"] as? [String: Any]
        else { return nil }
        let auth = settings["auth"] as? [String: Any]
        if let access = cleaned(auth?["accessToken"] as? String) {
            return Credential(token: access.hasPrefix("workos:") ? access : "workos:\(access)", isOAuth: true)
        }
        guard let key = cleaned(settings["apiKey"] as? String) ?? cleaned(auth?["apiKey"] as? String) else {
            return nil
        }
        return Credential(token: key, isOAuth: false)
    }

    static func parse(_ data: Data, isOAuth: Bool, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = root["success"] as? NSNumber,
              CFGetTypeID(success) == CFBooleanGetTypeID(), success.boolValue,
              let payload = root["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]]
        else { throw UsageCollectionError.unreadableResponse }
        let definitions = [("five_hour", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly")]
        var windows: [String: UsageWindow] = [:]
        for limit in limits {
            guard let type = limit["type"] as? String else { throw UsageCollectionError.unreadableResponse }
            guard let definition = definitions.first(where: { $0.0 == type }) else { continue }
            guard let percent = limit["percentUsed"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(), percent.doubleValue.isFinite
            else { throw UsageCollectionError.unreadableResponse }
            var reset: Date?
            if let value = limit["resetsAt"], !(value is NSNull) {
                guard let timestamp = value as? String else { throw UsageCollectionError.unreadableResponse }
                reset = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
                if reset == nil { reset = try? Date.ISO8601FormatStyle().parse(timestamp) }
                guard reset != nil else { throw UsageCollectionError.unreadableResponse }
            }
            windows[type] = UsageWindow(
                id: "clinepass-\(type)",
                label: definition.1,
                usedFraction: min(100, max(0, percent.doubleValue)) / 100,
                resetsAt: reset,
                detail: nil
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "clinepass"),
            state: .ready,
            windows: definitions.compactMap { windows[$0.0] },
            details: [UsageDetail(
                id: "clinepass-auth",
                label: AppLocalization.text("认证方式", "Authentication"),
                value: isOAuth
                    ? AppLocalization.text("浏览器登录", "Browser")
                    : AppLocalization.text("API Key", "API key")
            )],
            updatedAt: now,
            message: nil
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
