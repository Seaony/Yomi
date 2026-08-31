import Foundation

enum UsageCollectionError: LocalizedError {
    case missingCredential
    case missingEndpoint
    case unreadableResponse
    case requestFailed(Int)
    case commandFailed(String)
    case localDataNotFound

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
        case .localDataNotFound:
            AppLocalization.text("未找到本机用量记录", "No local usage records found")
        }
    }
}

actor UsageCollector {
    private let session: URLSession
    private var pricingCatalog: ModelPricingCatalog?
    private var pricingCatalogReloadAt = Date.distantPast

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
        let catalog = await resolvedPricingCatalog()
        return addingLocalMetadata(to: usage, descriptor: descriptor, pricingCatalog: catalog)
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

        if configuration.source == .account || configuration.source == .automatic {
            if let result = try? localUsage(descriptor: descriptor) {
                return result
            }
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

        if descriptor.id.rawValue == "claude" {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
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

    private func localUsage(descriptor: ProviderDescriptor) throws -> ProviderUsage {
        let manager = FileManager.default
        for url in localCandidates(for: descriptor.id) where manager.fileExists(atPath: url.path) {
            if let data = try? boundedData(from: url),
               let usage = try? UsageParser.parse(data, descriptor: descriptor) {
                return usage
            }
        }

        for directory in localDirectories(for: descriptor.id) {
            guard let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let files = enumerator.compactMap { $0 as? URL }
                .filter { ["json", "jsonl", "log"].contains($0.pathExtension.lowercased()) }
                .prefix(120)
                .sorted { modificationDate($0) > modificationDate($1) }

            for file in files.prefix(12) {
                if let data = try? boundedData(from: file),
                   let usage = try? UsageParser.parse(data, descriptor: descriptor) {
                    return usage
                }
            }
        }
        throw UsageCollectionError.localDataNotFound
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
        return ""
    }

    private func addingLocalMetadata(
        to usage: ProviderUsage,
        descriptor: ProviderDescriptor,
        pricingCatalog: ModelPricingCatalog?
    ) -> ProviderUsage {
        var enriched = usage
        if enriched.plan == nil {
            enriched.plan = localPlan(for: descriptor)
        }
        enriched.today = LocalDailyUsageScanner.scan(
            providerID: descriptor.id,
            pricingCatalog: pricingCatalog
        )
        return enriched
    }

    private func resolvedPricingCatalog() async -> ModelPricingCatalog? {
        let now = Date()
        if now < pricingCatalogReloadAt { return pricingCatalog }
        pricingCatalog = await ModelPricingCatalog.load(session: session)
        pricingCatalogReloadAt = now.addingTimeInterval(24 * 60 * 60)
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

    private func localDirectories(for id: ProviderID) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library/Application Support")
        switch id.rawValue {
        case "codex": return [home.appending(path: ".codex/sessions")]
        case "claude": return [home.appending(path: ".claude/projects")]
        case "gemini": return [home.appending(path: ".gemini/tmp")]
        case "cursor": return [library.appending(path: "Cursor/User/globalStorage")]
        case "windsurf": return [library.appending(path: "Windsurf/User/globalStorage")]
        case "zed": return [home.appending(path: ".config/zed")]
        case "kiro": return [home.appending(path: ".kiro")]
        case "opencode", "opencodego": return [home.appending(path: ".local/share/opencode")]
        default: return [home.appending(path: ".config/\(id.rawValue)")]
        }
    }

    private func boundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit: UInt64 = 2_000_000
        if size > limit { try handle.seek(toOffset: size - limit) } else { try handle.seek(toOffset: 0) }
        return try handle.readToEnd() ?? Data()
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
