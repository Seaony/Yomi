import Foundation
import Security
import Combine

enum ProviderPreferencesError: LocalizedError {
    case unreadableConfiguration
    case unreadableCredential

    var errorDescription: String? {
        switch self {
        case .unreadableConfiguration:
            AppLocalization.text("已保存的 Provider 配置无法读取，原数据已保留", "Saved provider configuration could not be read. The original data has been preserved.")
        case .unreadableCredential:
            AppLocalization.text("无法读取已保存的凭据", "The saved credential could not be read")
        }
    }
}

@MainActor
final class ProviderPreferences: ObservableObject {
    static let shared = ProviderPreferences()

    @Published private(set) var configurations: [ProviderConfiguration]
    let usageInvalidated = PassthroughSubject<ProviderID, Never>()

    private let defaults: UserDefaults
    private let storageKey = "providers.v1"
    private let configurationLoaded: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let saved: [ProviderConfiguration]
        if defaults.object(forKey: storageKey) != nil {
            if let data = defaults.data(forKey: storageKey),
               let decoded = try? JSONDecoder().decode([ProviderConfiguration].self, from: data) {
                saved = decoded
                configurationLoaded = true
            } else {
                saved = []
                configurationLoaded = false
            }
        } else {
            saved = []
            configurationLoaded = true
        }

        let savedByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        configurations = ProviderCatalog.all.map { savedByID[$0.id] ?? ProviderConfiguration(descriptor: $0) }
    }

    func configuration(for id: ProviderID) -> ProviderConfiguration {
        configurations.first(where: { $0.id == id })
            ?? ProviderConfiguration(descriptor: ProviderCatalog.byID[id]!)
    }

    func update(_ configuration: ProviderConfiguration) {
        guard configurationLoaded,
              let index = configurations.firstIndex(where: { $0.id == configuration.id }) else { return }
        let previous = configurations[index]
        configurations[index] = configuration
        persist()
        if previous.source != configuration.source || previous.endpoint != configuration.endpoint
            || previous.command != configuration.command || previous.account != configuration.account {
            invalidateUsage(for: configuration.id)
        }
    }

    func setEnabled(_ enabled: Bool, for id: ProviderID) {
        guard configurationLoaded,
              let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].isEnabled = enabled
        persist()
    }

    nonisolated func secret(for id: ProviderID) -> String {
        (try? SecretVault.read(account: id.rawValue)) ?? ""
    }

    func setSecret(_ secret: String, for id: ProviderID) throws {
        try validateConfiguration()
        guard try (SecretVault.read(account: id.rawValue) ?? "") != secret else { return }
        if secret.isEmpty {
            try SecretVault.delete(account: id.rawValue)
        } else {
            try SecretVault.write(secret, account: id.rawValue)
        }
        invalidateUsage(for: id)
    }

    nonisolated func auxiliarySecret(for id: ProviderID, key: String) -> String {
        (try? SecretVault.read(account: "\(id.rawValue).\(key)")) ?? ""
    }

    func setAuxiliarySecret(
        _ secret: String, for id: ProviderID, key: String,
        invalidatesUsage: Bool = true, expectedRevision: Int? = nil
    ) throws {
        if let expectedRevision, expectedRevision != usageRevision(for: id) { return }
        try validateConfiguration()
        let account = "\(id.rawValue).\(key)"
        guard try (SecretVault.read(account: account) ?? "") != secret else { return }
        if secret.isEmpty {
            try SecretVault.delete(account: account)
        } else {
            try SecretVault.write(secret, account: account)
        }
        if invalidatesUsage { invalidateUsage(for: id) }
    }

    nonisolated func editableSecret(for id: ProviderID, key: String? = nil) throws -> String {
        try SecretVault.read(account: key.map { "\(id.rawValue).\($0)" } ?? id.rawValue) ?? ""
    }

    func validateConfiguration() throws {
        guard configurationLoaded else { throw ProviderPreferencesError.unreadableConfiguration }
    }

    func usageRevision(for id: ProviderID) -> Int {
        defaults.integer(forKey: "usage-revision.\(id.rawValue)")
    }

    private func invalidateUsage(for id: ProviderID) {
        defaults.set(usageRevision(for: id) + 1, forKey: "usage-revision.\(id.rawValue)")
        usageInvalidated.send(id)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private nonisolated enum SecretVault {
    private static let service = "com.seaony.Yomi.providers"

    static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderPreferencesError.unreadableCredential
        }
        return value
    }

    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            try check(SecItemAdd(addition as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
