import Foundation

nonisolated enum IBMBobUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case noSubscription
    case apiError(Int)
    case untrustedRegion(String)
    case parseFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 IBM Bob API Key。请在设置中添加，或设置 BOBSHELL_API_KEY。",
                "Missing IBM Bob API key. Add one in Settings or set BOBSHELL_API_KEY."
            )
        case .invalidCredentials:
            AppLocalization.text(
                "IBM Bob 拒绝了 API Key。请确认密钥仍有效且可以读取订阅用量。",
                "IBM Bob rejected the API key. Check that it is active and can read subscription usage."
            )
        case .noSubscription:
            AppLocalization.text(
                "IBM Bob 没有返回此 API Key 可见的订阅实例或团队。",
                "IBM Bob returned no subscription instances or teams for this API key."
            )
        case let .apiError(statusCode):
            AppLocalization.text(
                "IBM Bob 接口返回 HTTP \(statusCode)。",
                "IBM Bob API returned HTTP \(statusCode)."
            )
        case let .untrustedRegion(host):
            AppLocalization.text(
                "IBM Bob 返回了不受信任的区域接口域名：\(host)。",
                "IBM Bob returned an untrusted regional API host: \(host)."
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 IBM Bob 用量：\(message)",
                "Could not parse IBM Bob usage: \(message)"
            )
        case let .networkError(message):
            AppLocalization.text(
                "IBM Bob 网络错误：\(message)",
                "IBM Bob network error: \(message)"
            )
        }
    }
}

