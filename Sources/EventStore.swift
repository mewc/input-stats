import Foundation
import SQLite3

// MARK: - Event Kinds

/// The categories of input we track at high resolution.
/// `move` stores accumulated pointer travel distance in pixels; all others are event counts.
enum EventKind: Int, CaseIterable, Identifiable {
    case key = 0
    /// Legacy click rows and all left clicks use raw value 1.
    case click = 1
    case scroll = 2
    case rightClick = 3
    case move = 4
    case otherClick = 5

    // Subsets of `key` (a keystroke may also be counted in one or more of these).
    /// Auto-repeat keyDowns from a held key.
    case keyRepeat = 6
    /// Keystrokes injected by software (text expanders, automation), not a physical key.
    case keySynthetic = 7
    /// Keystrokes with Cmd/Ctrl/Opt held.
    case keyShortcut = 8
    /// Modifier key presses (Shift/Cmd/Opt/Ctrl/Fn). Standalone — never part of the key total.
    case modifier = 9

    // Key composition: a partition of `key` by what was pressed (aggregate only, never sequences).
    case keyLetter = 10
    case keyDigit = 11
    case keySpace = 12
    case keyEnter = 13
    case keyBackspace = 14
    case keyNavigation = 15
    case keyOther = 16

    // Mouse subsets.
    /// Second click of a double-click (subset of `click`).
    case doubleClick = 17
    /// Pointer travel while a button is held (px, subset of `move`).
    case drag = 18
    /// Scroll ticks delivered by momentum/inertia after the fingers lift (subset of `scroll`).
    case scrollMomentum = 19
    /// Trackpad gestures: pinch, rotate, swipe, smart-zoom.
    case gesture = 20

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .key: return "Keys"
        case .click: return "Clicks"
        case .scroll: return "Scroll"
        case .rightClick: return "Right clicks"
        case .move: return "Movement"
        case .otherClick: return "Other clicks"
        case .keyRepeat: return "Held repeats"
        case .keySynthetic: return "Software-typed"
        case .keyShortcut: return "Shortcuts"
        case .modifier: return "Modifier presses"
        case .keyLetter: return "Letters"
        case .keyDigit: return "Digits"
        case .keySpace: return "Space"
        case .keyEnter: return "Enter"
        case .keyBackspace: return "Backspace"
        case .keyNavigation: return "Navigation"
        case .keyOther: return "Other keys"
        case .doubleClick: return "Double clicks"
        case .drag: return "Dragging"
        case .scrollMomentum: return "Momentum scroll"
        case .gesture: return "Gestures"
        }
    }

    /// Movement and dragging are distances (pixels), not counts — charted separately.
    var isDistance: Bool { self == .move || self == .drag }

    static let clickKinds: [EventKind] = [.click, .rightClick, .otherClick]
    static let keyCompositionKinds: [EventKind] = [.keyLetter, .keyDigit, .keySpace, .keyEnter,
                                                   .keyBackspace, .keyNavigation, .keyOther]
}

// MARK: - Input Devices

/// A physical (or virtual) input device we have attributed events to. Rows live in the `devices`
/// table; `id` is the foreign key stored on each event row. `id == 0` is the legacy/unattributed slot.
struct InputDevice: Identifiable, Hashable {
    enum Role: Int {
        case keyboard = 0
        case pointer = 1
    }

    static let unattributedID = 0

    let id: Int
    let key: String
    let role: Role
    let name: String
    let vendorID: Int
    let productID: Int
    let transport: String
    let isBuiltIn: Bool
    let isSoftware: Bool

    /// Human label for charts/legends. Built-in Apple devices share one product string
    /// ("Apple Internal Keyboard / Trackpad"), so name them by role instead.
    var displayName: String {
        if id == InputDevice.unattributedID { return "Unattributed" }
        if isSoftware { return "Software" }
        if isBuiltIn {
            return role == .keyboard ? "Built-in Keyboard" : "Built-in Trackpad"
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return role == .keyboard ? "Unknown keyboard" : "Unknown pointer" }
        return trimmed
    }

    /// Short connection label ("Built-in", "USB", "Bluetooth", ...).
    var connectionLabel: String {
        if isSoftware { return "Virtual" }
        if isBuiltIn { return "Built-in" }
        switch transport.uppercased() {
        case "": return "External"
        case "USB": return "USB"
        case "BLUETOOTH", "BLUETOOTH LOW ENERGY": return "Bluetooth"
        default: return transport
        }
    }

