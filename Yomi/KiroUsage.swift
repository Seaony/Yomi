import Darwin
import Foundation
import SQLite3

nonisolated enum KiroUsageError: LocalizedError, Equatable {
    case cliNotFound
    case notLoggedIn
    case cliFailed(String)
    case timedOut
    case parseFailed(String)
    case credentialsUnavailable(String)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            AppLocalization.text(
                "未找到 kiro-cli，请先安装并登录 Kiro",
                "kiro-cli was not found. Install it and sign in to Kiro first."
            )
        case .notLoggedIn:
            AppLocalization.text(
                "尚未登录 Kiro，请先运行 kiro-cli login",
                "Kiro is not signed in. Run kiro-cli login first."
            )
        case let .cliFailed(message):
            AppLocalization.text("Kiro 命令执行失败：\(message)", "Kiro command failed: \(message)")
        case .timedOut:
            AppLocalization.text("Kiro 命令执行超时", "Kiro command timed out")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Kiro 用量：\(message)", "Failed to parse Kiro usage: \(message)")
        case let .credentialsUnavailable(message):
            AppLocalization.text(
                "无法读取 Kiro 本机登录信息：\(message)",
                "Kiro local credentials are unavailable: \(message)"
            )
        case let .requestFailed(status):
            AppLocalization.text("Kiro 用量接口错误（HTTP \(status)）", "Kiro usage API error (HTTP \(status))")
        }
    }
}

nonisolated struct KiroUsageLimits: Sendable, Equatable {
    let planLimit: Double
    let planUsed: Double
    let overageUsed: Double
    let overageCap: Double?
    let overageEnabled: Bool?
    let overageCharges: Double?
    let overageRate: Double?
    let currencyCode: String
    let resetsAt: Date
    let hasUnseparatedBonus: Bool

    var overageChargeLimit: Double? {
        guard let overageCap, let overageRate, overageCap > 0, overageRate > 0 else { return nil }
        return overageCap * overageRate
    }
}

nonisolated struct KiroContextUsage: Sendable, Equatable {
    let totalPercentUsed: Double
    let contextFilesPercent: Double?
    let toolsPercent: Double?
    let kiroResponsesPercent: Double?
    let promptsPercent: Double?
}

nonisolated struct KiroCLIUsage: Sendable, Equatable {
    let planName: String
    let accountEmail: String?
    let authMethod: String?
    let creditsUsed: Double
    let creditsTotal: Double
    let creditsPercent: Double
    let bonusCreditsUsed: Double?
    let bonusCreditsTotal: Double?
    let bonusExpiryDays: Int?
    let overagesStatus: String?
    let overageCreditsUsed: Double?
    let estimatedOverageCostUSD: Double?
    let manageURL: String?
    let contextUsage: KiroContextUsage?
    let resetsAt: Date?

    var displayPlanName: String { KiroUsageFetcher.displayPlanName(planName) }
}

