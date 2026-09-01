import Foundation

nonisolated enum DeepgramUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidEndpoint
    case authenticationExpired
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case networkFailure(String)
    case parseFailure(String)
    case noProjects

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Deepgram API Key", "Missing Deepgram API key")
        case .invalidEndpoint:
            AppLocalization.text("Deepgram API URL 必须是 HTTPS 或裸主机名", "Deepgram API URL must use HTTPS or a bare host")
        case .authenticationExpired:
            AppLocalization.text("Deepgram API Key 无效或已过期", "The Deepgram API key is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("Deepgram API Key 无权读取项目用量", "The Deepgram API key cannot read project usage")
        case .rateLimited:
            AppLocalization.text("Deepgram 请求频率受限", "Deepgram rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("Deepgram 服务暂时不可用（HTTP \(status)）", "Deepgram is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Deepgram 接口请求失败（HTTP \(status)）", "Deepgram API request failed (HTTP \(status))")
        case let .networkFailure(message):
            AppLocalization.text("Deepgram 网络错误：\(message)", "Deepgram network error: \(message)")
        case let .parseFailure(message):
            AppLocalization.text("无法解析 Deepgram 用量：\(message)", "Failed to parse Deepgram usage: \(message)")
        case .noProjects:
            AppLocalization.text("Deepgram 未返回可用项目", "Deepgram returned no usable projects")
        }
    }
}

