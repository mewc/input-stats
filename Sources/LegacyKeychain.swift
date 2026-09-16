import Foundation
import Security

/// Read-and-retire access to the Keychain items used before v0.3.6.
///
/// Nothing writes here any more: credentials live in a file (see
/// `CredentialStore`). This exists only so an existing install keeps its pairing
/// instead of being asked to link the Mac again.
enum LegacyKeychain {
    private static var service: String {
        isDevBuild ? "com.mewc.input-stats.cloud.dev" : "com.mewc.input-stats.cloud"
    }

    /// v0.3.3+ consolidated every value into one item; older installs have one
    /// item per value. Both shapes are read so either can be migrated.
    private static let consolidatedAccount = "cloudCredentials"
    private static let perValueAccounts = [
        "deviceToken", "signingSecret", "serverDeviceID", "pendingPairingVerifier",
    ]

    /// `refused` distinguishes a dismissed authorization prompt from "nothing
    /// stored": only the latter means this Mac was never paired.
    static func readAll() -> (values: CredentialValues, refused: Bool) {
        let consolidated = read(consolidatedAccount)
        if let values = consolidated.data.flatMap(CredentialValues.decode), !values.isEmpty {
            return (values, false)
        }
        var values = CredentialValues()
        var refused = consolidated.refused
        for account in perValueAccounts {
            let result = read(account)
            if result.refused { refused = true; continue }
            guard let data = result.data, let value = String(data: data, encoding: .utf8) else { continue }
            values.set(value, for: account)
        }
        return (values, refused)
    }

    static func deleteAll() {
        for account in [consolidatedAccount] + perValueAccounts {
            SecItemDelete(query(for: account) as CFDictionary)
        }
    }

    private static func read(_ account: String) -> (data: Data?, refused: Bool) {
        var q = query(for: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess { return (out as? Data, false) }
        let refused = status == errSecUserCanceled
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecInteractionRequired
        return (nil, refused)
    }

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