nonisolated enum KiroUsageFetcher {
    static let usageLimitsEndpoint = URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!
    private static let target = "AmazonCodeWhispererService.GetUsageLimits"
    private static let contentType = "application/x-amz-json-1.0"
    private static let resetRange: ClosedRange<Double> = 1_000_000_000...4_102_444_800

    private struct Account: Sendable, Equatable {
        let authMethod: String?
        let email: String?
    }

    private struct CommandResult: Sendable {
        let output: String
        let terminationStatus: Int32
        let stoppedAfterOutput: Bool
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func isCancelled() -> Bool { lock.withLock { cancelled } }
    }

    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var lastActivity: Date?

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                data.append(chunk)
                lastActivity = Date()
            }
        }

        func snapshot() -> (data: Data, lastActivity: Date?) {
            lock.withLock { (data, lastActivity) }
        }
    }

    private struct UsageLimitsResponse: Decodable {
        let usageBreakdownList: [UsageBreakdown]
        let overageConfiguration: OverageConfiguration?
        let nextDateReset: Double?
    }

    private struct UsageBreakdown: Decodable {
        let resourceType: String
        let currentUsageWithPrecision: Double
        let usageLimitWithPrecision: Double
        let currentOveragesWithPrecision: Double?
        let overageCapWithPrecision: Double?
        let overageCharges: Double?
        let overageRate: Double?
        let currency: String?
        let nextDateReset: Double?
        let bonuses: [BonusEntry]?

        struct BonusEntry: Decodable {}
    }

    private struct OverageConfiguration: Decodable {
        let overageStatus: String
    }

    static func fetch(
        configuredCommand: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let binary = resolveBinary(
            configuredCommand: configuredCommand,
            environment: environment,
            homeDirectory: homeDirectory
        ) else {
            throw KiroUsageError.cliNotFound
        }

        async let accountResult = fetchAccount(binary: binary, environment: environment)

        let usageOutput: String
        do {
            usageOutput = try await runAcceptedCommand(
                binary: binary,
                arguments: ["chat", "--no-interactive", "/usage"],
                timeout: 20,
                idleTimeout: 4,
                environment: environment,
                accepts: { output in (try? parseCLI(output, now: now)) != nil }
            )
        } catch {
            do {
                _ = try await accountResult
            } catch is CancellationError {
                throw CancellationError()
            } catch KiroUsageError.notLoggedIn {
                throw KiroUsageError.notLoggedIn
            } catch {}
            throw error
        }

        let account: Account?
        do {
            account = try await accountResult
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            account = nil
        }
        let context: KiroContextUsage?
        do {
            context = try await fetchContext(binary: binary, environment: environment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            context = nil
        }
        let report = try parseCLI(
            usageOutput,
            accountEmail: account?.email,
            authMethod: account?.authMethod,
            contextUsage: context,
            now: now
        )

        let databaseURL = stateDatabaseURL(
            homeDirectory: homeDirectory,
            environment: environment,
            usesMacOSApplicationSupport: true
        )
        let limits: KiroUsageLimits?
        do {
            limits = try await fetchUsageLimits(
                databaseURL: databaseURL,
                endpoint: usageLimitsEndpoint,
                session: session
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            limits = nil
        }
        if let limits {
            return providerUsage(report: report, limits: limits, now: now)
        }
        return providerUsage(report: report, limits: nil, now: now)
    }

    static func resolveBinary(
        configuredCommand: String?,
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let configured = cleaned(configuredCommand)
        let override = cleaned(environment["KIRO_CLI_PATH"])
        for candidate in [configured, override].compactMap(\.self) where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let path = cleaned(environment["PATH"]) ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("kiro-cli").path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }

        for candidate in [
            homeDirectory.appendingPathComponent(".local/bin/kiro-cli").path,
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
        ] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func stateDatabaseURL(
        homeDirectory: URL,
        environment: [String: String],
        usesMacOSApplicationSupport: Bool
    ) -> URL {
        if let override = cleaned(environment["KIRO_DATA_DIR"]) {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("data.sqlite3")
        }
        if usesMacOSApplicationSupport {
            return homeDirectory
                .appendingPathComponent("Library/Application Support/kiro-cli", isDirectory: true)
                .appendingPathComponent("data.sqlite3")
        }
        let root = cleaned(environment["XDG_DATA_HOME"]).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        return root.appendingPathComponent("kiro-cli", isDirectory: true)
            .appendingPathComponent("data.sqlite3")
    }

    static func parseCLI(
        _ output: String,
        accountEmail: String? = nil,
        authMethod: String? = nil,
        contextUsage: KiroContextUsage? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> KiroCLIUsage {
        let stripped = stripANSI(output)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KiroUsageError.parseFailed("empty output")
        }
        let lower = stripped.lowercased()
        if isLoginRequired(stripped) { throw KiroUsageError.notLoggedIn }
        if lower.contains("could not retrieve usage information") {
            throw KiroUsageError.parseFailed("the service did not return usage information")
        }

        let parsedPlan = parsePlanName(stripped)
        let managed = lower.contains("managed by admin") || lower.contains("managed by organization")
        let percent = firstCapture(in: stripped, pattern: #"█+\s*(\d+)%"#).flatMap(Double.init)

        var creditsUsed: Double?
        var creditsTotal: Double?
        if let covered = firstMatch(in: stripped, pattern: #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#),
           covered.numberOfRanges >= 3,
           let usedRange = Range(covered.range(at: 1), in: stripped),
           let totalRange = Range(covered.range(at: 2), in: stripped) {
            creditsUsed = Double(stripped[usedRange])
            creditsTotal = Double(stripped[totalRange])
        }

        if parsedPlan.matchedNewFormat, managed, percent == nil, creditsUsed == nil {
            return KiroCLIUsage(
                planName: parsedPlan.name,
                accountEmail: cleaned(accountEmail),
                authMethod: cleaned(authMethod),
                creditsUsed: 0,
                creditsTotal: 0,
                creditsPercent: 0,
                bonusCreditsUsed: parseBonus(stripped).used,
                bonusCreditsTotal: parseBonus(stripped).total,
                bonusExpiryDays: parseBonus(stripped).expiryDays,
                overagesStatus: overageStatus(stripped),
                overageCreditsUsed: overageCreditsUsed(stripped),
                estimatedOverageCostUSD: overageCost(stripped),
                manageURL: manageURL(stripped),
                contextUsage: contextUsage,
                resetsAt: nil
            )
        }

        guard percent != nil || creditsUsed != nil else {
            throw KiroUsageError.parseFailed("no recognizable usage patterns")
        }
        let used = creditsUsed ?? 0
        let total = creditsTotal ?? 50
        let computedPercent = percent ?? (total > 0 ? used / total * 100 : 0)
        let bonus = parseBonus(stripped)
        return KiroCLIUsage(
            planName: parsedPlan.name,
            accountEmail: cleaned(accountEmail),
            authMethod: cleaned(authMethod),
            creditsUsed: used,
            creditsTotal: total,
            creditsPercent: computedPercent,
            bonusCreditsUsed: bonus.used,
            bonusCreditsTotal: bonus.total,
            bonusExpiryDays: bonus.expiryDays,
            overagesStatus: overageStatus(stripped),
            overageCreditsUsed: overageCreditsUsed(stripped),
            estimatedOverageCostUSD: overageCost(stripped),
            manageURL: manageURL(stripped),
            contextUsage: contextUsage,
            resetsAt: parseResetDate(in: stripped, now: now, calendar: calendar)
        )
    }

    static func parseContext(_ output: String) -> KiroContextUsage? {
        let stripped = stripANSI(output)
        guard let total = firstCapture(
            in: stripped,
            pattern: #"(?i)Context window:\s*(\d+\.?\d*)%\s+used"#
        ).flatMap(Double.init) else { return nil }
        return KiroContextUsage(
            totalPercentUsed: total,
            contextFilesPercent: percent(after: "Context files", in: stripped),
            toolsPercent: percent(after: "Tools", in: stripped),
            kiroResponsesPercent: percent(after: "Kiro responses", in: stripped),
            promptsPercent: percent(after: "Your prompts", in: stripped)
        )
    }

    static func parseUsageLimits(_ data: Data) throws -> KiroUsageLimits {
        let response: UsageLimitsResponse
        do {
            response = try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
        } catch {
            throw KiroUsageError.parseFailed(error.localizedDescription)
        }

        let credits = response.usageBreakdownList.filter { $0.resourceType == "CREDIT" }
        guard credits.count == 1, let credit = credits.first else {
            throw KiroUsageError.parseFailed(
                credits.isEmpty ? "no credit balance reported" : "several credit balances reported"
            )
        }

        let planLimit = try usableCredits(credit.usageLimitWithPrecision, field: "plan limit")
        let totalUsed = try usableCredits(credit.currentUsageWithPrecision, field: "usage")
        let overageUsed = try usableCredits(credit.currentOveragesWithPrecision ?? 0, field: "overage usage")
        guard totalUsed >= overageUsed else {
            throw KiroUsageError.parseFailed("overage exceeds total usage")
        }
        let planUsed = totalUsed - overageUsed
        let hasBonus = !(credit.bonuses ?? []).isEmpty
        guard hasBonus || planUsed <= planLimit else {
            throw KiroUsageError.parseFailed("plan usage exceeds plan limit")
        }

        let availability: Bool?
        switch creditStatus(response.overageConfiguration?.overageStatus) {
        case "enabled": availability = true
        case "disabled": availability = false
        default: availability = nil
        }
        let overageCap: Double? = if availability == true, let cap = credit.overageCapWithPrecision {
            try usableCredits(cap, field: "overage cap")
        } else {
            nil
        }
        let overageEnabled = availability == true && overageCap == nil ? nil : availability
        guard let resetValue = credit.nextDateReset ?? response.nextDateReset,
              resetValue.isFinite,
              resetRange.contains(resetValue) else {
            throw KiroUsageError.parseFailed("no plausible reset date reported")
        }

        return KiroUsageLimits(
            planLimit: planLimit,
            planUsed: planUsed,
            overageUsed: overageUsed,
            overageCap: overageCap,
            overageEnabled: overageEnabled,
            overageCharges: credit.overageCharges.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            overageRate: credit.overageRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            currencyCode: credit.currency ?? "USD",
            resetsAt: Date(timeIntervalSince1970: resetValue),
            hasUnseparatedBonus: hasBonus
        )
    }

    static func makeUsageLimitsRequest(identity: (accessToken: String, profileARN: String), endpoint: URL) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["profileArn": identity.profileARN])
        return request
    }

    static func providerUsage(
        report: KiroCLIUsage,
        limits: KiroUsageLimits?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderUsage {
        let report = limits.map { applying(limits: $0, to: report) } ?? report
        let remaining = max(0, report.creditsTotal - report.creditsUsed)
        var windows = [UsageWindow(
            id: "kiro-credits",
            label: AppLocalization.text("额度", "Credits"),
            usedFraction: report.creditsPercent / 100,
            resetsAt: report.resetsAt,
            detail: AppLocalization.text(
                "剩余 \(formatCredits(remaining)) / \(formatCredits(report.creditsTotal)) 点额度",
                "\(formatCredits(remaining)) of \(formatCredits(report.creditsTotal)) credits left"
            )
        )]

        if let used = report.bonusCreditsUsed,
           let total = report.bonusCreditsTotal,
           total > 0 {
            let expiry = report.bonusExpiryDays.flatMap { calendar.date(byAdding: .day, value: $0, to: now) }
            windows.append(UsageWindow(
                id: "kiro-bonus",
                label: AppLocalization.text("奖励额度", "Bonus"),
                usedFraction: used / total,
                resetsAt: expiry,
                detail: AppLocalization.text(
                    "剩余 \(formatCredits(max(0, total - used))) / \(formatCredits(total)) 点奖励额度",
                    "\(formatCredits(max(0, total - used))) of \(formatCredits(total)) bonus credits left"
                )
            ))
        }

        var additional: [UsageWindow] = []
        if let limits, let cap = limits.overageCap, cap > 0 {
            additional.append(UsageWindow(
                id: "kiro-overage",
                label: AppLocalization.text("超额额度", "Overage"),
                usedFraction: min(1, limits.overageUsed / cap),
                resetsAt: limits.resetsAt,
                detail: AppLocalization.text(
                    "剩余 \(formatCredits(max(0, cap - limits.overageUsed))) / \(formatCredits(cap)) 点额度",
                    "\(formatCredits(max(0, cap - limits.overageUsed))) of \(formatCredits(cap)) credits left"
                )
            ))
        }

        var details = [
            UsageDetail(
                id: "kiro-used",
                label: AppLocalization.text("已用额度", "Credits used"),
                value: formatCredits(report.creditsUsed)
            ),
        ]
        let overagesEnabled: Bool
        if let limits, let enabled = limits.overageEnabled {
            overagesEnabled = enabled && limits.overageCap != nil
        } else {
            overagesEnabled = report.overagesStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("enabled") == true
        }
        if overagesEnabled, let used = report.overageCreditsUsed {
            let capSuffix = limits?.overageCap.map { " / \(formatCredits($0))" } ?? ""
            details.append(UsageDetail(
                id: "kiro-overage-used",
                label: AppLocalization.text("超额额度用量", "Overage usage"),
                value: "\(formatCredits(used))\(capSuffix)"
            ))
        }
        if overagesEnabled,
           let cap = limits?.overageCap,
           let used = report.overageCreditsUsed {
            details.append(UsageDetail(
                id: "kiro-overage-left",
                label: AppLocalization.text("剩余超额额度", "Overage credits left"),
                value: formatCredits(max(0, cap - used))
            ))
        }
        if overagesEnabled, let cost = report.estimatedOverageCostUSD {
            details.append(UsageDetail(
                id: "kiro-overage-cost",
                label: AppLocalization.text("超额费用", "Overage cost"),
                value: formatCurrency(cost, code: limits?.currencyCode ?? "USD")
            ))
        }
        let providerCost: ProviderCostSummary? = limits.flatMap { value in
            guard let charges = value.overageCharges, let limit = value.overageChargeLimit else { return nil }
            return ProviderCostSummary(
                used: charges,
                limit: limit,
                currencyCode: value.currencyCode,
                period: AppLocalization.text("超额用量", "Overage"),
                balance: nil
            )
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "kiro"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: AppLocalization.text(
                "\(formatCredits(remaining)) 点额度",
                "\(formatCredits(remaining)) credits"
            ),
            plan: report.displayPlanName,
            providerCost: providerCost,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    static func displayPlanName(_ raw: String) -> String {
        let cleaned = cleanInline(raw).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        guard cleaned.localizedCaseInsensitiveContains("KIRO") else { return cleaned.isEmpty ? raw : cleaned }
        return cleaned.split(separator: " ").map { word in
            if word.caseInsensitiveCompare("KIRO") == .orderedSame { return "Kiro" }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func applying(limits: KiroUsageLimits, to report: KiroCLIUsage) -> KiroCLIUsage {
        let keepCLIPlan = limits.hasUnseparatedBonus
        let estimatedCost = limits.overageCharges
            ?? (limits.currencyCode.uppercased() == "USD" ? report.estimatedOverageCostUSD : nil)
        return KiroCLIUsage(
            planName: report.planName,
            accountEmail: report.accountEmail,
            authMethod: report.authMethod,
            creditsUsed: keepCLIPlan ? report.creditsUsed : limits.planUsed,
            creditsTotal: keepCLIPlan ? report.creditsTotal : limits.planLimit,
            creditsPercent: keepCLIPlan || limits.planLimit <= 0
                ? report.creditsPercent
                : limits.planUsed / limits.planLimit * 100,
            bonusCreditsUsed: report.bonusCreditsUsed,
            bonusCreditsTotal: report.bonusCreditsTotal,
            bonusExpiryDays: report.bonusExpiryDays,
            overagesStatus: limits.overageEnabled == false
                ? "Disabled"
                : (limits.overageEnabled == true ? report.overagesStatus ?? "Enabled" : report.overagesStatus),
            overageCreditsUsed: limits.overageUsed,
            estimatedOverageCostUSD: estimatedCost,
            manageURL: report.manageURL,
            contextUsage: report.contextUsage,
            resetsAt: limits.resetsAt
        )
    }

    private static func fetchAccount(
        binary: String,
        environment: [String: String]
    ) async throws -> Account {
        let output = try await runAcceptedCommand(
            binary: binary,
            arguments: ["whoami"],
            timeout: 3,
            idleTimeout: 1.5,
            environment: environment,
            accepts: { value in
                isLoginRequired(value) || parseAccount(value).authMethod != nil || parseAccount(value).email != nil
            }
        )
        if isLoginRequired(output) { throw KiroUsageError.notLoggedIn }
        return parseAccount(output)
    }

    private static func fetchContext(binary: String, environment: [String: String]) async throws -> KiroContextUsage? {
        let output = try await runAcceptedCommand(
            binary: binary,
            arguments: ["chat", "--no-interactive", "/context"],
            timeout: 8,
            idleTimeout: 3,
            environment: environment,
            accepts: { parseContext($0) != nil || $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        return parseContext(output)
    }

    private static func fetchUsageLimits(
        databaseURL: URL,
        endpoint: URL,
        session: URLSession
    ) async throws -> KiroUsageLimits {
        let identity = try readIdentity(databaseURL: databaseURL)
        let request = try makeUsageLimitsRequest(
            identity: identity,
            endpoint: endpoint
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KiroUsageError.parseFailed("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else { throw KiroUsageError.requestFailed(http.statusCode) }
        return try parseUsageLimits(data)
    }

    static func readIdentity(databaseURL: URL) throws -> (accessToken: String, profileARN: String) {
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            throw KiroUsageError.credentialsUnavailable("state database is not readable")
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            throw KiroUsageError.credentialsUnavailable(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        let tokenJSON = try queryValue(
            database: database,
            sql: "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'",
            field: "token"
        )
        let profileJSON = try queryValue(
            database: database,
            sql: "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'",
            field: "profile"
        )
        guard let accessToken = jsonString(tokenJSON, key: "access_token") else {
            throw KiroUsageError.credentialsUnavailable("token has no access_token")
        }
        guard let profileARN = jsonString(profileJSON, key: "arn") else {
            throw KiroUsageError.credentialsUnavailable("profile has no arn")
        }
        return (accessToken, profileARN)
    }

    private static func queryValue(database: OpaquePointer?, sql: String, field: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw KiroUsageError.credentialsUnavailable("could not read \(field)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw KiroUsageError.credentialsUnavailable("\(field) was not found")
        }
        return String(cString: value)
    }

    private static func jsonString(_ json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else { return nil }
        return cleaned(value)
    }

    private static func runAcceptedCommand(
        binary: String,
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        environment: [String: String],
        accepts: @escaping @Sendable (String) -> Bool
    ) async throws -> String {
        let fallbackDelay = min(5, max(0.1, timeout / 2))
        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await runCommand(
                    binary: binary,
                    arguments: arguments,
                    timeout: timeout,
                    idleTimeout: idleTimeout,
                    environment: environment,
                    usePTY: false
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(fallbackDelay))
                return try await runCommand(
                    binary: binary,
                    arguments: arguments,
                    timeout: max(0.1, timeout - fallbackDelay),
                    idleTimeout: min(idleTimeout, max(0.1, timeout - fallbackDelay)),
                    environment: environment,
                    usePTY: true
                )
            }

            var firstError: Error?
            while !group.isEmpty {
                do {
                    guard let result = try await group.next() else { break }
                    if isLoginRequired(result.output) {
                        group.cancelAll()
                        return result.output
                    }
                    let completed = result.terminationStatus == 0 || result.stoppedAfterOutput
                    if completed, accepts(result.output) {
                        group.cancelAll()
                        return result.output
                    }
                    if result.terminationStatus != 0, !result.stoppedAfterOutput {
                        firstError = KiroUsageError.cliFailed(
                            cleanInline(result.output).isEmpty
                                ? "exit status \(result.terminationStatus)"
                                : cleanInline(result.output)
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    firstError = firstError ?? error
                }
            }
            throw firstError ?? KiroUsageError.timedOut
        }
    }

    private static func runCommand(
        binary: String,
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        environment: [String: String],
        usePTY: Bool
    ) async throws -> CommandResult {
        let cancellation = CancellationState()
        let task = Task.detached(priority: .utility) {
            try runCommandSync(
                binary: binary,
                arguments: arguments,
                timeout: timeout,
                idleTimeout: idleTimeout,
                environment: environment,
                usePTY: usePTY,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runCommandSync(
        binary: String,
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        environment: [String: String],
        usePTY: Bool,
        cancellation: CancellationState
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var processEnvironment = environment
        processEnvironment["TERM"] = "xterm-256color"
        process.environment = processEnvironment

        let capture = OutputCapture()
        let readHandle: FileHandle
        var writeHandles: [FileHandle] = []
        if usePTY {
            var master: Int32 = -1
            var slave: Int32 = -1
            var size = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else {
                throw KiroUsageError.cliFailed("could not create a terminal")
            }
            readHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            writeHandles = [slaveHandle]
        } else {
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            readHandle = stdout.fileHandleForReading
            writeHandles = [stdout.fileHandleForWriting, stderr.fileHandleForWriting]
            stderr.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
        }
        readHandle.readabilityHandler = { handle in capture.append(handle.availableData) }

        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            writeHandles.forEach { try? $0.close() }
        } catch {
            readHandle.readabilityHandler = nil
            try? readHandle.close()
            throw KiroUsageError.cliFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var stoppedAfterOutput = false
        while process.isRunning {
            if cancellation.isCancelled() {
                terminate(process)
                throw CancellationError()
            }
            let snapshot = capture.snapshot()
            if Date() >= deadline {
                terminate(process)
                if snapshot.data.isEmpty { throw KiroUsageError.timedOut }
                stoppedAfterOutput = true
                break
            }
            if let last = snapshot.lastActivity,
               !snapshot.data.isEmpty,
               Date().timeIntervalSince(last) >= idleTimeout {
                terminate(process)
                stoppedAfterOutput = true
                break
            }
            usleep(50_000)
        }

        process.waitUntilExit()
        usleep(20_000)
        readHandle.readabilityHandler = nil
        let data = capture.snapshot().data
        try? readHandle.close()
        return CommandResult(
            output: String(decoding: data, as: UTF8.self),
            terminationStatus: process.terminationStatus,
            stoppedAfterOutput: stoppedAfterOutput
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let group = getpgid(pid)
        if group == pid, group > 0, group != getpgrp() {
            _ = kill(-group, SIGTERM)
        } else {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            if group == pid, group > 0, group != getpgrp() {
                _ = kill(-group, SIGKILL)
            }
            _ = kill(pid, SIGKILL)
        }
    }

    private static func parseAccount(_ output: String) -> Account {
        var method: String?
        var email: String?
        for rawLine in stripANSI(output).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.localizedCaseInsensitiveContains("logged in with") {
                method = cleaned(line.replacingOccurrences(
                    of: #"(?i)^\s*logged in with\s+"#,
                    with: "",
                    options: .regularExpression
                ))
            } else if line.localizedCaseInsensitiveContains("email:") {
                email = cleaned(line.replacingOccurrences(
                    of: #"(?i)^\s*email:\s*"#,
                    with: "",
                    options: .regularExpression
                ))
            } else if email == nil, !line.contains(" "), line.contains("@") {
                email = line
            }
        }
        return Account(authMethod: method, email: email)
    }

    private static func parsePlanName(_ text: String) -> (name: String, matchedNewFormat: Bool) {
        var name = "Kiro"
        var newFormat = false
        if let match = firstCapture(in: text, pattern: #"\|[ \t]*(KIRO[ \t]+\w+)"#) {
            name = match
        }
        if let match = firstCapture(
            in: text,
            pattern: #"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)"#
        ) {
            name = match
        }
        if let match = firstCapture(in: text, pattern: #"Plan:[ \t]*(.+)"#) {
            name = match.components(separatedBy: .newlines).first.map(cleanInline) ?? match
            newFormat = true
        }
        return (name, newFormat)
    }

    private static func parseBonus(_ text: String) -> (used: Double?, total: Double?, expiryDays: Int?) {
        let match = firstMatch(in: text, pattern: #"Bonus credits:\s*(\d+\.?\d*)/(\d+)"#)
        let used = match.flatMap { capture($0, index: 1, in: text) }.flatMap(Double.init)
        let total = match.flatMap { capture($0, index: 2, in: text) }.flatMap(Double.init)
        let days = firstCapture(in: text, pattern: #"expires in (\d+) days?"#).flatMap(Int.init)
        return (used, total, days)
    }

    private static func overageStatus(_ text: String) -> String? {
        firstCapture(in: text, pattern: #"(?i)Overages:\s*([^\n]+)"#).map(cleanInline).flatMap(cleaned)
    }

    private static func overageCreditsUsed(_ text: String) -> Double? {
        firstCapture(in: text, pattern: #"(?i)Credits used:\s*(\d+\.?\d*)"#).flatMap(Double.init)
    }

    private static func overageCost(_ text: String) -> Double? {
        firstCapture(in: text, pattern: #"(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD"#).flatMap(Double.init)
    }

    private static func manageURL(_ text: String) -> String? {
        firstCapture(in: text, pattern: #"https://app\.kiro\.dev/account/usage"#)
    }

    private static func parseResetDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        guard let value = firstCapture(
            in: text,
            pattern: #"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#
        ) else { return nil }
        if value.contains("-") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: value)
        }
        let parts = value.split(separator: "/")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
        let year = calendar.component(.year, from: now)
        var components = DateComponents(year: year, month: month, day: day)
        if let date = calendar.date(from: components), date > now { return date }
        components.year = year + 1
        return calendar.date(from: components)
    }

    private static func isLoginRequired(_ text: String) -> Bool {
        let lower = stripANSI(text).lowercased()
        return lower.contains("not logged in")
            || lower.contains("login required")
            || lower.contains("failed to initialize auth portal")
            || lower.contains("kiro-cli login")
            || lower.contains("oauth error")
    }

    private static func percent(after label: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return firstCapture(in: text, pattern: #"(?i)"# + escaped + #"\s+(\d+\.?\d*)%"#)
            .flatMap(Double.init)
    }

    private static func usableCredits(_ value: Double, field: String) throws -> Double {
        guard value.isFinite, value >= 0 else { throw KiroUsageError.parseFailed("no usable \(field)") }
        return value
    }

    private static func creditStatus(_ value: String?) -> String? {
        cleaned(value)?.lowercased()
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func cleanInline(_ value: String) -> String {
        stripANSI(value)
            .replacingOccurrences(of: #"\x1B|\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let match = firstMatch(in: text, pattern: pattern) else { return nil }
        return capture(match, index: match.numberOfRanges > 1 ? 1 : 0, in: text).map(cleanInline)
    }

    private static func capture(_ match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func formatCurrency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(String(format: "%.2f", value))"
    }
}
