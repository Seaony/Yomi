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
    private static let claudeWeeklyAmountEstimatorKey = "claude-weekly-amount-estimator.v1"

    private let session: URLSession
    private var pricingCatalog: ModelPricingCatalog?
    private var pricingCatalogLoadTask: Task<ModelPricingCatalogLoadResult, Never>?
    private var pricingCatalogReloadAt = Date.distantPast
    private let localUsageScanner = LocalDailyUsageScanner()
    private var claudeWeeklyAmountEstimator: ClaudeWeeklyAmountEstimator

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        claudeWeeklyAmountEstimator = UserDefaults.standard.data(
            forKey: Self.claudeWeeklyAmountEstimatorKey
        ).flatMap { try? JSONDecoder().decode(ClaudeWeeklyAmountEstimator.self, from: $0) }
            ?? ClaudeWeeklyAmountEstimator()
    }

    func collect(
        descriptor: ProviderDescriptor,
        configuration: ProviderConfiguration,
        secret: String,
        allowVertexClaudeFallback: Bool = false,
        allowBrowserCookieImport: Bool = false
    ) async throws -> ProviderUsage {
        let usage = try await collectRaw(
            descriptor: descriptor,
            configuration: configuration,
            secret: secret,
            allowBrowserCookieImport: allowBrowserCookieImport
        )
        if descriptor.id.rawValue == "opencodego" {
            return OpenCodeGoLocalUsageReader.enrich(usage)
        }
        let claudeUsesAdminAPI = descriptor.id.rawValue == "claude"
            && configuration.source == .token
            && [secret, environmentSecret(for: descriptor)].contains { credential in
                credential.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().hasPrefix("sk-ant-admin")
            }
        if claudeUsesAdminAPI {
            return usage
        }
        guard descriptor.id.rawValue == "codex"
            || descriptor.id.rawValue == "claude"
            || descriptor.id.rawValue == "vertexai"
        else {
            return usage
        }
        return await enrichLocalMetadata(
            to: usage,
            descriptor: descriptor,
            allowVertexClaudeFallback: allowVertexClaudeFallback
        )
    }

    func enrichLocalMetadata(
        to usage: ProviderUsage,
        descriptor: ProviderDescriptor,
        allowVertexClaudeFallback: Bool = false
    ) async -> ProviderUsage {
        guard descriptor.id.rawValue == "codex"
            || descriptor.id.rawValue == "claude"
            || descriptor.id.rawValue == "vertexai"
        else {
            return usage
        }
        let catalog = await resolvedPricingCatalog()
        return await addingLocalMetadata(
            to: usage,
            descriptor: descriptor,
            pricingCatalog: catalog,
            allowVertexClaudeFallback: allowVertexClaudeFallback
        )
    }

    private func collectRaw(
        descriptor: ProviderDescriptor,
        configuration: ProviderConfiguration,
        secret: String,
        allowBrowserCookieImport: Bool
    ) async throws -> ProviderUsage {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptor.id.rawValue == "codex" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            var environment = ProcessInfo.processInfo.environment
            let configuredBinary = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configuredBinary.isEmpty { environment["CODEX_CLI_PATH"] = configuredBinary }
            return try await CodexUsageFetcher.fetch(
                source: configuration.source,
                configuredCredential: secret.isEmpty ? nil : secret,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                allowBrowserImport: allowBrowserCookieImport,
                session: session,
                environment: environment,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "kiro" {
            return try await KiroUsageFetcher.fetch(
                configuredCommand: configuration.command.isEmpty ? nil : configuration.command,
                session: session
            )
        }
        if descriptor.id.rawValue == "windsurf" {
            let dataSource: WindsurfUsageDataSource = switch configuration.source {
            case .cookie: .web
            case .account: .local
            default: .automatic
            }
            let sessionSource = WindsurfSessionSource(rawValue: configuration.account) ?? .automatic
            return try await WindsurfUsageFetcher.fetch(
                dataSource: dataSource,
                sessionSource: sessionSource,
                manualSessionInput: secret.isEmpty ? nil : secret,
                session: session
            )
        }
        if descriptor.id.rawValue == "bedrock" {
            let stored = await MainActor.run {
                let preferences = ProviderPreferences.shared
                return (
                    secretAccessKey: preferences.auxiliarySecret(for: descriptor.id, key: "secret-access-key"),
                    profile: preferences.auxiliarySecret(for: descriptor.id, key: "aws-profile"),
                    region: preferences.auxiliarySecret(for: descriptor.id, key: "aws-region"),
                    authMode: preferences.auxiliarySecret(for: descriptor.id, key: "aws-auth-mode")
                )
            }
            return try await BedrockUsageFetcher.fetch(
                accessKeyID: secret.isEmpty ? nil : secret,
                secretAccessKey: stored.secretAccessKey.isEmpty ? nil : stored.secretAccessKey,
                profile: stored.profile.isEmpty ? nil : stored.profile,
                region: stored.region.isEmpty ? nil : stored.region,
                authMode: BedrockAuthMode(rawValue: stored.authMode),
                session: session
            )
        }
        if descriptor.id.rawValue == "sub2api" {
            return try await Sub2APIUsageFetcher.fetch(
                apiKey: secret.isEmpty ? nil : secret,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "wayfinder" {
            return try await WayfinderUsageFetcher.fetch(
                configuredBaseURL: configuration.endpoint.isEmpty ? nil : configuration.endpoint
            )
        }
        if descriptor.id.rawValue == "llmproxy" {
            return try await LLMProxyUsageFetcher.fetch(
                apiKey: secret.isEmpty ? nil : secret,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "litellm" {
            return try await LiteLLMUsageFetcher.fetch(
                apiKey: secret.isEmpty ? nil : secret,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }

        if descriptor.id.rawValue == "codebuff" {
            return try await CodebuffUsageFetcher.fetch(
                credential: secret.isEmpty ? nil : secret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "stepfun" {
            let stored = await MainActor.run {
                let preferences = ProviderPreferences.shared
                return (
                    manual: preferences.auxiliarySecret(for: descriptor.id, key: "manual-token"),
                    cached: preferences.auxiliarySecret(for: descriptor.id, key: "session-token")
                )
            }
            let configuredSecret = configuration.source == .token
                ? (stored.manual.isEmpty ? secret : stored.manual)
                : secret
            return try await StepFunUsageFetcher.fetch(
                source: configuration.source,
                configuredUsername: configuration.account.isEmpty ? nil : configuration.account,
                configuredSecret: configuredSecret.isEmpty ? nil : configuredSecret,
                cachedToken: stored.cached.isEmpty ? nil : stored.cached,
                session: session,
                cachedTokenUpdater: { token in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            token ?? "",
                            for: descriptor.id,
                            key: "session-token"
                        )
                    }
                },
                manualTokenUpdater: { token in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            token,
                            for: descriptor.id,
                            key: "manual-token"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "longcat" {
            return try await LongCatUsageFetcher.fetch(
                credential: secret,
                source: configuration.source,
                session: session,
                environment: ProcessInfo.processInfo.environment,
                allowBrowserImport: allowBrowserCookieImport
            )
        }
        if descriptor.id.rawValue == "zoommate" {
            let cached = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await ZoomMateUsageFetcher.fetch(
                credential: secret.isEmpty ? nil : secret,
                source: configuration.source,
                session: session,
                cachedCookieHeaders: cached.isEmpty ? nil : cached,
                allowBrowserImport: allowBrowserCookieImport,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }

        if descriptor.id.rawValue == "claude" {
            return try await claudeUsage(
                descriptor: descriptor,
                configuration: configuration,
                secret: secret
            )
        }

        let environmentValue = environmentSecret(for: descriptor)
        let localValue = localCredential(for: descriptor.id)
        let resolvedSecret = [secret, environmentValue, localValue].first(where: { !$0.isEmpty }) ?? ""
        if descriptor.id.rawValue == "notion" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await NotionUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                workspaceID: configuration.account.isEmpty ? nil : configuration.account,
                session: session,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                },
                allowBrowserImport: allowBrowserCookieImport
            )
        }
        if descriptor.id.rawValue == "vertexai" {
            return try await VertexAIUsageFetcher.fetch(session: session)
        }
        if descriptor.id.rawValue == "openai", !resolvedSecret.isEmpty {
            let environment = ProcessInfo.processInfo.environment
            let projectID = [
                configuration.account,
                environment["OPENAI_PROJECT_ID"] ?? "",
            ].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let usesAdminKey = !secret.isEmpty || !(environment["OPENAI_ADMIN_KEY"] ?? "").isEmpty
            return try await OpenAIAPIUsageFetcher.fetch(
                apiKey: resolvedSecret,
                projectID: projectID,
                usesAdminKey: usesAdminKey,
                session: session
            )
        }
        if descriptor.id.rawValue == "azureopenai" {
            let environment = ProcessInfo.processInfo.environment
            let endpoint = [
                configuration.endpoint,
                environment["AZURE_OPENAI_ENDPOINT"] ?? "",
            ].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let deployment = [
                configuration.account,
                environment["AZURE_OPENAI_DEPLOYMENT_NAME"] ?? "",
            ].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            return try await AzureOpenAIUsageFetcher.fetch(
                apiKey: resolvedSecret,
                endpoint: endpoint,
                deploymentName: deployment,
                apiVersion: environment["AZURE_OPENAI_API_VERSION"],
                session: session
            )
        }
        if descriptor.id.rawValue == "cursor" {
            return try await CursorUsageFetcher.fetch(
                credential: resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "opencode" {
            return try await OpenCodeUsageFetcher.fetch(
                cookie: resolvedSecret,
                workspaceID: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "opencodego" {
            return try await OpenCodeGoUsageFetcher.fetch(
                credential: resolvedSecret,
                workspaceID: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "alibaba" {
            return try await AlibabaCodingPlanFetcher.fetch(
                credential: resolvedSecret,
                region: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "alibabatokenplan" {
            return try await AlibabaTokenPlanFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                region: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "factory" {
            return try await FactoryUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "qwencloud" {
            return try await QwenCloudUsageFetcher.fetch(
                credential: resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "gemini" {
            return try await GeminiUsageFetcher.fetch(session: session)
        }
        if descriptor.id.rawValue == "antigravity" {
            return try await AntigravityUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "fireworks" {
            guard let apiKey = FireworksUsageFetcher.resolvedAPIKey(configured: resolvedSecret) else {
                throw FireworksUsageError.missingCredentials
            }
            let snapshot = try await FireworksUsageFetcher.fetch(
                apiKey: apiKey,
                accountSlug: FireworksUsageFetcher.resolvedAccountSlug(
                    configured: configuration.account
                ),
                session: session
            )
            if snapshot.accountSlugWasDiscovered {
                await FireworksUsageFetcher.persistDiscoveredAccountSlug(snapshot.accountSlug)
            }
            return snapshot.toProviderUsage()
        }
        if descriptor.id.rawValue == "copilot" {
            return try await CopilotUsageFetcher.fetch(
                token: resolvedSecret,
                enterpriseHost: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "devin" {
            return try await DevinUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                organization: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "zai" {
            return try await ZaiUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                region: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "minimax" {
            return try await MiniMaxUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                region: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "manus" {
            return try await ManusUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "kimi" {
            return try await KimiUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "kilo" {
            return try await KiloUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                organization: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "augment" {
            return try await AugmentUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "jetbrains" {
            return try JetBrainsUsageFetcher.fetch(
                configuredPath: configuration.account.isEmpty ? nil : configuration.account
            )
        }
        if descriptor.id.rawValue == "moonshot" {
            return try await MoonshotUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                region: configuration.account.isEmpty ? nil : configuration.account,
                apiKeyRegion: MoonshotUsageFetcher.storedAPIKeyRegion(
                    configuration.endpoint,
                    hasLegacyStoredKey: !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ),
                session: session
            )
        }
        if descriptor.id.rawValue == "t3chat" {
            return try await T3ChatUsageFetcher.fetch(
                cookieHeaderOverride: configuration.source == .cookie ? resolvedSecret : nil,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "amp" {
            return try await AmpUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "ollama" {
            return try await OllamaUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "synthetic" {
            return try await SyntheticUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "zed" {
            return try await ZedUsageFetcher.fetch(session: session)
        }
        if descriptor.id.rawValue == "openrouter" {
            let managementAPIKey = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "management-api-key")
            }
            return try await OpenRouterUsageFetcher.fetch(
                apiKey: resolvedSecret,
                endpoint: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                managementAPIKey: managementAPIKey.isEmpty ? nil : managementAPIKey,
                session: session
            )
        }
        if descriptor.id.rawValue == "elevenlabs" {
            return try await ElevenLabsUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "warp" {
            return try await WarpUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "perplexity" {
            return try await PerplexityUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session
            )
        }
        if descriptor.id.rawValue == "mimo" {
            return try await MiMoUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "doubao" {
            let secretAccessKey = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "secret-access-key")
            }
            return try await DoubaoUsageFetcher.fetch(
                credential: resolvedSecret,
                secretAccessKey: secretAccessKey.isEmpty ? nil : secretAccessKey,
                region: configuration.account.isEmpty ? nil : configuration.account,
                source: configuration.source,
                configuredCommand: configuration.command.isEmpty ? nil : configuration.command,
                session: session
            )
        }
        if descriptor.id.rawValue == "sakana" {
            return try await SakanaUsageFetcher.fetch(
                cookie: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "abacus" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await AbacusUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "deepinfra" {
            return try await DeepInfraUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "crof" {
            return try await CrofUsageFetcher.fetch(
                apiKey: secret.isEmpty ? nil : secret,
                session: session
            )
        }
        if descriptor.id.rawValue == "venice" {
            return try await VeniceUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "deepgram" {
            return try await DeepgramUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                projectID: configuration.account.isEmpty ? nil : configuration.account,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "poe" {
            return try await PoeUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "commandcode" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await CommandCodeUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "mistral" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await MistralUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "qoder" {
            let cached = await MainActor.run {
                let preferences = ProviderPreferences.shared
                return (
                    cookie: preferences.auxiliarySecret(for: descriptor.id, key: "imported-cookie"),
                    site: preferences.auxiliarySecret(for: descriptor.id, key: "imported-site")
                )
            }
            return try await QoderUsageFetcher.fetch(
                credential: resolvedSecret,
                source: configuration.source,
                session: session,
                cachedCookieHeader: cached.cookie.isEmpty ? nil : cached.cookie,
                cachedSite: QoderWebSite(cacheKey: cached.site),
                cacheUpdate: { cookie, site in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            cookie ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            site?.cacheKey ?? "",
                            for: descriptor.id,
                            key: "imported-site"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "deepseek" {
            return try await DeepSeekUsageFetcher.fetch(
                source: configuration.source,
                apiKey: configuration.source == .cookie
                    ? nil
                    : (resolvedSecret.isEmpty ? nil : resolvedSecret),
                platformToken: configuration.source == .cookie
                    ? (resolvedSecret.isEmpty ? nil : resolvedSecret)
                    : nil,
                selectedProfileID: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "chutes" {
            return try await ChutesUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "neuralwatt" {
            return try await NeuralWattUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "clawrouter" {
            return try await ClawRouterUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                endpointOverride: configuration.endpoint.isEmpty ? nil : configuration.endpoint,
                session: session
            )
        }
        if descriptor.id.rawValue == "xai" {
            return try await XAIUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                teamID: configuration.account.isEmpty ? nil : configuration.account,
                session: session
            )
        }
        if descriptor.id.rawValue == "aiand" {
            return try await AiAndUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "zenmux" {
            return try await ZenMuxUsageFetcher.fetch(
                managementKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "ibmbob" {
            return try await IBMBobUsageFetcher.fetch(
                apiKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                session: session
            )
        }
        if descriptor.id.rawValue == "grok" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await GrokUsageFetcher.fetch(
                source: configuration.source,
                credential: resolvedSecret.isEmpty ? nil : resolvedSecret,
                cachedCookie: cachedCookie.isEmpty ? nil : cachedCookie,
                allowBrowserImport: allowBrowserCookieImport,
                session: session,
                environment: ProcessInfo.processInfo.environment,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if descriptor.id.rawValue == "groq" {
            let cachedCookie = await MainActor.run {
                ProviderPreferences.shared.auxiliarySecret(for: descriptor.id, key: "imported-cookie")
            }
            return try await GroqUsageFetcher.fetch(
                configuredAPIKey: resolvedSecret.isEmpty ? nil : resolvedSecret,
                source: configuration.source,
                session: session,
                cachedCookieHeader: cachedCookie.isEmpty ? nil : cachedCookie,
                allowBrowserImport: allowBrowserCookieImport,
                cacheUpdate: { value in
                    await MainActor.run {
                        try? ProviderPreferences.shared.setAuxiliarySecret(
                            value ?? "",
                            for: descriptor.id,
                            key: "imported-cookie"
                        )
                    }
                }
            )
        }
        if let recipe = ProviderRecipes.recipe(for: descriptor.id), !resolvedSecret.isEmpty {
            return try await remoteUsage(descriptor: descriptor, recipe: recipe, secret: resolvedSecret)
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

    private func claudeUsage(
        descriptor: ProviderDescriptor,
        configuration: ProviderConfiguration,
        secret: String
    ) async throws -> ProviderUsage {
        let environment = ProcessInfo.processInfo.environment
        let configured = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentCredential = environmentSecret(for: descriptor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localCredential(for: descriptor.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oauthCredential = [configured, local].first { value in
            value.lowercased().hasPrefix("sk-ant-oat")
        }
        let tokenCredential = [configured, environmentCredential, local]
            .first { !$0.isEmpty }
        let webCredential = !configured.isEmpty
            && !configured.lowercased().hasPrefix("sk-ant-") ? configured : nil
        let configuredBinary = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCLI = ClaudeCLIUsageFetcher.resolveBinary(
            configuredBinary: configuredBinary.isEmpty ? nil : configuredBinary,
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) != nil

        let sources: [ClaudeUsageDataSource]
        switch configuration.source {
        case .automatic:
            sources = ClaudeUsageSourcePlanner.automaticAppOrder(
                hasOAuthCredentials: oauthCredential != nil,
                hasCLI: hasCLI,
                hasWebSession: webCredential != nil
            )
        case .account:
            sources = ClaudeUsageSourcePlanner.explicitOAuthAppOrder(hasCLI: hasCLI)
        case .token:
            guard let source = ClaudeUsageSourcePlanner.explicitSource(
                for: configuration.source,
                credential: tokenCredential ?? ""
            ) else {
                throw UsageCollectionError.missingCredential
            }
            sources = [source]
        case .cookie, .command:
            guard let source = ClaudeUsageSourcePlanner.explicitSource(
                for: configuration.source,
                credential: configured
            ) else {
                throw UsageCollectionError.missingCredential
            }
            sources = [source]
        case .endpoint:
            throw UsageCollectionError.missingEndpoint
        }

        guard !sources.isEmpty else { throw UsageCollectionError.missingCredential }
        var lastError: Error?
        for source in sources {
            do {
                switch source {
                case .oauthAPI:
                    let credential = configuration.source == .token
                        ? tokenCredential
                        : oauthCredential
                    guard let credential else { throw UsageCollectionError.missingCredential }
                    guard let recipe = ProviderRecipes.recipe(for: descriptor.id) else {
                        throw UsageCollectionError.missingEndpoint
                    }
                    return try await remoteUsage(
                        descriptor: descriptor,
                        recipe: recipe,
                        secret: credential
                    )
                case .adminAPI:
                    let credential = [configured, environmentCredential]
                        .first { $0.lowercased().hasPrefix("sk-ant-admin") }
                    guard let credential else { throw UsageCollectionError.missingCredential }
                    return try await ClaudeAdminAPIUsageFetcher.fetch(apiKey: credential, session: session)
                case .webAPI:
                    guard let webCredential else { throw UsageCollectionError.missingCredential }
                    return try await ClaudeWebUsageFetcher.fetch(
                        cookie: webCredential,
                        organizationID: configuration.account,
                        descriptor: descriptor,
                        session: session
                    )
                case .cli:
                    return try await ClaudeCLIUsageFetcher.fetch(
                        configuredBinary: configuredBinary.isEmpty ? nil : configuredBinary,
                        environment: environment
                    )
                case .automatic:
                    throw UsageCollectionError.missingCredential
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UsageCollectionError.missingCredential
    }

    private func environmentSecret(for descriptor: ProviderDescriptor) -> String {
        let environment = ProcessInfo.processInfo.environment
        for key in descriptor.environmentKeys {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return ""
    }

    private func localCredential(for id: ProviderID) -> String {
        if id.rawValue == "cursor", let token = cursorAppAccessToken() {
            return token
        }
        if id.rawValue == "opencodego", let key = openCodeGoLocalAPIKey() {
            return key
        }
        let keys = ["access_token", "accessToken", "oauth_token", "token", "api_key", "apiKey"]
        for url in localCandidates(for: id) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let value = Self.findString(in: object, keys: Set(keys)) else { continue }
            return value
        }
        if id.rawValue == "claude", let data = claudeKeychainCredentialData(),
           let object = try? JSONSerialization.jsonObject(with: data),
           let value = Self.findString(
               in: object,
               keys: ["access_token", "accessToken", "oauth_token", "token"]
           ) {
            return value
        }
        return ""
    }

    private func openCodeGoLocalAPIKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        let normalized = OpenCodeGoUsageFetcher.normalizeAPIKey(key)
        return normalized.isEmpty ? nil : normalized
    }

    private func cursorAppAccessToken() -> String? {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")
        else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            database.path,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil
        } catch {
            return nil
        }
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

    private func addingLocalMetadata(
        to usage: ProviderUsage,
        descriptor: ProviderDescriptor,
        pricingCatalog: ModelPricingCatalog?,
        allowVertexClaudeFallback: Bool
    ) async -> ProviderUsage {
        var enriched = usage
        if enriched.plan == nil {
            enriched.plan = localPlan(for: descriptor)
        }
        let weeklyWindow = Self.weeklyWindow(in: enriched, descriptor: descriptor)
        let now = Date()
        let weeklyReset = weeklyWindow?.resetsAt.flatMap { $0 > now ? $0 : nil }
        let weekStart = weeklyReset
            .map { $0.addingTimeInterval(-7 * 24 * 60 * 60) }
            ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let localUsage = await localUsageScanner.scan(
            providerID: descriptor.id,
            currentWeekStart: weekStart,
            now: now,
            pricingCatalog: pricingCatalog,
            allowVertexClaudeFallback: allowVertexClaudeFallback
        )
        enriched.today = localUsage?.today
        enriched.todayDate = localUsage?.today == nil ? nil : now
        enriched.last30Days = localUsage?.last30Days
        enriched.last30DaysDaily = localUsage?.last30DaysDaily ?? []
        if descriptor.id.rawValue == "claude",
           let localWeeklyUsage = localUsage?.currentWeek,
           let localWeeklyCost = localWeeklyUsage.valueUSD,
           let weeklyReset,
           let usedFraction = weeklyWindow?.clampedFraction,
           usedFraction >= 0.01,
           usedFraction <= 1 {
            let estimatedAmountUSD = claudeWeeklyAmountEstimator.estimate(
                currentCostUSD: localWeeklyCost,
                usedFraction: usedFraction,
                resetAt: weeklyReset,
                plan: enriched.plan
            )
            enriched.weeklyEstimate = DailyTokenUsage(
                tokens: estimatedTokens(
                    localTokens: localWeeklyUsage.tokens,
                    usedFraction: usedFraction
                ),
                valueUSD: estimatedAmountUSD
            )
            persistClaudeWeeklyAmountEstimator()
        } else {
            enriched.weeklyEstimate = weeklyEstimate(
                localUsage: localUsage?.currentWeek,
                usedFraction: weeklyReset == nil ? nil : weeklyWindow?.clampedFraction
            )
        }
        return enriched
    }

    nonisolated static func weeklyWindow(
        in usage: ProviderUsage,
        descriptor: ProviderDescriptor
    ) -> UsageWindow? {
        if descriptor.id.rawValue == "claude",
           let weekly = usage.windows.first(where: {
               $0.id == "claude-weekly" || $0.id == "claude-seven_day"
           }) {
            return weekly
        }
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
            tokens: estimatedTokens(localTokens: localUsage.tokens, usedFraction: usedFraction),
            valueUSD: localUsage.valueUSD.map { $0 / usedFraction }
        )
    }

    private func estimatedTokens(localTokens: Int64, usedFraction: Double) -> Int64 {
        Int64((Double(localTokens) / usedFraction).rounded())
    }

    private func persistClaudeWeeklyAmountEstimator() {
        guard let data = try? JSONEncoder().encode(claudeWeeklyAmountEstimator) else { return }
        UserDefaults.standard.set(data, forKey: Self.claudeWeeklyAmountEstimatorKey)
    }

    private func resolvedPricingCatalog() async -> ModelPricingCatalog? {
        let now = Date()
        if now < pricingCatalogReloadAt { return pricingCatalog }
        if let pricingCatalogLoadTask {
            return await pricingCatalogLoadTask.value.catalog
        }

        let task = Task { [session] in
            await ModelPricingCatalog.load(session: session, now: now)
        }
        pricingCatalogLoadTask = task
        let result = await task.value
        pricingCatalog = result.catalog
        pricingCatalogLoadTask = nil
        pricingCatalogReloadAt = result.reloadAt
        return pricingCatalog
    }

    private func localPlan(for descriptor: ProviderDescriptor) -> String? {
        switch descriptor.id.rawValue {
        case "codex":
            let url = codexHomeDirectory().appending(path: "auth.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Self.codexPlan(fromAuthData: data, descriptor: descriptor)
        case "claude":
            return localClaudePlan(descriptor: descriptor)
        default:
            return nil
        }
    }

    private func localClaudePlan(descriptor: ProviderDescriptor) -> String? {
        let account = claudeProfileURLs().lazy.compactMap { profileURL -> [String: Any]? in
            guard let data = try? Data(contentsOf: profileURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return root["oauthAccount"] as? [String: Any]
        }.first
        if let account {
            let rateLimitTier = Self.findString(
                in: account,
                keys: ["organizationRateLimitTier", "rateLimitTier", "rate_limit_tier"]
            )
            let billingType = Self.findString(in: account, keys: ["billingType", "billing_type"])
            let seatTier = Self.findString(in: account, keys: ["seatTier", "seat_tier"])
            if let plan = UsageParser.displayClaudeWebPlan(
                rateLimitTier: rateLimitTier,
                billingType: billingType,
                seatTier: seatTier
            ) {
                return plan
            }
        }

        var credentialData = localCandidates(for: descriptor.id).compactMap { try? Data(contentsOf: $0) }
        if let keychainData = claudeKeychainCredentialData() {
            credentialData.append(keychainData)
        }
        for data in credentialData {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            let rateLimitTier = Self.findString(
                in: root,
                keys: ["rateLimitTier", "rate_limit_tier", "organizationRateLimitTier"]
            )
            let subscriptionType = Self.findString(
                in: root,
                keys: ["subscriptionType", "subscription_type"]
            )
            if let plan = UsageParser.displayClaudeOAuthPlan(
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            ) {
                return plan
            }
        }
        return nil
    }

    nonisolated static func codexPlan(
        fromAuthData data: Data,
        descriptor: ProviderDescriptor
    ) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = root["tokens"] as? [String: Any]
        let idToken = (tokens?["id_token"] as? String)
            ?? (tokens?["idToken"] as? String)
            ?? (root["id_token"] as? String)
            ?? (root["idToken"] as? String)
        let payload = idToken.flatMap(Self.decodeJWTPayload)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let tokenPlan = (auth?["chatgpt_plan_type"] as? String)
            ?? (payload?["chatgpt_plan_type"] as? String)
        return tokenPlan.flatMap {
            UsageParser.displayPlan($0, descriptor: descriptor)
        }
    }

    private nonisolated static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private nonisolated static func findString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key), let string = child as? String, !string.isEmpty { return string }
            }
            for child in dictionary.values {
                if let result = Self.findString(in: child, keys: keys) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = Self.findString(in: child, keys: keys) { return result }
            }
        }
        return nil
    }

    private func localCandidates(for id: ProviderID) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch id.rawValue {
        case "codex":
            return [codexHomeDirectory().appending(path: "auth.json")]
        case "claude":
            let environment = ProcessInfo.processInfo.environment
            if let secureRoot = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
                let root = secureRoot.isEmpty ? claudeConfigDirectory() : directoryURL(secureRoot)
                return [root.appending(path: ".credentials.json")]
            }
            return [
                claudeConfigDirectory().appending(path: ".credentials.json"),
                home.appending(path: ".config/claude/credentials.json"),
            ]
        case "gemini":
            return [
                home.appending(path: ".gemini/oauth_creds.json"),
                home.appending(path: ".gemini/google_accounts.json"),
            ]
        case "opencodego":
            return [home.appending(path: ".local/share/opencode/auth.json")]
        default:
            return []
        }
    }

    private func codexHomeDirectory() -> URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    private func claudeConfigDirectory() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return directoryURL(configured)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude", directoryHint: .isDirectory)
    }

    private func claudeProfileURLs() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            let root = directoryURL(configured)
            return [root.appending(path: ".config.json"), root.appending(path: ".claude.json")]
        }
        return [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")]
    }

    private func directoryURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: path, directoryHint: .isDirectory)
            .standardizedFileURL
    }

}
