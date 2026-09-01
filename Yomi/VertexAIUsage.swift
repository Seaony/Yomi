import Foundation

nonisolated struct VertexAICredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let clientID: String
    let clientSecret: String
    let projectID: String?
    let email: String?
    let expiryDate: Date?

    var needsRefresh: Bool {
        guard let expiryDate else { return true }
        return Date().addingTimeInterval(300) > expiryDate
    }
}

nonisolated enum VertexAIUsageError: LocalizedError, Equatable {
    case credentialsNotFound
    case invalidCredentials(String)
    case missingTokens
    case missingClientCredentials
    case missingProject
    case unauthorized
    case forbidden
    case refreshExpired
    case refreshRevoked
    case networkError(String)
    case noData
    case requestFailed(Int, String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            AppLocalization.text(
                "未找到 gcloud 应用默认凭据。请运行 gcloud auth application-default login。",
                "gcloud credentials not found. Run `gcloud auth application-default login`."
            )
        case let .invalidCredentials(message):
            AppLocalization.text("无法读取 gcloud 凭据：\(message)", "Failed to read gcloud credentials: \(message)")
        case .missingTokens:
            AppLocalization.text("gcloud 凭据中没有可用令牌。", "gcloud credentials contain no usable token.")
        case .missingClientCredentials:
            AppLocalization.text("gcloud 凭据缺少客户端 ID 或密钥。", "gcloud credentials lack a client ID or secret.")
        case .missingProject:
            AppLocalization.text(
                "尚未配置 Google Cloud 项目。请运行 gcloud config set project PROJECT_ID。",
                "No Google Cloud project is configured. Run `gcloud config set project PROJECT_ID`."
            )
        case .unauthorized:
            AppLocalization.text(
                "Vertex AI 请求未获授权。请重新运行 gcloud auth application-default login。",
                "Vertex AI request unauthorized. Run `gcloud auth application-default login` again."
            )
        case .forbidden:
            AppLocalization.text(
                "无权读取 Cloud Monitoring，请检查 IAM 权限。",
                "Access forbidden. Check the IAM permissions for Cloud Monitoring."
            )
        case .refreshExpired:
            AppLocalization.text(
                "刷新令牌已过期，请重新运行 gcloud auth application-default login。",
                "The refresh token expired. Run `gcloud auth application-default login` again."
            )
        case .refreshRevoked:
            AppLocalization.text(
                "刷新令牌已被撤销，请重新运行 gcloud auth application-default login。",
                "The refresh token was revoked. Run `gcloud auth application-default login` again."
            )
        case let .networkError(message):
            AppLocalization.text("Vertex AI 网络错误：\(message)", "Vertex AI network error: \(message)")
        case .noData:
            AppLocalization.text(
                "当前项目没有 Vertex AI 用量数据。",
                "No Vertex AI usage data was found for the current project."
            )
        case let .requestFailed(status, body):
            AppLocalization.text(
                "Vertex AI 请求失败（HTTP \(status)）：\(body)",
                "Vertex AI request failed (HTTP \(status)): \(body)"
            )
        case let .commandFailed(message):
            AppLocalization.text("gcloud 命令失败：\(message)", "gcloud command failed: \(message)")
        }
    }
}

