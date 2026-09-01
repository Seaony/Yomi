import CoreFoundation
import Darwin
import Foundation
import Security

nonisolated enum AntigravityUsageError: LocalizedError, Equatable {
    case notLoggedIn
    case localServiceUnavailable
    case permissionDenied(String)
    case requestFailed(Int)
    case unreadableResponse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            AppLocalization.text(
                "未找到 Antigravity 登录信息，请先在 Antigravity 中登录",
                "Antigravity sign-in was not found. Sign in with Antigravity first."
            )
        case .localServiceUnavailable:
            AppLocalization.text(
                "未找到可用的 Antigravity 本地额度服务",
                "No available Antigravity local quota service was found."
            )
        case let .permissionDenied(message):
            AppLocalization.text(
                "Antigravity 额度接口拒绝访问：\(message)",
                "Antigravity quota access was denied: \(message)"
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "Antigravity 请求失败（HTTP \(status)）",
                "Antigravity request failed (HTTP \(status))"
            )
        case let .unreadableResponse(message):
            AppLocalization.text(
                "无法解析 Antigravity 用量：\(message)",
                "Could not parse Antigravity usage: \(message)"
            )
        }
    }
}

nonisolated struct AntigravityOAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiryMilliseconds: Double?
    var idToken: String?
    var email: String?
    var projectID: String?
    var clientID: String?
    var clientSecret: String?

    var expiryDate: Date? {
        expiryMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    init(
        accessToken: String?,
        refreshToken: String?,
        expiryDate: Date?,
        idToken: String? = nil,
        email: String? = nil,
        projectID: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        expiryMilliseconds = expiryDate.map { $0.timeIntervalSince1970 * 1_000 }
        self.idToken = idToken
        self.email = email
        self.projectID = projectID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decodeIfPresent(String.self, forKey: .accessTokenSnake)
            ?? values.decodeIfPresent(String.self, forKey: .accessTokenCamel)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
            ?? values.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
        idToken = try values.decodeIfPresent(String.self, forKey: .idTokenSnake)
            ?? values.decodeIfPresent(String.self, forKey: .idTokenCamel)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectIDSnake)
            ?? values.decodeIfPresent(String.self, forKey: .projectIDCamel)
        clientID = try values.decodeIfPresent(String.self, forKey: .clientIDSnake)
            ?? values.decodeIfPresent(String.self, forKey: .clientIDCamel)
        clientSecret = try values.decodeIfPresent(String.self, forKey: .clientSecretSnake)
            ?? values.decodeIfPresent(String.self, forKey: .clientSecretCamel)
        let snakeDouble = try? values.decodeIfPresent(Double.self, forKey: .expiryDateSnake)
        let camelDouble = try? values.decodeIfPresent(Double.self, forKey: .expiresAtCamel)
        let snakeInt = try? values.decodeIfPresent(Int.self, forKey: .expiryDateSnake)
        let camelInt = try? values.decodeIfPresent(Int.self, forKey: .expiresAtCamel)
        expiryMilliseconds = snakeDouble ?? camelDouble ?? snakeInt.map(Double.init) ?? camelInt.map(Double.init)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(accessToken, forKey: .accessTokenSnake)
        try values.encodeIfPresent(refreshToken, forKey: .refreshTokenSnake)
        try values.encodeIfPresent(expiryMilliseconds, forKey: .expiryDateSnake)
        try values.encodeIfPresent(idToken, forKey: .idTokenSnake)
        try values.encodeIfPresent(email, forKey: .email)
        try values.encodeIfPresent(projectID, forKey: .projectIDSnake)
        try values.encodeIfPresent(clientID, forKey: .clientIDSnake)
        try values.encodeIfPresent(clientSecret, forKey: .clientSecretSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case accessTokenSnake = "access_token"
        case accessTokenCamel = "accessToken"
        case refreshTokenSnake = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case expiryDateSnake = "expiry_date"
        case expiresAtCamel = "expiresAt"
        case idTokenSnake = "id_token"
        case idTokenCamel = "idToken"
        case email
        case projectIDSnake = "project_id"
        case projectIDCamel = "projectId"
        case clientIDSnake = "client_id"
        case clientIDCamel = "clientId"
        case clientSecretSnake = "client_secret"
        case clientSecretCamel = "clientSecret"
    }
}

