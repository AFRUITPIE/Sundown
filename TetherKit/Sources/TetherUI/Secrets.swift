import Foundation
import Security

/// Where a host's environment values are kept: the Keychain, not the defaults file, since they're
/// often credentials (API keys, AWS profiles).
protocol SecretStore: AnyObject {
    func read(_ account: String) -> Data?
    func write(_ data: Data?, for account: String)
}

final class KeychainSecrets: SecretStore {
    private let service = "Tether Host Environment"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data?, for account: String) {
        guard let data else {
            SecItemDelete(query(account) as CFDictionary)
            return
        }
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// For tests, previews and UI tests, which keep defaults of their own and shouldn't touch the
/// Keychain: kept in those defaults, under a key apart from the rest.
final class DefaultsSecrets: SecretStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func read(_ account: String) -> Data? { defaults.data(forKey: "tether.secret.\(account)") }
    func write(_ data: Data?, for account: String) { defaults.set(data, forKey: "tether.secret.\(account)") }
}
