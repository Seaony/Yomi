import CryptoKit
import Foundation

nonisolated enum BedrockAuthMode: String, Codable, CaseIterable, Sendable, Equatable {
    case keys
    case profile
}

nonisolated enum BedrockUsageError: LocalizedError, Equatable {
    case missingCredentials
    case awsCLINotFound
    case profileSessionExpired(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case cloudWatchAPIError(String)
    case cloudWatchParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未配置 AWS 凭据，请设置 Access Key ID 和 Secret Access Key，或配置 AWS Profile",
                "AWS credentials are not configured. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or configure an AWS profile."
            )
        case .awsCLINotFound:
            AppLocalization.text(
                "未找到 AWS CLI，请安装 AWS CLI v2 或设置 AWS_CLI_PATH",
                "AWS CLI not found. Install AWS CLI v2 or set AWS_CLI_PATH."
            )
        case let .profileSessionExpired(profile):
            AppLocalization.text(
                "AWS Profile 会话已过期，请运行 aws sso login --profile \(profile)",
                "AWS profile session expired. Run `aws sso login --profile \(profile)` and try again."
            )
        case let .networkError(message):
            AppLocalization.text("AWS Bedrock 网络错误：\(message)", "AWS Bedrock network error: \(message)")
        case let .apiError(message):
            AppLocalization.text("AWS Cost Explorer 接口错误：\(message)", "AWS Cost Explorer API error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 AWS Cost Explorer 响应：\(message)",
                "Failed to parse AWS Cost Explorer response: \(message)"
            )
        case let .cloudWatchAPIError(message):
            AppLocalization.text("AWS CloudWatch 接口错误：\(message)", "AWS CloudWatch API error: \(message)")
        case let .cloudWatchParseFailed(message):
            AppLocalization.text(
                "无法解析 AWS CloudWatch 响应：\(message)",
                "Failed to parse AWS CloudWatch response: \(message)"
            )
        }
    }
}

nonisolated struct BedrockCredentials: Sendable, Equatable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
}

nonisolated struct BedrockResolvedCredentials: Sendable, Equatable {
    let credentials: BedrockCredentials
    let region: String
}

nonisolated struct BedrockCLIResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let status: Int32
}

