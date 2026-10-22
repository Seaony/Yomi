import CryptoKit
import Foundation
import Security

nonisolated struct MagpieClaudeAccount: Sendable {
    let id: ProviderID
    let user: String

    @MainActor var descriptor: ProviderDescriptor {
        let claude = ProviderCatalog.byID[ProviderID(rawValue: "claude")]!
        return ProviderDescriptor(
            id: id, name: claude.name, shortName: claude.shortName,
            primaryLabel: claude.primaryLabel, secondaryLabel: claude.secondaryLabel,
            metricKind: claude.metricKind, preferredSources: claude.preferredSources,
            environmentKeys: [], defaultEndpoint: nil, symbol: claude.symbol,
            hue: claude.hue, defaultEnabled: true, accountName: user
        )
    }
}

nonisolated enum MagpieClaudeAccounts {
    private struct Login: Decodable {
        let id: String?
        let agent: String
        let user: String
        let plan: String?
        let hidden: String?
        let lapsed: String?
        let auth: Credentials?
        let profile: Profile?

        var account: MagpieClaudeAccount {
            let fallback = SHA256.hash(data: Data("magpie login\nclaude\n\(user.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())".utf8))
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            return MagpieClaudeAccount(
                id: ProviderID(rawValue: "claude-magpie-" + (id.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)),
                user: user
            )
        }
    }

    private struct Credentials: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct Profile: Decodable {
        let accountUuid: String?
        let organizationUuid: String?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?

        var validToken: String? {
            guard let accessToken, !accessToken.isEmpty,
                  expiresAt.map({ $0 > Date().timeIntervalSince1970 * 1000 }) ?? true else { return nil }
            return accessToken
        }
    }

    private static var loginsURL: URL {
        let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let directory = root.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return directory.appending(path: "magpie/logins.json")
    }

    private static func logins() throws -> [Login] {
        let url = loginsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // 先挑出 Claude，其他服务的凭据格式可能完全不同。
        guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
            throw UsageCollectionError.unreadableResponse
        }
        return try rows.filter { $0["agent"] as? String == "claude" }.map {
            try JSONDecoder().decode(Login.self, from: JSONSerialization.data(withJSONObject: $0))
        }.filter { ($0.hidden ?? "").isEmpty && !$0.user.isEmpty }
    }

    static func accounts() throws -> [MagpieClaudeAccount] {
        var seen = Set<ProviderID>()
        return try logins().map(\.account).filter { seen.insert($0.id).inserted }
    }

    static func credential(
        for id: ProviderID, session: URLSession, rejectedToken: String? = nil
    ) async throws -> (token: String, plan: String?) {
        guard let login = try logins().first(where: { $0.account.id == id }) else {
            throw unavailableCredential
        }
        let oauth: OAuth
        if (login.lapsed ?? "").isEmpty,
           let saved = login.auth?.claudeAiOauth,
           let token = saved.validToken, token != rejectedToken {
            oauth = saved
        } else {
            guard let current = try await currentCredential(for: login, session: session, rejectedToken: rejectedToken) else {
                throw unavailableCredential
            }
            oauth = current
        }
        guard let token = oauth.validToken else { throw unavailableCredential }
        return (token, UsageParser.displayClaudeOAuthPlan(
            subscriptionType: oauth.subscriptionType ?? login.plan,
            rateLimitTier: oauth.rateLimitTier
        ))
    }

    private static var unavailableCredential: UsageCollectionError {
        .browserAccessFailed(AppLocalization.text(
            "账号凭据不可用或已过期，请在 Magpie 中刷新或重新登录后重试",
            "The account credentials are unavailable or expired. Refresh or sign in again in Magpie, then retry."
        ))
    }

    private static func currentCredential(
        for login: Login, session: URLSession, rejectedToken: String?
    ) async throws -> OAuth? {
        guard let accountID = login.profile?.accountUuid, !accountID.isEmpty,
              let organizationID = login.profile?.organizationUuid, !organizationID.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(login.user.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let savedDirectory = loginsURL.deletingLastPathComponent().appending(path: "claude-accounts/\(hash)")
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let localDirectory = configured.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        for (directory, custom) in [(savedDirectory, true), (localDirectory, configured != nil)] {
            guard let oauth = readCredential(directory: directory, custom: custom),
                  let token = oauth.validToken, token != rejectedToken else { continue }
            // 本机可能已经切换账号，必须用凭据本身核对账号和组织。
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageCollectionError.unreadableResponse }
            if http.statusCode == 401 { continue }
            guard http.statusCode == 200 else { throw UsageCollectionError.requestFailed(http.statusCode) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageCollectionError.unreadableResponse
            }
            let account = (root["account"] as? [String: Any])?["uuid"] as? String
                ?? root["accountUuid"] as? String ?? root["account_uuid"] as? String
            let organization = (root["organization"] as? [String: Any])?["uuid"] as? String
                ?? root["organizationUuid"] as? String ?? root["organization_uuid"] as? String
            if account == accountID, organization == organizationID { return oauth }
        }
        return nil
    }

    private static func readCredential(directory: URL, custom: Bool) -> OAuth? {
        let suffix = SHA256.hash(data: Data(directory.path.precomposedStringWithCanonicalMapping.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials" + (custom ? "-\(suffix)" : ""),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return (try? JSONDecoder().decode(Credentials.self, from: data))?.claudeAiOauth
        }
        guard let data = try? Data(contentsOf: directory.appending(path: ".credentials.json")) else { return nil }
        return (try? JSONDecoder().decode(Credentials.self, from: data))?.claudeAiOauth
    }
}
