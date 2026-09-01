import CryptoKit
import Foundation

nonisolated struct DoubaoCodingPlanCredentials: Sendable, Equatable {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
}

nonisolated enum DoubaoUsageError: LocalizedError, Equatable {
    case missingCredentials
    case cliNotFound
    case cliAuthenticationRequired
    case cliTimedOut
    case cliOutputTooLarge
    case cliFailed(Int32, String)
    case parseFailed(String)
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("未找到豆包认证信息", "Doubao credentials were not found")
        case .cliNotFound:
            AppLocalization.text(
                "未找到 arkcli，请先安装并运行 arkcli auth login",
                "arkcli was not found. Install it and run arkcli auth login first."
            )
        case .cliAuthenticationRequired:
            AppLocalization.text(
                "arkcli 尚未登录，请先运行 arkcli auth login",
                "arkcli is not signed in. Run arkcli auth login first."
            )
        case .cliTimedOut:
            AppLocalization.text("arkcli 用量请求超时", "arkcli usage timed out")
        case .cliOutputTooLarge:
            AppLocalization.text("arkcli 返回的数据过大", "arkcli returned too much data")
        case let .cliFailed(code, message):
            AppLocalization.text(
                "arkcli 用量请求失败（\(code)）：\(message)",
                "arkcli usage failed (\(code)): \(message)"
            )
        case let .parseFailed(message):
            AppLocalization.text("无法解析豆包用量：\(message)", "Failed to parse Doubao usage: \(message)")
        case let .requestFailed(status, message):
            AppLocalization.text(
                "豆包用量接口错误（HTTP \(status)）：\(message)",
                "Doubao usage request failed (HTTP \(status)): \(message)"
            )
        }
    }
}

nonisolated struct DoubaoPlanUsage: Sendable, Equatable {
    struct Quota: Sendable, Equatable {
        let level: String
        let usedFraction: Double
        let resetsAt: Date?
    }

    let authenticationMethod: String?
    let updatedAt: Date?
    let quotas: [Quota]

    func providerUsage(now: Date) -> ProviderUsage {
        let primary = Self.windows(
            quotas: quotas,
            prefixes: [""],
            idPrefix: "doubao",
            includePlanPrefix: false
        )
        var additional: [UsageWindow] = []
        additional += Self.windows(
            quotas: quotas,
            prefixes: ["agent_"],
            idPrefix: "doubao-agent",
            includePlanPrefix: true
        )
        additional += Self.windows(
            quotas: quotas,
            prefixes: ["coding_team_"],
            idPrefix: "doubao-coding-team",
            includePlanPrefix: true
        )
        additional += Self.windows(
            quotas: quotas,
            prefixes: ["agent_team_"],
            idPrefix: "doubao-agent-team",
            includePlanPrefix: true
        )

        let hasCoding = !primary.isEmpty
        let hasAgent = quotas.contains { $0.level.lowercased().hasPrefix("agent_") }
        let hasTeam = quotas.contains { $0.level.lowercased().contains("_team_") }
        let plan: String? = switch (hasCoding, hasAgent, hasTeam) {
        case (true, true, _): AppLocalization.text("Coding Plan + Agent Plan", "Coding Plan + Agent Plan")
        case (true, false, true): AppLocalization.text("Coding Plan（团队版）", "Coding Plan (Team)")
        case (true, false, false): "Coding Plan"
        case (false, true, true): AppLocalization.text("Agent Plan（团队版）", "Agent Plan (Team)")
        case (false, true, false): "Agent Plan"
        case (false, false, true): AppLocalization.text("团队版计划", "Team Plan")
        case (false, false, false): nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "doubao"),
            state: .ready,
            windows: primary,
            additionalWindows: additional,
            balance: nil,
            plan: plan,
            details: [],
            updatedAt: updatedAt ?? now,
            message: nil
        )
    }

    private static func windows(
        quotas: [Quota],
        prefixes: [String],
        idPrefix: String,
        includePlanPrefix: Bool
    ) -> [UsageWindow] {
        let definitions: [(aliases: Set<String>, suffix: String, label: String)] = [
            (["session", "5-hour", "five_hour", "5h"], "5h", "5-hour"),
            (["weekly", "week"], "weekly", "Weekly"),
            (["monthly", "month"], "monthly", "Monthly"),
        ]
        return definitions.compactMap { definition in
            guard let quota = quotas.first(where: { quota in
                let level = quota.level.lowercased()
                return prefixes.contains { prefix in
                    definition.aliases.contains(String(level.dropFirst(prefix.count)))
                        && level.hasPrefix(prefix)
                }
            }) else { return nil }
            let detail: String? = if includePlanPrefix {
                switch idPrefix {
                case "doubao-agent": "Agent Plan"
                case "doubao-coding-team": AppLocalization.text("Coding Plan（团队版）", "Coding Plan (Team)")
                case "doubao-agent-team": AppLocalization.text("Agent Plan（团队版）", "Agent Plan (Team)")
                default: nil
                }
            } else {
                nil
            }
            return UsageWindow(
                id: "\(idPrefix)-\(definition.suffix)",
                label: definition.label,
                usedFraction: min(1, max(0, quota.usedFraction)),
                resetsAt: quota.resetsAt,
                detail: detail
            )
        }
    }
}

