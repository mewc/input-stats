import Cocoa
import Sparkle

/// Lightweight "is there a newer GitHub Release?" checker.
///
/// This fork distributes via direct GitHub Release downloads (no Sparkle auto-install — see
/// appcast.xml), so instead of driving a Sparkle feed we just compare the latest release tag
/// to the running version and nudge the user to download. The Sparkle controller is still
/// constructed so the bundled framework stays valid, but it never checks a feed.
class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")

    private let repo = "mewc/input-stats"
    private var updaterController: SPUStandardUpdaterController!

    /// Newer version string (e.g. "0.1.3") when an update is available, else nil.
    private(set) var availableVersion: String?
    /// The GitHub release page to open for the available update.
    private(set) var releaseURL: URL?

    var updateAvailable: Bool { availableVersion != nil }

    private override init() {
        super.init()
        // Constructed but not started; we don't use Sparkle's feed (see checkForUpdates()).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Query the latest GitHub release and compare to the running version. Posts
    /// `updateAvailableNotification` when a newer version is first seen. `completion` runs on main.
    func checkForUpdates(completion: (() -> Void)? = nil) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion?()
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }

            var newVersion: String?
            var page: URL?
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.isNewer(latest, than: self.currentVersion) {
                    newVersion = latest
                    if let html = json["html_url"] as? String { page = URL(string: html) }
                }
            }

            DispatchQueue.main.async {
                let firstSeen = newVersion != nil && newVersion != self.availableVersion
                self.availableVersion = newVersion
                self.releaseURL = page ?? URL(string: "https://github.com/\(self.repo)/releases/latest")
                if firstSeen {
                    NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
                }
                completion?()
            }
        }.resume()
    }

    /// Open the available release (or the releases page) in the browser.
    func openReleasePage() {
        let url = releaseURL ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    /// True if semantic version `a` is strictly greater than `b` (numeric, dot-separated).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
