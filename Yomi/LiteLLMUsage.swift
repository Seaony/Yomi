import Foundation

nonisolated enum LiteLLMUsageError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case missingBaseURL
    case invalidEndpointOverride(String)
    case missingUserID
    case invalidURL
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return AppLocalization.text("缺少 LiteLLM API Key", "Missing LiteLLM API key")
        case .missingBaseURL:
            return AppLocalization.text("缺少 LiteLLM Base URL", "Missing LiteLLM base URL")
        case let .invalidEndpointOverride(key):
            return AppLocalization.text(
                "LiteLLM Base URL 覆盖 \(key) 无效。仅允许 HTTPS，或私有网络地址使用 HTTP，且不能包含认证信息。",
                "LiteLLM base URL override \(key) is invalid. Use HTTPS, or HTTP for private-network addresses, without credentials."
            )
        case .missingUserID:
            return AppLocalization.text(
                "LiteLLM Key 信息未包含 user_id 或 team_id",
                "LiteLLM key info did not include a user_id or team_id"
            )
        case .invalidURL:
            return AppLocalization.text("LiteLLM URL 无效", "Invalid LiteLLM URL")
        case let .apiError(message):
            return AppLocalization.text("LiteLLM 接口错误：\(message)", "LiteLLM API error: \(message)")
        case let .parseFailed(message):
            return AppLocalization.text("无法解析 LiteLLM 用量：\(message)", "LiteLLM parse error: \(message)")
        }
    }
}

nonisolated struct LiteLLMKeyInfoSnapshot: Codable, Sendable, Equatable {
    let userID: String?
    let teamID: String?
    let keyName: String?
    let spendUSD: Double
    let expiresAt: Date?
}

nonisolated struct LiteLLMUsageSnapshot: Codable, Sendable, Equatable {
    struct TeamUsage: Codable, Sendable, Equatable {
        let id: String
        let alias: String?
        let spendUSD: Double
        let budgetUSD: Double?
        let resetAt: Date?
        let budgetDuration: String?
    }

    let userID: String?
    let accountEmail: String?
    let personalSpendUSD: Double
    let personalBudgetUSD: Double?
    let personalResetAt: Date?
    let teamUsage: TeamUsage?
    let keyName: String?
    let keyExpiresAt: Date?
    let updatedAt: Date

    func providerUsage() -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let budget = personalBudgetUSD, budget > 0 {
            windows.append(UsageWindow(
                id: "litellm-personal",
                label: "Personal budget",
                usedFraction: min(max(personalSpendUSD / budget, 0), 1),
                resetsAt: personalResetAt,
                detail: "\(Self.usd(personalSpendUSD)) / \(Self.usd(budget))"
            ))
        }
        if let teamUsage, let budget = teamUsage.budgetUSD, budget > 0 {
            windows.append(UsageWindow(
                id: "litellm-team",
                label: "Team budget",
                usedFraction: min(max(teamUsage.spendUSD / budget, 0), 1),
                resetsAt: teamUsage.resetAt,
                detail: "\(Self.usd(teamUsage.spendUSD)) / \(Self.usd(budget))"
            ))
        }

        let selectedSpend: Double
        let selectedBudget: Double?
        let period: String
        if userID == nil, let teamUsage {
            selectedSpend = teamUsage.spendUSD
            selectedBudget = teamUsage.budgetUSD
            period = (teamUsage.budgetUSD ?? 0) > 0 ? "Team budget" : "Team spend"
        } else {
            selectedSpend = personalSpendUSD
            selectedBudget = personalBudgetUSD
            period = (personalBudgetUSD ?? 0) > 0 ? "Personal budget" : "Personal spend"
        }
        let providerCost = selectedSpend > 0 || (selectedBudget ?? 0) > 0
            ? ProviderCostSummary(
                used: selectedSpend,
                limit: max(0, selectedBudget ?? 0),
                currencyCode: "USD",
                period: period
            )
            : nil

        return ProviderUsage(
            id: ProviderID(rawValue: "litellm"),
            state: .ready,
            windows: windows,
            providerCost: providerCost,
            details: [],
            updatedAt: updatedAt
        )
    }

    private static func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

