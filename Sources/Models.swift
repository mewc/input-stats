import Foundation

enum CloudSyncMigration {
    static func needsServerDeviceIdentity(hasToken: Bool, hasServerDeviceID: Bool) -> Bool {
        hasToken && !hasServerDeviceID
    }
}

// MARK: - Privacy-safe cloud minute payload

struct MinuteClicksPayload: Codable {
    let left: Int
    let right: Int
    let other: Int
}

struct MinuteAppPayload: Codable {
    let bundleId: String
    let keys: Int
}

struct MinuteBucketPayload: Codable {
    let startedAt: Date
    let utcOffsetMinutes: Int
    let keys: Int
    let clicks: MinuteClicksPayload
    let scrollTicks: Int
    let pointerDistance: Int
    let apps: [MinuteAppPayload]
}

struct MinuteBatchPayload: Codable {
    let schemaVersion: Int
    let clientDeviceId: String
    let appVersion: String
    let osVersion: String
    let buckets: [MinuteBucketPayload]
}

// MARK: - Sync Data Models

struct DailyCount: Codable {
    var count: Int
    var lastModified: TimeInterval
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)
    /// A monotonic reset generation. Counts remain max-merged within a generation, while an
    /// explicit reset or repair can supersede stale higher counts from iCloud/cloud sync.
    var resetAt: TimeInterval?

    init(count: Int, appCounts: [String: Int]? = nil, resetAt: TimeInterval? = nil) {
        self.count = count
        self.lastModified = Date().timeIntervalSince1970
        self.appCounts = appCounts
        self.resetAt = resetAt
    }
}

struct DeviceData: Codable {
    var dailyCounts: [String: DailyCount]

    init() {
        dailyCounts = [:]
    }

    mutating func setCount(_ count: Int,
                           for date: String,
                           appCounts: [String: Int]? = nil,
                           reset: Bool = false) {
        let resetAt = reset ? Date().timeIntervalSince1970 : dailyCounts[date]?.resetAt
        dailyCounts[date] = DailyCount(count: count, appCounts: appCounts, resetAt: resetAt)
    }

    func count(for date: String) -> Int {
        dailyCounts[date]?.count ?? 0
    }

    func appCounts(for date: String) -> [String: Int] {
        dailyCounts[date]?.appCounts ?? [:]
    }

    /// Reconcile UserDefaults with a reset-protected sync row. Older app versions can retain the
    /// carried total locally after the iCloud row is repaired; the per-app sum identifies that
    /// stale snapshot without discarding genuine keystrokes recorded after the repair.
    func reconcileLocalSnapshot(count localCount: Int,
                                appCounts localAppCounts: [String: Int],
                                for date: String) -> (count: Int, appCounts: [String: Int]) {
        guard let stored = dailyCounts[date] else {
            return (localCount, localAppCounts)
        }

        let localTrackedCount = localAppCounts.values.reduce(0, +)
        let localStillContainsCarry = stored.resetAt != nil
            && !localAppCounts.isEmpty
            && localCount > localTrackedCount

        if localStillContainsCarry {
            if localTrackedCount >= stored.count {
                return (localTrackedCount, localAppCounts)
            }
            return (stored.count, stored.appCounts ?? [:])
        }

        if localCount > stored.count {
            return (localCount, localAppCounts)
        }
        let storedAppCounts = stored.appCounts ?? [:]
        return (stored.count, storedAppCounts.isEmpty ? localAppCounts : storedAppCounts)
    }

    mutating func pruneOldData(keepingDays: Int = 60) {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -keepingDays, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = formatter.string(from: cutoffDate)

        dailyCounts = dailyCounts.filter { $0.key >= cutoffString }
    }
}

struct SyncData: Codable {
    var devices: [String: DeviceData]
    var version: Int

    init() {
        devices = [:]
        version = 2
    }

    func totalCount(for date: String) -> Int {
        devices.values.reduce(0) { $0 + $1.count(for: date) }
    }

    /// Aggregate app counts across all devices for a specific date
    func totalAppCounts(for date: String) -> [String: Int] {
        var aggregated: [String: Int] = [:]
        for device in devices.values {
            for (bundleID, count) in device.appCounts(for: date) {
                aggregated[bundleID, default: 0] += count
            }
        }
        return aggregated
    }

    /// Aggregate app counts across all devices for a date range
    func totalAppCounts(forDays days: Int, from date: Date) -> [String: Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var aggregated: [String: Int] = [:]
        for i in 0..<days {
            guard let pastDate = calendar.date(byAdding: .day, value: -i, to: date) else { continue }
            let dateString = formatter.string(from: pastDate)
            for (bundleID, count) in totalAppCounts(for: dateString) {
                aggregated[bundleID, default: 0] += count
            }
        }
        return aggregated
    }

    func recordDay() -> (count: Int, date: String)? {
        var allDates = Set<String>()
        for device in devices.values {
            allDates.formUnion(device.dailyCounts.keys)
        }

        var maxCount = 0
        var maxDate: String?

        for date in allDates {
            let count = totalCount(for: date)
            if count > maxCount {
                maxCount = count
                maxDate = date
            }
        }

        guard let date = maxDate else { return nil }
        return (maxCount, date)
    }

