import CoreFoundation
import Foundation

nonisolated enum CodebuffUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidEndpointOverride
    case unauthorized
    case endpointNotFound
    case serviceUnavailable(Int)
    case apiError(Int)
    case networkError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "未找到 Codebuff 凭据，请设置 CODEBUFF_API_KEY 或运行 codebuff login",
                "Codebuff credentials were not found. Set CODEBUFF_API_KEY or run codebuff login."
            )
        case .invalidEndpointOverride:
            AppLocalization.text(
                "CODEBUFF_API_URL 必须使用 HTTPS 或仅填写主机名",
                "CODEBUFF_API_URL must use HTTPS or be a bare host."
            )
        case .unauthorized:
            AppLocalization.text("Codebuff 认证失败，请重新登录", "Codebuff authentication failed. Sign in again.")
        case .endpointNotFound:
            AppLocalization.text("Codebuff 用量接口不存在", "Codebuff usage endpoint was not found.")
        case let .serviceUnavailable(status):
            AppLocalization.text(
                "Codebuff 服务暂时不可用（HTTP \(status)）",
                "Codebuff service is temporarily unavailable (HTTP \(status))."
            )
        case let .apiError(status):
            AppLocalization.text(
                "Codebuff 请求失败（HTTP \(status)）",
                "Codebuff request failed (HTTP \(status))."
            )
        case let .networkError(message):
            AppLocalization.text("Codebuff 网络错误：\(message)", "Codebuff network error: \(message)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Codebuff 用量：\(message)", "Failed to parse Codebuff usage: \(message)")
        }
    }
}

