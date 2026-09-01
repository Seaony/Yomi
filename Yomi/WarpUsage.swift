import Foundation

nonisolated struct WarpUsageSnapshot: Sendable, Equatable {
    let requestLimit: Int
    let requestsUsed: Int
    let nextRefreshTime: Date?
    let isUnlimited: Bool
    let updatedAt: Date
    let bonusCreditsRemaining: Int
    let bonusCreditsTotal: Int
    let bonusNextExpiration: Date?
    let bonusNextExpirationRemaining: Int

    init(
        requestLimit: Int,
        requestsUsed: Int,
        nextRefreshTime: Date?,
        isUnlimited: Bool,
        updatedAt: Date,
        bonusCreditsRemaining: Int = 0,
        bonusCreditsTotal: Int = 0,
        bonusNextExpiration: Date? = nil,
        bonusNextExpirationRemaining: Int = 0
    ) {
        self.requestLimit = requestLimit
        self.requestsUsed = requestsUsed
        self.nextRefreshTime = nextRefreshTime
        self.isUnlimited = isUnlimited
        self.updatedAt = updatedAt
        self.bonusCreditsRemaining = bonusCreditsRemaining
        self.bonusCreditsTotal = bonusCreditsTotal
        self.bonusNextExpiration = bonusNextExpiration
        self.bonusNextExpirationRemaining = bonusNextExpirationRemaining
    }

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        let primaryUsedFraction: Double
        if isUnlimited {
            primaryUsedFraction = 0
        } else if requestLimit > 0 {
            primaryUsedFraction = min(1, max(0, Double(requestsUsed) / Double(requestLimit)))
        } else {
            primaryUsedFraction = 0
        }

        let primaryDetail = isUnlimited
            ? AppLocalization.text("无限", "Unlimited", language: language)
            : AppLocalization.text(
                "\(requestsUsed)/\(requestLimit) 点数",
                "\(requestsUsed)/\(requestLimit) credits",
                language: language
            )
        let primary = UsageWindow(
            id: "credits",
            label: "Credits",
            usedFraction: primaryUsedFraction,
            resetsAt: isUnlimited ? nil : nextRefreshTime,
            detail: primaryDetail
        )

        let hasBonusWindow = bonusCreditsTotal > 0
            || bonusCreditsRemaining > 0
        let additionalWindows: [UsageWindow]
        if hasBonusWindow {
            let bonusUsedFraction: Double
            if bonusCreditsTotal > 0 {
                let used = bonusCreditsTotal - bonusCreditsRemaining
                bonusUsedFraction = min(1, max(0, Double(used) / Double(bonusCreditsTotal)))
            } else {
                bonusUsedFraction = bonusCreditsRemaining > 0 ? 0 : 1
            }
            additionalWindows = [UsageWindow(
                id: "add-on-credits",
                label: "Add-on credits",
                usedFraction: bonusUsedFraction,
                resetsAt: nil,
                detail: nil
            )]
        } else {
            additionalWindows = []
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "warp"),
            state: .ready,
            windows: [primary],
            additionalWindows: additionalWindows,
            balance: nil,
            plan: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }
}

nonisolated enum WarpUsageError: LocalizedError, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(Int, String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Warp API Key", "Missing Warp API key")
        case let .networkError(message):
            AppLocalization.text("Warp 网络错误：\(message)", "Warp network error: \(message)")
        case let .apiError(code, message):
            AppLocalization.text(
                "Warp API 错误（\(code)）：\(message)",
                "Warp API error (\(code)): \(message)"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 Warp 返回的数据：\(message)",
                "Failed to parse Warp response: \(message)"
            )
        }
    }
}

