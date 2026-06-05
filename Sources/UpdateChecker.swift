import Foundation
import Sparkle

class UpdateChecker: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateChecker()
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")

    private var updaterController: SPUStandardUpdaterController!
    private(set) var availableVersion: String?

    var updateAvailable: Bool {
        availableVersion != nil
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    private override init() {
        super.init()
        // Auto-update is disabled for this fork (downloads-only distribution). We construct the
        // controller without starting the updater so nothing checks a feed or shows error dialogs.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        // No-op: this fork ships via direct GitHub Release downloads, not Sparkle.
    }

    func installUpdate() {
        // No-op: see checkForUpdates().
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }
}
