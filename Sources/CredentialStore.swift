import Foundation

/// Small `Codable` bag holding every cloud credential in one record.
///
/// Kept as a separate type so the encoding is testable without touching the
/// real filesystem or Keychain.
struct CredentialValues: Codable, Equatable {
    private(set) var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    var isEmpty: Bool { values.isEmpty }

    func value(for account: String) -> String? { values[account] }

    mutating func set(_ value: String, for account: String) { values[account] = value }

    mutating func remove(_ account: String) { values.removeValue(forKey: account) }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> CredentialValues? {
        if let store = try? JSONDecoder().decode(CredentialValues.self, from: data) { return store }
        // Tolerate a bare dictionary so a hand-edited or future-shaped payload
        // still loads rather than forcing the user to pair the Mac again.
        if let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return CredentialValues(values: raw)
        }
        return nil
    }
}

/// Where the cloud device token, signing secret and device ID live.
///
/// **Why this is a file and not the Keychain.** Every Keychain item carries a
/// partition list naming the code allowed to read it without prompting. Code
/// signed by an Apple-issued certificate partitions as `teamid:<TEAM>`, which is
/// stable for the life of the certificate. This app is signed with a self-signed
/// certificate and has no team, so macOS falls back to `cdhash:<hash>` — which
/// changes on *every build*. The result was an authorization prompt after every
/// update, and "Always Allow" never stuck because it appends one more dead
/// cdhash rather than generalising. An explicit ACL does not override this; that
/// was tried and measured in v0.3.5.
///
/// The trade, stated plainly: the token now sits in a `0600` file rather than
/// encrypted at rest, so any process running as this user can read it without a
/// dialog. It is a per-device upload credential — it can push this Mac's counts
/// and read what this account has already synced, nothing more. Signing with a
/// Developer ID certificate would make the Keychain viable again; see
/// `scripts/keychain-partitions.sh`.
enum CredentialStore {
    private static let lock = NSLock()
    private static var cache: CredentialValues?

    /// Whether the first load has happened. Until it has, reading can still cost the one-time
    /// Keychain migration prompt, which blocks the calling thread until the user answers.
    static var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache != nil
    }

    /// Perform the first load off the main thread.
    ///
    /// On machines upgrading from a Keychain build the first read runs `migrateFromKeychainLocked`,
    /// which blocks inside `SecItemCopyMatching` until SecurityAgent is answered. Doing that on the
    /// main thread froze the whole app — the menu-bar item never appeared, so the counter looked
    /// dead until the dialog was dismissed. Load in the background and let main-thread callers use
    /// `cached(_:)` until it lands.
    static func warm(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock()
            _ = loadLocked()
            lock.unlock()
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Non-blocking read: the value if the store is already loaded, otherwise nil. Main-thread
    /// callers must use this rather than `get`, which can block on the migration prompt.
    static func cached(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.value(for: account)
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().value(for: account)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = loadLocked()
        values.set(value, for: account)
        return writeLocked(values)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = loadLocked()
        guard values.value(for: account) != nil else { return true }
        values.remove(account)
        return writeLocked(values)
    }

    /// `~/Library/Application Support/TypingStats/credentials.json`, beside the
    /// existing sync data. Dev builds keep their own folder, as elsewhere.
    static var fileURL: URL {
        let folderName = isDevBuild ? "TypingStats-Dev" : "TypingStats"
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    // MARK: - Internals (call with `lock` held)

    private static func loadLocked() -> CredentialValues {
        if let cache { return cache }
        let values = readFile() ?? migrateFromKeychainLocked()
        cache = values
        return values
    }

    private static func readFile() -> CredentialValues? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return CredentialValues.decode(data)
    }

    /// One-time move off the Keychain. Costs a final authorization prompt on
    /// machines that still hold the old items, then never again. The Keychain
    /// copy is removed only once the file is safely on disk.
    private static func migrateFromKeychainLocked() -> CredentialValues {
        let (values, refused) = LegacyKeychain.readAll()
        guard !values.isEmpty else { return values }
        // A refused prompt means some values are unknown; writing a partial file
        // would strand the rest, so leave everything and retry on a later launch.
        guard !refused, writeLocked(values) else { return values }
        LegacyKeychain.deleteAll()
        return values
    }

    private static func writeLocked(_ values: CredentialValues) -> Bool {
        guard let data = values.encoded() else { return false }
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Write to a sibling and rename, so an interrupted write cannot truncate
        // a working credential file. Permissions are set before the value lands.
        let temporary = directory.appendingPathComponent("credentials.json.tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        // replaceItemAt can carry over the replaced file's attributes.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cache = values
        return true
    }
}
