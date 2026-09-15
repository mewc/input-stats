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
        print("InputStats event-store tests: 5 passed")
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

    private static func row(_ minute: Int, _ kind: EventKind, _ app: String, _ value: Int) -> EventStore.MinuteRow {
        .init(minute: minute, kind: kind.rawValue, app: app, value: value)
    }
}