private nonisolated struct LiteLLMKeyInfoResponse: Decodable {
    struct Info: Decodable {
        let keyName: String?
        let spend: Double?
        let expires: String?
        let userID: String?
        let teamID: String?

        private enum CodingKeys: String, CodingKey {
            case keyName = "key_name"
            case spend, expires
            case userID = "user_id"
            case teamID = "team_id"
        }
    }
    let info: Info
}

private nonisolated struct LiteLLMUserInfoResponse: Decodable {
    struct UserInfo: Decodable {
        struct Metadata: Decodable {
            let preferredUsername: String?
            private enum CodingKeys: String, CodingKey { case preferredUsername = "preferred_username" }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                preferredUsername = try? values.decodeIfPresent(String.self, forKey: .preferredUsername)
            }
        }
        let userID: String?
        let userAlias: String?
        let maxBudget: Double?
        let spend: Double?
        let userEmail: String?
        let budgetResetAt: String?
        let metadata: Metadata?

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case userAlias = "user_alias"
            case maxBudget = "max_budget"
            case spend
            case userEmail = "user_email"
            case budgetResetAt = "budget_reset_at"
            case metadata
        }
    }
    struct Team: Decodable {
        let teamAlias: String?
        let teamID: String
        let maxBudget: Double?
        let spend: Double?
        let budgetResetAt: String?
        let budgetDuration: String?

        private enum CodingKeys: String, CodingKey {
            case teamAlias = "team_alias"
            case teamID = "team_id"
            case maxBudget = "max_budget"
            case spend
            case budgetResetAt = "budget_reset_at"
            case budgetDuration = "budget_duration"
        }
    }
    let userID: String?
    let userInfo: UserInfo
    let teams: [Team]?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userInfo = "user_info"
        case teams
    }
}

private nonisolated struct LiteLLMTeamInfoResponse: Decodable {
    struct TeamInfo: Decodable {
        let teamAlias: String?
        let teamID: String?
        let maxBudget: Double?
        let spend: Double?
        let budgetResetAt: String?
        let budgetDuration: String?

        private enum CodingKeys: String, CodingKey {
            case teamAlias = "team_alias"
            case teamID = "team_id"
            case maxBudget = "max_budget"
            case spend
            case budgetResetAt = "budget_reset_at"
            case budgetDuration = "budget_duration"
        }
    }
    let teamID: String?
    let teamInfo: TeamInfo

    private enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case teamInfo = "team_info"
    }
}