nonisolated enum WarpUsageFetcher {
    private struct BonusGrant: Sendable, Equatable {
        let granted: Int
        let remaining: Int
        let expiration: Date?
    }

    private struct BonusSummary: Sendable, Equatable {
        let remaining: Int
        let total: Int
        let nextExpiration: Date?
        let nextExpirationRemaining: Int
    }

    static let apiKeyEnvironmentKeys = ["WARP_API_KEY", "WARP_TOKEN"]
    static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    static let clientID = "warp-app"
    static let userAgent = "Warp/1.0"
    static let timeout: TimeInterval = 15

    private static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user {
            requestLimitInfo {
              isUnlimited
              nextRefreshTime
              requestLimit
              requestsUsedSinceLastRefresh
            }
            bonusGrants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
            workspaces {
              bonusGrantsInfo {
                grants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
              }
            }
          }
        }
      }
    }
    """

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let configured = cleaned(configured) { return configured }
        for key in apiKeyEnvironmentKeys {
            if let value = cleaned(environment[key]) { return value }
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
            throw WarpUsageError.missingCredentials
        }

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersionString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try requestBody(osVersionString: osVersionString)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WarpUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WarpUsageError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            throw WarpUsageError.apiError(
                http.statusCode,
                apiErrorSummary(statusCode: http.statusCode, data: data)
            )
        }
        return try parse(data, updatedAt: now).toProviderUsage()
    }

    static func requestBody(osVersionString: String) throws -> Data {
        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": osVersionString,
                ] as [String: Any],
            ] as [String: Any],
        ]
        let body: [String: Any] = [
            "query": graphQLQuery,
            "variables": variables,
            "operationName": "GetRequestLimitInfo",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parse(_ data: Data, updatedAt: Date = Date()) throws -> WarpUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any] else {
            throw WarpUsageError.parseFailed("Root JSON is not an object.")
        }

        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let messages = rawErrors.compactMap(graphQLErrorMessage)
            let summary = messages.isEmpty
                ? "GraphQL request failed."
                : messages.prefix(3).joined(separator: " | ")
            throw WarpUsageError.apiError(200, summary)
        }

        guard let dataObject = json["data"] as? [String: Any],
              let userObject = dataObject["user"] as? [String: Any] else {
            throw WarpUsageError.parseFailed("Missing data.user in response.")
        }

        let typeName = (userObject["__typename"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let innerUserObject = userObject["user"] as? [String: Any],
              let limitInfo = innerUserObject["requestLimitInfo"] as? [String: Any] else {
            if let typeName, !typeName.isEmpty, typeName != "UserOutput" {
                throw WarpUsageError.parseFailed("Unexpected user type '\(typeName)'.")
            }
            throw WarpUsageError.parseFailed("Unable to extract requestLimitInfo from response.")
        }

        let nextRefreshTime = (limitInfo["nextRefreshTime"] as? String).flatMap(parseDate)
        let bonus = parseBonusCredits(from: innerUserObject)
        return WarpUsageSnapshot(
            requestLimit: intValue(limitInfo["requestLimit"]),
            requestsUsed: intValue(limitInfo["requestsUsedSinceLastRefresh"]),
            nextRefreshTime: nextRefreshTime,
            isUnlimited: boolValue(limitInfo["isUnlimited"]),
            updatedAt: updatedAt,
            bonusCreditsRemaining: bonus.remaining,
            bonusCreditsTotal: bonus.total,
            bonusNextExpiration: bonus.nextExpiration,
            bonusNextExpirationRemaining: bonus.nextExpirationRemaining
        )
    }

    static func apiErrorSummary(statusCode: Int, data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return compactSummaryText(text)
            }
            return "Unexpected response body (\(data.count) bytes)."
        }

        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let joined = rawErrors.compactMap(graphQLErrorMessage).prefix(3).joined(separator: " | ")
            if !joined.isEmpty { return compactSummaryText(joined) }
        }
        for key in ["error", "message"] {
            if let text = json[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return compactSummaryText(trimmed) }
            }
        }
        return "HTTP \(statusCode) (\(data.count) bytes)."
    }

    private static func parseBonusCredits(from userObject: [String: Any]) -> BonusSummary {
        var grants: [BonusGrant] = []
        if let userGrants = userObject["bonusGrants"] as? [[String: Any]] {
            grants.append(contentsOf: userGrants.map(parseBonusGrant))
        }
        if let workspaces = userObject["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                guard let bonusInfo = workspace["bonusGrantsInfo"] as? [String: Any],
                      let workspaceGrants = bonusInfo["grants"] as? [[String: Any]] else { continue }
                grants.append(contentsOf: workspaceGrants.map(parseBonusGrant))
            }
        }

        let totalRemaining = grants.reduce(0) { $0 + $1.remaining }
        let totalGranted = grants.reduce(0) { $0 + $1.granted }
        let expiring = grants.compactMap { grant -> (date: Date, remaining: Int)? in
            guard grant.remaining > 0, let expiration = grant.expiration else { return nil }
            return (expiration, grant.remaining)
        }

        if let earliest = expiring.min(by: { $0.date < $1.date }) {
            let earliestSecond = Int(earliest.date.timeIntervalSince1970)
            let earliestRemaining = expiring.reduce(0) { result, grant in
                result + (Int(grant.date.timeIntervalSince1970) == earliestSecond ? grant.remaining : 0)
            }
            return BonusSummary(
                remaining: totalRemaining,
                total: totalGranted,
                nextExpiration: earliest.date,
                nextExpirationRemaining: earliestRemaining
            )
        }
        return BonusSummary(
            remaining: totalRemaining,
            total: totalGranted,
            nextExpiration: nil,
            nextExpirationRemaining: 0
        )
    }

    private static func parseBonusGrant(_ grant: [String: Any]) -> BonusGrant {
        BonusGrant(
            granted: intValue(grant["requestCreditsGranted"]),
            remaining: intValue(grant["requestCreditsRemaining"]),
            expiration: (grant["expiration"] as? String).flatMap(parseDate)
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let integer = Int(value) { return integer }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: break
            }
        }
        return false
    }

    private static func graphQLErrorMessage(_ value: Any) -> String? {
        let message: String?
        if let value = value as? String {
            message = value
        } else if let value = value as? [String: Any] {
            message = value["message"] as? String
        } else {
            message = nil
        }
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func compactSummaryText(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<end])..."
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: text)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
