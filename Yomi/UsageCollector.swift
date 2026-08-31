import Foundation
import LocalAuthentication
import Security

enum UsageCollectionError: LocalizedError {
    case missingCredential
    case missingEndpoint
    case unreadableResponse
    case requestFailed(Int)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            AppLocalization.text("未找到可用的认证信息", "No available credentials found")
        case .missingEndpoint:
            AppLocalization.text("尚未配置用量接口", "Usage endpoint is not configured")
        case .unreadableResponse:
            AppLocalization.text("无法识别返回的用量数据", "The returned usage data could not be read")
        case let .requestFailed(status):
            AppLocalization.text("请求失败（HTTP \(status)）", "Request failed (HTTP \(status))")
        case let .commandFailed(message):
            AppLocalization.text("命令执行失败：\(message)", "Command failed: \(message)")
        }
    }
}

actor UsageCollector {
    private let session: URLSession
    private var pricingCatalog: ModelPricingCatalog?
    private var pricingCatalogLoadTask: Task<ModelPricingCatalog?, Never>?
    private var pricingCatalogReloadAt = Date.distantPast
    private let localUsageScanner = LocalDailyUsageScanner()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func collect(
        descriptor: ProviderDescriptor,
        configuration: ProviderConfiguration,
        secret: String
    ) async throws -> ProviderUsage {
        let usage = try await collectRaw(
            descriptor: descriptor,
            configuration: configuration,
            secret: secret
        )
        guard descriptor.id.rawValue == "codex" || descriptor.id.rawValue == "claude" else {
            return usage
        }
        let catalog = await resolvedPricingCatalog()
        return await addingLocalMetadata(
            to: usage,
            descriptor: descriptor,
            pricingCatalog: catalog
        )
    }

    private func collectRaw(
        descriptor: ProviderDescriptor,
        configuration: ProviderConfiguration,
        secret: String
    ) async throws -> ProviderUsage {
        if configuration.source == .command {
            return try await commandUsage(descriptor: descriptor, command: configuration.command)
        }

        if configuration.source == .endpoint {
            guard !configuration.endpoint.isEmpty else { throw UsageCollectionError.missingEndpoint }
            return try await remoteUsage(
                descriptor: descriptor,
                recipe: ProviderRecipe(configuration.endpoint),
                secret: secret
            )
        }

        let environmentValue = environmentSecret(for: descriptor)
        let localValue = localCredential(for: descriptor.id)
        let resolvedSecret = [secret, environmentValue, localValue].first(where: { !$0.isEmpty }) ?? ""
        if let recipe = ProviderRecipes.recipe(for: descriptor.id), !resolvedSecret.isEmpty {
            return try await remoteUsage(descriptor: descriptor, recipe: recipe, secret: resolvedSecret)
        }

        if !configuration.command.isEmpty {
            return try await commandUsage(descriptor: descriptor, command: configuration.command)
        }

        if resolvedSecret.isEmpty { throw UsageCollectionError.missingCredential }
        throw UsageCollectionError.missingEndpoint
    }

    private func remoteUsage(
        descriptor: ProviderDescriptor,
        recipe: ProviderRecipe,
        secret: String
    ) async throws -> ProviderUsage {
        guard let url = URL(string: recipe.endpoint) else { throw UsageCollectionError.missingEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = recipe.method
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi/1", forHTTPHeaderField: "User-Agent")

        if !secret.isEmpty {
            switch recipe.authorization {
            case .bearer:
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            case let .header(name):
                request.setValue(secret, forHTTPHeaderField: name)
            case .cookie:
                request.setValue(secret, forHTTPHeaderField: "Cookie")
            }
        }

        if descriptor.id.rawValue == "codex", let accountID = codexAccountID() {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        } else if descriptor.id.rawValue == "claude" {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        }
        if let body = recipe.body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageCollectionError.requestFailed(http.statusCode)
        }
        return try UsageParser.parse(data, descriptor: descriptor)
    }

    private func commandUsage(descriptor: ProviderDescriptor, command: String) async throws -> ProviderUsage {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw UsageCollectionError.commandFailed(
                AppLocalization.text("未配置命令", "Command is not configured")
            )
        }

        let usage = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", cleaned]
                process.standardOutput = output
                process.standardError = errors

                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let data = errors.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: data, encoding: .utf8) ?? AppLocalization.text(
                            "退出码 \(process.terminationStatus)",
                            "Exit code \(process.terminationStatus)"
                        )
                        throw UsageCollectionError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: try UsageParser.parse(data, descriptor: descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return usage
    }

    private func environmentSecret(for descriptor: ProviderDescriptor) -> String {
        let environment = ProcessInfo.processInfo.environment
        for key in descriptor.environmentKeys {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return ""
    }

    private func localCredential(for id: ProviderID) -> String {
        let keys = ["access_token", "accessToken", "oauth_token", "token", "api_key", "apiKey"]
        for url in localCandidates(for: id) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let value = findString(in: object, keys: Set(keys)) else { continue }
            return value
        }
        if id.rawValue == "claude", let data = claudeKeychainCredentialData(),
           let object = try? JSONSerialization.jsonObject(with: data),
           let value = findString(
               in: object,
               keys: ["access_token", "accessToken", "oauth_token", "token"]
           ) {
            return value
        }
        return ""
    }

    private func claudeKeychainCredentialData() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func codexAccountID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return findString(in: object, keys: ["account_id", "accountId"])
    }

    private func addingLocalMetadata(
        to usage: ProviderUsage,
        descriptor: ProviderDescriptor,
        pricingCatalog: ModelPricingCatalog?
    ) async -> ProviderUsage {
        var enriched = usage
        if enriched.plan == nil {
            enriched.plan = localPlan(for: descriptor)
        }
        let weeklyWindow = weeklyWindow(in: enriched, descriptor: descriptor)
        let now = Date()
        let weeklyReset = weeklyWindow?.resetsAt.flatMap { $0 > now ? $0 : nil }
        let weekStart = weeklyReset
            .flatMap { Calendar.current.date(byAdding: .day, value: -7, to: $0) }
            ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let localUsage = await localUsageScanner.scan(
            providerID: descriptor.id,
            currentWeekStart: weekStart,
            now: now,
            pricingCatalog: pricingCatalog
        )
        enriched.today = localUsage?.today
        enriched.last30Days = localUsage?.last30Days
        enriched.weeklyEstimate = weeklyEstimate(
            localUsage: localUsage?.currentWeek,
            usedFraction: weeklyReset == nil ? nil : weeklyWindow?.clampedFraction
        )
        return enriched
    }

    private func weeklyWindow(
        in usage: ProviderUsage,
        descriptor: ProviderDescriptor
    ) -> UsageWindow? {
        let secondary = descriptor.secondaryLabel.lowercased()
        return usage.windows.first { $0.label.lowercased() == secondary }
            ?? usage.windows.first {
                let label = $0.label.lowercased()
                return label.contains("week")
                    || label.contains("7 day")
                    || label.contains("7-day")
                    || label.contains("seven_day")
            }
    }

    private func weeklyEstimate(
        localUsage: DailyTokenUsage?,
        usedFraction: Double?
    ) -> DailyTokenUsage? {
        guard let localUsage,
              let usedFraction,
              usedFraction >= 0.01,
              usedFraction <= 1
        else { return nil }
        return DailyTokenUsage(
            tokens: Int64((Double(localUsage.tokens) / usedFraction).rounded()),
            valueUSD: localUsage.valueUSD.map { $0 / usedFraction }
        )
    }

    private func resolvedPricingCatalog() async -> ModelPricingCatalog? {
        let now = Date()
        if now < pricingCatalogReloadAt { return pricingCatalog }
        if let pricingCatalogLoadTask {
            return await pricingCatalogLoadTask.value
        }

        let task = Task { [session] in
            await ModelPricingCatalog.load(session: session, now: now)
        }
        pricingCatalogLoadTask = task
        pricingCatalog = await task.value
        pricingCatalogLoadTask = nil
        let retryInterval: TimeInterval = pricingCatalog == nil ? 15 * 60 : 24 * 60 * 60
        pricingCatalogReloadAt = now.addingTimeInterval(retryInterval)
        return pricingCatalog
    }

    private func localPlan(for descriptor: ProviderDescriptor) -> String? {
        guard descriptor.id.rawValue == "claude" else { return nil }
        let profileURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: profileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        for key in ["organizationRateLimitTier", "subscriptionType", "billingType"] {
            guard let value = account[key] as? String,
                  let plan = UsageParser.displayPlan(value, descriptor: descriptor)
            else { continue }
            return plan
        }
        return nil
    }

    private func findString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key), let string = child as? String, !string.isEmpty { return string }
            }
            for child in dictionary.values {
                if let result = findString(in: child, keys: keys) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = findString(in: child, keys: keys) { return result }
            }
        }
        return nil
    }

    private func localCandidates(for id: ProviderID) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch id.rawValue {
        case "codex":
            return [home.appending(path: ".codex/auth.json")]
        case "claude":
            return [
                home.appending(path: ".claude/.credentials.json"),
                home.appending(path: ".config/claude/credentials.json"),
            ]
        case "gemini":
            return [
                home.appending(path: ".gemini/oauth_creds.json"),
                home.appending(path: ".gemini/google_accounts.json"),
            ]
        default:
            return []
        }
    }

}