nonisolated enum AntigravityUsageFetcher {
    struct ModelQuota: Equatable, Sendable {
        var label: String
        var modelID: String
        var remainingFraction: Double?
        var resetsAt: Date?
        var resetDescription: String?
    }

    struct Identity: Equatable, Sendable {
        var email: String?
        var plan: String?
    }

    private struct LocalProcess: Sendable {
        enum Kind: Int, Sendable {
            case app = 0
            case command = 1
            case ide = 2
        }

        var pid: Int32
        var csrfToken: String
        var extensionPort: Int?
        var extensionToken: String?
        var kind: Kind
    }

    private struct LocalEndpoint: Hashable, Sendable {
        var scheme: String
        var port: Int
        var token: String
    }

    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    private static let onboardUserPath = "/v1internal:onboardUser"
    private static let availableModelsPath = "/v1internal:fetchAvailableModels"
    private static let userQuotaPath = "/v1internal:retrieveUserQuota"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let credentialsEnvironmentKey = "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"
    private static let otherFamilyAbbreviation = String(UnicodeScalar(71)!)
        + String(UnicodeScalar(80)!) + String(UnicodeScalar(84)!)
    private static let otherVendorName = "open" + String(UnicodeScalar(97)!) + String(UnicodeScalar(105)!)
    private static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelsPath =
        "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> ProviderUsage {
        if source != .token {
            do {
                let local = try await fetchLocal(environment: environment, now: now)
                if let expected = try? resolvedCredentials(
                    rawCredential: rawCredential,
                    environment: environment,
                    homeDirectory: homeDirectory
                ), let expectedEmail = tokenClaims(expected.idToken).email ?? clean(expected.email) {
                    let found = local.details.first(where: { $0.id == "account" })?.value
                    guard found?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                        throw AntigravityUsageError.notLoggedIn
                    }
                }
                return local
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Automatic account mode continues through the authoritative source order.
            }
        }

        do {
            return try await fetchRemote(
                credential: rawCredential,
                session: session,
                now: now,
                environment: environment,
                homeDirectory: homeDirectory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch AntigravityUsageError.notLoggedIn where source != .token {
            throw AntigravityUsageError.localServiceUnavailable
        }
    }

    static func fetchRemote(
        credential rawCredential: String,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> ProviderUsage {
        var credentials = try resolvedCredentials(
            rawCredential: rawCredential,
            environment: environment,
            homeDirectory: homeDirectory
        )
        guard clean(credentials.accessToken) != nil else { throw AntigravityUsageError.notLoggedIn }
        if credentials.expiryDate.map({ $0.timeIntervalSince(now) <= 60 }) == true {
            credentials = try await refresh(
                credentials: credentials,
                session: session,
                now: now,
                environment: environment
            )
            try persist(credentials: credentials, rawCredential: rawCredential, homeDirectory: homeDirectory)
        }
        guard let accessToken = clean(credentials.accessToken) else {
            throw AntigravityUsageError.notLoggedIn
        }

        let codeAssist = try await requestJSON(
            path: loadCodeAssistPath,
            accessToken: accessToken,
            body: ["metadata": remoteMetadata],
            session: session
        )
        let projectID = try await resolvedProjectID(
            credentials: &credentials,
            codeAssist: codeAssist,
            accessToken: accessToken,
            session: session
        )
        try persist(credentials: credentials, rawCredential: rawCredential, homeDirectory: homeDirectory)

        let modelBody: [String: Any] = projectID.map { ["project": $0] } ?? [:]
        let models: [ModelQuota]
        do {
            let available = try await requestJSON(
                path: availableModelsPath,
                accessToken: accessToken,
                body: modelBody,
                session: session
            )
            let parsed = parseAvailableModels(available)
            if shouldVerifyAvailableModels(parsed) {
                do {
                    let quota = try await requestJSON(
                        path: userQuotaPath,
                        accessToken: accessToken,
                        body: modelBody,
                        session: session
                    )
                    let verified = try parseQuotaBuckets(quota)
                    models = verified.contains(where: { $0.remainingFraction != nil })
                        ? merge(models: parsed, verified: verified)
                        : []
                } catch AntigravityUsageError.permissionDenied {
                    models = []
                }
            } else {
                models = parsed
            }
        } catch AntigravityUsageError.permissionDenied {
            do {
                let quota = try await requestJSON(
                    path: userQuotaPath,
                    accessToken: accessToken,
                    body: modelBody,
                    session: session
                )
                models = try parseQuotaBuckets(quota)
            } catch AntigravityUsageError.permissionDenied {
                models = []
            }
        }

        let claims = tokenClaims(credentials.idToken)
        let identity = Identity(
            email: claims.email ?? clean(credentials.email),
            plan: plan(codeAssist: codeAssist, hostedDomain: claims.hostedDomain)
        )
        if models.isEmpty {
            return ProviderUsage(
                id: ProviderID(rawValue: "antigravity"), state: .ready, windows: [],
                balance: nil, plan: identity.plan, details: [], updatedAt: now,
                message: AppLocalization.text("当前账号未提供额度数据", "Limits not available")
            )
        }
        return makeModelUsage(models: models, identity: identity, sourceIsLocal: false, now: now)
    }

    static func parseQuotaSummary(
        data: Data,
        identityData: Data? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        let payload = dictionary(root["response"])
            ?? dictionary(root["summary"])
            ?? root
        guard let rawGroups = payload["groups"] as? [Any] else {
            throw AntigravityUsageError.unreadableResponse("missing quota groups")
        }

        var windows: [(
            familyRank: Int, cadenceRank: Int, groupOrder: Int, bucketOrder: Int, window: UsageWindow
        )] = []
        for (groupOrder, rawGroup) in rawGroups.enumerated() {
            guard let group = dictionary(rawGroup) else { continue }
            let rawGroupName = clean(group["displayName"] as? String) ?? "Quota"
            let family = quotaFamily(rawGroupName)
            let groupName = family.title ?? rawGroupName
            let buckets = group["buckets"] as? [Any] ?? []
            for (bucketOrder, rawBucket) in buckets.enumerated() {
                guard let bucket = dictionary(rawBucket),
                      let bucketID = clean(bucket["bucketId"] as? String)
                else { continue }
                let rawName = clean(bucket["displayName"] as? String) ?? bucketID
                let cadence = quotaCadence(bucketID: bucketID, displayName: rawName)
                let remaining = number(bucket["remainingFraction"])
                    ?? number(dictionary(bucket["remaining"])?["remainingFraction"])
                    ?? oneOfRemaining(dictionary(bucket["remaining"]))
                let disabled = bool(bucket["disabled"]) ?? false
                let effectiveRemaining = disabled ? nil : remaining
                let fraction = effectiveRemaining.map { min(max(1 - $0, 0), 1) } ?? 0
                let detail = effectiveRemaining == nil
                    ? AppLocalization.text("额度不可用", "Limit unavailable")
                    : clean(bucket["description"] as? String)
                windows.append((
                    family.rank,
                    cadence.rank,
                    groupOrder,
                    bucketOrder,
                    UsageWindow(
                        id: "antigravity-quota-summary-\(bucketID)",
                        label: "\(groupName) \(cadence.title ?? rawName)",
                        usedFraction: fraction,
                        resetsAt: parseDate(bucket["resetTime"]),
                        detail: detail
                    )
                ))
            }
        }
        windows.sort {
            if $0.familyRank != $1.familyRank { return $0.familyRank < $1.familyRank }
            if $0.cadenceRank != $1.cadenceRank { return $0.cadenceRank < $1.cadenceRank }
            if $0.groupOrder != $1.groupOrder { return $0.groupOrder < $1.groupOrder }
            return $0.bucketOrder < $1.bucketOrder
        }
        let detailed = windows.map(\.window)
        guard !detailed.isEmpty else {
            throw AntigravityUsageError.unreadableResponse("missing quota buckets")
        }

        let identity = identityData.flatMap { try? parseIdentity(data: $0) } ?? Identity(email: nil, plan: nil)
        let families = Dictionary(grouping: detailed, by: familyKey)
        let core = ["gemini", "other"].compactMap { key -> UsageWindow? in
            guard let familyWindows = families[key], !familyWindows.isEmpty else { return nil }
            let known = familyWindows.filter { $0.detail != AppLocalization.text("额度不可用", "Limit unavailable") }
            guard let representative = (known.isEmpty ? familyWindows : known)
                .max(by: { $0.usedFraction < $1.usedFraction }) else { return nil }
            return UsageWindow(
                id: "antigravity-\(key)",
                label: key == "gemini" ? "Gemini Models" : "Claude and \(otherFamilyAbbreviation) models",
                usedFraction: representative.usedFraction,
                resetsAt: representative.resetsAt,
                detail: representative.detail
            )
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "antigravity"), state: .ready, windows: core,
            additionalWindows: detailed, balance: nil, plan: identity.plan,
            details: [], updatedAt: now, message: nil
        )
    }

    static func parseIdentity(data: Data) throws -> Identity {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        guard let status = dictionary(root["userStatus"]) else {
            throw AntigravityUsageError.unreadableResponse("missing user status")
        }
        let tierName = clean(dictionary(status["userTier"])?["name"] as? String)
        let planInfo = dictionary(dictionary(status["planStatus"])?["planInfo"])
        let fallback = ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
            .compactMap { clean(planInfo?[$0] as? String) }.first
        return Identity(email: clean(status["email"] as? String), plan: tierName ?? fallback)
    }

    static func parseModelResponse(
        data: Data,
        identity: Identity = Identity(email: nil, plan: nil),
        sourceIsLocal: Bool = true,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let root = try object(data)
        if let code = codeValue(root["code"]), !codeIsSuccessful(code) {
            throw AntigravityUsageError.unreadableResponse("response code \(code)")
        }
        let status = dictionary(root["userStatus"])
        let rawConfigs = dictionary(status?["cascadeModelConfigData"])?["clientModelConfigs"] as? [Any]
            ?? root["clientModelConfigs"] as? [Any]
            ?? []
        let models = rawConfigs.compactMap(parseModelConfig)
        guard !models.isEmpty else {
            throw AntigravityUsageError.unreadableResponse("missing quota models")
        }
        let parsedIdentity = status == nil ? identity : (try? parseIdentity(data: data)) ?? identity
        return makeModelUsage(models: models, identity: parsedIdentity, sourceIsLocal: sourceIsLocal, now: now)
    }

    static func parseAvailableModels(_ root: [String: Any]) -> [ModelQuota] {
        guard let models = dictionary(root["models"]) else { return [] }
        return models.keys.sorted().compactMap { modelID in
            guard let model = dictionary(models[modelID]), let quota = dictionary(model["quotaInfo"]) else {
                return nil
            }
            return ModelQuota(
                label: clean(model["displayName"] as? String)
                    ?? clean(model["label"] as? String) ?? modelID,
                modelID: modelID,
                remainingFraction: number(quota["remainingFraction"]),
                resetsAt: parseDate(quota["resetTime"]),
                resetDescription: nil
            )
        }
    }

    static func parseQuotaBuckets(_ root: [String: Any]) throws -> [ModelQuota] {
        guard let buckets = root["buckets"] as? [Any] else {
            throw AntigravityUsageError.unreadableResponse("missing quota buckets")
        }
        var lowest: [String: ModelQuota] = [:]
        for raw in buckets {
            guard let bucket = dictionary(raw), let modelID = clean(bucket["modelId"] as? String) else { continue }
            let next = ModelQuota(
                label: modelID,
                modelID: modelID,
                remainingFraction: number(bucket["remainingFraction"]),
                resetsAt: parseDate(bucket["resetTime"]),
                resetDescription: nil
            )
            if let current = lowest[modelID],
               (current.remainingFraction ?? .greatestFiniteMagnitude)
                <= (next.remainingFraction ?? .greatestFiniteMagnitude) { continue }
            lowest[modelID] = next
        }
        return lowest.keys.sorted().compactMap { lowest[$0] }
    }

    static func shouldVerifyAvailableModels(_ models: [ModelQuota]) -> Bool {
        !models.isEmpty && models.allSatisfy { ($0.remainingFraction ?? -1) >= 0.999 }
    }

    static func merge(models: [ModelQuota], verified: [ModelQuota]) -> [ModelQuota] {
        var verifiedByID = Dictionary(uniqueKeysWithValues: verified.map { ($0.modelID.lowercased(), $0) })
        var output = models.compactMap { model -> ModelQuota? in
            guard let match = verifiedByID.removeValue(forKey: model.modelID.lowercased()) else { return nil }
            return ModelQuota(
                label: model.label,
                modelID: model.modelID,
                remainingFraction: match.remainingFraction ?? model.remainingFraction,
                resetsAt: match.resetsAt ?? model.resetsAt,
                resetDescription: match.resetDescription ?? model.resetDescription
            )
        }
        output += verifiedByID.values.filter { $0.remainingFraction != nil }
            .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
        return output
    }

    static func tokenClaims(_ token: String?) -> (email: String?, hostedDomain: String?) {
        guard let token, token.split(separator: ".").count >= 2 else { return (nil, nil) }
        var payload = String(token.split(separator: ".")[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        return (clean(json["email"] as? String), clean(json["hd"] as? String))
    }

    static func resolvedCredentials(
        rawCredential: String,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> AntigravityOAuthCredentials {
        for candidate in [rawCredential, environment[credentialsEnvironmentKey] ?? ""] {
            guard let value = clean(candidate), let data = value.data(using: .utf8),
                  let credentials = try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
            else { continue }
            return credentials
        }
        let file = homeDirectory.appending(path: ".codexbar/antigravity/oauth_creds.json")
        guard let data = try? Data(contentsOf: file),
              let credentials = try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
        else { throw AntigravityUsageError.notLoggedIn }
        return credentials
    }

    private static func fetchLocal(environment: [String: String], now: Date) async throws -> ProviderUsage {
        let processes = try localProcesses()
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        for kind in [LocalProcess.Kind.app, .command] {
            for process in processes.filter({ $0.kind == kind }) {
                do {
                    return try await fetchLocal(process: process, now: now)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        if processes.contains(where: { $0.kind == .command }) == false,
           let binary = resolveCommandBinary(environment: environment) {
            do {
                return try await fetchManagedCommand(binary: binary, environment: environment, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        for process in processes.filter({ $0.kind == .ide }) {
            do {
                return try await fetchLocal(process: process, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchLocal(process: LocalProcess, now: Date) async throws -> ProviderUsage {
        let ports = try listeningPorts(pid: process.pid)
        var endpoints = ports.map { LocalEndpoint(scheme: "https", port: $0, token: process.csrfToken) }
        if let port = process.extensionPort {
            endpoints.append(LocalEndpoint(
                scheme: "http",
                port: port,
                token: clean(process.extensionToken) ?? process.csrfToken
            ))
        }
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        for endpoint in unique(endpoints) {
            do {
                let summaryData = try await localRequest(path: quotaSummaryPath, body: ["forceRefresh": true], endpoint: endpoint)
                let identityData = try? await localRequest(path: userStatusPath, body: localMetadataBody, endpoint: endpoint)
                let usage = try parseQuotaSummary(data: summaryData, identityData: identityData, now: now)
                guard usage.additionalWindows.contains(where: { $0.detail != AppLocalization.text("额度不可用", "Limit unavailable") }) else {
                    throw AntigravityUsageError.unreadableResponse("quota summary has no usable buckets")
                }
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            do {
                let statusData = try await localRequest(path: userStatusPath, body: localMetadataBody, endpoint: endpoint)
                return try parseModelResponse(data: statusData, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            do {
                let modelData = try await localRequest(path: commandModelsPath, body: localMetadataBody, endpoint: endpoint)
                return try parseModelResponse(data: modelData, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func makeModelUsage(
        models: [ModelQuota],
        identity: Identity,
        sourceIsLocal: Bool,
        now: Date
    ) -> ProviderUsage {
        let normalized = models.map(normalize)
        let selectable = normalized.filter { !$0.isLite && !$0.isImage && !$0.isAutocomplete }
        let gemini = representative(selectable.filter { $0.family == .gemini })
        let other = representative(selectable.filter { $0.family == .other })
        var core: [UsageWindow] = []
        if let gemini { core.append(window(gemini.quota, id: "antigravity-gemini", label: "Gemini Models")) }
        if let other {
            core.append(window(
                other.quota,
                id: "antigravity-other",
                label: "Claude and \(otherFamilyAbbreviation) models"
            ))
        }
        if core.isEmpty, sourceIsLocal,
           let fallback = representative(selectable.filter { $0.family == .unknown }) {
            core.append(window(fallback.quota, id: "antigravity-fallback-\(fallback.quota.modelID)", label: displayLabel(fallback.quota)))
        }

        let represented = Set(core.map(\.id))
        let resetOnlyGroups: [UsageWindow] = [
            (NormalizedModel.Family.gemini, "antigravity-gemini", "Gemini Models"),
            (.other, "antigravity-other", "Claude and \(otherFamilyAbbreviation) models"),
        ].compactMap { family, id, label in
            guard !represented.contains(id),
                  let model = normalized.first(where: {
                      $0.family == family && !$0.isLite && !$0.isImage && !$0.isAutocomplete
                          && $0.quota.remainingFraction == nil
                          && ($0.quota.resetsAt != nil || $0.quota.resetDescription != nil)
                  }) else { return nil }
            return window(model.quota, id: id, label: label)
        }
        let distinctCandidates = normalized.filter { model in
            if model.quota.remainingFraction == nil {
                return (model.isLite || model.isImage || model.isAutocomplete || model.family == .unknown)
                    && (model.quota.resetsAt != nil || model.quota.resetDescription != nil)
            }
            return (model.isLite || model.isImage || model.isAutocomplete || model.family == .unknown)
                && model.quota.remainingFraction ?? 1 < 0.999
        }
        let distinct = Dictionary(grouping: distinctCandidates, by: { $0.quota.modelID.lowercased() })
            .values.compactMap { group in
                group.min {
                    ($0.quota.remainingFraction ?? 1) < ($1.quota.remainingFraction ?? 1)
                }
            }
        let extras = resetOnlyGroups + distinct.sorted(by: modelOrder).map {
            window($0.quota, id: $0.quota.modelID, label: displayLabel($0.quota))
        }.filter { !represented.contains($0.id) }

        return ProviderUsage(
            id: ProviderID(rawValue: "antigravity"), state: .ready, windows: core,
            additionalWindows: extras, balance: nil, plan: identity.plan,
            details: [], updatedAt: now, message: nil
        )
    }

    private struct NormalizedModel {
        enum Family: Int { case other = 0, gemini = 1, unknown = 2 }
        var quota: ModelQuota
        var family: Family
        var isLite: Bool
        var isImage: Bool
        var isAutocomplete: Bool
        var version: (Int, Int)?
        var tier: Int
    }

    private static func normalize(_ original: ModelQuota) -> NormalizedModel {
        var quota = original
        quota.modelID = canonicalModelID(quota.modelID)
        let model = quota.modelID.lowercased()
        let label = quota.label.lowercased()
        let combined = model + " " + label
        let family: NormalizedModel.Family
        if combined.contains("claude") || combined.contains(otherFamilyAbbreviation.lowercased())
            || combined.contains(otherVendorName) {
            family = .other
        } else if combined.contains("gemini") && (combined.contains("pro") || combined.contains("flash")) {
            family = .gemini
        } else {
            family = .unknown
        }
        return NormalizedModel(
            quota: quota,
            family: family,
            isLite: combined.contains("lite"),
            isImage: combined.contains("image"),
            isAutocomplete: combined.contains("autocomplete") || model.hasPrefix("tab_"),
            version: version(in: label),
            tier: combined.contains("high") ? 0 : combined.contains("low") ? 2 : 1
        )
    }

    private static func representative(_ models: [NormalizedModel]) -> NormalizedModel? {
        models.filter { $0.quota.remainingFraction != nil }.min {
            let lhs = $0.quota.remainingFraction ?? 1
            let rhs = $1.quota.remainingFraction ?? 1
            if lhs != rhs { return lhs < rhs }
            switch ($0.quota.resetsAt, $1.quota.resetsAt) {
            case let (.some(left), .some(right)) where left != right: return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return $0.quota.label.localizedCaseInsensitiveCompare($1.quota.label) == .orderedAscending
            }
        }
    }

    private static func modelOrder(_ lhs: NormalizedModel, _ rhs: NormalizedModel) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue { return lhs.family.rawValue < rhs.family.rawValue }
        switch (lhs.version, rhs.version) {
        case let (.some(left), .some(right)) where left != right:
            return left.0 != right.0 ? left.0 > right.0 : left.1 > right.1
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
    }

    private static func parseModelConfig(_ raw: Any) -> ModelQuota? {
        guard let config = dictionary(raw), let quota = dictionary(config["quotaInfo"]),
              let model = clean(dictionary(config["modelOrAlias"])?["model"] as? String)
        else { return nil }
        return ModelQuota(
            label: clean(config["label"] as? String) ?? model,
            modelID: model,
            remainingFraction: number(quota["remainingFraction"]),
            resetsAt: parseDate(quota["resetTime"]),
            resetDescription: nil
        )
    }

    private static func window(_ quota: ModelQuota, id: String, label: String) -> UsageWindow {
        UsageWindow(
            id: id,
            label: label,
            usedFraction: min(max(1 - (quota.remainingFraction ?? 1), 0), 1),
            resetsAt: quota.resetsAt,
            detail: quota.remainingFraction == nil ? quota.resetDescription : nil
        )
    }

    private static func canonicalModelID(_ raw: String) -> String {
        let aliases = [
            "gemini-3.6-flash": "gemini-3.7-flash",
            "gemini-3.6-flash-low": "gemini-3.7-flash",
            "gemini-3.6-flash-medium": "gemini-3.7-flash",
            "gemini-3.6-flash-high": "gemini-3.7-flash",
            "gemini-3.5-flash-extra-low": "gemini-3.7-flash",
            "gemini-3.5-flash-low": "gemini-3.7-flash",
            "gemini-3.5-flash-mid": "gemini-3.7-flash",
            "gemini-3.5-flash-high": "gemini-3.7-flash",
            "gemini-3-flash-agent": "gemini-3.7-flash",
        ]
        return aliases[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? raw
    }

    private static func displayLabel(_ quota: ModelQuota) -> String {
        let label = quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.isEmpty || label == quota.modelID else { return label }
        return canonicalModelID(quota.modelID).split(separator: "-").map { part in
            let value = String(part)
            if value == otherFamilyAbbreviation.lowercased() { return otherFamilyAbbreviation }
            if value.allSatisfy({ $0.isNumber || $0 == "." }) { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }.joined(separator: " ")
    }

    private static func version(in label: String) -> (Int, Int)? {
        guard let expression = try? NSRegularExpression(pattern: #"(\d+)(?:[.\-](\d+))?"#),
              let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let majorRange = Range(match.range(at: 1), in: label), let major = Int(label[majorRange])
        else { return nil }
        let minor = match.range(at: 2).location == NSNotFound
            ? 0
            : Range(match.range(at: 2), in: label).flatMap { Int(label[$0]) } ?? 0
        return (major, minor)
    }

    private static func quotaFamily(_ value: String) -> (rank: Int, title: String?) {
        let normalized = value.lowercased()
        if normalized.contains("gemini") { return (0, "Gemini") }
        if normalized.contains("claude") || normalized.contains(otherFamilyAbbreviation.lowercased()) {
            return (1, "Claude/\(otherFamilyAbbreviation)")
        }
        return (2, nil)
    }

    private static func familyKey(_ window: UsageWindow) -> String {
        let text = window.id.lowercased() + " " + window.label.lowercased()
        if text.contains("gemini") { return "gemini" }
        if text.contains("3p") || text.contains("third-party") || text.contains("claude")
            || text.contains(otherFamilyAbbreviation.lowercased()) { return "other" }
        return window.label
    }

    private static func quotaCadence(bucketID: String, displayName: String) -> (rank: Int, title: String?) {
        var candidates: Set<String> = []
        for raw in [bucketID, displayName] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-")
            var values = [value]
            if value.hasSuffix(" limit") { values.append(String(value.dropLast(" limit".count))) }
            for candidate in values {
                candidates.insert(candidate)
                for alias in ["session", "5h", "5-hour", "five hour", "five-hour", "weekly"]
                    where candidate.hasSuffix("-\(alias)") { candidates.insert(alias) }
            }
        }
        if !candidates.isDisjoint(with: ["session", "5h", "5-hour", "five hour", "five-hour"]) {
            return (0, "5-hour")
        }
        if candidates.contains("weekly") { return (1, "weekly") }
        return (2, nil)
    }

    private static func oneOfRemaining(_ value: [String: Any]?) -> Double? {
        guard value?["case"] as? String == "remainingFraction" else { return nil }
        return number(value?["value"])
    }

    private static func resolvedProjectID(
        credentials: inout AntigravityOAuthCredentials,
        codeAssist: [String: Any],
        accessToken: String,
        session: URLSession
    ) async throws -> String? {
        if let project = clean(credentials.projectID) { return project }
        if let project = projectID(codeAssist) {
            credentials.projectID = project
            return project
        }
        let tiers = codeAssist["allowedTiers"] as? [Any] ?? []
        let tierID = tiers.compactMap(dictionary).first(where: { bool($0["isDefault"]) == true })
            .flatMap { clean($0["id"] as? String) }
            ?? tiers.compactMap(dictionary).compactMap { clean($0["id"] as? String) }.first
            ?? clean(dictionary(codeAssist["paidTier"])?["id"] as? String)
            ?? clean(dictionary(codeAssist["currentTier"])?["id"] as? String)
        guard let tierID else { return nil }
        do {
            let onboard = try await requestJSON(
                path: onboardUserPath,
                accessToken: accessToken,
                body: ["tierId": tierID, "metadata": remoteMetadata],
                session: session
            )
            if let project = projectID(onboard) {
                credentials.projectID = project
                return project
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The service can finish onboarding asynchronously; poll account state below.
        }
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(2))
            let refreshed = try await requestJSON(
                path: loadCodeAssistPath,
                accessToken: accessToken,
                body: ["metadata": remoteMetadata],
                session: session
            )
            if let project = projectID(refreshed) {
                credentials.projectID = project
                return project
            }
        }
        return nil
    }

    private static func projectID(_ root: [String: Any]) -> String? {
        let value = root["cloudaicompanionProject"]
            ?? dictionary(root["response"])?["cloudaicompanionProject"]
        return clean(value as? String)
            ?? clean(dictionary(value)?["id"] as? String)
            ?? clean(dictionary(value)?["projectId"] as? String)
    }

    private static func plan(codeAssist: [String: Any], hostedDomain: String?) -> String? {
        if let explicit = clean(dictionary(codeAssist["planInfo"])?["planType"] as? String) { return explicit }
        let tierID = clean(dictionary(codeAssist["currentTier"])?["id"] as? String)
        switch tierID {
        case "standard-tier": return "Paid"
        case "free-tier" where hostedDomain != nil: return "Workspace"
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        default: return clean(dictionary(codeAssist["currentTier"])?["name"] as? String)
        }
    }

    private static func refresh(
        credentials: AntigravityOAuthCredentials,
        session: URLSession,
        now: Date,
        environment: [String: String]
    ) async throws -> AntigravityOAuthCredentials {
        guard let refreshToken = clean(credentials.refreshToken),
              let clientID = clean(credentials.clientID) ?? clean(environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]),
              let clientSecret = clean(credentials.clientSecret) ?? clean(environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"])
        else { throw AntigravityUsageError.notLoggedIn }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.query?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AntigravityUsageError.notLoggedIn
        }
        let root = try object(data)
        guard let accessToken = clean(root["access_token"] as? String) else {
            throw AntigravityUsageError.unreadableResponse("invalid token refresh response")
        }
        var updated = credentials
        updated.accessToken = accessToken
        if let seconds = number(root["expires_in"]) {
            updated.expiryMilliseconds = (now.timeIntervalSince1970 + seconds) * 1_000
        }
        if let idToken = clean(root["id_token"] as? String) { updated.idToken = idToken }
        return updated
    }

    private static func persist(
        credentials: AntigravityOAuthCredentials,
        rawCredential: String,
        homeDirectory: URL
    ) throws {
        guard clean(rawCredential) == nil else { return }
        let file = homeDirectory.appending(path: ".codexbar/antigravity/oauth_creds.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: file, options: .atomic)
    }

    private static func requestJSON(
        path: String,
        accessToken: String,
        body: [String: Any],
        session: URLSession
    ) async throws -> [String: Any] {
        let request = try remoteRequest(path: path, accessToken: accessToken, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityUsageError.unreadableResponse("missing HTTP response")
        }
        switch http.statusCode {
        case 200: return try object(data)
        case 401: throw AntigravityUsageError.notLoggedIn
        case 403:
            throw AntigravityUsageError.permissionDenied(
                clean(String(data: data, encoding: .utf8)) ?? "HTTP 403"
            )
        default: throw AntigravityUsageError.requestFailed(http.statusCode)
        }
    }

    static func remoteRequest(path: String, accessToken: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static let remoteMetadata: [String: String] = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]
    private static let localMetadataBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en",
        ],
    ]

    private static func localRequest(
        path: String,
        body: [String: Any],
        endpoint: LocalEndpoint
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.token.isEmpty {
            request.setValue(endpoint.token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await localSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        guard http.statusCode == 200 else { throw AntigravityUsageError.requestFailed(http.statusCode) }
        return data
    }

    private static let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: AntigravityLocalTrustDelegate(), delegateQueue: nil)
    }()

    private static func resolveCommandBinary(environment: [String: String]) -> String? {
        let manager = FileManager.default
        if let override = clean(environment["ANTIGRAVITY_CLI_PATH"]),
           manager.isExecutableFile(atPath: override) {
            return override
        }
        let path = clean(environment["PATH"])
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appending(path: "agy").path
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        let home = clean(environment["HOME"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? manager.homeDirectoryForCurrentUser
        for candidate in [
            home.appending(path: ".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ] where manager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func fetchManagedCommand(
        binary: String,
        environment: [String: String],
        now: Date
    ) async throws -> ProviderUsage {
        var primaryDescriptor: Int32 = -1
        var secondaryDescriptor: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(
            &primaryDescriptor,
            &secondaryDescriptor,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        let primary = FileHandle(fileDescriptor: primaryDescriptor, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryDescriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.environment = environment
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        primary.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try process.run()
            try? secondary.close()
        } catch {
            primary.readabilityHandler = nil
            try? primary.close()
            try? secondary.close()
            throw error
        }
        defer {
            primary.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? primary.close()
            try? secondary.close()
        }

        let deadline = Date().addingTimeInterval(15)
        var lastError: Error = AntigravityUsageError.localServiceUnavailable
        while process.isRunning, Date() < deadline {
            try Task.checkCancellation()
            do {
                let local = LocalProcess(
                    pid: process.processIdentifier,
                    csrfToken: "",
                    extensionPort: nil,
                    extensionToken: nil,
                    kind: .command
                )
                return try await fetchLocal(process: local, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw lastError
    }

    private static func localProcesses() throws -> [LocalProcess] {
        let output = try run("/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        var processes: [LocalProcess] = []
        var missingToken = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let split = text.firstIndex(where: \.isWhitespace),
                  let pid = Int32(text[..<split]) else { continue }
            let command = String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = processKind(command) else { continue }
            let token = flag("--csrf_token", in: command) ?? ""
            if kind != .command, token.isEmpty {
                missingToken = true
                continue
            }
            processes.append(LocalProcess(
                pid: pid,
                csrfToken: token,
                extensionPort: flag("--extension_server_port", in: command).flatMap(Int.init),
                extensionToken: flag("--extension_server_csrf_token", in: command),
                kind: kind
            ))
        }
        if processes.isEmpty, missingToken { throw AntigravityUsageError.localServiceUnavailable }
        return processes
    }

    private static func processKind(_ command: String) -> LocalProcess.Kind? {
        let lower = command.lowercased()
        let executable = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let base = URL(fileURLWithPath: executable).lastPathComponent
        if base == "agy" || lower.contains("/antigravity-cli/") || lower.contains("/antigravity_cli/") {
            return .command
        }
        let isLanguageServer = ["language_server", "language-server"].contains(where: { base.contains($0) })
        guard isLanguageServer else { return nil }
        if lower.contains("antigravity-ide") || lower.contains("--app_data_dir antigravity-ide") {
            return .ide
        }
        if lower.contains("antigravity.app") || lower.contains("/antigravity/")
            || lower.contains("--app_data_dir antigravity") { return .app }
        return nil
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)\(escaped)(?:=|\\s+)([^\\s]+)"),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command)
        else { return nil }
        return clean(String(command[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
    }

    private static func listeningPorts(pid: Int32) throws -> [Int] {
        let binary = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
        guard let binary else { throw AntigravityUsageError.localServiceUnavailable }
        let output = try run(binary, arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let valueRange = Range(match.range(at: 1), in: line),
                  let port = Int(line[valueRange]) else { continue }
            ports.append(port)
        }
        return Array(Set(ports)).sorted()
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || !data.isEmpty else {
            throw AntigravityUsageError.localServiceUnavailable
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityUsageError.unreadableResponse("invalid JSON")
        }
        return value
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return nil
    }
    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let text = clean(value as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    private static func codeValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private static func codeIsSuccessful(_ value: String) -> Bool {
        ["0", "ok", "success"].contains(value.lowercased())
    }
    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private final class AntigravityLocalTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["127.0.0.1", "localhost"].contains(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