nonisolated struct IBMBobUsageSnapshot: Sendable, Equatable {
    struct TeamUsage: Sendable, Equatable {
        let instanceName: String
        let teamName: String
        let planName: String?
        let usedBobcoins: Double
        let limitBobcoins: Double?
        let resetsAt: Date?
    }

    let teams: [TeamUsage]
    let updatedAt: Date

    var usedBobcoins: Double {
        teams.reduce(0) { $0 + $1.usedBobcoins }
    }

    var limitBobcoins: Double? {
        let limits = teams.compactMap(\.limitBobcoins)
        guard limits.count == teams.count, !limits.isEmpty else { return nil }
        return limits.reduce(0, +)
    }

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        let used = usedBobcoins
        let limit = limitBobcoins
        let reset = teams.compactMap(\.resetsAt).min()
        let fraction = limit.flatMap { $0 > 0 ? min(1, max(0, used / $0)) : nil } ?? 0
        let summary = limit.map {
            AppLocalization.text(
                "\(Self.bobcoins(used)) / \(Self.bobcoins($0)) Bobcoin",
                "\(Self.bobcoins(used)) / \(Self.bobcoins($0)) Bobcoins",
                language: language
            )
        } ?? AppLocalization.text(
            "已使用 \(Self.bobcoins(used)) Bobcoin",
            "\(Self.bobcoins(used)) Bobcoins used",
            language: language
        )
        let planNames = Array(Set(teams.compactMap(\.planName))).sorted()
        return ProviderUsage(
            id: ProviderID(rawValue: "ibmbob"),
            state: .ready,
            windows: [UsageWindow(
                id: "ibmbob-monthly",
                label: AppLocalization.text("每月 Bobcoin", "Monthly Bobcoins", language: language),
                usedFraction: fraction,
                resetsAt: reset,
                detail: summary
            )],
            plan: planNames.isEmpty ? nil : planNames.joined(separator: ", "),
            updatedAt: updatedAt
        )
    }

    private static func bobcoins(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

private nonisolated struct IBMBobProfileResponse: Decodable, Sendable {
    struct Instance: Decodable, Sendable {
        struct Team: Decodable, Sendable {
            let id: String
            let name: String?
            let budgetLimit: Double?
            let usage: Double?

            private enum CodingKeys: String, CodingKey {
                case id
                case name
                case budgetLimit = "budget_limit"
                case usage
            }
        }

        let instanceID: String
        let instanceName: String?
        let legacyName: String?
        let userID: String?
        let planName: String?
        let refreshAt: IBMBobRefreshAt?
        let regionDomain: String?
        let teams: [Team]

        var name: String? { instanceName ?? legacyName }

        private enum CodingKeys: String, CodingKey {
            case instanceID = "instance_id"
            case instanceName = "instance_name"
            case legacyName = "name"
            case userID = "user_id"
            case planName = "plan_name"
            case refreshAt = "refresh_at"
            case regionDomain = "region_domain"
            case teams
        }
    }

    let instances: [Instance]
}

private nonisolated enum IBMBobRefreshAt: Decodable, Sendable {
    case seconds(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if let seconds = try? values.decode(Double.self) {
            self = .seconds(seconds)
        } else if let text = try? values.decode(String.self) {
            self = .text(text)
        } else {
            throw DecodingError.dataCorruptedError(
                in: values,
                debugDescription: "Expected IBM Bob refresh_at to be Unix seconds or an ISO-8601 string."
            )
        }
    }
}

private nonisolated struct IBMBobTeamBudgetResponse: Decodable, Sendable {
    let usage: Double
    let budgetLimit: Double?

    private enum CodingKeys: String, CodingKey {
        case usage
        case budgetLimit = "budget_limit"
    }
}

nonisolated enum IBMBobUsageFetcher {
    static let apiKeyEnvironmentKey = "BOBSHELL_API_KEY"
    static let baseURL = URL(string: "https://api.us-east.bob.ibm.com")!
    private static let timeoutSeconds: TimeInterval = 20

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for raw in [configured, environment[apiKeyEnvironmentKey]] {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if value.count >= 2,
               value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configuredAPIKey, environment: environment) else {
            throw IBMBobUsageError.missingCredentials
        }
        return try await fetchSnapshot(apiKey: apiKey, session: session, now: now).toProviderUsage()
    }

    static func fetchSnapshot(
        apiKey: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> IBMBobUsageSnapshot {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw IBMBobUsageError.missingCredentials }

        do {
            let profileData = try await response(
                request(
                    url: baseURL.appendingPathComponent("admin/v1/profile"),
                    token: token,
                    instanceID: nil,
                    teamID: nil
                ),
                session: session
            )
            let profile = try decodeProfile(profileData)

            var teamUsage: [IBMBobUsageSnapshot.TeamUsage] = []
            for instance in profile.instances {
                guard let userID = instance.userID, !userID.isEmpty else { continue }
                let regionalBaseURL = try regionalBaseURL(instance.regionDomain)
                for team in instance.teams {
                    guard !team.id.isEmpty else { continue }
                    let url = regionalBaseURL
                        .appendingPathComponent("admin/v1/teams")
                        .appendingPathComponent(team.id)
                        .appendingPathComponent("users")
                        .appendingPathComponent(userID)
                    let budgetData = try await response(
                        request(
                            url: url,
                            token: token,
                            instanceID: instance.instanceID,
                            teamID: team.id
                        ),
                        session: session
                    )
                    let budget = try JSONDecoder().decode(IBMBobTeamBudgetResponse.self, from: budgetData)
                    let limit = (budget.budgetLimit ?? team.budgetLimit).flatMap { $0 >= 0 ? $0 : nil }
                    teamUsage.append(IBMBobUsageSnapshot.TeamUsage(
                        instanceName: nonEmpty(instance.name) ?? instance.instanceID,
                        teamName: nonEmpty(team.name) ?? team.id,
                        planName: nonEmpty(instance.planName),
                        usedBobcoins: max(0, budget.usage),
                        limitBobcoins: limit,
                        resetsAt: parseDate(instance.refreshAt)
                    ))
                }
            }
            guard !teamUsage.isEmpty else { throw IBMBobUsageError.noSubscription }
            return IBMBobUsageSnapshot(teams: teamUsage, updatedAt: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IBMBobUsageError {
            throw error
        } catch let error as DecodingError {
            throw IBMBobUsageError.parseFailed(error.localizedDescription)
        } catch {
            throw IBMBobUsageError.networkError(error.localizedDescription)
        }
    }

    static func authorizationValue(_ token: String) -> String {
        isJWT(token) ? "Bearer \(token)" : "Apikey \(token)"
    }

    static func regionalBaseURL(_ regionDomain: String?) throws -> URL {
        guard let domain = nonEmpty(regionDomain) else { return baseURL }
        let host = domain.lowercased().hasPrefix("api.") ? domain : "api.\(domain)"
        guard let url = URL(string: "https://\(host)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let parsedHost = url.host?.lowercased(),
              parsedHost == "bob.ibm.com" || parsedHost.hasSuffix(".bob.ibm.com") else {
            throw IBMBobUsageError.untrustedRegion(host)
        }
        return url
    }

    static func parseDate(seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func parseISO8601Date(_ value: String) -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func response(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IBMBobUsageError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw IBMBobUsageError.invalidCredentials
        default:
            throw IBMBobUsageError.apiError(http.statusCode)
        }
    }

    private static func request(
        url: URL,
        token: String,
        instanceID: String?,
        teamID: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationValue(token), forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        if let instanceID { request.setValue(instanceID, forHTTPHeaderField: "x-instance-id") }
        if let teamID { request.setValue(teamID, forHTTPHeaderField: "x-team-id") }
        return request
    }

    private static func isJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            return false
        }
        return true
    }

    private static func decodeProfile(_ data: Data) throws -> IBMBobProfileResponse {
        do {
            return try JSONDecoder().decode(IBMBobProfileResponse.self, from: data)
        } catch {
            throw IBMBobUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseDate(_ value: IBMBobRefreshAt?) -> Date? {
        guard let value else { return nil }
        return switch value {
        case let .seconds(seconds): parseDate(seconds: seconds)
        case let .text(text): parseISO8601Date(text)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
