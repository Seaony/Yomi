import Foundation
import LocalAuthentication
import Security

nonisolated enum ZedUsageError: LocalizedError, Equatable {
    case notSignedIn
    case keychainUnavailable
    case invalidServerURL(String)
    case untrustedServerConfiguration
    case networkError(String)
    case httpError(Int)
    case unauthorized
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            AppLocalization.text(
                "尚未登录 Zed，请先在 Zed 编辑器中使用 GitHub 登录",
                "Not signed in to Zed. Sign in from the Zed editor with GitHub."
            )
        case .keychainUnavailable:
            AppLocalization.text(
                "无法读取 Zed 钥匙串凭据，请允许访问或重新登录 Zed",
                "Could not read Zed credentials from Keychain. Allow access or sign in again."
            )
        case let .invalidServerURL(value):
            AppLocalization.text("Zed 服务器地址无效：\(value)", "Invalid Zed server URL: \(value)")
        case .untrustedServerConfiguration:
            AppLocalization.text(
                "Zed 自定义服务器必须使用 HTTPS，并使用相同服务器地址保存凭据",
                "Zed custom servers must use HTTPS and store credentials under the same server URL."
            )
        case let .networkError(message):
            AppLocalization.text("Zed 云端请求失败：\(message)", "Zed cloud request failed: \(message)")
        case let .httpError(status):
            AppLocalization.text("Zed 云端返回 HTTP \(status)", "Zed cloud returned HTTP \(status)")
        case .unauthorized:
            AppLocalization.text("Zed 凭据无效或已过期", "Zed credentials are invalid or expired")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 Zed 账号数据：\(message)", "Could not parse Zed account data: \(message)")
        }
    }
}

nonisolated struct ZedCredentials: Equatable, Sendable {
    let userID: String
    let accessToken: String

    var authorizationHeader: String { "\(userID) \(accessToken)" }
}

nonisolated struct ZedClientSettings: Equatable, Sendable {
    let credentialsURL: String?
    let serverURL: String?

    var keychainServiceURL: String {
        Self.cleaned(credentialsURL) ?? Self.cleaned(serverURL) ?? ZedUsageFetcher.defaultServiceURL
    }

    var cloudAPIURL: URL? {
        let server = Self.cleaned(serverURL) ?? ZedUsageFetcher.defaultServiceURL
        let trusted = server == "https://zed.dev" || server == "https://staging.zed.dev"
        if !trusted, let credentials = Self.cleaned(credentialsURL), credentials != server { return nil }
        let base = trusted ? "https://cloud.zed.dev" : server
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url.appendingPathComponent("client/users/me")
    }

    static func load(from url: URL = ZedUsageFetcher.defaultSettingsURL) -> ZedClientSettings? {
        struct Payload: Decodable {
            let credentialsURL: String?
            let serverURL: String?

            enum CodingKeys: String, CodingKey {
                case credentialsURL = "credentials_url"
                case serverURL = "server_url"
            }
        }
        guard let data = try? Data(contentsOf: url), let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return ZedClientSettings(credentialsURL: payload.credentialsURL, serverURL: payload.serverURL)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

nonisolated enum ZedUsageLimit: Equatable, Sendable, Decodable {
    case limited(Int)
    case unlimited

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let value = try? container.decode(String.self), value == "unlimited" {
                self = .unlimited
                return
            }
            if let value = try? container.decode(Int.self) {
                self = .limited(value)
                return
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int.self, forKey: .limited) {
            self = .limited(value)
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized Zed usage limit"
        ))
    }

    private enum CodingKeys: String, CodingKey { case limited }
}

nonisolated struct ZedAuthenticatedUserResponse: Decodable, Equatable, Sendable {
    struct User: Decodable, Equatable, Sendable {
        let id: Int
        let githubLogin: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case id
            case githubLogin = "github_login"
            case name
        }
    }

    struct Plan: Decodable, Equatable, Sendable {
        struct SubscriptionPeriod: Decodable, Equatable, Sendable {
            let startedAt: Date
            let endedAt: Date

            enum CodingKeys: String, CodingKey {
                case startedAt = "started_at"
                case endedAt = "ended_at"
            }
        }

        struct CurrentUsage: Decodable, Equatable, Sendable {
            struct UsageData: Decodable, Equatable, Sendable {
                let used: Int
                let limit: ZedUsageLimit
            }

            let editPredictions: UsageData

            enum CodingKeys: String, CodingKey { case editPredictions = "edit_predictions" }
        }

        let planV3: String
        let subscriptionPeriod: SubscriptionPeriod?
        let usage: CurrentUsage
        let hasOverdueInvoices: Bool

        enum CodingKeys: String, CodingKey {
            case planV3 = "plan_v3"
            case subscriptionPeriod = "subscription_period"
            case usage
            case hasOverdueInvoices = "has_overdue_invoices"
        }
    }

    let user: User
    let plan: Plan
}

