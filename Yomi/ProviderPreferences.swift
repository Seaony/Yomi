import Foundation
import Security
import Combine

@MainActor
final class ProviderPreferences: ObservableObject {
    static let shared = ProviderPreferences()

    @Published private(set) var configurations: [ProviderConfiguration]

    private let defaults: UserDefaults
    private let storageKey = "providers.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let saved: [ProviderConfiguration]
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ProviderConfiguration].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }

        let savedByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        configurations = ProviderCatalog.all.map { savedByID[$0.id] ?? ProviderConfiguration(descriptor: $0) }
    }

    func configuration(for id: ProviderID) -> ProviderConfiguration {
        configurations.first(where: { $0.id == id })
            ?? ProviderConfiguration(descriptor: ProviderCatalog.byID[id]!)
    }

    func update(_ configuration: ProviderConfiguration) {
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else { return }
        configurations[index] = configuration
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: ProviderID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].isEnabled = enabled
        persist()
    }

    func secret(for id: ProviderID) -> String {
        SecretVault.read(account: id.rawValue) ?? ""
    }

    func setSecret(_ secret: String, for id: ProviderID) throws {
        if secret.isEmpty {
            try SecretVault.delete(account: id.rawValue)
        } else {
            try SecretVault.write(secret, account: id.rawValue)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private enum SecretVault {
    private static let service = "com.seaony.Yomi.providers"

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
