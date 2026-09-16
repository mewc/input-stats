import Foundation

@main
struct SyncDataTests {
    static func main() throws {
        try legacyDailyCountDecodesWithoutResetGeneration()
        newerResetGenerationOverridesHigherStaleCount()
        countCanGrowWithinResetGeneration()
        repairsEntireConsecutiveCarryChain()
        repairsEveryDeviceAndIsIdempotent()
        doesNotRepairNonConsecutiveOrNonMatchingData()
        preservesResetGenerationAsCountAdvances()
        repairedSyncRowRejectsStaleLocalCarry()
        repairedSyncRowKeepsLivePostRepairKeys()
        try minutePayloadContainsCountsButNoInputContent()
        try minutePayloadUsesMinuteTimestampAndClickTypes()
        legacyCredentialsRefreshMissingServerDeviceIdentity()
        handoffLinkRoutesEachBrowserRedirect()
        handoffLinkExplainsEveryRejection()
        compactCountUsesAtMostThreeSignificantDigits()
        print("InputStats model tests: 15 passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func legacyDailyCountDecodesWithoutResetGeneration() throws {
        let json = #"{"count":42,"lastModified":123,"appCounts":{"app":42}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DailyCount.self, from: json)

        expect(decoded.count == 42, "legacy count changed")
        expect(decoded.resetAt == nil, "legacy row unexpectedly gained a reset generation")
    }

    private static func newerResetGenerationOverridesHigherStaleCount() {
        var local = syncData(count: 12, resetAt: 200)
        let stale = syncData(count: 5_000, resetAt: nil)

        local.merge(with: stale)

        expect(local.devices["device"]?.count(for: "2026-09-15") == 12, "stale count beat reset")
        expect(local.devices["device"]?.dailyCounts["2026-09-15"]?.resetAt == 200, "reset generation changed")
    }

    private static func countCanGrowWithinResetGeneration() {
        var local = syncData(count: 12, resetAt: 200)
        let newerCount = syncData(count: 25, resetAt: 200)

        local.merge(with: newerCount)

        expect(local.devices["device"]?.count(for: "2026-09-15") == 25, "count did not grow after reset")
    }

    private static func repairsEntireConsecutiveCarryChain() {
        var device = DeviceData()
        device.dailyCounts["2026-09-08"] = DailyCount(count: 100, appCounts: ["app": 100])
        device.dailyCounts["2026-09-09"] = DailyCount(count: 140, appCounts: ["app": 40])
        device.dailyCounts["2026-09-10"] = DailyCount(count: 165, appCounts: ["app": 25])
        var data = SyncData()
        data.devices["device"] = device

        let repaired = data.repairCarriedDailyCounts(for: "device")

        expect(repaired == ["2026-09-09", "2026-09-10"], "carry chain was not fully detected")
        expect(data.devices["device"]?.count(for: "2026-09-09") == 40, "first carried day not repaired")
        expect(data.devices["device"]?.count(for: "2026-09-10") == 25, "second carried day not repaired")
        expect(data.devices["device"]?.dailyCounts["2026-09-09"]?.resetAt != nil, "repair lacks reset generation")
    }

    private static func doesNotRepairNonConsecutiveOrNonMatchingData() {
        var device = DeviceData()
        device.dailyCounts["2026-09-08"] = DailyCount(count: 100, appCounts: ["app": 100])
        device.dailyCounts["2026-09-10"] = DailyCount(count: 140, appCounts: ["app": 40])
        device.dailyCounts["2026-09-11"] = DailyCount(count: 170, appCounts: ["app": 60])
        var data = SyncData()
        data.devices["device"] = device

        expect(data.repairCarriedDailyCounts(for: "device").isEmpty, "valid data was repaired")
        expect(data.devices["device"]?.count(for: "2026-09-10") == 140, "non-consecutive day changed")
        expect(data.devices["device"]?.count(for: "2026-09-11") == 170, "non-matching day changed")
    }

    private static func repairsEveryDeviceAndIsIdempotent() {
        var data = SyncData()
        for deviceID in ["mac-a", "mac-b"] {
            var device = DeviceData()
            device.dailyCounts["2026-09-08"] = DailyCount(count: 100, appCounts: ["app": 100])
            device.dailyCounts["2026-09-09"] = DailyCount(count: 140, appCounts: ["app": 40])
            data.devices[deviceID] = device
        }

        let repaired = data.repairAllCarriedDailyCounts()

        expect(Set(repaired.keys) == Set(["mac-a", "mac-b"]), "not every device was repaired")
        expect(data.devices["mac-a"]?.count(for: "2026-09-09") == 40, "first device stayed corrupt")
        expect(data.devices["mac-b"]?.count(for: "2026-09-09") == 40, "second device stayed corrupt")
        expect(data.repairAllCarriedDailyCounts().isEmpty, "repair was not idempotent")
    }

    private static func preservesResetGenerationAsCountAdvances() {
        var device = DeviceData()
        device.dailyCounts["2026-09-15"] = DailyCount(count: 0, resetAt: 200)

        device.setCount(25, for: "2026-09-15", appCounts: ["app": 25])

        expect(device.dailyCounts["2026-09-15"]?.count == 25, "count did not advance")
        expect(device.dailyCounts["2026-09-15"]?.resetAt == 200, "count advance lost reset generation")
    }

    private static func repairedSyncRowRejectsStaleLocalCarry() {
        var device = DeviceData()
        device.dailyCounts["2026-09-15"] = DailyCount(
            count: 40,
            appCounts: ["app": 40],
            resetAt: 200
        )

        let reconciled = device.reconcileLocalSnapshot(
            count: 140,
            appCounts: ["app": 40],
            for: "2026-09-15"
        )

        expect(reconciled.count == 40, "stale UserDefaults carry beat repaired sync row")
        expect(reconciled.appCounts == ["app": 40], "repaired app totals changed")
    }

    private static func repairedSyncRowKeepsLivePostRepairKeys() {
        var device = DeviceData()
        device.dailyCounts["2026-09-15"] = DailyCount(
            count: 40,
            appCounts: ["app": 40],
            resetAt: 200
        )

        let reconciled = device.reconcileLocalSnapshot(
            count: 55,
            appCounts: ["app": 55],
            for: "2026-09-15"
        )

        expect(reconciled.count == 55, "live keys recorded after repair were discarded")
        expect(reconciled.appCounts == ["app": 55], "live app totals were discarded")
    }

    private static func compactCountUsesAtMostThreeSignificantDigits() {
        expect(CountFormatter.compact(999) == "999", "sub-thousand formatting failed")
        expect(CountFormatter.compact(1_234) == "1.23k", "one-thousand formatting failed")
        expect(CountFormatter.compact(12_345) == "12.3k", "ten-thousand formatting failed")
        expect(CountFormatter.compact(232_850) == "233k", "hundred-thousand formatting failed")
        expect(CountFormatter.compact(999_999) == "1M", "million rollover formatting failed")
        expect(CountFormatter.compact(1_234_567) == "1.23M", "million formatting failed")
    }

    private static func minutePayloadContainsCountsButNoInputContent() throws {
        let payload = sampleMinutePayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let buckets = object["buckets"] as! [[String: Any]]
        let bucketKeys = Set(buckets[0].keys)

        expect(Set(object.keys) == Set(["schemaVersion", "clientDeviceId", "appVersion", "osVersion", "buckets"]), "minute batch gained an unknown top-level field")
        expect(bucketKeys == Set(["startedAt", "utcOffsetMinutes", "keys", "clicks", "scrollTicks", "pointerDistance", "apps", "inputs"]), "minute bucket gained a content-level field")

        // Hardware identity stays local: only the coarse class may be uploaded.
        let inputs = buckets[0]["inputs"] as! [[String: Any]]
        expect(Set(inputs[0].keys) == Set(["source", "keys", "clicks", "scrollTicks", "pointerDistance"]), "input split gained a field")
        expect(["builtin", "external", "virtual", "unknown"].contains(inputs[0]["source"] as! String), "input split leaked a device identity")

        let json = String(data: data, encoding: .utf8)!
        for forbidden in ["text", "keyCode", "windowTitle", "url", "clipboard", "filePath",
                          "vendor", "productId", "serial", "displayName"] {
            expect(!json.contains(forbidden), "minute payload contains forbidden field \(forbidden)")
        }
        expect(json.contains("com.apple.Terminal"), "private bundle ID was not encoded")
    }

    private static func minutePayloadUsesMinuteTimestampAndClickTypes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sampleMinutePayload())
        let json = String(data: data, encoding: .utf8)!
        expect(json.contains("2026-09-15T12:29:00Z"), "minute timestamp encoding changed")
        expect(json.contains(#""left":4"#), "left clicks missing")
        expect(json.contains(#""right":1"#), "right clicks missing")
        expect(json.contains(#""other":2"#), "other clicks missing")
    }

    private static func legacyCredentialsRefreshMissingServerDeviceIdentity() {
        expect(CloudSyncMigration.needsServerDeviceIdentity(hasToken: true, hasServerDeviceID: false), "legacy credentials did not request identity refresh")
        expect(!CloudSyncMigration.needsServerDeviceIdentity(hasToken: true, hasServerDeviceID: true), "known identity refreshed unnecessarily")
        expect(!CloudSyncMigration.needsServerDeviceIdentity(hasToken: false, hasServerDeviceID: false), "missing credential requested identity refresh")
    }

    private static func handoffLinkRoutesEachBrowserRedirect() {
        let classify = { (s: String) in CloudHandoffLink.classify(URL(string: s)!, expectedScheme: "inputstats") }

        expect(classify("inputstats://pair") == .pair, "pair link did not route to pairing")
        expect(classify("inputstats://connected?code=isl_abc") == .connect(code: "isl_abc"), "PKCE handoff did not route to completion")
        expect(classify("inputstats://connected?token=tok_abc") == .legacyToken("tok_abc"), "legacy token handoff stopped working")
        expect(classify("INPUTSTATS://pair") == .pair, "scheme match became case-sensitive")
    }

    /// A stale dev bundle claiming the release `inputstats://` scheme used to swallow
    /// the handoff silently, so "Open Input Stats" looked like a dead button.
    private static func handoffLinkExplainsEveryRejection() {
        let classify = { (s: String) in CloudHandoffLink.classify(URL(string: s)!, expectedScheme: "inputstats-dev") }

        guard case .rejected(let wrongBuild) = classify("inputstats://connected?code=isl_abc") else {
            fatalError("release handoff was accepted by a dev build")
        }
        expect(wrongBuild.contains("inputstats://"), "rejection did not name the scheme that arrived")

        guard case .rejected = classify("inputstats-dev://connected") else {
            fatalError("handoff with no code was accepted")
        }
        guard case .rejected = classify("inputstats-dev://connected?code=") else {
            fatalError("handoff with an empty code was accepted")
        }
        guard case .rejected = classify("inputstats-dev://whatever") else {
            fatalError("unknown link action was accepted")
        }
        guard case .rejected = classify("connected?code=isl_abc") else {
            fatalError("schemeless link was accepted")
        }
    }

    private static func sampleMinutePayload() -> MinuteBatchPayload {
        MinuteBatchPayload(
            schemaVersion: 1,
            clientDeviceId: "device",
            appVersion: "0.2.0",
            osVersion: "macOS",
            buckets: [MinuteBucketPayload(
                startedAt: ISO8601DateFormatter().date(from: "2026-09-15T12:29:00Z")!,
                utcOffsetMinutes: 600,
                keys: 42,
                clicks: MinuteClicksPayload(left: 4, right: 1, other: 2),
                scrollTicks: 12,
                pointerDistance: 1_234,
                apps: [MinuteAppPayload(bundleId: "com.apple.Terminal", keys: 42)],
                inputs: [MinuteInputPayload(source: "external", keys: 42, clicks: 7,
                                            scrollTicks: 12, pointerDistance: 1_234)]
            )]
        )
    }

    private static func syncData(count: Int, resetAt: TimeInterval?) -> SyncData {
        var device = DeviceData()
        device.dailyCounts["2026-09-15"] = DailyCount(
            count: count,
            appCounts: ["app": count],
            resetAt: resetAt
        )
        var data = SyncData()
        data.devices["device"] = device
        return data
    }
}