nonisolated enum CodebuffUsageFetcher {
    enum CredentialSource: Sendable, Equatable {
        case environment
        case configured
        case authFile
    }

    struct Credential: Sendable, Equatable {
        let token: String
        let source: CredentialSource
    }

    struct UsagePayload: Sendable, Equatable {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let nextQuotaReset: Date?
        let autoTopUpEnabled: Bool?
    }

    struct SubscriptionPayload: Sendable, Equatable {
        let status: String?
        let tier: String?
        let billingPeriodEnd: Date?
        let weeklyUsed: Double?
        let weeklyLimit: Double?
        let weeklyResetsAt: Date?
        let email: String?
    }

    struct Snapshot: Sendable, Equatable {
        let creditsUsed: Double?
        let creditsTotal: Double?
        let creditsRemaining: Double?
        let weeklyUsed: Double?
        let weeklyLimit: Double?
        let weeklyResetsAt: Date?
        let billingPeriodEnd: Date?
        let nextQuotaReset: Date?
        let tier: String?
        let subscriptionStatus: String?
        let autoTopUpEnabled: Bool?
        let accountEmail: String?
        let updatedAt: Date
    }

    static let apiKeyEnvironmentKey = "CODEBUFF_API_KEY"
    static let apiURLEnvironmentKey = "CODEBUFF_API_URL"
    static let defaultBaseURL = URL(string: "https://www.codebuff.com")!

    static func fetch(
        credential configuredToken: String?,
        source: ProviderSource,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        subscriptionGrace: Duration = .seconds(2),
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard source == .automatic || source == .token else {
            throw CodebuffUsageError.missingCredentials
        }
        guard let credential = resolvedCredential(
            configured: configuredToken,
            environment: environment,
            authFileURL: authFileURL,
            homeDirectory: homeDirectory
        ) else {
            throw CodebuffUsageError.missingCredentials
        }
        let baseURL = try resolvedBaseURL(environment: environment)
        let snapshot = try await fetchSnapshot(
            token: credential.token,
            baseURL: baseURL,
            includeSubscription: credential.source == .authFile,
            session: session,
            subscriptionGrace: subscriptionGrace,
            now: now
        )
        return providerUsage(snapshot)
    }

    static func resolvedCredential(
        configured: String?,
        environment: [String: String],
        authFileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Credential? {
        if let token = cleaned(environment[apiKeyEnvironmentKey]) {
            return Credential(token: token, source: .environment)
        }
        if let token = cleaned(configured) {
            return Credential(token: token, source: .configured)
        }
        let fileURL = authFileURL ?? defaultAuthFileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: fileURL), let token = parseAuthToken(data) else { return nil }
        return Credential(token: token, source: .authFile)
    }

    static func defaultAuthFileURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("manicode", isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }

    static func parseAuthToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let profile = root["default"] as? [String: Any]
        return cleaned(profile?["authToken"] as? String) ?? cleaned(root["authToken"] as? String)
    }

    static func resolvedBaseURL(environment: [String: String]) throws -> URL {
        guard let raw = cleaned(environment[apiURLEnvironmentKey]) else { return defaultBaseURL }
        let candidate = hasExplicitScheme(raw) ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url)
        else {
            throw CodebuffUsageError.invalidEndpointOverride
        }
        return url
    }

    static func usageURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("/api/v1/usage")
    }

    static func subscriptionURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("/api/user/subscription")
    }

    static func fetchSnapshot(
        token: String,
        baseURL: URL,
        includeSubscription: Bool,
        session: URLSession,
        subscriptionGrace: Duration = .seconds(2),
        now: Date = Date()
    ) async throws -> Snapshot {
        guard let token = cleaned(token) else { throw CodebuffUsageError.missingCredentials }
        let payloads = try await fetchPayloads(
            token: token,
            baseURL: baseURL,
            includeSubscription: includeSubscription,
            session: session,
            subscriptionGrace: subscriptionGrace
        )
        return Snapshot(
            creditsUsed: payloads.usage.used,
            creditsTotal: payloads.usage.total,
            creditsRemaining: payloads.usage.remaining,
            weeklyUsed: payloads.subscription?.weeklyUsed,
            weeklyLimit: payloads.subscription?.weeklyLimit,
            weeklyResetsAt: payloads.subscription?.weeklyResetsAt,
            billingPeriodEnd: payloads.subscription?.billingPeriodEnd,
            nextQuotaReset: payloads.usage.nextQuotaReset,
            tier: payloads.subscription?.tier,
            subscriptionStatus: payloads.subscription?.status,
            autoTopUpEnabled: payloads.usage.autoTopUpEnabled,
            accountEmail: payloads.subscription?.email,
            updatedAt: now
        )
    }

    static func parseUsage(_ data: Data) throws -> UsagePayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }
        return UsagePayload(
            used: number(root["usage"]) ?? number(root["used"]),
            total: number(root["quota"]) ?? number(root["limit"]),
            remaining: number(root["remainingBalance"]) ?? number(root["remaining"]),
            nextQuotaReset: date(root["next_quota_reset"]),
            autoTopUpEnabled: root["autoTopupEnabled"] as? Bool ?? root["auto_topup_enabled"] as? Bool
        )
    }

    static func parseSubscription(_ data: Data) throws -> SubscriptionPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }
        let subscription = root["subscription"] as? [String: Any]
        let rateLimit = root["rateLimit"] as? [String: Any]
        let tier = string(subscription?["displayName"])
            ?? string(root["displayName"])
            ?? string(subscription?["tier"])
            ?? string(root["tier"])
            ?? string(subscription?["scheduledTier"])
        let user = root["user"] as? [String: Any]
        return SubscriptionPayload(
            status: subscription?["status"] as? String,
            tier: tier,
            billingPeriodEnd: date(subscription?["billingPeriodEnd"])
                ?? date(subscription?["currentPeriodEnd"]),
            weeklyUsed: number(rateLimit?["weeklyUsed"]) ?? number(rateLimit?["used"]),
            weeklyLimit: number(rateLimit?["weeklyLimit"]) ?? number(rateLimit?["limit"]),
            weeklyResetsAt: date(rateLimit?["weeklyResetsAt"]),
            email: root["email"] as? String ?? user?["email"] as? String
        )
    }

    static func providerUsage(_ snapshot: Snapshot) -> ProviderUsage {
        var windows: [UsageWindow] = []
        let total = resolvedTotal(snapshot)
        if let total, total > 0 {
            let used = resolvedUsed(snapshot, total: total)
            windows.append(UsageWindow(
                id: "codebuff-credits",
                label: "Credits",
                usedFraction: clamped(used / total),
                resetsAt: snapshot.nextQuotaReset,
                detail: nil
            ))
        }
        if let limit = snapshot.weeklyLimit, limit > 0 {
            windows.append(UsageWindow(
                id: "codebuff-weekly",
                label: "Weekly",
                usedFraction: clamped(max(0, snapshot.weeklyUsed ?? 0) / limit),
                resetsAt: snapshot.weeklyResetsAt,
                detail: nil
            ))
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "codebuff"),
            state: .ready,
            windows: windows,
            balance: snapshot.creditsRemaining.map(compactNumber),
            plan: cleaned(snapshot.tier)?.capitalized,
            details: [],
            updatedAt: snapshot.updatedAt,
            message: nil
        )
    }

    private static func fetchPayloads(
        token: String,
        baseURL: URL,
        includeSubscription: Bool,
        session: URLSession,
        subscriptionGrace: Duration
    ) async throws -> (usage: UsagePayload, subscription: SubscriptionPayload?) {
        guard includeSubscription else {
            return (try await fetchUsagePayload(token: token, baseURL: baseURL, session: session), nil)
        }

        let subscriptionTask = Task<SubscriptionPayload, Error> {
            try await fetchSubscriptionPayload(token: token, baseURL: baseURL, session: session)
        }
        let usage: UsagePayload
        do {
            usage = try await withTaskCancellationHandler {
                try await fetchUsagePayload(token: token, baseURL: baseURL, session: session)
            } onCancel: {
                subscriptionTask.cancel()
            }
        } catch {
            subscriptionTask.cancel()
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            subscriptionTask.cancel()
            throw error
        }

        let join = CodebuffBoundedTaskJoin(sourceTask: subscriptionTask)
        switch await join.value(joinGrace: subscriptionGrace) {
        case let .value(subscription):
            try Task.checkCancellation()
            return (usage, subscription)
        case .timedOut:
            try Task.checkCancellation()
            return (usage, nil)
        case .failure:
            subscriptionTask.cancel()
            try Task.checkCancellation()
            return (usage, nil)
        }
    }

    private static func fetchUsagePayload(token: String, baseURL: URL, session: URLSession) async throws -> UsagePayload {
        var request = URLRequest(url: usageURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprintId": "codexbar-usage"])
        let (data, status) = try await response(for: request, session: session)
        try validate(status: status)
        return try parseUsage(data)
    }

    private static func fetchSubscriptionPayload(
        token: String,
        baseURL: URL,
        session: URLSession
    ) async throws -> SubscriptionPayload {
        var request = URLRequest(url: subscriptionURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await response(for: request, session: session)
        try validate(status: status)
        return try parseSubscription(data)
    }

    private static func response(for request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodebuffUsageError.networkError("Invalid response")
            }
            return (data, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as CodebuffUsageError {
            throw error
        } catch {
            throw CodebuffUsageError.networkError(error.localizedDescription)
        }
    }

    private static func validate(status: Int) throws {
        switch status {
        case 200: return
        case 401, 403: throw CodebuffUsageError.unauthorized
        case 404: throw CodebuffUsageError.endpointNotFound
        case 500...599: throw CodebuffUsageError.serviceUnavailable(status)
        default: throw CodebuffUsageError.apiError(status)
        }
    }

    private static func resolvedTotal(_ snapshot: Snapshot) -> Double? {
        if let total = snapshot.creditsTotal { return max(0, total) }
        if let used = snapshot.creditsUsed, let remaining = snapshot.creditsRemaining {
            return max(0, used + remaining)
        }
        return nil
    }

    private static func resolvedUsed(_ snapshot: Snapshot, total: Double) -> Double {
        if let used = snapshot.creditsUsed { return max(0, used) }
        if let remaining = snapshot.creditsRemaining { return max(0, total - remaining) }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? raw : nil
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return cleaned(string)
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number.stringValue : nil
        default:
            return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let result = fractional.date(from: value) { return result }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let result = plain.date(from: value) { return result }
            if let result = Double(value), result.isFinite { return numericDate(result) }
            return nil
        }
        if let number = value as? NSNumber, number.doubleValue.isFinite {
            return numericDate(number.doubleValue)
        }
        return nil
    }

    private static func numericDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func compactNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        let suffixStart = raw.index(after: colon)
        let suffixEnd = raw[suffixStart...].firstIndex(where: { "/?#".contains($0) }) ?? raw.endIndex
        let suffix = raw[suffixStart..<suffixEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    private static func hostHasNoEncodedDelimiters(_ encoded: String, decodedHost: String, url: URL) -> Bool {
        if decodedHost.contains(":") {
            guard encoded == decodedHost,
                  let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  host.hasPrefix("["), host.hasSuffix("]") else { return false }
            let address = host.dropFirst().dropLast()
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        guard decodedHost.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@:")) == nil else { return false }
        return !["%2f", "%5c", "%3f", "%23", "%40", "%3a"].contains { encoded.contains($0) }
    }
}

nonisolated enum CodebuffBoundedTaskJoinOutcome<Value: Sendable> {
    case value(Value)
    case failure(any Error)
    case timedOut
}

nonisolated final class CodebuffBoundedTaskJoin<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceTask: Task<Value, Error>
    private var outcome: CodebuffBoundedTaskJoinOutcome<Value>?
    private var continuation: CheckedContinuation<CodebuffBoundedTaskJoinOutcome<Value>, Never>?
    private var observerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(sourceTask: Task<Value, Error>) {
        self.sourceTask = sourceTask
    }

    func value(joinGrace: Duration) async -> CodebuffBoundedTaskJoinOutcome<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                self.continuation = continuation
                let sourceTask = sourceTask
                observerTask = Task { [weak self] in
                    do { self?.resolve(.value(try await sourceTask.value), cancelSource: false) }
                    catch { self?.resolve(.failure(error), cancelSource: false) }
                }
                timeoutTask = Task { [weak self] in
                    do {
                        if joinGrace > .zero { try await Task.sleep(for: joinGrace) }
                        self?.resolve(.timedOut, cancelSource: true)
                    } catch {}
                }
                lock.unlock()
            }
        } onCancel: {
            resolve(.failure(CancellationError()), cancelSource: true)
        }
    }

    private func resolve(_ outcome: CodebuffBoundedTaskJoinOutcome<Value>, cancelSource: Bool) {
        lock.lock()
        guard self.outcome == nil else { lock.unlock(); return }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        let observerTask = observerTask
        let timeoutTask = timeoutTask
        self.observerTask = nil
        self.timeoutTask = nil
        lock.unlock()
        if cancelSource { sourceTask.cancel() }
        observerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: outcome)
    }
}