    func averageCount(forLastDays days: Int, from date: Date) -> Double {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var total = 0
        var daysWithData = 0

        for i in 0..<days {
            guard let pastDate = calendar.date(byAdding: .day, value: -i, to: date) else { continue }
            let dateString = formatter.string(from: pastDate)
            let count = totalCount(for: dateString)
            if count > 0 {
                total += count
                daysWithData += 1
            }
        }

        return daysWithData > 0 ? Double(total) / Double(daysWithData) : 0
    }

    mutating func merge(with other: SyncData) {
        for (deviceID, otherDeviceData) in other.devices {
            if devices[deviceID] == nil {
                devices[deviceID] = DeviceData()
            }

            for (date, otherDailyCount) in otherDeviceData.dailyCounts {
                if let existing = devices[deviceID]?.dailyCounts[date] {
                    let existingReset = existing.resetAt ?? 0
                    let otherReset = otherDailyCount.resetAt ?? 0

                    if otherReset > existingReset {
                        devices[deviceID]?.dailyCounts[date] = otherDailyCount
                    } else if otherReset == existingReset && otherDailyCount.count > existing.count {
                        devices[deviceID]?.dailyCounts[date] = otherDailyCount
                    } else if otherReset == existingReset && otherDailyCount.count == existing.count {
                        // Same count - merge app counts from both
                        var mergedAppCounts = existing.appCounts ?? [:]
                        if let otherAppCounts = otherDailyCount.appCounts {
                            for (bundleID, count) in otherAppCounts {
                                mergedAppCounts[bundleID] = max(mergedAppCounts[bundleID] ?? 0, count)
                            }
                        }
                        devices[deviceID]?.dailyCounts[date]?.appCounts = mergedAppCounts.isEmpty ? nil : mergedAppCounts
                    }
                } else {
                    devices[deviceID]?.dailyCounts[date] = otherDailyCount
                }
            }
        }
    }

    /// Repair the midnight-rollover bug shipped in v0.1.8. Its fingerprint is exact: on
    /// consecutive days, `count == previous stored count + sum(appCounts)`. Keep the original
    /// previous value while walking the chain so every affected day can be repaired in one pass.
    /// Repaired rows get a reset generation so max-based replicas cannot resurrect bad totals.
    @discardableResult
    mutating func repairCarriedDailyCounts(for deviceID: String) -> [String] {
        guard var device = devices[deviceID] else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"

        var previousDate: Date?
        var previousStoredCount: Int?
        var repairedDates: [String] = []

        for dateKey in device.dailyCounts.keys.sorted() {
            guard let original = device.dailyCounts[dateKey],
                  let date = formatter.date(from: dateKey) else { continue }

            defer {
                previousDate = date
                previousStoredCount = original.count
            }

            guard let priorDate = previousDate,
                  let priorCount = previousStoredCount,
                  Calendar(identifier: .gregorian).dateComponents([.day], from: priorDate, to: date).day == 1,
                  let appCounts = original.appCounts,
                  !appCounts.isEmpty else { continue }

            let trackedCount = appCounts.values.reduce(0, +)
            guard original.count > trackedCount,
                  original.count - trackedCount == priorCount else { continue }

            device.dailyCounts[dateKey] = DailyCount(
                count: trackedCount,
                appCounts: appCounts,
                resetAt: Date().timeIntervalSince1970
            )
            repairedDates.append(dateKey)
        }

        devices[deviceID] = device
        return repairedDates
    }

    /// Repair every device represented in a merged file. This lets a Mac clean up historical
    /// rows left by another device that is offline or no longer in use.
    @discardableResult
    mutating func repairAllCarriedDailyCounts() -> [String: [String]] {
        var repairedByDevice: [String: [String]] = [:]
        for deviceID in devices.keys.sorted() {
            let repairedDates = repairCarriedDailyCounts(for: deviceID)
            if !repairedDates.isEmpty {
                repairedByDevice[deviceID] = repairedDates
            }
        }
        return repairedByDevice
    }

    mutating func pruneAllDevices(keepingDays: Int = 60) {
        for deviceID in devices.keys {
            devices[deviceID]?.pruneOldData(keepingDays: keepingDays)
        }
    }
}

// MARK: - Count Formatting

enum CountFormatter {
    private static let compactNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 3
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    /// Up to three significant digits plus a suffix, so the status item stays compact.
    static func compact(_ count: Int) -> String {
        let magnitude: Double
        let suffix: String
        if count >= 999_500 {
            magnitude = Double(count) / 1_000_000
            suffix = "M"
        } else if count >= 1_000 {
            magnitude = Double(count) / 1_000
            suffix = "k"
        } else {
            return "\(count)"
        }

        return (compactNumberFormatter.string(from: NSNumber(value: magnitude)) ?? "\(magnitude)") + suffix
    }
}

// MARK: - Local State

struct LocalState: Codable {
    var date: String
    var count: Int
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)
}
