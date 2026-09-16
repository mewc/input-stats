import Foundation
import Security

/// Keychain storage for the cloud device token, signing secret and device ID.
///
/// Two properties matter here, both learned the hard way:
///
/// 1. **One item, not four.** The app is signed with a self-signed certificate
///    that chains to no trusted root, so macOS cannot pin the Keychain ACL to a
///    stable designated requirement and pins the binary hash instead. Every new
///    build invalidates it and the user is asked to authorize again — once per
///    item. Keeping a single item makes that one prompt instead of four.
/// 2. **Read once per launch.** `isConnected` alone used to hit the Keychain
///    twice, and it is consulted on every menu rebuild and every sync tick, so a
///    single stale ACL turned into a prompt storm. Values are cached in memory
///    for the life of the process; writes and deletes keep the cache coherent.
enum Keychain {
    // Keep dev sign-ins from overwriting the production app's credentials.
    private static var service: String {
        isDevBuild ? "com.mewc.input-stats.cloud.dev" : "com.mewc.input-stats.cloud"
    }

    /// Account name of the consolidated item.
    private static let storeAccount = "cloudCredentials"

    /// Items written before consolidation, migrated on first access.
    private static let legacyAccounts = [
        "deviceToken", "signingSecret", "serverDeviceID", "pendingPairingVerifier",
    ]

    /// Build that last re-anchored the Keychain ACL.
    private static let aclBuildKey = "keychainACLBuild"

    private static let lock = NSLock()
    private static var cache: CredentialStore?
    private static var loaded = false

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var store = loadLocked()
        store.set(value, for: account)
        return writeLocked(store)
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().value(for: account)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var store = loadLocked()
        guard store.value(for: account) != nil else { return true }
        store.remove(account)
        return writeLocked(store)
    }

    // MARK: - Internals (call with `lock` held)

    private static func loadLocked() -> CredentialStore {
        if let cache, loaded { return cache }
        let result = readItem(storeAccount)
        if let store = result.data.flatMap(CredentialStore.decode) {
            cache = store
            loaded = true
            rewriteAfterUpgradeLocked(store)
            return store
        }
        // A denied or impossible prompt is not the same as "no credentials". If
        // we cached that, the app would report itself signed out for the rest of
        // the session and invite the user to pair an already-paired Mac.
        if result.wasRefused { return CredentialStore() }

        let (migrated, refused) = migrateLegacyLocked()
        guard !refused else { return migrated }
        cache = migrated
        loaded = true
        return migrated
    }

    /// Rewrites the item once per build. Installs created before the
    /// prompt-free access policy still carry a binary-pinned ACL, so the first
    /// read on a new build costs one prompt; rewriting then replaces that ACL
    /// with the app-agnostic one and no further prompt appears.
    private static func rewriteAfterUpgradeLocked(_ store: CredentialStore) {
        guard !store.isEmpty else { return }
        let defaults = UserDefaults.standard
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        guard defaults.string(forKey: aclBuildKey) != build else { return }
        guard writeItem(store) else { return }
        defaults.set(build, forKey: aclBuildKey)
    }

    /// Reads the pre-consolidation items once, folds them into a single item and
    /// removes the originals. Costs one prompt per surviving legacy item, once.
    private static func migrateLegacyLocked() -> (store: CredentialStore, refused: Bool) {
        var store = CredentialStore()
        var found: [String] = []
        var refused = false
        for account in legacyAccounts {
            let result = readItem(account)
            if result.wasRefused { refused = true; continue }
            guard let data = result.data, let value = String(data: data, encoding: .utf8) else { continue }
            store.set(value, for: account)
            found.append(account)
        }
        guard !found.isEmpty else { return (store, refused) }
        // A refused read leaves some values unknown. Writing now would persist a
        // partial set and, because the consolidated item would then exist, never
        // retry — stranding the rest in items nothing reads. Leave everything as
        // it is and migrate on a later launch, when the prompt can be approved.
        guard !refused else { return (store, true) }
        // Drop the originals only once the new item is safely written, so a
        // failed write can never leave the user without credentials.
        guard writeItem(store) else { return (store, false) }
        for account in found { SecItemDelete(query(for: account) as CFDictionary) }
        return (store, false)
    }

    private static func writeLocked(_ store: CredentialStore) -> Bool {
        guard writeItem(store) else { return false }
        cache = store
        loaded = true
        return true
    }

    /// Access policy attached to the item.
    ///
    /// Without one, macOS pins the ACL to the exact binary that created the
    /// item. The app is signed with a self-signed certificate that chains to no
    /// trusted root, so that pin cannot survive a rebuild and every update
    /// costs the user an authorization prompt. Creating the access with a null
    /// trusted-application list means "any application", which removes the
    /// prompt for good.
    ///
    /// The trade is deliberate: any process running as this user can now read
    /// the item without a dialog, the same exposure as a file in the user's
    /// home directory. It still sits encrypted at rest in the login keychain,
    /// and the value is a device token that can only upload this Mac's counts.
    ///
    /// `SecAccessCreate` is deprecated alongside SecKeychain but remains the
    /// only way to express this for a file-based keychain item; the data
    /// protection keychain would need a Team ID this app does not have.
    private static func itemAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Input Stats" as CFString, nil, &access) == errSecSuccess else { return nil }
        return access
    }

    private static func writeItem(_ store: CredentialStore) -> Bool {
        guard let data = store.encoded() else { return false }
        // Delete first so the ACL is regenerated for the binary doing the write.
        // SecItemUpdate keeps the original ACL, which is what left upgraded
        // installs prompting forever.
        SecItemDelete(query(for: storeAccount) as CFDictionary)
        var attrs = query(for: storeAccount)
        attrs[kSecValueData as String] = data
        if let access = itemAccess() {
            // kSecAttrAccess and kSecAttrAccessible are mutually exclusive: the
            // former is the file-based keychain's ACL, the latter belongs to the
            // data protection keychain.
            attrs[kSecAttrAccess as String] = access
        } else {
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// `wasRefused` separates "the user dismissed the authorization prompt, or
    /// one could not be shown" from "there is no such item", which callers must
    /// not confuse: only the latter means the Mac is unpaired.
    private static func readItem(_ account: String) -> (data: Data?, wasRefused: Bool) {
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