nonisolated enum BedrockCredentialResolver {
    typealias CLIRunner = @Sendable (_ binary: String, _ arguments: [String], _ environment: [String: String]) async throws
        -> BedrockCLIResult

    static let defaultRegion = "us-east-1"

    static func inferredAuthMode(
        configured: BedrockAuthMode?,
        environment: [String: String]
    ) -> BedrockAuthMode {
        if let configured { return configured }
        if let raw = cleaned(environment["CODEXBAR_BEDROCK_AUTH_MODE"])?.lowercased(),
           let mode = BedrockAuthMode(rawValue: raw) {
            return mode
        }
        if cleaned(environment["AWS_PROFILE"]) != nil,
           !(cleaned(environment["AWS_ACCESS_KEY_ID"]) != nil
               && cleaned(environment["AWS_SECRET_ACCESS_KEY"]) != nil) {
            return .profile
        }
        return .keys
    }

    static func resolve(
        accessKeyID configuredAccessKeyID: String?,
        secretAccessKey configuredSecretAccessKey: String?,
        profile configuredProfile: String?,
        region configuredRegion: String?,
        authMode configuredAuthMode: BedrockAuthMode?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolveAWSBinary: ([String: String]) -> String? = BedrockCredentialResolver.resolveAWSBinary,
        cliRunner: @escaping CLIRunner = liveCLIRunner
    ) async throws -> BedrockResolvedCredentials {
        switch inferredAuthMode(configured: configuredAuthMode, environment: environment) {
        case .keys:
            guard let accessKeyID = cleaned(configuredAccessKeyID) ?? cleaned(environment["AWS_ACCESS_KEY_ID"]),
                  let secretAccessKey = cleaned(configuredSecretAccessKey)
                    ?? cleaned(environment["AWS_SECRET_ACCESS_KEY"])
            else { throw BedrockUsageError.missingCredentials }
            return BedrockResolvedCredentials(
                credentials: BedrockCredentials(
                    accessKeyID: accessKeyID,
                    secretAccessKey: secretAccessKey,
                    sessionToken: cleaned(environment["AWS_SESSION_TOKEN"])
                ),
                region: resolvedRegion(configured: configuredRegion, environment: environment) ?? defaultRegion
            )
        case .profile:
            guard let profile = cleaned(configuredProfile) ?? cleaned(environment["AWS_PROFILE"]) else {
                throw BedrockUsageError.missingCredentials
            }
            guard let binary = resolveAWSBinary(environment) else { throw BedrockUsageError.awsCLINotFound }
            var cliEnvironment = environment
            cliEnvironment["AWS_PROFILE"] = nil
            let exported = try await cliRunner(
                binary,
                ["configure", "export-credentials", "--profile", profile, "--format", "process"],
                cliEnvironment
            )
            guard exported.status == 0 else { throw mapCLIError(exported.stderr, profile: profile) }
            let credentials = try parseExportedCredentials(exported.stdout)
            let region: String
            if let explicit = resolvedRegion(configured: configuredRegion, environment: environment) {
                region = explicit
            } else {
                let result = try await cliRunner(
                    binary,
                    ["configure", "get", "region", "--profile", profile],
                    cliEnvironment
                )
                region = result.status == 0 ? cleaned(result.stdout) ?? defaultRegion : defaultRegion
            }
            return BedrockResolvedCredentials(credentials: credentials, region: region)
        }
    }

    static func parseExportedCredentials(_ stdout: String) throws -> BedrockCredentials {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessKeyID = cleaned(object["AccessKeyId"] as? String),
              let secretAccessKey = cleaned(object["SecretAccessKey"] as? String)
        else { throw BedrockUsageError.parseFailed("Could not parse AWS CLI export-credentials output") }
        return BedrockCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: cleaned(object["SessionToken"] as? String)
        )
    }

    static func mapCLIError(_ stderr: String, profile: String) -> BedrockUsageError {
        let lower = stderr.lowercased()
        if lower.contains("sso login") || lower.contains("expired") || lower.contains("token has expired") {
            return .profileSessionExpired(profile)
        }
        return .apiError(cleaned(stderr) ?? "AWS CLI failed to export credentials")
    }

    static func resolveAWSBinary(environment: [String: String]) -> String? {
        let manager = FileManager.default
        if let explicit = cleaned(environment["AWS_CLI_PATH"]), manager.isExecutableFile(atPath: explicit) {
            return explicit
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/aws",
            "/usr/local/bin/aws",
            "\(home)/.local/bin/aws",
        ]
        for candidate in candidates where manager.isExecutableFile(atPath: candidate) { return candidate }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/aws"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func resolvedRegion(configured: String?, environment: [String: String]) -> String? {
        cleaned(configured) ?? cleaned(environment["AWS_REGION"]) ?? cleaned(environment["AWS_DEFAULT_REGION"])
    }

    static func liveCLIRunner(
        binary: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> BedrockCLIResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() } catch { throw BedrockUsageError.apiError(error.localizedDescription) }
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning, Date() < deadline {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                process.terminate()
                throw BedrockUsageError.apiError("AWS CLI timed out")
            }
            return BedrockCLIResult(
                stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                status: process.terminationStatus
            )
        }.value
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

nonisolated enum BedrockAWSSigner {
    static func sign(
        request: inout URLRequest,
        credentials: BedrockCredentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        let amzDate = formatted(date, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = formatted(date, format: "yyyyMMdd")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        request.setValue(request.url?.host ?? "", forHTTPHeaderField: "Host")
        let bodyHash = sha256Hex(request.httpBody ?? Data())
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")
        let headers = signedHeaders(request)
        let url = request.url!
        let canonical = [
            request.httpMethod ?? "GET",
            encodedPath(url.path.isEmpty ? "/" : url.path),
            canonicalQuery(url),
            headers.canonical + "\n",
            headers.keys,
            bodyHash,
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonical.utf8))]
            .joined(separator: "\n")
        let dateKey = hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), value: dateStamp)
        let regionKey = hmac(key: dateKey, value: region)
        let serviceKey = hmac(key: regionKey, value: service)
        let signingKey = hmac(key: serviceKey, value: "aws4_request")
        let signature = hmac(key: signingKey, value: toSign).map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(headers.keys), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func signedHeaders(_ request: URLRequest) -> (keys: String, canonical: String) {
        let values = (request.allHTTPHeaderFields ?? [:]).map {
            ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces))
        }.sorted { $0.0 < $1.0 }
        return (
            values.map(\.0).joined(separator: ";"),
            values.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        )
    }

    private static func canonicalQuery(_ url: URL) -> String {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            "\(encode($0.name))=\(encode($0.value ?? ""))"
        }.sorted().joined(separator: "&")
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }.joined(separator: "/")
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func hmac(key: Data, value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

nonisolated struct BedrockClaudeActivity: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let requestCount: Int
}