    static let unattributed = InputDevice(id: unattributedID, key: "unattributed", role: .keyboard, name: "",
                                          vendorID: 0, productID: 0, transport: "", isBuiltIn: false,
                                          isSoftware: false)
}

/// What the resolver learns about a device from IORegistry. `key` is the stable identity used to
/// de-duplicate across reconnects/reboots (registry IDs are not stable): role + vendor + name + built-in.
/// Product ID is deliberately excluded so a mouse that switches between wired/dongle PIDs stays one row.
struct InputDeviceDescriptor {
    let role: InputDevice.Role
    let name: String
    let vendorID: Int
    let productID: Int
    let transport: String
    let isBuiltIn: Bool
    let isSoftware: Bool

    var key: String {
        if isSoftware { return "\(role.rawValue)|software" }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(role.rawValue)|\(vendorID)|\(cleanName)|\(isBuiltIn ? 1 : 0)"
    }

    static func software(role: InputDevice.Role) -> InputDeviceDescriptor {
        InputDeviceDescriptor(role: role, name: "Software", vendorID: 0, productID: 0, transport: "",
                              isBuiltIn: false, isSoftware: true)
    }

    static func unknown(role: InputDevice.Role) -> InputDeviceDescriptor {
        InputDeviceDescriptor(role: role, name: "", vendorID: 0, productID: 0, transport: "",
                              isBuiltIn: false, isSoftware: false)
    }
}

// SQLite wants this destructor for transient (Swift-owned) strings bound to statements.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Event Store (local, high-resolution timeseries)

/// A local-only SQLite store of input events bucketed at `baseBucketSeconds`.
/// Daily cross-device totals still live in the iCloud JSON (see `SyncData`); this store
/// powers sub-daily drilldown (down to 5s blocks) for the current Mac only.
final class EventStore {
    static let shared = EventStore()

    /// Base resolution. Every higher resolution must be a multiple of this.
    static let baseBucketSeconds = 5
    /// How long we keep raw 5s data before pruning.
    private let retentionDays = 30

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.input-stats.eventstore", qos: .utility)

    /// Identifies a per-bucket accumulation slot. Shared with AppDelegate's in-memory accumulator.
    struct BucketKey: Hashable {
        let kind: Int
        let app: String
        let device: Int
    }

    struct DeviceSeriesPoint: Identifiable {
        let id = UUID()
        let date: Date
        let device: Int
        let kind: EventKind
        let value: Int
    }

    struct SeriesPoint: Identifiable {
        let id = UUID()
        let date: Date
        let kind: EventKind
        let value: Int
    }

    struct AppSeriesPoint: Identifiable {
        let id = UUID()
        let date: Date
        let app: String
        let value: Int
    }

    struct MinuteAppCount {
        let bundleID: String
        let keys: Int
    }

    struct MinuteBucket {
        let startedAt: Date
        let utcOffsetMinutes: Int
        let keys: Int
        let clicksLeft: Int
        let clicksRight: Int
        let clicksOther: Int
        let scrollTicks: Int
        let pointerDistance: Int
        let apps: [MinuteAppCount]
    }

    struct MinuteExport {
        let buckets: [MinuteBucket]
        let scannedThrough: Int
    }

    struct MinuteRow {
        let minute: Int
        let kind: Int
        let app: String
        let value: Int
    }

    private init() {
        queue.sync {
            open()
            migrate()
            pruneLocked()
        }
    }

    // MARK: Setup