nonisolated enum DoubaoUsageFetcher {
    static let apiKeyEnvironmentKeys = ["ARK_API_KEY", "VOLCENGINE_API_KEY", "DOUBAO_API_KEY"]
    static let accessKeyIDEnvironmentKeys = [
        "VOLCENGINE_ACCESS_KEY_ID", "VOLCENGINE_ACCESS_KEY", "VOLC_ACCESSKEY", "DOUBAO_ACCESS_KEY_ID",
    ]
    static let secretAccessKeyEnvironmentKeys = [
        "VOLCENGINE_SECRET_ACCESS_KEY", "VOLCENGINE_SECRET_KEY", "VOLCENGINE_ACCESS_KEY_SECRET",
        "VOLC_SECRETKEY", "DOUBAO_SECRET_ACCESS_KEY",
    ]
    static let regionEnvironmentKeys = [
        "VOLCENGINE_REGION", "VOLCENGINE_REGION_ID", "VOLC_REGION", "DOUBAO_REGION",
    ]
    static let defaultRegion = "cn-beijing"

    private static let arkURL = URL(
        string: "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions"
    )!
    private static let codingPlanURL = URL(
        string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01"
    )!
    private static let agentPlanURL = URL(
        string: "https://open.volcengineapi.com/?Action=GetAFPUsage&Version=2024-01-01"
    )!
    private static let probeModels = [
        "doubao-seed-2.0-code", "doubao-1.5-pro-32k", "doubao-lite-32k",
    ]

    static func fetch(
        credential: String,
        secretAccessKey configuredSecretAccessKey: String? = nil,
        region configuredRegion: String? = nil,
        source: ProviderSource,
        configuredCommand: String? = nil,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let configured = clean(credential)
        let apiKey = configured.hasPrefix("AKLT")
            ? firstValue(environment, keys: apiKeyEnvironmentKeys)
            : (!configured.isEmpty ? configured : firstValue(environment, keys: apiKeyEnvironmentKeys))
        let accessKeyID = configured.hasPrefix("AKLT")
            ? configured
            : firstValue(environment, keys: accessKeyIDEnvironmentKeys)
        let secretAccessKey = clean(configuredSecretAccessKey ?? "").nilIfEmpty
            ?? firstValue(environment, keys: secretAccessKeyEnvironmentKeys)
        let region = clean(configuredRegion ?? "").nilIfEmpty
            ?? firstValue(environment, keys: regionEnvironmentKeys)
            ?? defaultRegion
        let signedCredentials = accessKeyID.flatMap { accessKeyID in
            secretAccessKey.map {
                DoubaoCodingPlanCredentials(accessKeyID: accessKeyID, secretAccessKey: $0, region: region)
            }
        }

        switch source {
        case .command, .account:
            return try await fetchCLI(
                configuredCommand: configuredCommand,
                environment: environment,
                now: now
            )
        case .token, .cookie, .endpoint:
            return try await fetchAPI(
                signedCredentials: signedCredentials,
                apiKey: apiKey,
                session: session,
                now: now
            )
        case .automatic:
            if signedCredentials != nil || apiKey != nil {
                return try await fetchAPI(
                    signedCredentials: signedCredentials,
                    apiKey: apiKey,
                    session: session,
                    now: now
                )
            }
            return try await fetchCLI(
                configuredCommand: configuredCommand,
                environment: environment,
                now: now
            )
        }
    }

    static func parseArkcli(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        struct Response: Decodable {
            struct Viewer: Decodable {
                let authMethod: String?
                enum CodingKeys: String, CodingKey { case authMethod = "auth_method" }
            }
            struct Item: Decodable {
                struct Period: Decodable {
                    let label: String
                    let percent: Double
                    let resetAt: ResetAt?
                    enum CodingKeys: String, CodingKey {
                        case label, percent
                        case resetAt = "reset_at"
                    }
                }
                let product: String
                let subscribed: Bool?
                let periods: [Period]?
                let updatedAt: TimeInterval?
                let error: String?
                enum CodingKeys: String, CodingKey {
                    case product, subscribed, periods, error
                    case updatedAt = "updated_at"
                }
            }
            let viewer: Viewer?
            let items: [Item]
        }

        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw DoubaoUsageError.parseFailed(error.localizedDescription)
        }
        let authentication = clean(response.viewer?.authMethod ?? "")
        if authentication.lowercased() == "none" { throw DoubaoUsageError.cliAuthenticationRequired }

        let supported = Set(["agent-plan", "coding-plan", "agent-plan-team", "coding-plan-team"])
        if let incomplete = response.items.first(where: {
            supported.contains($0.product.lowercased()) && $0.subscribed != false && $0.periods?.isEmpty != false
        }) {
            let message = clean(incomplete.error ?? "").nilIfEmpty
                ?? "\(incomplete.product.lowercased()) has no usage periods"
            throw DoubaoUsageError.parseFailed(message)
        }

        var quotas: [DoubaoPlanUsage.Quota] = []
        var updatedAt: Date?
        for item in response.items {
            let prefix: String? = switch item.product.lowercased() {
            case "agent-plan": "agent_"
            case "coding-plan": ""
            case "agent-plan-team": "agent_team_"
            case "coding-plan-team": "coding_team_"
            default: nil
            }
            guard let prefix, item.subscribed != false else { continue }
            let periods = item.periods ?? []
            if !periods.isEmpty, let timestamp = item.updatedAt, timestamp > 0 {
                let candidate = epochDate(timestamp)
                if updatedAt.map({ candidate > $0 }) ?? true { updatedAt = candidate }
            }
            quotas += periods.map {
                DoubaoPlanUsage.Quota(
                    level: prefix + $0.label,
                    usedFraction: min(100, max(0, $0.percent)) / 100,
                    resetsAt: $0.resetAt?.date
                )
            }
        }
        guard !quotas.isEmpty else {
            let error = response.items.lazy
                .filter { supported.contains($0.product.lowercased()) }
                .compactMap(\.error)
                .map(clean)
                .first { !$0.isEmpty }
            throw DoubaoUsageError.parseFailed(error ?? "No active Coding or Agent Plan usage")
        }
        return DoubaoPlanUsage(
            authenticationMethod: authentication.nilIfEmpty,
            updatedAt: updatedAt,
            quotas: quotas
        ).providerUsage(now: now)
    }

    static func parseCodingPlan(_ data: Data) throws -> DoubaoPlanUsage {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Quota: Decodable {
                    let level: String
                    let percent: Double
                    let resetTimestamp: TimeInterval?
                    enum CodingKeys: String, CodingKey {
                        case level = "Level"
                        case percent = "Percent"
                        case resetTimestamp = "ResetTimestamp"
                    }
                }
                let status: String?
                let updateTimestamp: TimeInterval?
                let quotaUsage: [Quota]
                enum CodingKeys: String, CodingKey {
                    case status = "Status"
                    case updateTimestamp = "UpdateTimestamp"
                    case quotaUsage = "QuotaUsage"
                }
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    status = try values.decodeIfPresent(String.self, forKey: .status)
                    updateTimestamp = try values.decodeIfPresent(TimeInterval.self, forKey: .updateTimestamp)
                    quotaUsage = try values.decodeIfPresent([Quota].self, forKey: .quotaUsage) ?? []
                }
            }
            let result: Result
            enum CodingKeys: String, CodingKey { case result = "Result" }
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw DoubaoUsageError.parseFailed(error.localizedDescription)
        }
        return DoubaoPlanUsage(
            authenticationMethod: response.result.status,
            updatedAt: response.result.updateTimestamp.flatMap(positiveEpochDate),
            quotas: response.result.quotaUsage.map {
                DoubaoPlanUsage.Quota(
                    level: $0.level,
                    usedFraction: min(100, max(0, $0.percent)) / 100,
                    resetsAt: $0.resetTimestamp.flatMap(positiveEpochDate)
                )
            }
        )
    }

    static func parseAgentPlan(_ data: Data) throws -> DoubaoPlanUsage {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Window: Decodable {
                    let quota: Double
                    let used: Double
                    let resetTime: TimeInterval?
                    enum CodingKeys: String, CodingKey {
                        case quota = "Quota"
                        case used = "Used"
                        case resetTime = "ResetTime"
                    }
                }
                let fiveHour: Window?
                let weekly: Window?
                let monthly: Window?
                enum CodingKeys: String, CodingKey {
                    case fiveHour = "AFPFiveHour"
                    case weekly = "AFPWeekly"
                    case monthly = "AFPMonthly"
                }
            }
            let result: Result
            enum CodingKeys: String, CodingKey { case result = "Result" }
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw DoubaoUsageError.parseFailed(error.localizedDescription)
        }
        var quotas: [DoubaoPlanUsage.Quota] = []
        func append(_ window: Response.Result.Window?, level: String) {
            guard let window, window.quota > 0 else { return }
            quotas.append(DoubaoPlanUsage.Quota(
                level: level,
                usedFraction: min(1, max(0, window.used / window.quota)),
                resetsAt: window.resetTime.flatMap { value in
                    value > 0 ? Date(timeIntervalSince1970: value / 1000) : nil
                }
            ))
        }
        append(response.result.fiveHour, level: "agent_5h")
        append(response.result.weekly, level: "agent_weekly")
        append(response.result.monthly, level: "agent_monthly")
        return DoubaoPlanUsage(authenticationMethod: nil, updatedAt: nil, quotas: quotas)
    }

    static func resolveAPIKey(environment: [String: String]) -> String? {
        firstValue(environment, keys: apiKeyEnvironmentKeys)
    }

    static func resolveCodingPlanCredentials(environment: [String: String]) -> DoubaoCodingPlanCredentials? {
        guard let accessKeyID = firstValue(environment, keys: accessKeyIDEnvironmentKeys),
              let secretAccessKey = firstValue(environment, keys: secretAccessKeyEnvironmentKeys)
        else { return nil }
        return DoubaoCodingPlanCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            region: firstValue(environment, keys: regionEnvironmentKeys) ?? defaultRegion
        )
    }

    private static func fetchAPI(
        signedCredentials: DoubaoCodingPlanCredentials?,
        apiKey: String?,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        var signedError: Error?
        if let signedCredentials {
            do { return try await fetchSigned(credentials: signedCredentials, session: session, now: now) } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                signedError = error
            }
        }
        if let apiKey { return try await fetchArk(apiKey: apiKey, session: session, now: now) }
        if let signedError { throw signedError }
        throw DoubaoUsageError.missingCredentials
    }

    private static func fetchSigned(
        credentials: DoubaoCodingPlanCredentials,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let codingData = try await signedRequest(
            url: codingPlanURL,
            credentials: credentials,
            session: session,
            now: now
        )
        let coding = try parseCodingPlan(codingData)
        let agent: DoubaoPlanUsage?
        do {
            agent = try parseAgentPlan(try await signedRequest(
                url: agentPlanURL,
                credentials: credentials,
                session: session,
                now: now
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let DoubaoUsageError.requestFailed(status, _) where status == 403 || status == 404 {
            agent = nil
        } catch {
            if coding.quotas.isEmpty { throw error }
            agent = nil
        }
        let combined: DoubaoPlanUsage
        if coding.quotas.isEmpty, let agent, !agent.quotas.isEmpty {
            combined = agent
        } else {
            combined = DoubaoPlanUsage(
                authenticationMethod: coding.authenticationMethod,
                updatedAt: coding.updatedAt ?? agent?.updatedAt,
                quotas: coding.quotas + (agent?.quotas ?? [])
            )
        }
        return combined.providerUsage(now: now)
    }

    private static func signedRequest(
        url: URL,
        credentials: DoubaoCodingPlanCredentials,
        session: URLSession,
        now: Date
    ) async throws -> Data {
        let body = Data()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        sign(request: &request, body: body, credentials: credentials, date: now)
        return try await execute(request, session: session)
    }

    private struct ArkProbe {
        let remaining: Int
        let limit: Int
        let resetsAt: Date?
        let status: Int
        let reliable: Bool

        var ambiguousZero: Bool { status == 200 && reliable && limit > 0 && remaining == 0 }

        func providerUsage(now: Date) -> ProviderUsage {
            let windows: [UsageWindow]
            if reliable, limit > 0 {
                windows = [UsageWindow(
                    id: "doubao-requests",
                    label: "Requests",
                    usedFraction: min(1, max(0, Double(limit - remaining) / Double(limit))),
                    resetsAt: resetsAt,
                    detail: "\(max(0, limit - remaining)) / \(limit) requests used"
                )]
            } else {
                windows = []
            }
            return ProviderUsage(
                id: ProviderID(rawValue: "doubao"),
                state: .ready,
                windows: windows,
                balance: nil,
                plan: nil,
                updatedAt: now,
                message: windows.isEmpty
                    ? AppLocalization.text("接口未返回可验证的请求额度", "Request limits are not available")
                    : nil
            )
        }
    }

    private static func fetchArk(apiKey: String, session: URLSession, now: Date) async throws -> ProviderUsage {
        var lastError: Error?
        for model in probeModels {
            do {
                let initial = try await probe(apiKey: apiKey, model: model, session: session, now: now)
                guard initial.ambiguousZero else { return initial.providerUsage(now: now) }
                do {
                    let confirmation = try await probe(apiKey: apiKey, model: model, session: session, now: now)
                    if confirmation.status == 429 {
                        return (confirmation.reliable ? confirmation : initial).providerUsage(now: now)
                    }
                    if confirmation.ambiguousZero {
                        return ArkProbe(
                            remaining: confirmation.remaining,
                            limit: confirmation.limit,
                            resetsAt: confirmation.resetsAt,
                            status: confirmation.status,
                            reliable: false
                        ).providerUsage(now: now)
                    }
                    return confirmation.providerUsage(now: now)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    return initial.providerUsage(now: now)
                }
            } catch let DoubaoUsageError.requestFailed(status, _) where status == 403 || status == 404 {
                lastError = DoubaoUsageError.requestFailed(status, "Probe model is unavailable")
            } catch {
                throw error
            }
        }
        throw lastError ?? DoubaoUsageError.requestFailed(0, "All probe models failed")
    }

    private static func probe(
        apiKey: String,
        model: String,
        session: URLSession,
        now: Date
    ) async throws -> ArkProbe {
        let request = try arkRequest(apiKey: apiKey, model: model)
        let (data, response) = try await session.data(for: request, delegate: DoubaoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 || http.statusCode == 429 else {
            throw DoubaoUsageError.requestFailed(http.statusCode, errorSummary(data, status: http.statusCode))
        }
        let limit = intHeader(http, "x-ratelimit-limit-requests")
        let remaining = intHeader(http, "x-ratelimit-remaining-requests")
        let reliable = http.statusCode == 429 ? limit != nil : limit != nil && remaining != nil
        return ArkProbe(
            remaining: remaining ?? 0,
            limit: limit ?? 0,
            resetsAt: stringHeader(http, "x-ratelimit-reset-requests").flatMap { resetDate($0, now: now) },
            status: http.statusCode,
            reliable: reliable
        )
    }

    static func arkRequest(apiKey: String, model: String = "doubao-seed-2.0-code") throws -> URLRequest {
        var request = URLRequest(url: arkURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])
        return request
    }

    private static func execute(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: DoubaoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else {
            throw DoubaoUsageError.requestFailed(http.statusCode, errorSummary(data, status: http.statusCode))
        }
        return data
    }

    private static func fetchCLI(
        configuredCommand: String?,
        environment: [String: String],
        now: Date
    ) async throws -> ProviderUsage {
        guard let executable = resolveArkcli(configuredCommand: configuredCommand, environment: environment) else {
            throw DoubaoUsageError.cliNotFound
        }
        let data = try await runArkcli(executable: executable, environment: environment)
        return try parseArkcli(data, now: now)
    }

    static func resolveArkcli(configuredCommand: String?, environment: [String: String]) -> URL? {
        let configured = clean(configuredCommand ?? "")
        if !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let path = clean(environment["ARKCLI_PATH"] ?? "").nilIfEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let home = clean(environment["HOME"] ?? "").nilIfEmpty
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        for directory in search {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("arkcli")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func attach(_ process: Process) {
            lock.withLock {
                self.process = process
                if cancelled, process.isRunning { process.terminate() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
    }

    private final class BoundedCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()
        private var exceeded = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                guard !exceeded else { return }
                let remaining = max(0, limit - storage.count)
                storage.append(chunk.prefix(remaining))
                exceeded = chunk.count > remaining
            }
        }

        func snapshot() -> (data: Data, exceeded: Bool) {
            lock.withLock { (storage, exceeded) }
        }
    }

    private static func runArkcli(executable: URL, environment: [String: String]) async throws -> Data {
        let state = ProcessState()
        let task = Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = ["usage", "plan", "--format", "json"]
            process.environment = environment
            process.standardOutput = output
            process.standardError = errors
            let stdout = BoundedCapture(limit: 256 * 1024)
            let stderr = BoundedCapture(limit: 64 * 1024)
            output.fileHandleForReading.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
            }
            do { try process.run() } catch {
                throw DoubaoUsageError.cliFailed(-1, error.localizedDescription)
            }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            state.attach(process)
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                throw DoubaoUsageError.cliTimedOut
            }
            process.waitUntilExit()
            try await Task.sleep(for: .milliseconds(20))
            let outputResult = stdout.snapshot()
            let errorResult = stderr.snapshot()
            guard !outputResult.exceeded else { throw DoubaoUsageError.cliOutputTooLarge }
            guard process.terminationStatus == 0 else {
                let message = compact(String(decoding: errorResult.data, as: UTF8.self))
                if isAuthenticationError(message) { throw DoubaoUsageError.cliAuthenticationRequired }
                throw DoubaoUsageError.cliFailed(
                    process.terminationStatus,
                    message.isEmpty ? "unknown error" : message
                )
            }
            return outputResult.data
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            state.cancel()
        }
    }

    private static func sign(
        request: inout URLRequest,
        body: Data,
        credentials: DoubaoCodingPlanCredentials,
        date: Date
    ) {
        let timestamp = formatted(date, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = formatted(date, format: "yyyyMMdd")
        let payloadHash = sha256Hex(body)
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
            ?? "application/x-www-form-urlencoded; charset=utf-8"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        let url = request.url!
        let host = url.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalRequest = [
            request.httpMethod ?? "POST",
            percentEncode(url.path.isEmpty ? "/" : url.path, encodeSlash: false),
            canonicalQuery(url),
            "content-type:\(contentType)",
            "host:\(host)",
            "x-content-sha256:\(payloadHash)",
            "x-date:\(timestamp)",
            "",
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(credentials.region)/ark/request"
        let stringToSign = ["HMAC-SHA256", timestamp, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")
        let dateKey = hmac(key: Data(credentials.secretAccessKey.utf8), message: dateStamp)
        let regionKey = hmac(key: dateKey, message: credentials.region)
        let serviceKey = hmac(key: regionKey, message: "ark")
        let signingKey = hmac(key: serviceKey, message: "request")
        let signature = hmac(key: signingKey, message: stringToSign).map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var pairs: [(key: String, value: String)] = items.map { item in
            (key: percentEncode(item.name), value: percentEncode(item.value ?? ""))
        }
        pairs.sort { lhs, rhs in
            lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key
        }
        return pairs.map { pair in pair.key + "=" + pair.value }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String, encodeSlash: Bool = true) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        if !encodeSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func firstValue(_ environment: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { clean(environment[$0] ?? "").nilIfEmpty }.first
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func epochDate(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value >= 1e11 ? value / 1000 : value)
    }

    private static func positiveEpochDate(_ value: TimeInterval) -> Date? {
        value > 0 ? epochDate(value) : nil
    }

    private static func intHeader(_ response: HTTPURLResponse, _ name: String) -> Int? {
        stringHeader(response, name).flatMap(Int.init)
    }

    private static func stringHeader(_ response: HTTPURLResponse, _ name: String) -> String? {
        response.allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }

    private static func resetDate(_ raw: String, now: Date) -> Date? {
        let value = clean(raw)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        let regex = try? NSRegularExpression(pattern: #"(\d+)([dhms])"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var seconds: TimeInterval = 0
        regex?.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let match,
                  let countRange = Range(match.range(at: 1), in: value),
                  let unitRange = Range(match.range(at: 2), in: value),
                  let count = Double(value[countRange]) else { return }
            let component: TimeInterval
            switch value[unitRange] {
            case "d": component = count * 86_400
            case "h": component = count * 3_600
            case "m": component = count * 60
            default: component = count
            }
            seconds += component
        }
        if seconds > 0 { return now.addingTimeInterval(seconds) }
        return TimeInterval(value).map { now.addingTimeInterval($0) }
    }

    private static func errorSummary(_ data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let metadata = object["ResponseMetadata"] as? [String: Any],
               let error = metadata["Error"] as? [String: Any] {
                let code = clean(error["Code"] as? String ?? "")
                let message = clean(error["Message"] as? String ?? "")
                if !code.isEmpty, !message.isEmpty { return compact("\(code): \(message)") }
                if !code.isEmpty { return compact(code) }
                if !message.isEmpty { return compact(message) }
            }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return compact(message)
            }
            if let message = object["message"] as? String { return compact(message) }
        }
        let text = compact(String(decoding: data, as: UTF8.self))
        return text.isEmpty ? "HTTP \(status)" : text
    }

    private static func compact(_ text: String) -> String {
        let value = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= 200 ? value : String(value.prefix(200)) + "..."
    }

    private static func isAuthenticationError(_ message: String) -> Bool {
        let value = message.lowercased()
        return [
            "not logged in", "not authenticated", "authentication required", "login required",
            "please login", "please log in",
        ].contains { value.contains($0) }
    }

    private enum ResetAt: Decodable {
        case string(String)
        case number(TimeInterval)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(TimeInterval.self) { self = .number(number) } else {
                self = try .string(value.decode(String.self))
            }
        }

        var date: Date? {
            switch self {
            case let .number(value): return positiveEpochDate(value)
            case let .string(value):
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: clean(value)) { return date }
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                return standard.date(from: clean(value))
            }
        }
    }
}

private nonisolated final class DoubaoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