nonisolated enum LiteLLMUsageFetcher {
    static let apiKeyEnvironmentKey = "LITELLM_API_KEY"
    static let baseURLEnvironmentKey = "LITELLM_BASE_URL"

    static func fetch(
        apiKey configuredKey: String?,
        endpointOverride configuredBaseURL: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        updatedAt: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredKey) ?? cleaned(environment[apiKeyEnvironmentKey]) else {
            throw LiteLLMUsageError.missingCredentials
        }
        guard let rawBaseURL = cleaned(configuredBaseURL) ?? cleaned(environment[baseURLEnvironmentKey]) else {
            throw LiteLLMUsageError.missingBaseURL
        }
        guard let baseURL = ProviderEndpointValidator.privateNetworkURL(rawBaseURL) else {
            throw LiteLLMUsageError.invalidEndpointOverride(baseURLEnvironmentKey)
        }

        let keyInfoData = try await request(keyInfoURL(baseURL), apiKey: apiKey, session: session)
        let keyInfo = try parseKeyInfo(keyInfoData)
        let snapshot: LiteLLMUsageSnapshot
        if let userID = keyInfo.userID {
            snapshot = try parseUserInfo(
                try await request(userInfoURL(baseURL, userID: userID), apiKey: apiKey, session: session),
                keyInfo: keyInfo,
                updatedAt: updatedAt
            )
        } else if let teamID = keyInfo.teamID {
            snapshot = try parseTeamInfo(
                try await request(teamInfoURL(baseURL, teamID: teamID), apiKey: apiKey, session: session),
                keyInfo: keyInfo,
                updatedAt: updatedAt
            )
        } else {
            throw LiteLLMUsageError.missingUserID
        }
        return snapshot.providerUsage()
    }

    static func keyInfoURL(_ baseURL: URL) -> URL {
        managementBaseURL(baseURL).appendingPathComponent("key").appendingPathComponent("info")
    }

    static func userInfoURL(_ baseURL: URL, userID: String) -> URL {
        url(managementBaseURL(baseURL), path: ["user", "info"], query: URLQueryItem(name: "user_id", value: userID))
    }

    static func teamInfoURL(_ baseURL: URL, teamID: String) -> URL {
        url(managementBaseURL(baseURL), path: ["team", "info"], query: URLQueryItem(name: "team_id", value: teamID))
    }

    static func parseKeyInfo(_ data: Data) throws -> LiteLLMKeyInfoSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMKeyInfoResponse.self, from: data)
            let userID = nonEmpty(decoded.info.userID)
            let teamID = nonEmpty(decoded.info.teamID)
            guard userID != nil || teamID != nil else { throw LiteLLMUsageError.missingUserID }
            return LiteLLMKeyInfoSnapshot(
                userID: userID,
                teamID: teamID,
                keyName: decoded.info.keyName,
                spendUSD: decoded.info.spend ?? 0,
                expiresAt: date(decoded.info.expires)
            )
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    static func parseUserInfo(
        _ data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date
    ) throws -> LiteLLMUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMUserInfoResponse.self, from: data)
            guard let expectedUserID = keyInfo.userID else {
                throw LiteLLMUsageError.parseFailed("/user/info requested without a user_id")
            }
            if let responseUserID = decoded.userInfo.userID ?? decoded.userID,
               responseUserID != expectedUserID {
                throw LiteLLMUsageError.parseFailed("user_id did not match /key/info")
            }
            let team = decoded.teams?.first { $0.teamID == keyInfo.teamID }
            return LiteLLMUsageSnapshot(
                userID: expectedUserID,
                accountEmail: firstNonEmpty(
                    decoded.userInfo.userEmail,
                    decoded.userInfo.userAlias,
                    decoded.userInfo.metadata?.preferredUsername
                ),
                personalSpendUSD: decoded.userInfo.spend ?? 0,
                personalBudgetUSD: decoded.userInfo.maxBudget,
                personalResetAt: date(decoded.userInfo.budgetResetAt),
                teamUsage: team.map {
                    .init(
                        id: $0.teamID,
                        alias: $0.teamAlias,
                        spendUSD: $0.spend ?? 0,
                        budgetUSD: $0.maxBudget,
                        resetAt: date($0.budgetResetAt),
                        budgetDuration: $0.budgetDuration
                    )
                },
                keyName: keyInfo.keyName,
                keyExpiresAt: keyInfo.expiresAt,
                updatedAt: updatedAt
            )
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    static func parseTeamInfo(
        _ data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date
    ) throws -> LiteLLMUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMTeamInfoResponse.self, from: data)
            guard let expectedTeamID = keyInfo.teamID else {
                throw LiteLLMUsageError.parseFailed("/team/info requested without a team_id")
            }
            if let responseTeamID = firstNonEmpty(decoded.teamInfo.teamID, decoded.teamID),
               responseTeamID != expectedTeamID {
                throw LiteLLMUsageError.parseFailed("team_id did not match /key/info")
            }
            let team = decoded.teamInfo
            return LiteLLMUsageSnapshot(
                userID: nil,
                accountEmail: nil,
                personalSpendUSD: 0,
                personalBudgetUSD: nil,
                personalResetAt: nil,
                teamUsage: .init(
                    id: expectedTeamID,
                    alias: team.teamAlias,
                    spendUSD: team.spend ?? 0,
                    budgetUSD: team.maxBudget,
                    resetAt: date(team.budgetResetAt),
                    budgetDuration: team.budgetDuration
                ),
                keyName: keyInfo.keyName,
                keyExpiresAt: keyInfo.expiresAt,
                updatedAt: updatedAt
            )
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func request(_ url: URL, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiteLLMUsageError.apiError("") }
        guard (200..<300).contains(http.statusCode) else {
            let summary = String(bytes: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LiteLLMUsageError.apiError("HTTP \(http.statusCode): \(summary)")
        }
        return data
    }

    private static func managementBaseURL(_ baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.split(separator: "/").last == "v1" else { return baseURL }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "/").dropLast()
        components?.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return components?.url ?? baseURL
    }

    private static func url(_ baseURL: URL, path: [String], query: URLQueryItem) -> URL {
        let result = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: result, resolvingAgainstBaseURL: false) else { return result }
        components.queryItems = [query]
        return components.url ?? result
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap(nonEmpty).first
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = nonEmpty(raw) else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
