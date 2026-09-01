import CoreFoundation
import Foundation

nonisolated enum GeminiUsageFetcher {
    enum AuthType: String {
        case oauthPersonal = "oauth-personal"
        case apiKey = "gemini-api-key"
        case vertex = "vertex-ai"
        case unknown
    }

    enum Tier: String {
        case free = "free-tier"
        case legacy = "legacy-tier"
        case standard = "standard-tier"
    }

    struct Credentials: Equatable {
        var accessToken: String?
        var idToken: String?
        var refreshToken: String?
        var expiry: Date?
    }

    struct CodeAssistStatus: Equatable {
        var tier: Tier?
        var projectID: String?
        var paidTierName: String?
    }

    private static let quotaEndpoint = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    )!
    private static let codeAssistEndpoint = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
    private static let projectsEndpoint = URL(
        string: "https://cloudresourcemanager.googleapis.com/v1/projects"
    )!
    private static let refreshEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static func fetch(session: URLSession, now: Date = Date()) async throws -> ProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appending(path: ".gemini/settings.json")
        switch authType(settingsURL: settingsURL) {
        case .apiKey, .vertex:
            throw UsageCollectionError.missingCredential
        case .oauthPersonal, .unknown:
            break
        }

        let credentialsURL = home.appending(path: ".gemini/oauth_creds.json")
        var credentials = try loadCredentials(url: credentialsURL)
        var accessToken = credentials.accessToken?.isEmpty == false ? credentials.accessToken : nil
        if accessToken == nil || credentials.expiry.map({ $0 < now }) == true {
            guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty,
                  let client = oauthClient()
            else { throw UsageCollectionError.missingCredential }
            let refreshed = try await refresh(
                token: refreshToken, clientID: client.id, clientSecret: client.secret,
                session: session, now: now
            )
            accessToken = refreshed.accessToken
            credentials.accessToken = refreshed.accessToken
            credentials.idToken = refreshed.idToken ?? credentials.idToken
            credentials.expiry = refreshed.expiry
            try updateCredentials(credentials, url: credentialsURL)
        }
        guard let accessToken else { throw UsageCollectionError.missingCredential }

        let claims = tokenClaims(credentials.idToken)
        let codeAssist = try await loadCodeAssist(
            accessToken: accessToken, hostedDomain: claims.hostedDomain, session: session
        )
        let projectID: String?
        if let detected = codeAssist.projectID {
            projectID = detected
        } else {
            projectID = try? await discoverProject(accessToken: accessToken, session: session)
        }
        var request = URLRequest(url: quotaEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: projectID.map { ["project": $0] } ?? [:])
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try parseQuota(
            data: data,
            email: claims.email,
            plan: plan(tier: codeAssist.tier, hostedDomain: claims.hostedDomain, paidTierName: codeAssist.paidTierName),
            now: now
        )
    }

    static func authType(settingsURL: URL) -> AuthType {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = root["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String
        else { return .unknown }
        if selected == "api-key" { return .apiKey }
        return AuthType(rawValue: selected) ?? .unknown
    }

    static func loadCredentials(url: URL) throws -> Credentials {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageCollectionError.missingCredential }
        return Credentials(
            accessToken: clean(root["access_token"] as? String),
            idToken: clean(root["id_token"] as? String),
            refreshToken: clean(root["refresh_token"] as? String),
            expiry: number(root["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    static func parseQuota(
        data: Data, email: String? = nil, plan: String? = nil, now: Date = Date()
    ) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]], !buckets.isEmpty
        else { throw UsageCollectionError.unreadableResponse }
        var lowest: [String: (remaining: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String,
                  let remaining = number(bucket["remainingFraction"]), remaining.isFinite
            else { continue }
            if let current = lowest[model], current.remaining <= remaining { continue }
            lowest[model] = (remaining, date(bucket["resetTime"]))
        }
        let tiers: [(String, (String) -> Bool)] = [
            ("Pro", { $0.contains("pro") }),
            ("Flash", { $0.contains("flash") && !$0.contains("flash-lite") }),
            ("Flash Lite", { $0.contains("flash-lite") }),
        ]
        let windows = tiers.compactMap { label, matches -> UsageWindow? in
            let quota = lowest
                .filter { matches($0.key.lowercased()) }
                .map(\.value)
                .min { $0.remaining < $1.remaining }
            guard let quota else { return nil }
            return UsageWindow(
                id: "gemini-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))",
                label: label, usedFraction: 1 - quota.remaining,
                resetsAt: quota.reset, detail: nil
            )
        }
        guard !windows.isEmpty else { throw UsageCollectionError.unreadableResponse }
        return ProviderUsage(
            id: ProviderID(rawValue: "gemini"), state: .ready, windows: windows,
            balance: nil, plan: plan, details: [], updatedAt: now, message: nil
        )
    }

    static func parseCodeAssist(data: Data, hostedDomain: String?) throws -> CodeAssistStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageCollectionError.unreadableResponse
        }
        let rawProject: String? = {
            if let project = root["cloudaicompanionProject"] as? String { return clean(project) }
            if let project = root["cloudaicompanionProject"] as? [String: Any] {
                return clean(project["id"] as? String) ?? clean(project["projectId"] as? String)
            }
            return nil
        }()
        let tier = ((root["currentTier"] as? [String: Any])?["id"] as? String)
            .flatMap(Tier.init(rawValue:))
        let paidName = clean((root["paidTier"] as? [String: Any])?["name"] as? String)
        let unsupported = (root["ineligibleTiers"] as? [[String: Any]])?.contains { item in
            [item["reasonCode"], item["reasonMessage"]].compactMap { $0 as? String }
                .contains { isConsumerDeprecation($0) }
        } == true
        if tier == nil, paidName == nil, hostedDomain == nil, unsupported {
            throw UsageCollectionError.unreadableResponse
        }
        return CodeAssistStatus(tier: tier, projectID: rawProject, paidTierName: paidName)
    }

    static func plan(tier: Tier?, hostedDomain: String?, paidTierName: String?) -> String? {
        if let paidTierName = clean(paidTierName) { return paidTierName }
        switch (tier, clean(hostedDomain)) {
        case (.standard, _): return "Paid"
        case (.free, .some): return "Workspace"
        case (.free, .none): return "Free"
        case (.legacy, _): return "Legacy"
        case (.none, _): return nil
        }
    }

    static func tokenClaims(_ token: String?) -> (email: String?, hostedDomain: String?) {
        guard let token else { return (nil, nil) }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        return (clean(root["email"] as? String), clean(root["hd"] as? String))
    }

    static func isConsumerDeprecation(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("unsupported_client")
            || normalized.contains("ineligibletiererror")
            || normalized.contains("no longer supported") && normalized.contains("gemini code assist")
            || normalized.contains("migrate") && normalized.contains("antigravity")
                && normalized.contains("gemini")
    }

    private static func loadCodeAssist(
        accessToken: String, hostedDomain: String?, session: URLSession
    ) async throws -> CodeAssistStatus {
        var request = URLRequest(url: codeAssistEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CodeAssistStatus(tier: nil, projectID: nil, paidTierName: nil)
            }
            if http.statusCode != 200 {
                if let text = String(data: data, encoding: .utf8), isConsumerDeprecation(text) {
                    throw UsageCollectionError.unreadableResponse
                }
                return CodeAssistStatus(tier: nil, projectID: nil, paidTierName: nil)
            }
            return try parseCodeAssist(data: data, hostedDomain: hostedDomain)
        } catch let error as UsageCollectionError {
            throw error
        } catch {
            return CodeAssistStatus(tier: nil, projectID: nil, paidTierName: nil)
        }
    }

    private static func discoverProject(accessToken: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: projectsEndpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [[String: Any]] else { return nil }
        for project in projects {
            guard let id = clean(project["projectId"] as? String) else { continue }
            if id.hasPrefix("gen-lang-client") { return id }
            if (project["labels"] as? [String: Any])?["generative-language"] != nil { return id }
        }
        return nil
    }

    private static func refresh(
        token: String, clientID: String, clientSecret: String,
        session: URLSession, now: Date
    ) async throws -> (accessToken: String, idToken: String?, expiry: Date?) {
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: token),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = clean(root["access_token"] as? String)
        else { throw UsageCollectionError.unreadableResponse }
        let expiry = number(root["expires_in"]).map { now.addingTimeInterval($0) }
        return (accessToken, clean(root["id_token"] as? String), expiry)
    }

    private static func updateCredentials(_ credentials: Credentials, url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        root["access_token"] = credentials.accessToken
        root["id_token"] = credentials.idToken
        root["expiry_date"] = credentials.expiry.map { $0.timeIntervalSince1970 * 1000 }
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try updated.write(to: url, options: .atomic)
    }

    private static func oauthClient() -> (id: String, secret: String)? {
        let environment = ProcessInfo.processInfo.environment
        if let id = clean(environment["GEMINI_OAUTH_CLIENT_ID"]),
           let secret = clean(environment["GEMINI_OAUTH_CLIENT_SECRET"]) { return (id, secret) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            clean(environment["GEMINI_OAUTH2_JS_PATH"]),
            "/opt/homebrew/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "\(home)/.npm-global/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ].compactMap { $0 }
        if let binary = resolveGeminiBinary(environment: environment) {
            let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
            let binDirectory = (resolved as NSString).deletingLastPathComponent
            let baseDirectory = (binDirectory as NSString).deletingLastPathComponent
            let relative = "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
            candidates += [
                "\(baseDirectory)/libexec/lib/\(relative)",
                "\(baseDirectory)/lib/\(relative)",
                "\(baseDirectory)/share/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                "\(baseDirectory)/../gemini-cli-core/dist/src/code_assist/oauth2.js",
                "\(baseDirectory)/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            ]
            if let packageRoot = findPackageRoot(startingAt: resolved) {
                candidates += oauthCandidates(packageRoot: packageRoot)
            }
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let optRoot = "\(prefix)/opt/gemini-cli"
            candidates += oauthCandidates(packageRoot: optRoot)
            let cellar = "\(prefix)/Cellar/gemini-cli"
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
                for version in versions.sorted() {
                    candidates += oauthCandidates(packageRoot: "\(cellar)/\(version)")
                }
            }
        }
        var visited = Set<String>()
        for path in candidates {
            guard visited.insert(path).inserted else { continue }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  let id = capture(#"(?:const|let|var)?\s*OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#, content),
                  let secret = capture(#"(?:const|let|var)?\s*OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#, content)
            else { continue }
            return (id, secret)
        }
        return nil
    }

    private static func resolveGeminiBinary(environment: [String: String]) -> String? {
        if let configured = clean(environment["GEMINI_CLI_PATH"]),
           FileManager.default.isExecutableFile(atPath: configured) { return configured }
        let path = environment["PATH"] ?? ""
        let pathCandidates = path.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "." : String($0) }
            .map { URL(fileURLWithPath: $0).appending(path: "gemini").path }
        return (pathCandidates + [
            "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin/gemini",
        ]).first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func findPackageRoot(startingAt path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue { current.deleteLastPathComponent() }
        for _ in 0...8 {
            let package = current.appending(path: "package.json")
            if let data = try? Data(contentsOf: package),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["name"] as? String == "@google/gemini-cli" { return current.path }
            for subpath in [
                "lib/node_modules/@google/gemini-cli/package.json",
                "libexec/lib/node_modules/@google/gemini-cli/package.json",
            ] {
                let nested = current.appending(path: subpath)
                if let data = try? Data(contentsOf: nested),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   root["name"] as? String == "@google/gemini-cli" {
                    return nested.deletingLastPathComponent().path
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func oauthCandidates(packageRoot: String) -> [String] {
        [
            "\(packageRoot)/dist/src/code_assist/oauth2.js",
            "\(packageRoot)/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "\(packageRoot)/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
        guard http.statusCode == 200 else {
            if let text = String(data: data, encoding: .utf8), isConsumerDeprecation(text) {
                throw UsageCollectionError.unreadableResponse
            }
            throw UsageCollectionError.requestFailed(http.statusCode)
        }
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func clean(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = clean(value as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