    private var dbURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderName = isDevBuild ? "TypingStats-Dev" : "TypingStats"
        let folder = appSupport.appendingPathComponent(folderName)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("events.db")
    }

    private func open() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("EventStore: failed to open db at \(dbURL.path)")
            db = nil
            return
        }
        // WAL keeps writes from blocking reads and is more crash-resilient.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    /// Schema versions (PRAGMA user_version):
    /// 0 — events(bucket, kind, app, count)
    /// 1 — events gains a `device` column (PK includes it) + `devices` table
    private static let schemaVersion = 1

    private func migrate() {
        exec("""
            CREATE TABLE IF NOT EXISTS devices (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                key        TEXT NOT NULL UNIQUE,
                role       INTEGER NOT NULL,
                name       TEXT NOT NULL,
                vendor_id  INTEGER NOT NULL DEFAULT 0,
                product_id INTEGER NOT NULL DEFAULT 0,
                transport  TEXT NOT NULL DEFAULT '',
                builtin    INTEGER NOT NULL DEFAULT 0,
                software   INTEGER NOT NULL DEFAULT 0,
                first_seen INTEGER NOT NULL,
                last_seen  INTEGER NOT NULL
            );
            """)

        let version = userVersion()
        if version < 1 {
            exec("BEGIN;")
            if tableExists("events") {
                // SQLite can't alter a primary key in place: rebuild with `device` in the PK and
                // park every legacy row on the unattributed device (0).
                exec("""
                    CREATE TABLE events_v1 (
                        bucket INTEGER NOT NULL,
                        kind   INTEGER NOT NULL,
                        app    TEXT NOT NULL,
                        device INTEGER NOT NULL DEFAULT 0,
                        count  INTEGER NOT NULL,
                        PRIMARY KEY (bucket, kind, app, device)
                    );
                    """)
                exec("INSERT INTO events_v1(bucket, kind, app, device, count) SELECT bucket, kind, app, 0, count FROM events;")
                exec("DROP TABLE events;")
                exec("ALTER TABLE events_v1 RENAME TO events;")
            } else {
                exec("""
                    CREATE TABLE events (
                        bucket INTEGER NOT NULL,
                        kind   INTEGER NOT NULL,
                        app    TEXT NOT NULL,
                        device INTEGER NOT NULL DEFAULT 0,
                        count  INTEGER NOT NULL,
                        PRIMARY KEY (bucket, kind, app, device)
                    );
                    """)
            }
            exec("PRAGMA user_version = 1;")
            exec("COMMIT;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_events_bucket ON events(bucket);")
    }

    private func userVersion() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { print("EventStore exec error: \(String(cString: err))"); sqlite3_free(err) }
            return false
        }
        return true
    }

    // MARK: Writes

    /// Floor an epoch timestamp to the base bucket.
    static func bucket(for date: Date = Date()) -> Int {
        (Int(date.timeIntervalSince1970) / baseBucketSeconds) * baseBucketSeconds
    }

    /// Persist a batch of accumulated counts for a single 5s bucket. Runs async on the store queue.
    func record(bucket: Int, counts: [BucketKey: Int]) {
        guard !counts.isEmpty else { return }
        queue.async { [weak self] in
            self?.upsertLocked(bucket: bucket, counts: counts)
        }
    }

    private func upsertLocked(bucket: Int, counts: [BucketKey: Int]) {
        guard let db else { return }
        let sql = """
            INSERT INTO events(bucket, kind, app, device, count) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(bucket, kind, app, device) DO UPDATE SET count = count + excluded.count;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        for (key, value) in counts where value != 0 {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(bucket))
            sqlite3_bind_int(stmt, 2, Int32(key.kind))
            sqlite3_bind_text(stmt, 3, key.app, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(key.device))
            sqlite3_bind_int64(stmt, 5, Int64(value))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Block until all queued writes have drained (used on app quit).
    func flushAndWait() {
        queue.sync {}
    }

    /// Export privacy-safe, completed minute summaries for cloud upload. The
    /// caller advances to `scannedThrough` even when a range contains no input,
    /// so long idle periods do not stall the durable upload cursor.
    func minuteExport(startBucket: Int,
                      endBucket: Int,
                      completion: @escaping (MinuteExport) -> Void) {
        queue.async { [weak self] in
            let result = self?.minuteExportLocked(startBucket: startBucket, endBucket: endBucket)
                ?? MinuteExport(buckets: [], scannedThrough: endBucket)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func minuteExportLocked(startBucket: Int, endBucket: Int) -> MinuteExport {
        guard let db, endBucket > startBucket else {
            return MinuteExport(buckets: [], scannedThrough: endBucket)
        }
        let sql = """
            SELECT (bucket / 60) * 60 AS minute, kind, app, SUM(count)
            FROM events
            WHERE bucket >= ? AND bucket < ?
            GROUP BY minute, kind, app
            ORDER BY minute, kind, app;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return MinuteExport(buckets: [], scannedThrough: startBucket)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(startBucket))
        sqlite3_bind_int64(stmt, 2, Int64(endBucket))

        var rows: [MinuteRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(MinuteRow(
                minute: Int(sqlite3_column_int64(stmt, 0)),
                kind: Int(sqlite3_column_int(stmt, 1)),
                app: String(cString: sqlite3_column_text(stmt, 2)),
                value: Int(sqlite3_column_int64(stmt, 3))
            ))
        }
        let buckets = Self.foldMinuteRows(rows) { date in
            TimeZone.current.secondsFromGMT(for: date) / 60
        }
        return MinuteExport(buckets: buckets, scannedThrough: endBucket)
    }

    /// Pure folding seam used by both SQLite export and zero-dependency tests.
    static func foldMinuteRows(_ rows: [MinuteRow],
                               utcOffsetMinutes: (Date) -> Int) -> [MinuteBucket] {
        struct Accum {
            var keys = 0
            var clicksLeft = 0
            var clicksRight = 0
            var clicksOther = 0
            var scrollTicks = 0
            var pointerDistance = 0
            var apps: [String: Int] = [:]
        }
        var byMinute: [Int: Accum] = [:]
        for row in rows {
            var accum = byMinute[row.minute] ?? Accum()
            switch EventKind(rawValue: row.kind) {
            case .key:
                accum.keys += row.value
                accum.apps[row.app, default: 0] += row.value
            case .click: accum.clicksLeft += row.value
            case .rightClick: accum.clicksRight += row.value
            case .otherClick: accum.clicksOther += row.value
            case .scroll: accum.scrollTicks += row.value
            case .move: accum.pointerDistance += row.value
            // Subset/composition kinds overlap the totals above; unknown kinds are legacy noise.
            default: break
            }
            byMinute[row.minute] = accum
        }

        let buckets = byMinute.keys.sorted().compactMap { minute -> MinuteBucket? in
            guard let value = byMinute[minute] else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(minute))
            let apps = value.apps.keys.sorted().map {
                MinuteAppCount(bundleID: $0, keys: value.apps[$0] ?? 0)
            }
            return MinuteBucket(
                startedAt: date,
                utcOffsetMinutes: utcOffsetMinutes(date),
                keys: value.keys,
                clicksLeft: value.clicksLeft,
                clicksRight: value.clicksRight,
                clicksOther: value.clicksOther,
                scrollTicks: value.scrollTicks,
                pointerDistance: value.pointerDistance,
                apps: apps
            )
        }
        return buckets
    }

    // MARK: Pruning

    private func pruneLocked() {
        let cutoff = EventStore.bucket(for: Date().addingTimeInterval(-Double(retentionDays) * 86400))
        exec("DELETE FROM events WHERE bucket < \(cutoff);")
    }

    func prune() {
        queue.async { [weak self] in self?.pruneLocked() }
    }

    // MARK: Reads

    /// Aggregate the requested kinds between [startBucket, endBucket) into `resolution`-second buckets.
    /// `resolution` must be a multiple of `baseBucketSeconds`. Completion is delivered on the main queue.
    func series(startBucket: Int,
                endBucket: Int,
                resolution: Int,
                kinds: [EventKind],
                completion: @escaping ([SeriesPoint]) -> Void) {
        queue.async { [weak self] in
            let result = self?.seriesLocked(startBucket: startBucket,
                                            endBucket: endBucket,
                                            resolution: resolution,
                                            kinds: kinds) ?? []
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func seriesLocked(startBucket: Int,
                              endBucket: Int,
                              resolution: Int,
                              kinds: [EventKind]) -> [SeriesPoint] {
        guard let db, !kinds.isEmpty else { return [] }
        let res = max(EventStore.baseBucketSeconds, resolution)
        let kindList = kinds.map { String($0.rawValue) }.joined(separator: ",")
        let sql = """
            SELECT (bucket / \(res)) * \(res) AS t, kind, SUM(count)
            FROM events
            WHERE bucket >= ? AND bucket < ? AND kind IN (\(kindList))
            GROUP BY t, kind
            ORDER BY t;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(startBucket))
        sqlite3_bind_int64(stmt, 2, Int64(endBucket))

        var points: [SeriesPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let t = sqlite3_column_int64(stmt, 0)
            let kindRaw = Int(sqlite3_column_int(stmt, 1))
            let sum = Int(sqlite3_column_int64(stmt, 2))
            guard let kind = EventKind(rawValue: kindRaw) else { continue }
            points.append(SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(t)),
                                      kind: kind,
                                      value: sum))
        }
        return points
    }

    /// Per-app series for a single kind, bucketed into `resolution`-second buckets.
    /// Completion delivered on the main queue.
    func seriesByApp(kind: EventKind,
                     startBucket: Int,
                     endBucket: Int,
                     resolution: Int,
                     completion: @escaping ([AppSeriesPoint]) -> Void) {
        queue.async { [weak self] in
            var points: [AppSeriesPoint] = []
            if let db = self?.db {
                let res = max(EventStore.baseBucketSeconds, resolution)
                let sql = """
                    SELECT (bucket / \(res)) * \(res) AS t, app, SUM(count)
                    FROM events
                    WHERE bucket >= ? AND bucket < ? AND kind = ?
                    GROUP BY t, app
                    ORDER BY t;
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(startBucket))
                    sqlite3_bind_int64(stmt, 2, Int64(endBucket))
                    sqlite3_bind_int(stmt, 3, Int32(kind.rawValue))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let t = sqlite3_column_int64(stmt, 0)
                        let app = String(cString: sqlite3_column_text(stmt, 1))
                        let sum = Int(sqlite3_column_int64(stmt, 2))
                        points.append(AppSeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(t)),
                                                     app: app, value: sum))
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// Total per app for a single kind over a window, descending. Completion on the main queue.
    func topApps(kind: EventKind,
                 startBucket: Int,
                 endBucket: Int,
                 completion: @escaping ([(app: String, total: Int)]) -> Void) {
        queue.async { [weak self] in
            var result: [(app: String, total: Int)] = []
            if let db = self?.db {
                let sql = """
                    SELECT app, SUM(count) AS s
                    FROM events
                    WHERE bucket >= ? AND bucket < ? AND kind = ?
                    GROUP BY app
                    ORDER BY s DESC;
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(startBucket))
                    sqlite3_bind_int64(stmt, 2, Int64(endBucket))
                    sqlite3_bind_int(stmt, 3, Int32(kind.rawValue))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let app = String(cString: sqlite3_column_text(stmt, 0))
                        let sum = Int(sqlite3_column_int64(stmt, 1))
                        result.append((app, sum))
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Per-day totals for each requested kind, keyed by local "yyyy-MM-dd".
    /// Mirrors the day bucketing used by the iCloud sync data so menu stats line up.
    /// Completion delivered on the main queue.
    func dailyTotals(kinds: [EventKind],
                     completion: @escaping ([EventKind: [String: Int]]) -> Void) {
        queue.async { [weak self] in
            var result: [EventKind: [String: Int]] = [:]
            if let db = self?.db, !kinds.isEmpty {
                let kindList = kinds.map { String($0.rawValue) }.joined(separator: ",")
                let sql = """
                    SELECT strftime('%Y-%m-%d', bucket, 'unixepoch', 'localtime') AS day, kind, SUM(count)
                    FROM events
                    WHERE kind IN (\(kindList))
                    GROUP BY day, kind;
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let day = String(cString: sqlite3_column_text(stmt, 0))
                        let kindRaw = Int(sqlite3_column_int(stmt, 1))
                        let sum = Int(sqlite3_column_int64(stmt, 2))
                        if let kind = EventKind(rawValue: kindRaw) {
                            result[kind, default: [:]][day] = sum
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Total per kind over a time window (e.g. "today"). Completion delivered on the main queue.
    func totals(startBucket: Int,
                endBucket: Int,
                completion: @escaping ([EventKind: Int]) -> Void) {
        queue.async { [weak self] in
            var result: [EventKind: Int] = [:]
            if let db = self?.db {
                let sql = "SELECT kind, SUM(count) FROM events WHERE bucket >= ? AND bucket < ? GROUP BY kind;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(startBucket))
                    sqlite3_bind_int64(stmt, 2, Int64(endBucket))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let kindRaw = Int(sqlite3_column_int(stmt, 0))
                        let sum = Int(sqlite3_column_int64(stmt, 1))
                        if let kind = EventKind(rawValue: kindRaw) { result[kind] = sum }
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    // MARK: Devices

    /// Look up (or create) the row for a device and return its id. Synchronous: the resolver
    /// calls this once per newly-seen HID sender and caches the result, so it never runs per event.
    func deviceID(for descriptor: InputDeviceDescriptor) -> Int {
        var id = InputDevice.unattributedID
        queue.sync {
            id = deviceIDLocked(for: descriptor)
        }
        return id
    }

    private func deviceIDLocked(for descriptor: InputDeviceDescriptor) -> Int {
        guard let db else { return InputDevice.unattributedID }
        let now = Int64(Date().timeIntervalSince1970)
        let upsert = """
            INSERT INTO devices(key, role, name, vendor_id, product_id, transport, builtin, software, first_seen, last_seen)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                last_seen = excluded.last_seen,
                transport = CASE WHEN excluded.transport = '' THEN transport ELSE excluded.transport END,
                product_id = CASE WHEN excluded.product_id = 0 THEN product_id ELSE excluded.product_id END;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsert, -1, &stmt, nil) == SQLITE_OK else { return InputDevice.unattributedID }
        sqlite3_bind_text(stmt, 1, descriptor.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(descriptor.role.rawValue))
        sqlite3_bind_text(stmt, 3, descriptor.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(descriptor.vendorID))
        sqlite3_bind_int64(stmt, 5, Int64(descriptor.productID))
        sqlite3_bind_text(stmt, 6, descriptor.transport, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, descriptor.isBuiltIn ? 1 : 0)
        sqlite3_bind_int(stmt, 8, descriptor.isSoftware ? 1 : 0)
        sqlite3_bind_int64(stmt, 9, now)
        sqlite3_bind_int64(stmt, 10, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM devices WHERE key = ?;", -1, &select, nil) == SQLITE_OK else {
            return InputDevice.unattributedID
        }
        defer { sqlite3_finalize(select) }
        sqlite3_bind_text(select, 1, descriptor.key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(select) == SQLITE_ROW ? Int(sqlite3_column_int64(select, 0)) : InputDevice.unattributedID
    }

    /// Every device we've ever attributed input to, keyed by id (includes the unattributed slot).
    /// Completion delivered on the main queue.
    func devices(completion: @escaping ([Int: InputDevice]) -> Void) {
        queue.async { [weak self] in
            var result: [Int: InputDevice] = [InputDevice.unattributedID: .unattributed]
            if let db = self?.db {
                let sql = "SELECT id, key, role, name, vendor_id, product_id, transport, builtin, software FROM devices;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let id = Int(sqlite3_column_int64(stmt, 0))
                        let role = InputDevice.Role(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .keyboard
                        result[id] = InputDevice(
                            id: id,
                            key: String(cString: sqlite3_column_text(stmt, 1)),
                            role: role,
                            name: String(cString: sqlite3_column_text(stmt, 3)),
                            vendorID: Int(sqlite3_column_int64(stmt, 4)),
                            productID: Int(sqlite3_column_int64(stmt, 5)),
                            transport: String(cString: sqlite3_column_text(stmt, 6)),
                            isBuiltIn: sqlite3_column_int(stmt, 7) != 0,
                            isSoftware: sqlite3_column_int(stmt, 8) != 0
                        )
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Per-device, per-kind series bucketed into `resolution`-second buckets. Completion on the main queue.
    func seriesByDevice(kinds: [EventKind],
                        startBucket: Int,
                        endBucket: Int,
                        resolution: Int,
                        completion: @escaping ([DeviceSeriesPoint]) -> Void) {
        queue.async { [weak self] in
            var points: [DeviceSeriesPoint] = []
            if let db = self?.db, !kinds.isEmpty {
                let res = max(EventStore.baseBucketSeconds, resolution)
                let kindList = kinds.map { String($0.rawValue) }.joined(separator: ",")
                let sql = """
                    SELECT (bucket / \(res)) * \(res) AS t, device, kind, SUM(count)
                    FROM events
                    WHERE bucket >= ? AND bucket < ? AND kind IN (\(kindList))
                    GROUP BY t, device, kind
                    ORDER BY t;
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(startBucket))
                    sqlite3_bind_int64(stmt, 2, Int64(endBucket))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let t = sqlite3_column_int64(stmt, 0)
                        let device = Int(sqlite3_column_int64(stmt, 1))
                        guard let kind = EventKind(rawValue: Int(sqlite3_column_int(stmt, 2))) else { continue }
                        let sum = Int(sqlite3_column_int64(stmt, 3))
                        points.append(DeviceSeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(t)),
                                                        device: device, kind: kind, value: sum))
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// Totals of every kind per device over a window. Completion delivered on the main queue.
    func totalsByDevice(startBucket: Int,
                        endBucket: Int,
                        completion: @escaping ([Int: [EventKind: Int]]) -> Void) {
        queue.async { [weak self] in
            var result: [Int: [EventKind: Int]] = [:]
            if let db = self?.db {
                let sql = """
                    SELECT device, kind, SUM(count) FROM events
                    WHERE bucket >= ? AND bucket < ?
                    GROUP BY device, kind;
                    """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(startBucket))
                    sqlite3_bind_int64(stmt, 2, Int64(endBucket))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let device = Int(sqlite3_column_int64(stmt, 0))
                        guard let kind = EventKind(rawValue: Int(sqlite3_column_int(stmt, 1))) else { continue }
                        result[device, default: [:]][kind] = Int(sqlite3_column_int64(stmt, 2))
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
