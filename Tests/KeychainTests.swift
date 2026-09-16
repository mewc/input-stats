import Foundation

// Pure coverage for the credential bag. The Keychain itself is not exercised
// here: touching the real one would raise an authorization prompt mid-test.
@main
struct KeychainTests {
    static func main() {
        storeHoldsReadsAndOverwritesValues()
        removeClearsOnlyTheNamedValue()
        roundTripsThroughJson()
        decodesABareDictionary()
        rejectsGarbage()
        preservesAwkwardValues()
        print("InputStats keychain tests: 6 passed")
    }

    static func storeHoldsReadsAndOverwritesValues() {
        var store = CredentialStore()
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
        var store = CredentialStore()
        store.set("tok", for: "deviceToken")
        store.set("sec", for: "signingSecret")
        store.remove("deviceToken")
        expect(store.value(for: "deviceToken") == nil, "remove clears one value")
        expect(store.value(for: "signingSecret") == "sec", "remove leaves the others")
    }

    /// This shape is what actually lands in the Keychain item.
    static func roundTripsThroughJson() {
        var full = CredentialStore()
        full.set("a", for: "deviceToken")
        full.set("b", for: "signingSecret")
        full.set("c", for: "serverDeviceID")
        guard let data = full.encoded() else { return expect(false, "encodes") }
        expect(CredentialStore.decode(data) == full, "round-trips through JSON")
    }

    /// A future or hand-edited payload must still load rather than forcing the
    /// user to pair the Mac again.
    static func decodesABareDictionary() {
        let bare = Data(#"{"deviceToken":"x","signingSecret":"y"}"#.utf8)
        expect(CredentialStore.decode(bare)?.value(for: "deviceToken") == "x", "decodes a bare dictionary")
    }

    static func rejectsGarbage() {
        expect(CredentialStore.decode(Data("not json".utf8)) == nil, "rejects garbage")
    }

    static func preservesAwkwardValues() {
        var odd = CredentialStore()
        let awkward = "a\"b\nc\u{1F511}"
        odd.set(awkward, for: "signingSecret")
        guard let data = odd.encoded() else { return expect(false, "encodes awkward values") }
        expect(CredentialStore.decode(data)?.value(for: "signingSecret") == awkward, "preserves awkward values")
    }

    static func expect(_ condition: Bool, _ label: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
            exit(1)
        }
    }
}
