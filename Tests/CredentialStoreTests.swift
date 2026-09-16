import Foundation

// Coverage for the credential bag and for the on-disk store. The legacy
// Keychain path is not exercised here: touching the real one would raise an
// authorization prompt mid-test.
@main
struct CredentialStoreTests {
    static func main() {
        storeHoldsReadsAndOverwritesValues()
        removeClearsOnlyTheNamedValue()
        roundTripsThroughJson()
        decodesABareDictionary()
        rejectsGarbage()
        preservesAwkwardValues()
        writesA0600FileAndReadsItBack()
        print("InputStats credential-store tests: 8 passed")
    }

    static func storeHoldsReadsAndOverwritesValues() {
        var store = CredentialValues()
        expect(store.isEmpty, "a new store is empty")
        expect(store.value(for: "deviceToken") == nil, "missing values read as nil")

        store.set("tok", for: "deviceToken")
        store.set("sec", for: "signingSecret")
        expect(!store.isEmpty, "store holds values")
        expect(store.value(for: "deviceToken") == "tok", "reads back what was set")

        store.set("tok2", for: "deviceToken")
        expect(store.value(for: "deviceToken") == "tok2", "set overwrites")
        expect(store.value(for: "signingSecret") == "sec", "overwrite leaves the others")
    }

    static func removeClearsOnlyTheNamedValue() {
        var store = CredentialValues()
        store.set("tok", for: "deviceToken")
        store.set("sec", for: "signingSecret")
        store.remove("deviceToken")
        expect(store.value(for: "deviceToken") == nil, "remove clears one value")
        expect(store.value(for: "signingSecret") == "sec", "remove leaves the others")
    }

    /// This shape is what actually lands in the Keychain item.
    static func roundTripsThroughJson() {
        var full = CredentialValues()
        full.set("a", for: "deviceToken")
        full.set("b", for: "signingSecret")
        full.set("c", for: "serverDeviceID")
        guard let data = full.encoded() else { return expect(false, "encodes") }
        expect(CredentialValues.decode(data) == full, "round-trips through JSON")
    }

    /// A future or hand-edited payload must still load rather than forcing the
    /// user to pair the Mac again.
    static func decodesABareDictionary() {
        let bare = Data(#"{"deviceToken":"x","signingSecret":"y"}"#.utf8)
        expect(CredentialValues.decode(bare)?.value(for: "deviceToken") == "x", "decodes a bare dictionary")
    }

    static func rejectsGarbage() {
        expect(CredentialValues.decode(Data("not json".utf8)) == nil, "rejects garbage")
    }

    static func preservesAwkwardValues() {
        var odd = CredentialValues()
        let awkward = "a\"b\nc\u{1F511}"
        odd.set(awkward, for: "signingSecret")
        guard let data = odd.encoded() else { return expect(false, "encodes awkward values") }
        expect(CredentialValues.decode(data)?.value(for: "signingSecret") == awkward, "preserves awkward values")
    }

    /// The file replaces the Keychain, so its permissions are the protection.
    static func writesA0600FileAndReadsItBack() {
        let url = CredentialStore.fileURL
        let existed = FileManager.default.fileExists(atPath: url.path)
        expect(!existed, "test refuses to run over real credentials at \(url.path)")

        expect(CredentialStore.set("tok", for: "deviceToken"), "writes a value")
        expect(CredentialStore.set("sec", for: "signingSecret"), "writes a second value")
        expect(CredentialStore.get("deviceToken") == "tok", "reads a value back")

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(mode == 0o600, "file is 0600, got \(String(mode, radix: 8))")

        let onDisk = (try? Data(contentsOf: url)).flatMap(CredentialValues.decode)
        expect(onDisk?.value(for: "signingSecret") == "sec", "file holds what was written")

        CredentialStore.delete("deviceToken")
        expect(CredentialStore.get("deviceToken") == nil, "delete clears one value")
        expect(CredentialStore.get("signingSecret") == "sec", "delete leaves the others")

        try? FileManager.default.removeItem(at: url)
    }

    static func expect(_ condition: Bool, _ label: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
            exit(1)
        }
    }
}
