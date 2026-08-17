import Foundation
import Security

/// Minimal Keychain wrapper for storing the cloud device token + signing secret.
/// Generic-password items scoped to this app; values are small strings.
enum Keychain {
    private static let service = "com.mewc.input-stats.cloud"

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        // Remove any existing item first so we can cleanly re-add.
        SecItemDelete(query(for: account) as CFDictionary)
        var attrs = query(for: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var q = query(for: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete(query(for: account) as CFDictionary) == errSecSuccess
    }

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
