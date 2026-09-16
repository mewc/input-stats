import Foundation

/// Small `Codable` bag holding every cloud credential in one Keychain item.
///
/// Splitting these across four items meant four separate authorization prompts,
/// so they travel together. Kept as a separate type so the encoding is testable
/// without touching the real Keychain.
struct CredentialStore: Codable, Equatable {
    private(set) var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    var isEmpty: Bool { values.isEmpty }

    func value(for account: String) -> String? { values[account] }

    mutating func set(_ value: String, for account: String) { values[account] = value }

    mutating func remove(_ account: String) { values.removeValue(forKey: account) }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> CredentialStore? {
        if let store = try? JSONDecoder().decode(CredentialStore.self, from: data) { return store }
        // Tolerate a bare dictionary so a hand-edited or future-shaped payload
        // still loads rather than forcing the user to pair the Mac again.
        if let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return CredentialStore(values: raw)
        }
        return nil
    }
}