nonisolated struct BedrockUsageSnapshot: Codable, Sendable, Equatable {
    let monthlySpend: Double
    let monthlyBudget: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let requestCount: Int?
    let region: String
    let updatedAt: Date

    var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    func toProviderUsage(language: AppLanguage = AppLocalization.currentLanguage) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let monthlyBudget, monthlyBudget > 0 {
            windows.append(UsageWindow(
                id: "bedrock-monthly-budget",
                label: AppLocalization.text("月度预算", "Monthly budget", language: language),
                usedFraction: min(1, max(0, monthlySpend / monthlyBudget)),
                resetsAt: Self.endOfCurrentMonth(),
                detail: String(format: "$%.2f / $%.2f", monthlySpend, monthlyBudget)
            ))
        }
        var details: [UsageDetail] = []
        if let totalTokens {
            details.append(UsageDetail(
                id: "bedrock-claude-tokens",
                label: AppLocalization.text("Claude 14 天 Token", "Claude 14d tokens", language: language),
                value: Self.integer(totalTokens)
            ))
        }
        if let requestCount {
            details.append(UsageDetail(
                id: "bedrock-claude-requests",
                label: AppLocalization.text("Claude 14 天请求", "Claude 14d requests", language: language),
                value: Self.integer(requestCount)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "bedrock"),
            state: .ready,
            windows: windows,
            plan: nil,
            providerCost: ProviderCostSummary(
                used: monthlySpend,
                limit: monthlyBudget ?? 0,
                currencyCode: "USD",
                period: AppLocalization.text("本月", "Monthly", language: language),
                balance: nil
            ),
            details: details,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func endOfCurrentMonth() -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: start)
    }

    private static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

nonisolated enum BedrockUsageFetcher {
    private static let costExplorerRegion = "us-east-1"
    private static let timeout: TimeInterval = 15

    static func fetch(
        accessKeyID: String?,
        secretAccessKey: String?,
        profile: String?,
        region: String?,
        authMode: BedrockAuthMode?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        resolveAWSBinary: ([String: String]) -> String? = BedrockCredentialResolver.resolveAWSBinary,
        cliRunner: @escaping BedrockCredentialResolver.CLIRunner
    ) async throws -> ProviderUsage {
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            profile: profile,
            region: region,
            authMode: authMode,
            environment: environment,
            resolveAWSBinary: resolveAWSBinary,
            cliRunner: cliRunner
        )
        return try await fetch(
            credentials: resolved.credentials,
            region: resolved.region,
            budget: budget(environment),
            session: session,
            environment: environment,
            now: now
        ).toProviderUsage()
    }

    static func fetch(
        accessKeyID: String?,
        secretAccessKey: String?,
        profile: String?,
        region: String?,
        authMode: BedrockAuthMode?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        try await fetch(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            profile: profile,
            region: region,
            authMode: authMode,
            session: session,
            environment: environment,
            now: now,
            resolveAWSBinary: BedrockCredentialResolver.resolveAWSBinary,
            cliRunner: { binary, arguments, environment in
                try await BedrockCredentialResolver.liveCLIRunner(
                    binary: binary,
                    arguments: arguments,
                    environment: environment
                )
            }
        )
    }

    static func fetch(
        credentials: BedrockCredentials,
        region: String,
        budget: Double?,
        session: URLSession,
        environment: [String: String],
        now: Date
    ) async throws -> BedrockUsageSnapshot {
        let monthlySpend = try await fetchMonthlyCost(
            credentials: credentials,
            session: session,
            environment: environment,
            now: now
        )
        var activity: BedrockClaudeActivity?
        let cloudWatchOverride = environment["CODEXBAR_BEDROCK_CLOUDWATCH_API_URL"]
        let shouldFetchCloudWatch = environment["CODEXBAR_BEDROCK_API_URL"] == nil || cloudWatchOverride != nil
        if shouldFetchCloudWatch {
            do {
                activity = try await BedrockCloudWatchUsageFetcher.fetch(
                    credentials: credentials,
                    region: region,
                    now: now,
                    endpointOverride: cloudWatchOverride,
                    session: session
                )
            } catch {
                if Task.isCancelled { throw error }
            }
        }
        return BedrockUsageSnapshot(
            monthlySpend: monthlySpend,
            monthlyBudget: budget,
            inputTokens: activity?.inputTokens,
            outputTokens: activity?.outputTokens,
            requestCount: activity?.requestCount,
            region: region,
            updatedAt: now
        )
    }

    static func fetchMonthlyCost(
        credentials: BedrockCredentials,
        session: URLSession,
        environment: [String: String],
        now: Date
    ) async throws -> Double {
        let range = currentMonthRange(now: now)
        let pages = try await costExplorerPages(
            startDate: range.start,
            endDate: range.end,
            granularity: "MONTHLY",
            credentials: credentials,
            session: session,
            environment: environment,
            signingDate: now
        )
        return try pages.reduce(0) { $0 + (try parseTotalCost($1)) }
    }

    static func fetchDailyCosts(
        credentials: BedrockCredentials,
        since: Date,
        until: Date,
        session: URLSession,
        environment: [String: String],
        signingDate: Date = Date()
    ) async throws -> [(date: String, cost: Double)] {
        let formatter = dayFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let inclusiveEnd = calendar.date(byAdding: .day, value: 1, to: until) ?? until
        let pages = try await costExplorerPages(
            startDate: formatter.string(from: since),
            endDate: formatter.string(from: inclusiveEnd),
            granularity: "DAILY",
            credentials: credentials,
            session: session,
            environment: environment,
            signingDate: signingDate
        )
        var totals: [String: Double] = [:]
        for page in pages {
            for item in try parseGroupedResults(page) where !item.date.isEmpty && item.cost > 0 {
                totals[item.date, default: 0] += item.cost
            }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.date < $1.date }
    }

    private static func costExplorerPages(
        startDate: String,
        endDate: String,
        granularity: String,
        credentials: BedrockCredentials,
        session: URLSession,
        environment: [String: String],
        signingDate: Date
    ) async throws -> [Data] {
        var pages: [Data] = []
        var nextPageToken: String?
        var seenTokens: Set<String> = []
        repeat {
            let page = try await costExplorerPage(
                startDate: startDate,
                endDate: endDate,
                granularity: granularity,
                nextPageToken: nextPageToken,
                credentials: credentials,
                session: session,
                environment: environment,
                signingDate: signingDate
            )
            pages.append(page)
            nextPageToken = try parsedNextPageToken(from: page)
            if let nextPageToken, !seenTokens.insert(nextPageToken).inserted {
                throw BedrockUsageError.parseFailed("Cost Explorer returned repeated NextPageToken")
            }
        } while nextPageToken != nil
        return pages
    }

    private static func costExplorerPage(
        startDate: String,
        endDate: String,
        granularity: String,
        nextPageToken: String?,
        credentials: BedrockCredentials,
        session: URLSession,
        environment: [String: String],
        signingDate: Date
    ) async throws -> Data {
        let endpoint: URL
        if environment["CODEXBAR_BEDROCK_API_URL"] != nil {
            guard let raw = BedrockCredentialResolver.cleaned(environment["CODEXBAR_BEDROCK_API_URL"]),
                  let value = safeEndpoint(raw)
            else { throw BedrockUsageError.parseFailed("invalid endpoint override") }
            endpoint = value
        } else {
            endpoint = URL(string: "https://ce.us-east-1.amazonaws.com")!
        }
        var body: [String: Any] = [
            "TimePeriod": ["Start": startDate, "End": endDate],
            "Granularity": granularity,
            "Metrics": ["UnblendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]],
        ]
        if let nextPageToken { body["NextPageToken"] = nextPageToken }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSInsightsIndexService.GetCostAndUsage", forHTTPHeaderField: "X-Amz-Target")
        BedrockAWSSigner.sign(
            request: &request,
            credentials: credentials,
            region: costExplorerRegion,
            service: "ce",
            date: signingDate
        )
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw BedrockUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BedrockUsageError.parseFailed("invalid response") }
        guard http.statusCode == 200 else {
            if isDataUnavailable(status: http.statusCode, data: data) {
                return Data(#"{"ResultsByTime":[]}"#.utf8)
            }
            throw BedrockUsageError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    static func parseTotalCost(_ data: Data) throws -> Double {
        try parseGroupedResults(data).reduce(0) { $0 + $1.cost }
    }

    static func parseGroupedResults(_ data: Data) throws -> [(service: String, cost: Double, date: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["ResultsByTime"] as? [[String: Any]]
        else { throw BedrockUsageError.parseFailed("Missing ResultsByTime in Cost Explorer response") }
        var items: [(String, Double, String)] = []
        for result in results {
            let date = (result["TimePeriod"] as? [String: String])?["Start"] ?? ""
            for group in result["Groups"] as? [[String: Any]] ?? [] {
                guard let service = (group["Keys"] as? [String])?.first,
                      service.localizedCaseInsensitiveContains("Bedrock"),
                      let metrics = group["Metrics"] as? [String: Any],
                      let unblended = metrics["UnblendedCost"] as? [String: Any],
                      let amount = unblended["Amount"] as? String,
                      let cost = Double(amount)
                else { continue }
                items.append((service, cost, date))
            }
        }
        return items
    }

    static func currentMonthRange(now: Date) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let formatter = dayFormatter()
        return (formatter.string(from: start), formatter.string(from: tomorrow))
    }

    static func budget(_ environment: [String: String]) -> Double? {
        guard let raw = BedrockCredentialResolver.cleaned(environment["CODEXBAR_BEDROCK_BUDGET"]),
              let value = Double(raw), value > 0 else { return nil }
        return value
    }

    private static func parsedNextPageToken(from data: Data) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockUsageError.parseFailed("Invalid Cost Explorer response")
        }
        return BedrockCredentialResolver.cleaned(object["NextPageToken"] as? String)
    }

    private static func isDataUnavailable(status: Int, data: Data) -> Bool {
        guard status == 400,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let nested = object["Error"] as? [String: Any]
        let candidates = [object["__type"], object["code"], object["Code"], nested?["Code"]]
        return candidates.compactMap { $0 as? String }.contains {
            $0.split(separator: "#").last == "DataUnavailableException"
        }
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

nonisolated enum BedrockCloudWatchUsageFetcher {
    private enum Metric: String, CaseIterable {
        case inputTokens
        case outputTokens
        case requests

        var name: String {
            switch self {
            case .inputTokens: "InputTokenCount"
            case .outputTokens: "OutputTokenCount"
            case .requests: "Invocations"
            }
        }
    }

    static func fetch(
        credentials: BedrockCredentials,
        region: String,
        now: Date,
        endpointOverride: String?,
        session: URLSession
    ) async throws -> BedrockClaudeActivity {
        let endpoint = try endpoint(region: region, override: endpointOverride)
        var totals: [Metric: Double] = [:]
        var nextToken: String?
        var seenTokens: Set<String> = []
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= 20 else { throw BedrockUsageError.cloudWatchParseFailed("too many response pages") }
            let page = try await callPage(
                credentials: credentials,
                region: region,
                now: now,
                endpoint: endpoint,
                nextToken: nextToken,
                session: session
            )
            for (metric, value) in page.totals { totals[metric, default: 0] += value }
            nextToken = page.nextToken
            if let nextToken, !seenTokens.insert(nextToken).inserted {
                throw BedrockUsageError.cloudWatchParseFailed("repeated NextToken")
            }
        } while nextToken != nil
        func value(_ metric: Metric) throws -> Int {
            let total = totals[metric] ?? 0
            guard total.isFinite, total >= 0, total <= Double(Int.max) else {
                throw BedrockUsageError.cloudWatchParseFailed("invalid metric total")
            }
            return Int(total.rounded())
        }
        return try BedrockClaudeActivity(
            inputTokens: value(.inputTokens),
            outputTokens: value(.outputTokens),
            requestCount: value(.requests)
        )
    }

    private static func callPage(
        credentials: BedrockCredentials,
        region: String,
        now: Date,
        endpoint: URL,
        nextToken: String?,
        session: URLSession
    ) async throws -> (totals: [Metric: Double], nextToken: String?) {
        let queries: [[String: Any]] = Metric.allCases.map { metric in
            let search = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"\(metric.name)\" claude', 'Sum', 86400)"
            return ["Id": metric.rawValue, "Expression": "SUM(\(search))", "ReturnData": true]
        }
        var payload: [String: Any] = [
            "StartTime": now.addingTimeInterval(-14 * 24 * 60 * 60).timeIntervalSince1970,
            "EndTime": now.timeIntervalSince1970,
            "ScanBy": "TimestampAscending",
            "MetricDataQueries": queries,
        ]
        if let nextToken { payload["NextToken"] = nextToken }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 15
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("GraniteServiceVersion20100801.GetMetricData", forHTTPHeaderField: "X-Amz-Target")
        BedrockAWSSigner.sign(
            request: &request,
            credentials: credentials,
            region: region,
            service: "monitoring",
            date: now
        )
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw BedrockUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid response")
        }
        guard http.statusCode == 200 else {
            throw BedrockUsageError.cloudWatchAPIError("HTTP \(http.statusCode)")
        }
        guard data.count <= 4 * 1024 * 1024 else {
            throw BedrockUsageError.cloudWatchParseFailed("response exceeds 4 MiB")
        }
        return try parsePage(data)
    }

    private static func parsePage(_ data: Data) throws -> (totals: [Metric: Double], nextToken: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid JSON response")
        }
        if let messages = object["Messages"] as? [[String: Any]], !messages.isEmpty {
            throw BedrockUsageError.cloudWatchParseFailed("CloudWatch reported incomplete results")
        }
        var totals: [Metric: Double] = [:]
        for result in object["MetricDataResults"] as? [[String: Any]] ?? [] {
            guard let id = result["Id"] as? String, let metric = Metric(rawValue: id) else {
                throw BedrockUsageError.cloudWatchParseFailed("metric result had an unknown ID")
            }
            guard result["StatusCode"] as? String == "Complete" else {
                throw BedrockUsageError.cloudWatchParseFailed("metric result was incomplete")
            }
            for value in result["Values"] as? [Any] ?? [] {
                guard let number = value as? NSNumber else {
                    throw BedrockUsageError.cloudWatchParseFailed("metric value was not numeric")
                }
                guard number.doubleValue.isFinite, number.doubleValue >= 0 else {
                    throw BedrockUsageError.cloudWatchParseFailed("metric value was invalid")
                }
                totals[metric, default: 0] += number.doubleValue
            }
        }
        return (totals, BedrockCredentialResolver.cleaned(object["NextToken"] as? String))
    }

    static func endpoint(region: String, override: String?) throws -> URL {
        if override != nil {
            guard let raw = BedrockCredentialResolver.cleaned(override), let url = safeEndpoint(raw) else {
                throw BedrockUsageError.cloudWatchParseFailed("invalid endpoint override")
            }
            return url
        }
        guard region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else {
            throw BedrockUsageError.cloudWatchParseFailed("invalid region endpoint")
        }
        let suffix: String
        if region.hasPrefix("cn-") { suffix = "amazonaws.com.cn" }
        else if region.hasPrefix("eusc-") { suffix = "amazonaws.eu" }
        else if region.hasPrefix("us-iso-") { suffix = "c2s.ic.gov" }
        else if region.hasPrefix("us-isob-") { suffix = "sc2s.sgov.gov" }
        else if region.hasPrefix("eu-isoe-") { suffix = "cloud.adc-e.uk" }
        else if region.hasPrefix("us-isof-") { suffix = "csp.hci.ic.gov" }
        else { suffix = "amazonaws.com" }
        return URL(string: "https://monitoring.\(region).\(suffix)")!
    }
}

private nonisolated func safeEndpoint(_ raw: String) -> URL? {
    guard let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          components.user == nil,
          components.password == nil,
          let rawHost = components.host?.lowercased(),
          !rawHost.isEmpty,
          let url = components.url,
          let encodedHost = url.host(percentEncoded: true),
          !encodedHost.contains("%")
    else { return nil }
    let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
        ? String(rawHost.dropFirst().dropLast())
        : rawHost
    guard scheme == "https" || isBedrockLoopback(host) else { return nil }
    return url
}

private nonisolated func isBedrockLoopback(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" { return true }
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
          let first = UInt8(octets[0]),
          octets.dropFirst().allSatisfy({ UInt8($0) != nil }) else { return false }
    return first == 127
}
