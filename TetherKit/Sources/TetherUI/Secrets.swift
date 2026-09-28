import Foundation
import Security

/// Where a host's environment values are kept: the Keychain, not the defaults file, since they're
/// often credentials (API keys, AWS profiles). Read off the main thread, just before a host connects.
protocol SecretStore: AnyObject, Sendable {
    func read(_ account: String) -> Data?
    /// Stores `data`, or removes it when nil. False when the store refused, so the caller can keep
    /// its own copy until a write succeeds.
    @discardableResult func write(_ data: Data?, for account: String) -> Bool
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

    @discardableResult func write(_ data: Data?, for account: String) -> Bool {
        guard let data else {
            let status = SecItemDelete(query(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// For tests, previews and UI tests, which keep defaults of their own and shouldn't touch the
/// Keychain: kept in those defaults, under a key apart from the rest. Defaults are safe to use from
/// any thread.
final class DefaultsSecrets: SecretStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func read(_ account: String) -> Data? { defaults.data(forKey: "tether.secret.\(account)") }
    @discardableResult func write(_ data: Data?, for account: String) -> Bool {
        defaults.set(data, forKey: "tether.secret.\(account)")
        return true
    }
}