nonisolated enum VertexAICredentialsStore {
    static func credentialsFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = clean(environment["GOOGLE_APPLICATION_CREDENTIALS"]) {
            return URL(fileURLWithPath: path)
        }
        if let path = clean(environment["CLOUDSDK_CONFIG"]) {
            return URL(fileURLWithPath: path).appending(path: "application_default_credentials.json")
        }
        return homeDirectory.appending(path: ".config/gcloud/application_default_credentials.json")
    }

    static func projectFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = clean(environment["CLOUDSDK_CONFIG"]).map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appending(path: ".config/gcloud")
        return base.appending(path: "configurations/config_default")
    }

    static func hasCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let url = credentialsFileURL(environment: environment, homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let root = try? jsonObject(data)
        else { return false }
        if serviceAccountMetadata(root) != nil { return true }
        return (try? parseUserCredentials(
            root,
            environment: environment,
            homeDirectory: homeDirectory
        )) != nil
    }

    static func loadForFetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        accessTokenCommand: @escaping @Sendable ([String: String]) async throws -> String = printAccessToken
    ) async throws -> VertexAICredentials {
        let url = credentialsFileURL(environment: environment, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VertexAIUsageError.credentialsNotFound
        }
        let root = try jsonObject(Data(contentsOf: url))
        if let service = serviceAccountMetadata(root) {
            let token = try cleanToken(await accessTokenCommand(environment))
            return VertexAICredentials(
                accessToken: token,
                refreshToken: "",
                clientID: "",
                clientSecret: "",
                projectID: service.projectID ?? projectID(
                    environment: environment,
                    homeDirectory: homeDirectory
                ),
                email: service.email,
                expiryDate: Date().addingTimeInterval(50 * 60)
            )
        }
        return try parseUserCredentials(root, environment: environment, homeDirectory: homeDirectory)
    }

    static func parseUserCredentials(
        data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> VertexAICredentials {
        try parseUserCredentials(
            jsonObject(data),
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    static func projectID(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let fallback = [
            environment["GOOGLE_CLOUD_PROJECT"],
            environment["GCLOUD_PROJECT"],
            environment["CLOUDSDK_CORE_PROJECT"],
        ].compactMap(clean).first
        let url = projectFileURL(environment: environment, homeDirectory: homeDirectory)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("project") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            if parts.count >= 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return fallback
    }

    static func tokenEmail(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return clean(root["email"] as? String)
    }

    private static func parseUserCredentials(
        _ root: [String: Any],
        environment: [String: String],
        homeDirectory: URL
    ) throws -> VertexAICredentials {
        if serviceAccountMetadata(root) != nil {
            throw VertexAIUsageError.invalidCredentials(
                "Service account credentials require gcloud auth application-default print-access-token."
            )
        }
        guard let clientID = root["client_id"] as? String,
              let clientSecret = root["client_secret"] as? String
        else { throw VertexAIUsageError.missingClientCredentials }
        guard let refreshToken = clean(root["refresh_token"] as? String) else {
            throw VertexAIUsageError.missingTokens
        }
        let expiryDate = (root["token_expiry"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return VertexAICredentials(
            accessToken: root["access_token"] as? String ?? "",
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret,
            projectID: projectID(environment: environment, homeDirectory: homeDirectory),
            email: tokenEmail(root["id_token"] as? String),
            expiryDate: expiryDate
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAIUsageError.invalidCredentials("Invalid JSON")
        }
        return root
    }

    private static func serviceAccountMetadata(_ root: [String: Any]) -> (email: String, projectID: String?)? {
        guard let email = clean(root["client_email"] as? String),
              clean(root["private_key"] as? String) != nil
        else { return nil }
        return (email, clean(root["project_id"] as? String))
    }

    private static func printAccessToken(environment: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["gcloud", "auth", "application-default", "print-access-token"]
                var commandEnvironment = environment
                let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                commandEnvironment["PATH"] = [environment["PATH"], fallbackPath]
                    .compactMap(clean).joined(separator: ":")
                process.environment = commandEnvironment
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: stderr, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        throw VertexAIUsageError.commandFailed(message)
                    }
                    continuation.resume(returning: String(data: stdout, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func cleanToken(_ value: String) throws -> String {
        guard let token = clean(value) else { throw VertexAIUsageError.missingTokens }
        return token
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

nonisolated struct VertexAIQuotaUsage: Sendable, Equatable {
    let requestsUsedPercent: Double
}

nonisolated enum VertexAILogClassifier {
    private static let providerKeys: Set<String> = [
        "provider",
        "platform",
        "backend",
        "api_provider",
        "apiprovider",
        "api_type",
        "apitype",
        "source",
        "vendor",
        "client",
    ]

    static func isVertexUsageEntry(_ value: Any) -> Bool {
        guard let root = value as? [String: Any] else { return false }
        if let message = root["message"] as? [String: Any],
           let messageID = message["id"] as? String,
           messageID.contains("_vrtx_") {
            return true
        }
        if let requestID = root["requestId"] as? String,
           requestID.contains("_vrtx_") {
            return true
        }
        if let message = root["message"] as? [String: Any],
           let model = message["model"] as? String,
           model.hasPrefix("claude-"), model.contains("@") {
            return true
        }
        var candidates = [root]
        for key in ["metadata", "request", "context", "client"] {
            if let candidate = root[key] as? [String: Any] { candidates.append(candidate) }
        }
        if let message = root["message"] as? [String: Any] {
            for key in ["metadata", "request"] {
                if let candidate = message[key] as? [String: Any] { candidates.append(candidate) }
            }
        }
        return candidates.contains(where: containsMarker)
    }

    private static func containsMarker(_ dictionary: [String: Any]) -> Bool {
        for (key, value) in dictionary {
            let normalizedKey = key.lowercased()
            if normalizedKey.contains("vertex") || normalizedKey.contains("gcp") { return true }
            if providerKeys.contains(normalizedKey),
               let text = value as? String,
               text.lowercased().contains("vertex") {
                return true
            }
            if let nested = value as? [String: Any], containsMarker(nested) { return true }
            if let array = value as? [Any], containsMarker(array) { return true }
        }
        return false
    }

    private static func containsMarker(_ array: [Any]) -> Bool {
        array.contains { element in
            guard let dictionary = element as? [String: Any] else { return false }
            return containsMarker(dictionary)
        }
    }
}

nonisolated enum VertexAIUsageFetcher {
    private static let monitoringEndpoint = "https://monitoring.googleapis.com/v3/projects"
    private static let refreshEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let windowSeconds: TimeInterval = 24 * 60 * 60

    static func fetch(
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var credentials = try await VertexAICredentialsStore.loadForFetch(
            environment: environment,
            homeDirectory: homeDirectory
        )
        if credentials.needsRefresh {
            credentials = try await refresh(credentials, session: session, now: now)
        }
        guard let projectID = credentials.projectID, !projectID.isEmpty else {
            throw VertexAIUsageError.missingProject
        }
        do {
            _ = try await fetchQuotaUsage(
                accessToken: credentials.accessToken,
                projectID: projectID,
                session: session,
                now: now
            )
        } catch VertexAIUsageError.noData {
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "vertexai"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    static func refresh(
        _ credentials: VertexAICredentials,
        session: URLSession,
        now: Date = Date()
    ) async throws -> VertexAICredentials {
        guard !credentials.refreshToken.isEmpty else {
            throw VertexAIUsageError.invalidCredentials("No refresh token available")
        }
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VertexAIUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VertexAIUsageError.invalidCredentials("Invalid token response")
        }
        if http.statusCode == 400 || http.statusCode == 401 {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            switch code?.lowercased() {
            case "invalid_grant", nil: throw VertexAIUsageError.refreshExpired
            case "unauthorized_client": throw VertexAIUsageError.refreshRevoked
            default: throw VertexAIUsageError.invalidCredentials(code ?? "Refresh failed")
            }
        }
        guard http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw VertexAIUsageError.requestFailed(http.statusCode, responseBody(data)) }
        let accessToken = root["access_token"] as? String ?? credentials.accessToken
        let expiresIn = number(root["expires_in"]) ?? 3600
        return VertexAICredentials(
            accessToken: accessToken,
            refreshToken: credentials.refreshToken,
            clientID: credentials.clientID,
            clientSecret: credentials.clientSecret,
            projectID: credentials.projectID,
            email: VertexAICredentialsStore.tokenEmail(root["id_token"] as? String) ?? credentials.email,
            expiryDate: now.addingTimeInterval(expiresIn)
        )
    }

    static func fetchQuotaUsage(
        accessToken: String,
        projectID: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> VertexAIQuotaUsage {
        guard !projectID.isEmpty else { throw VertexAIUsageError.missingProject }
        let usageFilter = """
        metric.type="serviceruntime.googleapis.com/quota/allocation/usage" AND resource.type="consumer_quota" AND resource.label.service="aiplatform.googleapis.com"
        """
        let limitFilter = """
        metric.type="serviceruntime.googleapis.com/quota/limit" AND resource.type="consumer_quota" AND resource.label.service="aiplatform.googleapis.com"
        """
        let usage = try await fetchTimeSeries(
            accessToken: accessToken,
            projectID: projectID,
            filter: usageFilter,
            session: session,
            now: now
        )
        let limits = try await fetchTimeSeries(
            accessToken: accessToken,
            projectID: projectID,
            filter: limitFilter,
            session: session,
            now: now
        )
        return try quotaUsage(usageSeries: usage, limitSeries: limits)
    }

    static func parseQuotaUsage(usageData: Data, limitData: Data) throws -> VertexAIQuotaUsage {
        let decoder = JSONDecoder()
        let usage = try decoder.decode(TimeSeriesResponse.self, from: usageData)
        let limits = try decoder.decode(TimeSeriesResponse.self, from: limitData)
        return try quotaUsage(usageSeries: usage.timeSeries ?? [], limitSeries: limits.timeSeries ?? [])
    }

    private static func fetchTimeSeries(
        accessToken: String,
        projectID: String,
        filter: String,
        session: URLSession,
        now: Date
    ) async throws -> [TimeSeries] {
        var pageToken: String?
        var allSeries: [TimeSeries] = []
        repeat {
            guard var components = URLComponents(
                string: "\(monitoringEndpoint)/\(projectID)/timeSeries"
            ) else { throw VertexAIUsageError.invalidCredentials("Invalid Monitoring URL") }
            let formatter = ISO8601DateFormatter()
            var items = [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "interval.startTime", value: formatter.string(
                    from: now.addingTimeInterval(-windowSeconds)
                )),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "3600s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_MAX"),
                URLQueryItem(name: "view", value: "FULL"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            guard let url = components.url else {
                throw VertexAIUsageError.invalidCredentials("Invalid Monitoring URL")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw VertexAIUsageError.networkError(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw VertexAIUsageError.invalidCredentials("Invalid Monitoring response")
            }
            switch http.statusCode {
            case 200: break
            case 401: throw VertexAIUsageError.unauthorized
            case 403: throw VertexAIUsageError.forbidden
            default: throw VertexAIUsageError.requestFailed(http.statusCode, responseBody(data))
            }
            let decoded = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
            allSeries.append(contentsOf: decoded.timeSeries ?? [])
            pageToken = decoded.nextPageToken?.isEmpty == false ? decoded.nextPageToken : nil
        } while pageToken != nil
        return allSeries
    }

    private static func quotaUsage(
        usageSeries: [TimeSeries],
        limitSeries: [TimeSeries]
    ) throws -> VertexAIQuotaUsage {
        let usage = aggregate(usageSeries)
        let limits = aggregate(limitSeries)
        guard !usage.isEmpty, !limits.isEmpty else { throw VertexAIUsageError.noData }
        let percentages = usage.compactMap { key, value -> Double? in
            guard let limit = matchingLimit(for: key, limits: limits), limit > 0 else { return nil }
            return value / limit * 100
        }
        guard let maximum = percentages.max() else { throw VertexAIUsageError.noData }
        return VertexAIQuotaUsage(requestsUsedPercent: maximum)
    }

    private static func matchingLimit(for key: QuotaKey, limits: [QuotaKey: Double]) -> Double? {
        if let exact = limits[key], exact > 0 { return exact }
        guard key.limitName.isEmpty else { return nil }
        let candidates = limits.filter {
            $0.key.quotaMetric == key.quotaMetric && $0.key.location == key.location && $0.value > 0
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first?.value
    }

    private static func aggregate(_ series: [TimeSeries]) -> [QuotaKey: Double] {
        var result: [QuotaKey: Double] = [:]
        for entry in series {
            let metricLabels = entry.metric.labels ?? [:]
            let resourceLabels = entry.resource.labels ?? [:]
            guard let quotaMetric = metricLabels["quota_metric"] ?? resourceLabels["quota_id"],
                  !quotaMetric.isEmpty,
                  let value = entry.points.compactMap({ pointValue($0.value) }).max()
            else { continue }
            let key = QuotaKey(
                quotaMetric: quotaMetric,
                limitName: metricLabels["limit_name"] ?? "",
                location: resourceLabels["location"] ?? "global"
            )
            result[key] = max(result[key] ?? 0, value)
        }
        return result
    }

    private static func pointValue(_ value: PointValue) -> Double? {
        value.doubleValue ?? value.int64Value.flatMap(Double.init)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func responseBody(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private struct TimeSeriesResponse: Decodable {
        let timeSeries: [TimeSeries]?
        let nextPageToken: String?
    }

    private struct TimeSeries: Decodable {
        let metric: Metric
        let resource: Resource
        let points: [Point]
    }

    private struct Metric: Decodable {
        let labels: [String: String]?
    }

    private struct Resource: Decodable {
        let labels: [String: String]?
    }

    private struct Point: Decodable {
        let value: PointValue
    }

    private struct PointValue: Decodable {
        let doubleValue: Double?
        let int64Value: String?
    }

    private struct QuotaKey: Hashable {
        let quotaMetric: String
        let limitName: String
        let location: String
    }
}
