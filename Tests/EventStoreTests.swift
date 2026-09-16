import Foundation

let isDevBuild = true

@main
struct EventStoreTests {
    static func main() {
        foldsEveryNumericKindAndApp()
        sortsMinutesAndApps()
        ignoresUnknownLegacyKinds()
        preservesTimezoneOffset()
        emptyRowsStayEmpty()
        subsetKindsDoNotInflateCloudTotals()
        classifiesKeyCodes()
        countsModifierPressesNotReleases()
        deviceKeysMergeWiredAndWirelessModes()
        ratesUseActiveMinutesOnly()
        shippedKindRawValuesAreStable()
        displayIdentityIsStableAndNamed()
        layoutKeysFallBackToTheirIdentifier()
        splitsMinutesByDeviceClass()
        classifiesDeviceRowsIntoCloudCategories()
        print("InputStats event-store tests: 15 passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func foldsEveryNumericKindAndApp() {
        let buckets = EventStore.foldMinuteRows([
            row(120, .key, "com.apple.Terminal", 10),
            row(120, .key, "com.apple.Safari", 5),
            row(120, .click, "ignored", 2),
            row(120, .rightClick, "ignored", 3),
            row(120, .otherClick, "ignored", 4),
            row(120, .scroll, "ignored", 6),
            row(120, .move, "ignored", 700),
        ]) { _ in 600 }
        expect(buckets.count == 1, "minute rows split unexpectedly")
        let bucket = buckets[0]
        expect(bucket.keys == 15, "key total changed")
        expect(bucket.clicksLeft == 2 && bucket.clicksRight == 3 && bucket.clicksOther == 4, "click types changed")
        expect(bucket.scrollTicks == 6 && bucket.pointerDistance == 700, "mouse totals changed")
        expect(bucket.apps.map(\.bundleID) == ["com.apple.Safari", "com.apple.Terminal"], "apps are not deterministic")
    }

    private static func sortsMinutesAndApps() {
        let buckets = EventStore.foldMinuteRows([
            row(180, .key, "z.app", 1), row(120, .key, "a.app", 2),
        ]) { _ in 0 }
        expect(buckets.map { Int($0.startedAt.timeIntervalSince1970) } == [120, 180], "minutes are not ordered")
    }

    private static func ignoresUnknownLegacyKinds() {
        let buckets = EventStore.foldMinuteRows([
            .init(minute: 120, kind: 99, app: "unknown", value: 100),
            row(120, .key, "known", 1),
        ]) { _ in 0 }
        expect(buckets[0].keys == 1, "unknown kind polluted totals")
    }

    private static func preservesTimezoneOffset() {
        let buckets = EventStore.foldMinuteRows([row(120, .key, "app", 1)]) { _ in -300 }
        expect(buckets[0].utcOffsetMinutes == -300, "timezone offset changed")
    }

    private static func emptyRowsStayEmpty() {
        expect(EventStore.foldMinuteRows([]) { _ in 0 }.isEmpty, "empty input created a bucket")
    }

    /// Repeats/shortcuts/composition are overlays of `.key`; folding them into the cloud payload
    /// would double-count keystrokes.
    private static func subsetKindsDoNotInflateCloudTotals() {
        let buckets = EventStore.foldMinuteRows([
            row(120, .key, "app", 10),
            row(120, .keyRepeat, "app", 4),
            row(120, .keyShortcut, "app", 2),
            row(120, .keyLetter, "app", 8),
            row(120, .modifier, "app", 3),
            row(120, .click, "app", 5),
            row(120, .doubleClick, "app", 1),
            row(120, .scroll, "app", 6),
            row(120, .scrollMomentum, "app", 2),
            row(120, .move, "app", 100),
            row(120, .drag, "app", 40),
            row(120, .gesture, "app", 1),
        ]) { _ in 0 }
        let b = buckets[0]
        expect(b.keys == 10 && b.clicksLeft == 5 && b.scrollTicks == 6 && b.pointerDistance == 100,
               "subset kinds leaked into cloud totals")
    }

    private static func classifiesKeyCodes() {
        expect(KeyClass.classify(keyCode: 0) == .letter, "kVK_ANSI_A is a letter")
        expect(KeyClass.classify(keyCode: 46) == .letter, "kVK_ANSI_M is a letter")
        expect(KeyClass.classify(keyCode: 18) == .digit, "kVK_ANSI_1 is a digit")
        expect(KeyClass.classify(keyCode: 82) == .digit, "keypad 0 is a digit")
        expect(KeyClass.classify(keyCode: 49) == .space, "space")
        expect(KeyClass.classify(keyCode: 36) == .enter && KeyClass.classify(keyCode: 76) == .enter, "return / keypad enter")
        expect(KeyClass.classify(keyCode: 51) == .backspace && KeyClass.classify(keyCode: 117) == .backspace, "delete keys")
        expect(KeyClass.classify(keyCode: 123) == .navigation && KeyClass.classify(keyCode: 48) == .navigation, "arrows / tab")
        expect(KeyClass.classify(keyCode: 53) == .other && KeyClass.classify(keyCode: 122) == .other, "esc / F1 are other")
        expect(KeyClass.classify(keyCode: 43) == .other, "comma is other")
        expect(Set(KeyClass.allCases.map(\.kind)) == Set(EventKind.keyCompositionKinds), "composition kinds drifted")
    }

    private static func countsModifierPressesNotReleases() {
        var d = ModifierPressDetector()
        let shift: UInt64 = 0x0002_0000, cmd: UInt64 = 0x0010_0000, capsLock: UInt64 = 0x0001_0000
        expect(d.pressesOnUpdate(flags: shift) == 1, "shift press")
        expect(d.pressesOnUpdate(flags: shift | cmd) == 1, "cmd added while shift held")
        expect(d.pressesOnUpdate(flags: cmd) == 0, "shift release is not a press")
        expect(d.pressesOnUpdate(flags: 0) == 0, "cmd release is not a press")
        expect(d.pressesOnUpdate(flags: capsLock) == 0, "caps lock is ignored")
        expect(d.pressesOnUpdate(flags: capsLock | shift | cmd) == 2, "two modifiers at once")
    }

    private static func deviceKeysMergeWiredAndWirelessModes() {
        let wired = InputDeviceDescriptor(role: .pointer, name: "Razer DeathAdder V2 Pro", vendorID: 5426,
                                          productID: 125, transport: "USB", isBuiltIn: false, isSoftware: false)
        let dongle = InputDeviceDescriptor(role: .pointer, name: "Razer DeathAdder V2 Pro ", vendorID: 5426,
                                           productID: 124, transport: "USB", isBuiltIn: false, isSoftware: false)
        expect(wired.key == dongle.key, "same mouse on a different PID should be one device")
        let builtinKB = InputDeviceDescriptor(role: .keyboard, name: "Apple Internal Keyboard / Trackpad", vendorID: 0,
                                              productID: 0, transport: "FIFO", isBuiltIn: true, isSoftware: false)
        let builtinTP = InputDeviceDescriptor(role: .pointer, name: "Apple Internal Keyboard / Trackpad", vendorID: 0,
                                              productID: 0, transport: "FIFO", isBuiltIn: true, isSoftware: false)
        expect(builtinKB.key != builtinTP.key, "built-in keyboard and trackpad share a product string but differ by role")
        let kb = InputDevice(id: 1, key: builtinKB.key, role: .keyboard, name: builtinKB.name, vendorID: 0, productID: 0,
                             transport: "FIFO", isBuiltIn: true, isSoftware: false)
        let tp = InputDevice(id: 2, key: builtinTP.key, role: .pointer, name: builtinTP.name, vendorID: 0, productID: 0,
                             transport: "FIFO", isBuiltIn: true, isSoftware: false)
        expect(kb.displayName == "Built-in Keyboard" && tp.displayName == "Built-in Trackpad", "built-in display names")
        expect(InputDevice.unattributed.displayName == "Unattributed", "legacy rows label")
        expect(InputDeviceDescriptor.software(role: .keyboard).key != InputDeviceDescriptor.software(role: .pointer).key,
               "software devices are per role")
    }

    private static func ratesUseActiveMinutesOnly() {
        let stats = EventStore.rateStats(minuteTotals: [120, 0, 300, 0, 0, 60])
        expect(stats.activeMinutes == 3, "idle minutes counted as active")
        expect(stats.peakPerMinute == 300, "peak minute wrong")
        expect(stats.total == 480, "total wrong")
        expect(stats.perActiveMinute == 160, "average should divide by active minutes only")
        expect(EventStore.rateStats(minuteTotals: []).perActiveMinute == 0, "empty window must not divide by zero")
    }

    /// Raw values are persisted in SQLite and in shipped databases — renumbering orphans user data.
    private static func shippedKindRawValuesAreStable() {
        let expected: [(EventKind, Int)] = [
            (.key, 0), (.click, 1), (.scroll, 2), (.rightClick, 3), (.move, 4), (.otherClick, 5),
            (.keyRepeat, 6), (.keySynthetic, 7), (.keyShortcut, 8), (.modifier, 9),
            (.keyLetter, 10), (.keyDigit, 11), (.keySpace, 12), (.keyEnter, 13),
            (.keyBackspace, 14), (.keyNavigation, 15), (.keyOther, 16),
            (.doubleClick, 17), (.drag, 18), (.scrollMomentum, 19), (.gesture, 20),
        ]
        for (kind, raw) in expected {
            expect(kind.rawValue == raw, "\(kind.label) raw value moved from \(raw) to \(kind.rawValue)")
        }
        expect(Set(EventKind.allCases.map(\.rawValue)).count == EventKind.allCases.count, "duplicate raw values")
    }

    private static func displayIdentityIsStableAndNamed() {
        let external = DisplayTarget(id: 1, key: "UUID-A", name: "LG HDR WQHD", isBuiltIn: false)
        expect(external.displayName == "LG HDR WQHD", "named screens keep their name")
        let unnamedBuiltIn = DisplayTarget(id: 2, key: "UUID-B", name: "", isBuiltIn: true)
        expect(unnamedBuiltIn.displayName == "Built-in Display", "unnamed built-in screen label")
        let unnamedExternal = DisplayTarget(id: 3, key: "UUID-C", name: "", isBuiltIn: false)
        expect(unnamedExternal.displayName == "External Display", "unnamed external screen label")
        expect(DisplayTarget.unknown.displayName == "Unknown screen", "rows without a screen")
        expect(DisplayTarget.unknownID == 0, "unknown screen must stay the zero default")
    }

    private static func layoutKeysFallBackToTheirIdentifier() {
        let named = LayoutKey(id: "com.apple.keylayout.Australian", name: "Australian")
        expect(named.displayName == "Australian", "named layout should show its localized name")
        let unnamed = LayoutKey(id: "com.apple.keylayout.US", name: "")
        expect(unnamed.displayName == "com.apple.keylayout.US", "unnamed layout falls back to its id")
        expect(named != unnamed, "layouts are distinguished by id")
        expect(EventStore.dayString(for: Date(timeIntervalSince1970: 0)).count == 10, "day keys are yyyy-MM-dd")
    }

    /// The cloud rejects a split whose totals exceed the minute, so the fold must partition
    /// exactly — and must never leak anything but the four coarse classes.
    private static func splitsMinutesByDeviceClass() {
        let buckets = EventStore.foldMinuteRows([
            row(120, .key, "app", 10, "builtin"),
            row(120, .key, "app", 20, "external"),
            row(120, .click, "app", 3, "external"),
            row(120, .rightClick, "app", 1, "external"),
            row(120, .scroll, "app", 5, "external"),
            row(120, .move, "app", 900, "external"),
            row(120, .keyRepeat, "app", 4, "builtin"),   // overlay kind: must not be counted
        ]) { _ in 0 }
        let bucket = buckets[0]
        expect(bucket.keys == 30, "bucket keys changed")
        let split = Dictionary(uniqueKeysWithValues: bucket.inputs.map { ($0.source, $0) })
        expect(split.count == 2, "expected exactly the two contributing classes")
        expect(split["builtin"]?.keys == 10 && split["external"]?.keys == 20, "keys split wrong")
        expect(split["external"]?.clicks == 4, "clicks should sum every button for the class")
        expect(split["external"]?.scrollTicks == 5 && split["external"]?.pointerDistance == 900, "mouse split wrong")
        let keyTotal = bucket.inputs.reduce(0) { $0 + $1.keys }
        let clickTotal = bucket.inputs.reduce(0) { $0 + $1.clicks }
        expect(keyTotal <= bucket.keys, "split keys exceed the minute")
        expect(clickTotal <= bucket.clicksLeft + bucket.clicksRight + bucket.clicksOther, "split clicks exceed the minute")
        expect(bucket.inputs.map(\.source) == ["builtin", "external"], "split is not deterministically ordered")
    }

    private static func classifiesDeviceRowsIntoCloudCategories() {
        expect(InputSourceClass.classify(isSoftware: false, isBuiltIn: true, isAttributed: true) == "builtin", "built-in")
        expect(InputSourceClass.classify(isSoftware: false, isBuiltIn: false, isAttributed: true) == "external", "external")
        expect(InputSourceClass.classify(isSoftware: true, isBuiltIn: false, isAttributed: true) == "virtual", "software")
        expect(InputSourceClass.classify(isSoftware: true, isBuiltIn: true, isAttributed: false) == "unknown", "legacy rows")
    }

    private static func row(_ minute: Int,
                            _ kind: EventKind,
                            _ app: String,
                            _ value: Int,
                            _ source: String = InputSourceClass.unknown) -> EventStore.MinuteRow {
        .init(minute: minute, kind: kind.rawValue, app: app, value: value, source: source)
    }
}
