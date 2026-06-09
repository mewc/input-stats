import Foundation
import SQLite3

// MARK: - Event Kinds

/// The categories of input we track at high resolution.
/// `move` stores accumulated pointer travel distance in pixels; all others are event counts.
enum EventKind: Int, CaseIterable, Identifiable {
    case key = 0
    case click = 1
    case scroll = 2
    case move = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .key: return "Keys"
        case .click: return "Clicks"
        case .scroll: return "Scroll"
        case .move: return "Movement"
        }
    }

    /// Movement is a distance (pixels), not a count — charted separately.
    var isDistance: Bool { self == .move }
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
    private let queue = DispatchQueue(label: "com.typing-stats.eventstore", qos: .utility)

    /// Identifies a per-bucket accumulation slot. Shared with AppDelegate's in-memory accumulator.
    struct BucketKey: Hashable {
        let kind: Int
        let app: String
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

    private func migrate() {
        exec("""
            CREATE TABLE IF NOT EXISTS events (
                bucket INTEGER NOT NULL,
                kind   INTEGER NOT NULL,
                app    TEXT NOT NULL,
                count  INTEGER NOT NULL,
                PRIMARY KEY (bucket, kind, app)
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_bucket ON events(bucket);")
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
            INSERT INTO events(bucket, kind, app, count) VALUES(?, ?, ?, ?)
            ON CONFLICT(bucket, kind, app) DO UPDATE SET count = count + excluded.count;
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
            sqlite3_bind_int64(stmt, 4, Int64(value))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Block until all queued writes have drained (used on app quit).
    func flushAndWait() {
        queue.sync {}
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
}
