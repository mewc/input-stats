import Foundation
import Darwin

@main
struct RepairSyncData {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        let apply = arguments.contains("--apply")
        let fileURL = try syncFileURL(from: arguments)
        let originalData = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let original = try decoder.decode(SyncData.self, from: originalData)
        var repaired = original
        let changed = repaired.repairAllCarriedDailyCounts()

        guard !changed.isEmpty else {
            print("No carried daily totals found in \(fileURL.path).")
            return
        }

        for deviceID in changed.keys.sorted() {
            for date in changed[deviceID] ?? [] {
                let before = original.devices[deviceID]?.count(for: date) ?? 0
                let after = repaired.devices[deviceID]?.count(for: date) ?? 0
                print("\(deviceID)  \(date): \(before) -> \(after)")
            }
        }

        guard apply else {
            print("Dry run only. Re-run with --apply to create a backup and write these repairs.")
            return
        }

        let backupURL = uniqueBackupURL(for: fileURL)
        try FileManager.default.copyItem(at: fileURL, to: backupURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(repaired)
        try encoded.write(to: fileURL, options: .atomic)

        print("Repaired \(changed.values.reduce(0) { $0 + $1.count }) day(s).")
        print("Backup: \(backupURL.path)")
    }

    private static func syncFileURL(from arguments: [String]) throws -> URL {
        if let fileIndex = arguments.firstIndex(of: "--file") {
            guard arguments.indices.contains(fileIndex + 1) else {
                throw RepairError.missingFileArgument
            }
            return URL(fileURLWithPath: NSString(string: arguments[fileIndex + 1]).expandingTildeInPath)
        }

        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/TypingStats")
            .appendingPathComponent("typing-stats.json")
        return cloudDocs
    }

    private static func uniqueBackupURL(for fileURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        let filename = "typing-stats.backup-\(formatter.string(from: Date()))-\(suffix).json"
        return fileURL.deletingLastPathComponent().appendingPathComponent(filename)
    }

    private static func printUsage() {
        print("""
        Usage: ./repair-data.sh [--file PATH] [--apply]

        Scans Input Stats sync history for the exact v0.1.8 carried-count pattern.
        Without --apply, only prints proposed changes. Applying creates a backup beside the file.
        """)
    }

    private enum RepairError: LocalizedError {
        case missingFileArgument

        var errorDescription: String? {
            switch self {
            case .missingFileArgument:
                return "--file requires a path"
            }
        }
    }
}
