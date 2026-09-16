import SwiftUI

// Helper to detect dev builds (set via -DDEV_BUILD compiler flag)
var isDevBuild: Bool {
    #if DEV_BUILD
    return true
    #else
    return false
    #endif
}

/// Custom URL scheme this build registers (see build.sh, which rewrites Info.plist
/// for dev). Release and dev use different schemes so a `…://pair` link from the
/// production dashboard can never land in the dev app, or vice versa.
var appURLScheme: String { isDevBuild ? "inputstats-dev" : "inputstats" }

@main
struct InputStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