nonisolated enum ZedUsageFetcher {
    static let defaultServiceURL = "https://zed.dev"
    static let cloudAPIURL = URL(string: "https://cloud.zed.dev/client/users/me")!
    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/zed/settings.json")
    }

    static func fetch(
        session: URLSession,
        now: Date = Date(),
        settingsLoader: @Sendable () -> ZedClientSettings? = { ZedClientSettings.load() },
        credentialsLoader: @Sendable (String) throws -> ZedCredentials? = loadCredentials
    ) async throws -> ProviderUsage {
        let settings = settingsLoader()
        let serviceURL = settings?.keychainServiceURL ?? defaultServiceURL
        let endpoint: URL
        if let settings {
            guard let configuredURL = settings.cloudAPIURL else {
                let value = settings.serverURL ?? ""
                guard URL(string: value)?.scheme?.lowercased() == "https" else {
                    throw ZedUsageError.invalidServerURL(value)
                }
                throw ZedUsageError.untrustedServerConfiguration
            }
            endpoint = configuredURL
        } else {
            endpoint = cloudAPIURL
        }
        guard let credentials = try credentialsLoader(serviceURL) else { throw ZedUsageError.notSignedIn }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 18
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ZedUsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ZedUsageError.networkError("Invalid response")
        }
        switch http.statusCode {
        case 200: return providerUsage(try parse(data), now: now)
        case 401, 403: throw ZedUsageError.unauthorized
        default: throw ZedUsageError.httpError(http.statusCode)
        }
    }

    static func parse(_ data: Data) throws -> ZedAuthenticatedUserResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        do { return try decoder.decode(ZedAuthenticatedUserResponse.self, from: data) }
        catch { throw ZedUsageError.parseFailed(error.localizedDescription) }
    }

    static func providerUsage(_ response: ZedAuthenticatedUserResponse, now: Date = Date()) -> ProviderUsage {
        let edit = response.plan.usage.editPredictions
        var windows: [UsageWindow] = []
        switch edit.limit {
        case .unlimited:
            windows.append(UsageWindow(
                id: "zed-edit-predictions",
                label: "Edit predictions",
                usedFraction: 0,
                resetsAt: nil,
                detail: "Unlimited"
            ))
        case let .limited(limit) where limit > 0:
            let used = min(limit, max(0, edit.used))
            windows.append(UsageWindow(
                id: "zed-edit-predictions",
                label: "Edit predictions",
                usedFraction: Double(used) / Double(limit),
                resetsAt: nil,
                detail: "\(used) / \(limit) predictions"
            ))
        default:
            break
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "zed"),
            state: .ready,
            windows: windows,
            plan: displayPlanName(response.plan.planV3),
            details: [],
            updatedAt: now,
            message: nil
        )
    }

    static func displayPlanName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "zed_free": "Zed Free"
        case "zed_pro": "Zed Pro"
        case "zed_pro_trial": "Zed Pro Trial"
        case "zed_student": "Zed Student"
        case "zed_business": "Zed Business"
        default:
            raw.replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    static func loadCredentials(serviceURL: String) throws -> ZedCredentials? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let common: [String: Any] = [
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var internet = common
        internet[kSecClass as String] = kSecClassInternetPassword
        internet[kSecAttrServer as String] = serviceURL
        if let value = try credentials(query: internet) { return value }
        var generic = common
        generic[kSecClass as String] = kSecClassGenericPassword
        generic[kSecAttrService as String] = serviceURL
        return try credentials(query: generic)
    }

    private static func credentials(query: [String: Any]) throws -> ZedCredentials? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ZedUsageError.keychainUnavailable }
        guard let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = item[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return ZedCredentials(userID: account, accessToken: token)
    }
}