nonisolated enum DeepgramUsageFetcher {
    struct Project: Sendable, Equatable {
        let id: String
        let name: String?
    }

    struct Totals: Sendable, Equatable {
        var start: String?
        var end: String?
        var hours = 0.0
        var totalHours = 0.0
        var agentHours = 0.0
        var tokensIn: Int64 = 0
        var tokensOut: Int64 = 0
        var ttsCharacters: Int64 = 0
        var requests: Int64 = 0
    }

    static let defaultAPIURL = URL(string: "https://api.deepgram.com/v1")!

    static func fetch(
        apiKey configuredAPIKey: String?,
        projectID configuredProjectID: String?,
        endpointOverride configuredEndpoint: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["DEEPGRAM_API_KEY"]) else {
            throw DeepgramUsageError.missingCredentials
        }
        let baseURL = try resolvedAPIURL(
            configured: configuredEndpoint,
            environment: environment
        )
        let configuredProject = cleaned(configuredProjectID) ?? cleaned(environment["DEEPGRAM_PROJECT_ID"])
        let projects: [Project]
        if let configuredProject {
            projects = [Project(id: configuredProject, name: nil)]
        } else {
            projects = try await fetchProjects(baseURL: baseURL, apiKey: apiKey, session: session)
        }
        guard !projects.isEmpty else { throw DeepgramUsageError.noProjects }

        let totals = try await withThrowingTaskGroup(of: Totals.self) { group in
            let concurrencyLimit = 6
            var nextProjectIndex = 0
            var totals = Totals()

            func submit(_ project: Project) {
                group.addTask {
                    try await fetchUsage(
                        projectID: project.id,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        session: session
                    )
                }
            }

            while nextProjectIndex < min(concurrencyLimit, projects.count) {
                submit(projects[nextProjectIndex])
                nextProjectIndex += 1
            }
            while let projectTotals = try await group.next() {
                merge(projectTotals, into: &totals)
                if nextProjectIndex < projects.count {
                    submit(projects[nextProjectIndex])
                    nextProjectIndex += 1
                }
            }
            return totals
        }
        return providerUsage(totals: totals, projects: projects, now: now)
    }

    static func resolvedAPIURL(
        configured: String?,
        environment: [String: String]
    ) throws -> URL {
        guard let raw = cleaned(configured) ?? cleaned(environment["DEEPGRAM_API_URL"]) else {
            return defaultAPIURL
        }
        var candidate = raw
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw DeepgramUsageError.invalidEndpoint
        }
        components.scheme = "https"
        guard let url = components.url else { throw DeepgramUsageError.invalidEndpoint }
        return url
    }

    static func parseProjects(_ data: Data) throws -> [Project] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["projects"] as? [Any] else {
            throw DeepgramUsageError.parseFailure("projects must be an array")
        }
        return try values.enumerated().map { index, value in
            guard let project = value as? [String: Any],
                  let id = project["project_id"] as? String else {
                throw DeepgramUsageError.parseFailure("projects[\(index)].project_id must be a string")
            }
            return Project(id: id, name: try optionalString(project["name"], field: "projects[\(index)].name"))
        }
    }

    static func parseUsage(_ data: Data) throws -> Totals {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [Any] else {
            throw DeepgramUsageError.parseFailure("usage results must be an array")
        }
        let start = try optionalString(root["start"], field: "start")
        let end = try optionalString(root["end"], field: "end")
        if let resolution = root["resolution"], !(resolution is NSNull) {
            guard let resolution = resolution as? [String: Any] else {
                throw DeepgramUsageError.parseFailure("resolution must be an object")
            }
            _ = try optionalString(resolution["units"], field: "resolution.units")
            _ = try optionalInteger(resolution["amount"], field: "resolution.amount")
        }
        var totals = Totals(start: start, end: end)
        for value in results {
            guard let row = value as? [String: Any] else {
                throw DeepgramUsageError.parseFailure("usage result must be an object")
            }
            totals.hours += try optionalDouble(row["hours"], field: "hours")
            totals.totalHours += try optionalDouble(row["total_hours"], field: "total_hours")
            totals.agentHours += try optionalDouble(row["agent_hours"], field: "agent_hours")
            totals.tokensIn += try optionalInteger(row["tokens_in"], field: "tokens_in")
            totals.tokensOut += try optionalInteger(row["tokens_out"], field: "tokens_out")
            totals.ttsCharacters += try optionalInteger(row["tts_characters"], field: "tts_characters")
            totals.requests += try optionalInteger(row["requests"], field: "requests")
        }
        return totals
    }

    static func providerUsage(totals: Totals, projects _: [Project], now: Date) -> ProviderUsage {
        var details = [UsageDetail(id: "deepgram-requests", label: "Requests", value: integer(totals.requests))]
        if totals.hours != 0 || totals.totalHours != 0 {
            details.append(UsageDetail(
                id: "deepgram-audio",
                label: "Audio",
                value: "\(decimal(totals.hours)) hours · \(decimal(totals.totalHours)) billable hours"
            ))
        }
        if totals.agentHours != 0 {
            details.append(UsageDetail(id: "deepgram-agent-hours", label: "Agent hours", value: decimal(totals.agentHours)))
        }
        if totals.tokensIn != 0 || totals.tokensOut != 0 {
            details.append(UsageDetail(
                id: "deepgram-tokens",
                label: "Tokens",
                value: integer(totals.tokensIn + totals.tokensOut)
            ))
        }
        if totals.ttsCharacters != 0 {
            details.append(UsageDetail(
                id: "deepgram-tts",
                label: "TTS characters",
                value: integer(totals.ttsCharacters)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "deepgram"),
            state: .ready,
            windows: [],
            plan: nil,
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    private static func fetchProjects(baseURL: URL, apiKey: String, session: URLSession) async throws -> [Project] {
        try parseProjects(await responseData(
            url: baseURL.appendingPathComponent("projects"),
            apiKey: apiKey,
            session: session
        ))
    }

    private static func fetchUsage(
        projectID: String,
        baseURL: URL,
        apiKey: String,
        session: URLSession
    ) async throws -> Totals {
        let url = baseURL
            .appendingPathComponent("projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("usage")
            .appendingPathComponent("breakdown")
        return try parseUsage(await responseData(url: url, apiKey: apiKey, session: session))
    }

    private static func responseData(url: URL, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepgramUsageError.networkFailure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeepgramUsageError.networkFailure("Invalid response")
        }
        switch http.statusCode {
        case 200: return data
        case 401: throw DeepgramUsageError.authenticationExpired
        case 403: throw DeepgramUsageError.permissionDenied
        case 429: throw DeepgramUsageError.rateLimited
        case 500...599: throw DeepgramUsageError.providerUnavailable(http.statusCode)
        default: throw DeepgramUsageError.apiFailure(http.statusCode)
        }
    }

    private static func merge(_ value: Totals, into totals: inout Totals) {
        if let start = value.start, totals.start == nil || start < totals.start! { totals.start = start }
        if let end = value.end, totals.end == nil || end > totals.end! { totals.end = end }
        totals.hours += value.hours
        totals.totalHours += value.totalHours
        totals.agentHours += value.agentHours
        totals.tokensIn += value.tokensIn
        totals.tokensOut += value.tokensOut
        totals.ttsCharacters += value.ttsCharacters
        totals.requests += value.requests
    }

    private static func optionalString(_ value: Any?, field: String) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let value = value as? String else { throw DeepgramUsageError.parseFailure("\(field) must be a string") }
        return value
    }

    private static func optionalDouble(_ value: Any?, field: String) throws -> Double {
        if value == nil || value is NSNull { return 0 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw DeepgramUsageError.parseFailure("\(field) has an invalid number")
        }
        return number.doubleValue
    }

    private static func optionalInteger(_ value: Any?, field: String) throws -> Int64 {
        let number = try optionalDouble(value, field: field)
        guard number.rounded(.towardZero) == number,
              number >= Double(Int64.min), number <= Double(Int64.max) else {
            throw DeepgramUsageError.parseFailure("\(field) has an invalid number")
        }
        return Int64(number)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = value.rounded(.towardZero) == value ? 0 : 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
