import CodexBarCore
import Foundation

enum ProviderUsageClient {
    private nonisolated static let browserDetection = BrowserDetection()

    nonisolated static func fetch(
        _ definition: ProviderDefinition,
        configuration: ProviderConfig?,
        allConfigurations: [ProviderConfig]) async -> ProviderUsage
    {
        guard let provider = CodexBarCore.UsageProvider(rawValue: definition.id) else {
            return .unavailable(definition, issue: "不支持的 Provider")
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let environment = ProviderEnvironmentResolver.resolve(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            config: configuration,
            selectedAccount: nil)
        let settings = settingsSnapshot(configurations: allConfigurations)
        let fetcher = UsageFetcher(environment: environment)
        let claudeFetcher = ClaudeUsageFetcher(
            browserDetection: browserDetection,
            environment: environment,
            runtime: .app,
            oauthSafeCredentialSourcesOnly: true,
            allowBackgroundDelegatedRefresh: false)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: configuration?.source ?? .auto,
            includeCredits: true,
            includeOptionalUsage: true,
            requiresOptionalUsageCompleteness: false,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            costUsageHistoryDays: 30,
            persistsCLISessions: true,
            persistentCLISessionIdleWindow: 360)

        do {
            let result = try await descriptor.fetch(context: context)
            return map(result: result, definition: definition)
        } catch is CancellationError {
            return .unavailable(definition, issue: "刷新已取消")
        } catch {
            return .unavailable(definition, issue: error.localizedDescription)
        }
    }

    private nonisolated static func settingsSnapshot(
        configurations: [ProviderConfig]) -> ProviderSettingsSnapshot
    {
        var builder = ProviderSettingsSnapshotBuilder()
        for descriptor in ProviderDescriptorRegistry.all {
            if let contribution = descriptor.settingsSection.defaultContribution {
                builder.apply(contribution)
            }
            let configuration = configurations.first(where: { $0.id.rawValue == descriptor.id.rawValue })
            if let contribution = descriptor.settingsSection.credentialContribution(
                context: ProviderCredentialSettingsContext(config: configuration, account: nil))
            {
                builder.apply(contribution)
            }
        }
        return builder.build()
    }

    private nonisolated static func map(
        result: ProviderFetchResult,
        definition: ProviderDefinition) -> ProviderUsage
    {
        let snapshot = result.usage
        var windows: [UsageWindow] = []
        if let primary = snapshot.primary, !primary.isSyntheticPlaceholder {
            windows.append(window(primary, id: "primary", title: definition.sessionLabel))
        }
        if let secondary = snapshot.secondary, !secondary.isSyntheticPlaceholder {
            windows.append(window(secondary, id: "secondary", title: definition.weeklyLabel))
        }
        if let tertiary = snapshot.tertiary, !tertiary.isSyntheticPlaceholder {
            windows.append(window(tertiary, id: "tertiary", title: definition.tertiaryLabel))
        }
        for named in snapshot.extraRateWindows ?? [] where named.usageKnown {
            windows.append(window(named.window, id: named.id, title: named.title))
        }

        if windows.isEmpty,
           let cost = snapshot.providerCost,
           cost.limit > 0
        {
            windows.append(UsageWindow(
                id: "cost",
                title: cost.period ?? "当前周期",
                usedPercent: cost.used / cost.limit * 100,
                resetsAt: cost.resetsAt,
                resetDescription: nil))
        }

        let balanceText: String?
        if let balance = snapshot.providerCost?.balance {
            balanceText = formattedBalance(balance, code: snapshot.providerCost?.currencyCode)
        } else if let credits = result.credits {
            balanceText = "余额 \(String(format: "%.2f", credits.remaining))"
        } else {
            balanceText = nil
        }

        return ProviderUsage(
            id: definition.id,
            definition: definition,
            windows: windows,
            balanceText: balanceText,
            updatedAt: snapshot.updatedAt,
            issue: result.diagnostic)
    }

    private nonisolated static func window(
        _ value: RateWindow,
        id: String,
        title: String) -> UsageWindow
    {
        UsageWindow(
            id: id,
            title: title,
            usedPercent: value.usedPercent,
            resetsAt: value.resetsAt,
            resetDescription: value.resetDescription)
    }

    private nonisolated static func formattedBalance(_ value: Double, code: String?) -> String {
        let amount = String(format: "%.2f", value)
        guard let code, !code.isEmpty else { return "余额 \(amount)" }
        return "余额 \(amount) \(code)"
    }
}
