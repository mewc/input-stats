import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var historyWindowController: HistoryWindowController?
    private var statusItem: NSStatusItem!
    private var theMenu: NSMenu!
    private var localKeystrokeCount: Int = 0
    private var localAppCounts: [String: Int] = [:]  // bundleID -> count for today
    private var totalKeystrokeCount: Int = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hasAccessibilityPermission = false
    private var permissionCheckTimer: Timer?
    private var permissionCheckTicks = 0
    private var syncTimer: Timer?
    private var minuteSyncTimer: Timer?
    private var minuteUploadInFlight = false
    private var dayChangeTimer: Timer?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastSyncTime: Date?
    // in-memory cache; disk syncs happen async
    private var cachedSyncData = SyncData()
    private var updateChecker = UpdateChecker.shared
    private var updateCheckTimer: Timer?
    private var updateDotLayer: CALayer?

    // Optional cloud sync (Google login -> Postgres). iCloud stays the default/offline path.
    private let cloudSync = CloudSync.shared

    // High-resolution local timeseries (keys + mouse/trackpad). Local-only, never synced.
    private let eventStore = EventStore.shared
    private var currentBucket: Int = 0
    private var bucketAccum: [EventStore.BucketKey: Int] = [:]
    private var bucketFlushTimer: Timer?
    // Cached frontmost app bundle ID, refreshed on app-activation (avoids per-event lookups).
    private var currentAppBundleID: String = "unknown"
    // Physical-device attribution (built-in keyboard/trackpad vs external mouse/keyboard).
    private let deviceResolver = InputDeviceResolver.shared
    private var modifierDetector = ModifierPressDetector()
    // Which screen pointer input is happening on (keystrokes stay unattributed — the pointer may
    // be parked on a different screen than the one you're typing into).
    private let displayResolver = DisplayResolver.shared
    // Last trackpad pressure stage, so a Force click counts once per press, not per pressure event.
    private var lastPressureStage: Int = 0

    // Per-day local totals for clicks and pointer movement (px), keyed by "yyyy-MM-dd".
    // Refreshed async from EventStore when the menu opens; powers the menu's Clicks/Distance sections.
    private var clickDaily: [String: Int] = [:]
    private var moveDaily: [String: Int] = [:]

    // The day our in-memory counts belong to. Lets `checkDayChange()` detect a midnight rollover
    // with a cheap string compare instead of decoding JSON from UserDefaults on every keystroke.
    private var activeDay: String = ""
    private var menuIsOpen = false

    private let deviceID: String = {
        let defaults = UserDefaults.standard
        let key = "deviceUUID"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: key)
        return newID
    }()

    private var syncFileURL: URL? {
        let fileManager = FileManager.default
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let docsURL = iCloudURL.appendingPathComponent("Documents")
            try? fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
            return docsURL.appendingPathComponent("typing-stats.json")
        }
        let cloudDocsPath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        if fileManager.fileExists(atPath: cloudDocsPath) {
            let appFolder = URL(fileURLWithPath: cloudDocsPath).appendingPathComponent("TypingStats")
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
            return appFolder.appendingPathComponent("typing-stats.json")
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("TypingStats")
        try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("typing-stats.json")
    }

    private let localDefaultsKey = "localKeystrokeData"
    private let syncQueue = DispatchQueue(label: "com.input-stats.sync", qos: .utility)
    private let fileCoordinator = NSFileCoordinator()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        loadLocalCount()
        loadAndReconcileCounts()

        // Trust the tap, not the TCC flag: a stale grant after re-signing reads trusted but the
        // tap won't create, which would otherwise leave the app silently dead (no CTA, Today: 0).
        hasAccessibilityPermission = AXIsProcessTrusted() && startMonitoring()
        setupMenuBar()

        if !hasAccessibilityPermission {
            // Don't prompt immediately: AXIsProcessTrusted() can read false during TCC warm-up
            // even when the grant is valid. The timer re-checks and only prompts after a grace
            // period if still untrusted, so an existing grant never triggers a false dialog/CTA.
            startPermissionCheckTimer()
        }

        startSyncTimer()
        startMinuteSyncTimer()
        scheduleDayChangeTimer()
        startFileMonitor()
        startFrontmostAppTracking()
        // Listen for update availability, then kick off the GitHub release check + periodic re-check.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateAvailable),
            name: UpdateChecker.updateAvailableNotification,
            object: nil
        )
        updateChecker.checkForUpdates()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.updateChecker.checkForUpdates()
        }

        ensureLoginItemEnabled()
        setupCloudSync()
    }

    // MARK: - Cloud Sync (optional)

    private func setupCloudSync() {
        // Receive the `<scheme>://connected?token=…` redirect from the browser sign-in.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        cloudSync.onStateChange = { [weak self] in self?.rebuildMenu() }
        cloudSync.onPulled = { [weak self] pulled in self?.handleCloudPull(pulled) }
        if cloudSync.isConnected {
            cloudSync.refreshDeviceIdentityIfNeeded()
            pushToCloud()
            cloudSync.pull()
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else {
            cloudSync.reportLinkFailure("Sign-in link could not be read.")
            return
        }
        switch CloudHandoffLink.classify(url, expectedScheme: appURLScheme) {
        case .pair:
            handlePairRequest()
        case .connect(let code):
            cloudSync.completePairing(code: code)
        case .legacyToken(let token):
            cloudSync.acceptLegacyToken(token)
        case .rejected(let reason):
            cloudSync.reportLinkFailure(reason)
        }
    }

    /// `<scheme>://pair` — the web dashboard's "Pair this Mac" button. Starts the
    /// browser sign-in when this Mac isn't linked yet; if it already is, just push and
    /// pull so the dashboard sees a fresh last-seen time (the web's "check sync" path).
    private func handlePairRequest() {
        if cloudSync.isConnected {
            pushToCloud()
            cloudSync.pull()
        } else {
            signInToCloud()
        }
    }

    /// Upload this device's history (today reflects the live local count) to the cloud.
    private func pushToCloud(waitForCompletion: Bool = false) {
        checkDayChange()
        guard cloudSync.isConnected else { return }
        let today = todayString()
        var payload = SyncData()
        var deviceData = DeviceData()
        deviceData.dailyCounts = cachedSyncData.devices[deviceID]?.dailyCounts ?? [:]
        deviceData.setCount(localKeystrokeCount, for: today, appCounts: localAppCounts.isEmpty ? nil : localAppCounts)
        payload.devices[deviceID] = deviceData

        if waitForCompletion {
            let finished = DispatchSemaphore(value: 0)
            cloudSync.push(payload) { _ in finished.signal() }
            _ = finished.wait(timeout: .now() + 2)
        } else {
            cloudSync.push(payload)
        }
    }

    /// Merge a server blob into the in-memory cache + iCloud file and refresh the UI.
    private func handleCloudPull(_ pulled: SyncData) {
        checkDayChange()
        let today = todayString()

        cachedSyncData.merge(with: pulled)
        let repairedDates = cachedSyncData.repairAllCarriedDailyCounts()[deviceID] ?? []

        if cachedSyncData.devices[deviceID] == nil {
            cachedSyncData.devices[deviceID] = DeviceData()
        }
        // If the cloud has a higher count for this device today, adopt it unless this pull just
        // exposed a carried-total row that we repaired to its per-app sum.
        let cloudToday = cachedSyncData.devices[deviceID]?.count(for: today) ?? 0
        if repairedDates.contains(today) {
            let cloudAppCounts = cachedSyncData.devices[deviceID]?.appCounts(for: today) ?? [:]
            let liveTrackedCount = localAppCounts.values.reduce(0, +)
            if localAppCounts.isEmpty || liveTrackedCount < cloudToday {
                localKeystrokeCount = cloudToday
                localAppCounts = cloudAppCounts
            } else {
                localKeystrokeCount = liveTrackedCount
            }
            saveLocalCount()
        } else if cloudToday > localKeystrokeCount {
            localKeystrokeCount = cloudToday
            let cloudAppCounts = cachedSyncData.devices[deviceID]?.appCounts(for: today) ?? [:]
            if !cloudAppCounts.isEmpty { localAppCounts = cloudAppCounts }
            saveLocalCount()
        }
        cachedSyncData.devices[deviceID]?.setCount(localKeystrokeCount, for: today, appCounts: localAppCounts.isEmpty ? nil : localAppCounts)

        let total = cachedSyncData.totalCount(for: today)
        if total != totalKeystrokeCount {
            totalKeystrokeCount = total
            updateMenuBarTitle()
        }

        // Fold the pulled data into the iCloud file too, so the History window stays consistent.
        if let url = syncFileURL {
            let reconciled = cachedSyncData
            syncQueue.async {
                self.coordinatedSync(to: url) { existing in
                    var merged = existing
                    merged.merge(with: reconciled)
                    return merged
                }
            }
        }

        if !repairedDates.isEmpty {
            pushToCloud()
        }
    }

    @objc private func handleUpdateAvailable() {
        setStatusItemUpdateBadgeVisible(true)
        rebuildMenu()
        // A newer signed build is live — proactively present Sparkle's download-and-install prompt
        // instead of waiting for the user to open the menu. Silent if Sparkle finds nothing to do.
        updateChecker.promptForUpdateInBackground()
    }

    /// Key set to true only when the user explicitly turns "Start at Login" off from the menu.
    private let loginItemDisabledKey = "loginItemUserDisabled"

    /// Keep the app registered as a login item on every launch (self-heals a first-run failure or a
    /// registration that got cleared), unless the user has explicitly opted out via the menu toggle.
    private func ensureLoginItemEnabled() {
        guard !UserDefaults.standard.bool(forKey: loginItemDisabledKey) else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("Failed to enable launch at login: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        fileMonitor?.cancel()
        syncTimer?.invalidate()
        minuteSyncTimer?.invalidate()
        dayChangeTimer?.invalidate()
        permissionCheckTimer?.invalidate()
        updateCheckTimer?.invalidate()
        bucketFlushTimer?.invalidate()

        // Flush any pending high-res accumulations before exit.
        if !bucketAccum.isEmpty {
            eventStore.record(bucket: currentBucket, counts: bucketAccum)
            bucketAccum.removeAll()
        }
        eventStore.flushAndWait()

        checkDayChange()
        saveLocalCount()

        // URLSession tasks are normally cancelled when the process exits. Give the final cloud
        // upload a short bounded window so quitting fulfils the same sync guarantee as iCloud.
        pushToCloud(waitForCompletion: true)

        guard let url = syncFileURL else { return }
        let today = todayString()
        let finalCount = localKeystrokeCount

        let finalAppCounts = localAppCounts
        coordinatedSync(to: url) { existingData in
            var syncData = existingData
            if syncData.devices[self.deviceID] == nil {
                syncData.devices[self.deviceID] = DeviceData()
            }
            let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0
            if finalCount > existingCount {
                syncData.devices[self.deviceID]?.setCount(finalCount, for: today, appCounts: finalAppCounts.isEmpty ? nil : finalAppCounts)
            }
            return syncData
        }
    }

    // MARK: - Local Storage

    private func loadLocalCount() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: localDefaultsKey),
           let state = try? JSONDecoder().decode(LocalState.self, from: data) {
            if state.date == todayString() {
                localKeystrokeCount = state.count
                localAppCounts = state.appCounts ?? [:]
            } else {
                localKeystrokeCount = 0
                localAppCounts = [:]
            }
        }
        // In-memory counts now reflect today; record it so checkDayChange() only fires at rollover.
        activeDay = todayString()
    }

    private func saveLocalCount() {
        let state = LocalState(date: todayString(), count: localKeystrokeCount, appCounts: localAppCounts.isEmpty ? nil : localAppCounts)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: localDefaultsKey)
        }
    }

    // MARK: - Sync Storage

    private func loadAndReconcileCounts() {
        guard let url = syncFileURL else {
            totalKeystrokeCount = localKeystrokeCount
            saveLocalCount()
            return
        }

        coordinatedSync(to: url, forceMerge: false) { syncData in
            var updated = syncData
            let today = self.todayString()

            if updated.devices[self.deviceID] == nil {
                updated.devices[self.deviceID] = DeviceData()
            }

            let repairedDates = updated.repairAllCarriedDailyCounts()[self.deviceID] ?? []
            let reconciled = updated.devices[self.deviceID]!.reconcileLocalSnapshot(
                count: self.localKeystrokeCount,
                appCounts: self.localAppCounts,
                for: today
            )
            self.localKeystrokeCount = reconciled.count
            self.localAppCounts = reconciled.appCounts
            updated.devices[self.deviceID]?.setCount(
                reconciled.count,
                for: today,
                appCounts: reconciled.appCounts.isEmpty ? nil : reconciled.appCounts,
                reset: repairedDates.contains(today)
            )

            updated.pruneAllDevices(keepingDays: 60)
            self.cachedSyncData = updated
            self.totalKeystrokeCount = updated.totalCount(for: today)
            self.saveLocalCount()
            return updated
        }
    }

    private func coordinatedSync(to url: URL, forceMerge: Bool = true, transform: @escaping (SyncData) -> SyncData) {
        var coordinatorError: NSError?
        var readData = SyncData()

        fileCoordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinatorError
        ) { coordURL in
            if FileManager.default.fileExists(atPath: coordURL.path),
               let data = try? Data(contentsOf: coordURL),
               let existing = try? JSONDecoder().decode(SyncData.self, from: data) {
                readData = existing
            }

            var newData = transform(readData)

            if forceMerge,
               FileManager.default.fileExists(atPath: coordURL.path),
               let freshData = try? Data(contentsOf: coordURL),
               let freshSync = try? JSONDecoder().decode(SyncData.self, from: freshData) {
                newData.merge(with: freshSync)
            }

            if let encoded = try? JSONEncoder().encode(newData) {
                try? encoded.write(to: coordURL, options: .atomic)
            }
        }

        if let error = coordinatorError {
            print("File coordination error: \(error)")
        }
    }

    private func loadSyncData(from url: URL) -> SyncData {
        var result = SyncData()
        var coordinatorError: NSError?

        fileCoordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            guard FileManager.default.fileExists(atPath: coordURL.path),
                  let data = try? Data(contentsOf: coordURL),
                  let syncData = try? JSONDecoder().decode(SyncData.self, from: data) else {
                return
            }
            result = syncData
        }

        return result
    }

    private func syncToCloud() {
        // This must run before creating a cloud payload. The old order labelled yesterday's
        // cumulative count with today's date during the first timer tick after midnight.
        checkDayChange()

        // Best-effort push to the cloud backend (no-op unless the user connected).
        pushToCloud()

        guard let url = syncFileURL else { return }

        let today = todayString()
        let currentLocalCount = localKeystrokeCount
        let currentAppCounts = localAppCounts
        let currentCache = cachedSyncData

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            self.coordinatedSync(to: url) { existingData in
                var syncData = existingData
                // Preserve reset generations already accepted in memory. A delayed iCloud
                // conflict containing the old higher count must not resurrect it.
                syncData.merge(with: currentCache)

                if syncData.devices[self.deviceID] == nil {
                    syncData.devices[self.deviceID] = DeviceData()
                }

                let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0

                if currentLocalCount > existingCount {
                    syncData.devices[self.deviceID]?.setCount(currentLocalCount, for: today, appCounts: currentAppCounts.isEmpty ? nil : currentAppCounts)
                }

                return syncData
            }

            let syncData = self.loadSyncData(from: url)

            DispatchQueue.main.async {
                self.cachedSyncData = syncData
                // Re-apply local count — may have advanced while sync was in flight
                if self.cachedSyncData.devices[self.deviceID] == nil {
                    self.cachedSyncData.devices[self.deviceID] = DeviceData()
                }
                self.cachedSyncData.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts)
                self.lastSyncTime = Date()

                let reconciledTotal = self.cachedSyncData.totalCount(for: today)
                if reconciledTotal != self.totalKeystrokeCount {
                    self.totalKeystrokeCount = reconciledTotal
                    self.updateMenuBarTitle()
                }
            }
        }
    }

    // MARK: - File Monitoring

    private func startFileMonitor() {
        guard let url = syncFileURL else { return }

        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            coordinatedSync(to: url) { _ in SyncData() }
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        fileMonitor?.setCancelHandler {
            close(fd)
        }

        fileMonitor?.resume()
    }

    private func handleFileChange() {
        guard let url = syncFileURL else { return }

        checkDayChange()

        let today = todayString()

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            let syncData = self.loadSyncData(from: url)

            DispatchQueue.main.async {
                // Merge instead of replacing the cache so a stale iCloud notification cannot
                // discard a newer reset generation learned locally or from the SaaS service.
                var reconciled = self.cachedSyncData
                reconciled.merge(with: syncData)
                let repairedDates = reconciled.repairAllCarriedDailyCounts()[self.deviceID] ?? []

                if let cloudDeviceData = reconciled.devices[self.deviceID] {
                    let cloudCount = cloudDeviceData.count(for: today)
                    if repairedDates.contains(today) {
                        let cloudAppCounts = cloudDeviceData.appCounts(for: today)
                        let liveTrackedCount = self.localAppCounts.values.reduce(0, +)
                        if self.localAppCounts.isEmpty || liveTrackedCount < cloudCount {
                            self.localKeystrokeCount = cloudCount
                            self.localAppCounts = cloudAppCounts
                        } else {
                            self.localKeystrokeCount = liveTrackedCount
                        }
                        self.saveLocalCount()
                    }
                    if cloudCount > self.localKeystrokeCount {
                        self.localKeystrokeCount = cloudCount
                        let cloudAppCounts = cloudDeviceData.appCounts(for: today)
                        if !cloudAppCounts.isEmpty { self.localAppCounts = cloudAppCounts }
                        self.saveLocalCount()
                    }
                }

                self.cachedSyncData = reconciled
                // Re-apply local count — may have advanced while reading file
                if self.cachedSyncData.devices[self.deviceID] == nil {
                    self.cachedSyncData.devices[self.deviceID] = DeviceData()
                }
                self.cachedSyncData.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts)

                let reconciledTotal = self.cachedSyncData.totalCount(for: today)
                if reconciledTotal != self.totalKeystrokeCount {
                    self.totalKeystrokeCount = reconciledTotal
                    self.updateMenuBarTitle()
                }

                if !repairedDates.isEmpty {
                    self.pushToCloud()
                    let repaired = self.cachedSyncData
                    self.syncQueue.async {
                        self.coordinatedSync(to: url) { existing in
                            var merged = existing
                            merged.merge(with: repaired)
                            return merged
                        }
                    }
                }
            }
        }
    }

    // MARK: - Timers

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.syncToCloud()
            self?.cloudSync.pull()
        }
    }

    private func startMinuteSyncTimer() {
        if cloudSync.isConnected { uploadCompletedMinutes() }
        minuteSyncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.uploadCompletedMinutes()
        }
    }

    /// Scan at most twelve hours per batch. Advancing across idle ranges locally
    /// makes the initial 30-day backfill finite without uploading zero-activity
    /// minutes, which would reveal sleep/away patterns unnecessarily.
    private func uploadCompletedMinutes() {
        guard cloudSync.isConnected,
              let serverDeviceID = cloudSync.serverDeviceID,
              !minuteUploadInFlight else { return }

        let completedEnd = (Int(Date().timeIntervalSince1970) / 60) * 60
        let retentionStart = completedEnd - (30 * 24 * 60 * 60)
        let cursorKey = "cloudMinuteCursor.\(serverDeviceID)"
        let storedCursor = UserDefaults.standard.integer(forKey: cursorKey)
        let start = max(storedCursor > 0 ? storedCursor : retentionStart, retentionStart)
        guard start < completedEnd else { return }
        let scanEnd = min(start + (12 * 60 * 60), completedEnd)

        minuteUploadInFlight = true
        eventStore.minuteExport(startBucket: start, endBucket: scanEnd) { [weak self] export in
            guard let self else { return }
            if export.buckets.isEmpty {
                UserDefaults.standard.set(export.scannedThrough, forKey: cursorKey)
                self.minuteUploadInFlight = false
                DispatchQueue.main.async { self.uploadCompletedMinutes() }
                return
            }

            self.cloudSync.pushMinutes(clientDeviceID: self.deviceID, buckets: export.buckets) { acceptedThrough in
                DispatchQueue.main.async {
                    if acceptedThrough != nil {
                        UserDefaults.standard.set(export.scannedThrough, forKey: cursorKey)
                    }
                    self.minuteUploadInFlight = false
                    if acceptedThrough != nil && export.scannedThrough < completedEnd {
                        self.uploadCompletedMinutes()
                    }
                }
            }
        }
    }

    /// Fire at the next local midnight instead of waiting for a keypress or the five-minute sync.
    private func scheduleDayChangeTimer() {
        dayChangeTimer?.invalidate()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        dayChangeTimer = Timer(fire: tomorrow, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.checkDayChange()
            self.updateMenuBarTitle()
            self.rebuildMenu()
            self.pushToCloud()
            self.scheduleDayChangeTimer()
        }
        RunLoop.main.add(dayChangeTimer!, forMode: .common)
    }

    private func startPermissionCheckTimer() {
        permissionCheckTicks = 0
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.permissionCheckTicks += 1
            if AXIsProcessTrusted() {
                self.handlePermissionGranted()
                return
            }
            // Give TCC a couple seconds to warm up before showing the system prompt, so a
            // still-valid grant that briefly reads false at launch doesn't nag the user.
            if self.permissionCheckTicks == 2 {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            }
        }
    }

    /// Start monitoring and refresh the UI once the tap actually comes up. Idempotent.
    /// Only commits the granted state if `startMonitoring()` succeeds, so a TCC flag that reads
    /// trusted while the tap still won't create keeps the timer retrying instead of going dead.
    private func handlePermissionGranted() {
        guard !hasAccessibilityPermission else { return }
        guard startMonitoring() else { return }
        hasAccessibilityPermission = true
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        rebuildMenu()
        updateMenuBarTitle()
    }

    // MARK: - Helpers

    private func checkDayChange() {
        let today = todayString()
        guard today != activeDay else { return }

        // Finalize the old day before zeroing memory. Without this, the last unsaved (<50) keys
        // before midnight could disappear if the five-minute sync had not run yet.
        if !activeDay.isEmpty {
            let completedDay = activeDay
            let completedCount = localKeystrokeCount
            let completedAppCounts = localAppCounts
            if cachedSyncData.devices[deviceID] == nil {
                cachedSyncData.devices[deviceID] = DeviceData()
            }
            cachedSyncData.devices[deviceID]?.setCount(
                completedCount,
                for: completedDay,
                appCounts: completedAppCounts.isEmpty ? nil : completedAppCounts
            )
            if let url = syncFileURL {
                coordinatedSync(to: url) { existing in
                    var updated = existing
                    if updated.devices[self.deviceID] == nil {
                        updated.devices[self.deviceID] = DeviceData()
                    }
                    let storedCount = updated.devices[self.deviceID]?.count(for: completedDay) ?? 0
                    if completedCount > storedCount {
                        updated.devices[self.deviceID]?.setCount(
                            completedCount,
                            for: completedDay,
                            appCounts: completedAppCounts.isEmpty ? nil : completedAppCounts
                        )
                    }
                    return updated
                }
            }
        }

        activeDay = today
        localKeystrokeCount = 0
        localAppCounts = [:]
        totalKeystrokeCount = 0
        loadAndReconcileCounts()
    }

    /// Shared "yyyy-MM-dd" formatter — reused instead of allocating one per keystroke.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func todayString() -> String {
        AppDelegate.dayFormatter.string(from: Date())
    }

    private func yesterdayString() -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return AppDelegate.dayFormatter.string(from: yesterday)
    }

    private func formatCount(_ count: Int) -> String {
        CountFormatter.compact(count)
    }

    private static let fullCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formatCountFull(_ count: Int) -> String {
        AppDelegate.fullCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private struct SectionStats {
        let today: Int
        let yesterday: Int
        let avg7: Double
        let avg30: Double
        let recordCount: Int
        let recordDate: String?
    }

    /// Cross-device keyboard totals per day, keyed by "yyyy-MM-dd".
    private func keyboardDaily() -> [String: Int] {
        var dates = Set<String>()
        for device in cachedSyncData.devices.values {
            dates.formUnion(device.dailyCounts.keys)
        }
        var result: [String: Int] = [:]
        for date in dates {
            result[date] = cachedSyncData.totalCount(for: date)
        }
        return result
    }

    /// Compute the today / yesterday / 7-day / 30-day / record summary from a per-day total map.
    /// Averages count only days with data, matching `SyncData.averageCount`.
    private func computeSectionStats(daily: [String: Int]) -> SectionStats {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        func avg(_ days: Int) -> Double {
            var total = 0, n = 0
            for i in 0..<days {
                guard let d = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
                if let c = daily[formatter.string(from: d)], c > 0 { total += c; n += 1 }
            }
            return n > 0 ? Double(total) / Double(n) : 0
        }

        var recordCount = 0
        var recordDate: String?
        for (date, count) in daily where count > recordCount {
            recordCount = count
            recordDate = date
        }

        return SectionStats(
            today: daily[todayString()] ?? 0,
            yesterday: daily[yesterdayString()] ?? 0,
            avg7: avg(7),
            avg30: avg(30),
            recordCount: recordCount,
            recordDate: recordDate
        )
    }

    private func formatDateShort(_ dateString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        guard let date = inputFormatter.date(from: dateString) else {
            return dateString
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MM/dd"
        return outputFormatter.string(from: date)
    }

    // MARK: - Menu Bar Icons

    private func createKeyboardIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale: CGFloat = 18.0 / 24.0
            let lineWidth: CGFloat = 1.5

            // Use yellow for dev builds, black for release
            let color = isDevBuild ? NSColor.systemYellow : NSColor.black
            color.setStroke()

            let bodyRect = NSRect(x: 3 * scale, y: 6 * scale, width: 18 * scale, height: 12 * scale)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 2 * scale, yRadius: 2 * scale)
            body.lineWidth = lineWidth
            body.stroke()

            let spacebar = NSBezierPath()
            spacebar.move(to: NSPoint(x: 10 * scale, y: 14 * scale))
            spacebar.line(to: NSPoint(x: 14 * scale, y: 14 * scale))
            spacebar.lineWidth = lineWidth
            spacebar.lineCapStyle = .round
            spacebar.stroke()

            let dotRadius: CGFloat = 0.8
            let dots: [(CGFloat, CGFloat)] = [
                (6.5, 10), (6.5, 14),
                (10, 10),
                (14, 10),
                (17.5, 10), (17.5, 14)
            ]

            for (x, y) in dots {
                let dotRect = NSRect(
                    x: x * scale - dotRadius,
                    y: y * scale - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                let dot = NSBezierPath(ovalIn: dotRect)
                color.setFill()
                dot.fill()
            }

            return true
        }

        // Only use template mode for release builds (so they adapt to dark mode)
        // Dev builds use explicit yellow color
        image.isTemplate = !isDevBuild
        return image
    }

    private func createWarningIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let str = "\u{26A0}\u{FE0E}"
            let font = NSFont.systemFont(ofSize: 14)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attrStr = NSAttributedString(string: str, attributes: attrs)
            let strSize = attrStr.size()
            let point = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            attrStr.draw(at: point)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        theMenu = NSMenu()
        theMenu.delegate = self
        statusItem.menu = theMenu
        updateMenuBarTitle()
        rebuildMenu()
    }

    private func rebuildMenu() {
        theMenu.removeAllItems()

        // Update blue dot visibility based on update availability
        setStatusItemUpdateBadgeVisible(updateChecker.updateAvailable)

        if let newVersion = updateChecker.availableVersion {
            let header = NSMenuItem(title: "Update available", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: "Update available",
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
            theMenu.addItem(header)
            theMenu.addItem(NSMenuItem(
                title: "Install v\(newVersion)\u{2026}",
                action: #selector(installUpdate),
                keyEquivalent: ""
            ))
            theMenu.addItem(NSMenuItem.separator())
        }

        if !hasAccessibilityPermission {
            let permissionItem = NSMenuItem(
                title: "\u{26A0}\u{FE0E} Grant Accessibility Permission",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
            theMenu.addItem(permissionItem)
            theMenu.addItem(NSMenuItem.separator())
        }

        addStatsSection(title: "Keyboard", daily: keyboardDaily(), distance: false)
        theMenu.addItem(NSMenuItem.separator())
        addStatsSection(title: "Clicks", daily: clickDaily, distance: false)
        theMenu.addItem(NSMenuItem.separator())
        addStatsSection(title: "Movement", daily: moveDaily, distance: true)

        theMenu.addItem(NSMenuItem.separator())

        theMenu.addItem(NSMenuItem(
            title: "View History...",
            action: #selector(openHistory),
            keyEquivalent: ""
        ))

        theMenu.addItem(NSMenuItem.separator())

        addCloudSyncSection()

        theMenu.addItem(NSMenuItem(
            title: "Privacy Details…",
            action: #selector(showPrivacyDetails),
            keyEquivalent: ""
        ))

        theMenu.addItem(NSMenuItem.separator())

        let launchAtLogin = SMAppService.mainApp.status == .enabled
        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = launchAtLogin ? .on : .off
        theMenu.addItem(loginItem)

        theMenu.addItem(NSMenuItem.separator())

        theMenu.addItem(NSMenuItem(
            title: "About Input Stats",
            action: #selector(showAbout),
            keyEquivalent: ""
        ))

        theMenu.addItem(NSMenuItem.separator())

        theMenu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        if NSEvent.modifierFlags.contains(.option) {
            theMenu.addItem(NSMenuItem.separator())

            let debugHeader = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            debugHeader.isEnabled = false
            theMenu.addItem(debugHeader)

            let lastSyncString: String
            if let lastSync = lastSyncTime {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                lastSyncString = formatter.string(from: lastSync)
            } else {
                lastSyncString = "Never"
            }
            let syncItem = NSMenuItem(title: "Last sync: \(lastSyncString)", action: nil, keyEquivalent: "")
            syncItem.isEnabled = false
            theMenu.addItem(syncItem)

            let deviceItem = NSMenuItem(title: "Device: \(String(deviceID.prefix(8)))...", action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            theMenu.addItem(deviceItem)

            theMenu.addItem(NSMenuItem(
                title: "Reset Today",
                action: #selector(resetToday),
                keyEquivalent: ""
            ))
        }
    }

    /// Render a bold section header followed by the today/yesterday/avg/record rows for `daily`.
    /// `distance` formats values as pixels (pointer movement) rather than plain counts.
    private func addStatsSection(title: String, daily: [String: Int], distance: Bool) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        theMenu.addItem(header)

        let stats = computeSectionStats(daily: daily)
        func fmt(_ n: Int) -> String { distance ? "\(formatCountFull(n)) px" : formatCountFull(n) }

        func addRow(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            theMenu.addItem(item)
        }

        addRow("Today: \(fmt(stats.today))")
        addRow("Yesterday: \(fmt(stats.yesterday))")
        addRow("7-day avg: \(fmt(Int(stats.avg7)))")
        addRow("30-day avg: \(fmt(Int(stats.avg30)))")
        if let recordDate = stats.recordDate {
            addRow("Record: \(fmt(stats.recordCount)) (\(formatDateShort(recordDate)))")
        }
    }

    /// Cloud-sync menu row: a "Sign in to Sync…" CTA, or the connected account + sign-out.
    private func addCloudSyncSection() {
        if cloudSync.isConnected {
            let label: String
            if let error = cloudSync.lastError {
                label = "Cloud sync issue: \(error)"
            } else {
                label = cloudSync.accountEmail.map { "Synced: \($0)" } ?? "Synced to cloud"
            }
            let status = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            status.isEnabled = false
            theMenu.addItem(status)
            if cloudSync.lastError != nil {
                theMenu.addItem(NSMenuItem(
                    title: "Retry Cloud Sync",
                    action: #selector(retryCloudSync),
                    keyEquivalent: ""
                ))
            }
            theMenu.addItem(NSMenuItem(
                title: "Open Cloud Dashboard",
                action: #selector(openCloudDashboard),
                keyEquivalent: ""
            ))
            theMenu.addItem(NSMenuItem(
                title: "Share Public Profile\u{2026}",
                action: #selector(openPublicProfileSettings),
                keyEquivalent: ""
            ))
            theMenu.addItem(NSMenuItem(
                title: "Sign Out of Cloud Sync",
                action: #selector(signOutOfCloud),
                keyEquivalent: ""
            ))
        } else if cloudSync.isConnecting {
            let status = NSMenuItem(
                title: cloudSync.lastError ?? "Finishing cloud sign-in…",
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            theMenu.addItem(status)
            theMenu.addItem(NSMenuItem(
                title: "Try Cloud Sign-In Again…",
                action: #selector(signInToCloud),
                keyEquivalent: ""
            ))
            theMenu.addItem(NSMenuItem(
                title: "Enter Connection Code…",
                action: #selector(enterCloudConnectionCode),
                keyEquivalent: ""
            ))
        } else {
            if let error = cloudSync.lastError {
                let status = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                status.isEnabled = false
                theMenu.addItem(status)
            }
            theMenu.addItem(NSMenuItem(
                title: "Sign in to Sync\u{2026}",
                action: #selector(signInToCloud),
                keyEquivalent: ""
            ))
        }
    }

    @objc private func signInToCloud() {
        cloudSync.beginLogin(
            clientDeviceID: deviceID,
            deviceName: Host.current().localizedName ?? "Mac"
        )
    }

    @objc private func enterCloudConnectionCode() {
        let alert = NSAlert()
        alert.messageText = "Enter Connection Code"
        alert.informativeText = "Paste the eight-character code shown in your browser."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "ABCD-2345"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        cloudSync.completePairing(code: code)
    }

    @objc private func openCloudDashboard() {
        NSWorkspace.shared.open(cloudSync.baseURL.appendingPathComponent("dashboard"))
    }

    /// The profile is off by default; the web settings page is where it gets switched on and shared.
    @objc private func openPublicProfileSettings() {
        NSWorkspace.shared.open(cloudSync.baseURL.appendingPathComponent("dashboard/profile"))
    }

    @objc private func signOutOfCloud() {
        cloudSync.signOut()
    }

    @objc private func retryCloudSync() {
        pushToCloud()
        cloudSync.pull()
    }

    @objc private func showPrivacyDetails() {
        let alert = NSAlert()
        alert.messageText = "Counts, never content"
        alert.informativeText = "When account sync is on, Input Stats sends completed one-minute numeric totals: keys, left/right/other clicks, scroll ticks, pointer distance, timezone offset, app/OS version, and exact app bundle IDs for private per-app counts.\n\nIt never captures or sends typed characters, key codes, window titles, URLs, clipboard contents, file paths, screenshots, or raw input events. Five-second detail stays on this Mac."
        alert.addButton(withTitle: "Open Full Privacy Details")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(cloudSync.baseURL.appendingPathComponent("privacy"))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        checkDayChange()
        // Re-check live so a grant that read false at launch never leaves a stale CTA in the menu.
        if !hasAccessibilityPermission && AXIsProcessTrusted() {
            handlePermissionGranted()
        }
        rebuildMenu()
        updateMenuBarTitle()
        // Clicks/Distance come from the local SQLite store; fetch async and re-render in place.
        eventStore.dailyTotals(kinds: EventKind.clickKinds + [.move]) { [weak self] totals in
            guard let self = self else { return }
            var clicks: [String: Int] = [:]
            for kind in EventKind.clickKinds {
                for (date, count) in totals[kind] ?? [:] {
                    clicks[date, default: 0] += count
                }
            }
            self.clickDaily = clicks
            self.moveDaily = totals[.move] ?? [:]
            self.rebuildMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        updateMenuBarTitle()
    }

    // The menu-bar icons never change at runtime (they depend only on permission state), so build
    // each once and reuse it — recreating an NSImage + drawingHandler on every keystroke was pure churn.
    private lazy var keyboardIcon: NSImage = createKeyboardIcon()
    private lazy var warningIcon: NSImage = createWarningIcon()
    private static let menuBarFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func updateMenuBarTitle() {
        let count = menuIsOpen ? formatCountFull(totalKeystrokeCount) : formatCount(totalKeystrokeCount)
        let title = count + (isDevBuild ? " (dev)" : "")

        DispatchQueue.main.async {
            guard let button = self.statusItem?.button else { return }

            let attributes: [NSAttributedString.Key: Any] = [.font: AppDelegate.menuBarFont]
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: attributes)

            let icon = self.hasAccessibilityPermission ? self.keyboardIcon : self.warningIcon
            if button.image !== icon { button.image = icon }
        }
    }

    private func setStatusItemUpdateBadgeVisible(_ visible: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        if updateDotLayer == nil {
            let diameter: CGFloat = 6
            let layer = CALayer()
            layer.backgroundColor = NSColor.systemBlue.cgColor
            layer.cornerRadius = diameter / 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.cgColor
            // Position near top-right with a small inset
            layer.frame = CGRect(
                x: button.bounds.width - diameter - 2,
                y: button.bounds.height - diameter - 2,
                width: diameter,
                height: diameter
            )
            layer.autoresizingMask = [.layerMinXMargin, .layerMinYMargin]
            button.layer?.addSublayer(layer)
            updateDotLayer = layer
        }
        updateDotLayer?.isHidden = !visible
    }

    // MARK: - Menu Actions

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openHistory() {
        guard let url = syncFileURL else { return }

        checkDayChange()

        historyWindowController = HistoryWindowController(syncData: cachedSyncData, dataFileURL: url)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resetToday() {
        let alert = NSAlert()
        alert.messageText = "Reset Today's Count?"
        alert.informativeText = "This will reset your keystroke count to 0 for today on this device. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            localKeystrokeCount = 0
            localAppCounts = [:]
            saveLocalCount()

            let today = todayString()

            if cachedSyncData.devices[deviceID] == nil {
                cachedSyncData.devices[deviceID] = DeviceData()
            }
            cachedSyncData.devices[deviceID]?.setCount(0, for: today, appCounts: nil, reset: true)
            totalKeystrokeCount = cachedSyncData.totalCount(for: today)
            updateMenuBarTitle()

            // The SaaS merge is max-based within a reset generation. Push the new generation now
            // so a subsequent pull cannot bring the pre-reset count back.
            pushToCloud()

            // Write reset to iCloud file async
            if let url = syncFileURL {
                syncQueue.async {
                    self.coordinatedSync(to: url, forceMerge: false) { existingData in
                        var syncData = existingData
                        if syncData.devices[self.deviceID] == nil {
                            syncData.devices[self.deviceID] = DeviceData()
                        }
                        syncData.devices[self.deviceID]?.setCount(0, for: today, appCounts: nil, reset: true)
                        return syncData
                    }
                }
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
                // Remember the explicit opt-out so ensureLoginItemEnabled() doesn't re-enable it.
                UserDefaults.standard.set(true, forKey: loginItemDisabledKey)
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                UserDefaults.standard.set(false, forKey: loginItemDisabledKey)
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private var aboutWindowController: AboutWindowController?

    @objc private func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(updateChecker: updateChecker)
        }
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installUpdate() {
        updateChecker.installUpdate()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Keystroke Monitoring

    /// Create and enable the event tap. Returns true only if the tap was actually created —
    /// `tapCreate` fails (returns nil) when the process isn't really trusted, which happens with a
    /// stale Accessibility grant after re-signing even though `AXIsProcessTrusted()` may read true.
    /// Callers use the return value as the source of truth for "are we monitoring", not the TCC check.
    @discardableResult
    private func startMonitoring() -> Bool {
        let trackedTypes: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        var eventMask: CGEventMask = 0
        for type in trackedTypes {
            eventMask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        // Trackpad gestures (rotate/magnify/swipe/smart-zoom) have no CGEventType case but flow
        // through the tap under their NSEvent.EventType raw values.
        for raw in GestureEventType.allCases {
            eventMask |= CGEventMask(1) << CGEventMask(raw.rawValue)
        }
        eventMask |= CGEventMask(1) << CGEventMask(GestureEventType.pressureEventType)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                if let refcon = refcon {
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    appDelegate.handleTapEvent(type: type, event: event)
                }
                // `event` is a borrowed reference owned by the tap. Pass it back UNretained —
                // returning `passRetained` here adds a CFRetain the tap never balances, leaking
                // one CGEvent per delivered event (mouse-moves alone are hundreds/sec → GBs).
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        currentBucket = EventStore.bucket()

        // Flush idle-tail accumulations even when no events arrive to roll the bucket over.
        bucketFlushTimer = Timer.scheduledTimer(withTimeInterval: Double(EventStore.baseBucketSeconds), repeats: true) { [weak self] _ in
            self?.rolloverBucketIfNeeded()
        }
        return true
    }

    // MARK: - High-Resolution Event Accumulation

    private func startFrontmostAppTracking() {
        currentAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.currentAppBundleID = app?.bundleIdentifier ?? "unknown"
        }
    }

    /// Flush the previous bucket's accumulations once wall-clock crosses into a new 5s bucket.
    private func rolloverBucketIfNeeded() {
        let b = EventStore.bucket()
        guard b != currentBucket else { return }
        if !bucketAccum.isEmpty {
            eventStore.record(bucket: currentBucket, counts: bucketAccum)
            bucketAccum.removeAll(keepingCapacity: true)
        }
        currentBucket = b
    }

    /// Add `amount` of `kind` (count, or pixels for `.move`) to the current bucket for the frontmost
    /// app, attributed to `device` (a `devices` row id).
    private func accumulate(_ kind: EventKind, amount: Int, device: Int, display: Int = DisplayTarget.unknownID) {
        guard amount != 0 else { return }
        rolloverBucketIfNeeded()
        let key = EventStore.BucketKey(kind: kind.rawValue, app: currentAppBundleID,
                                       device: device, display: display)
        bucketAccum[key, default: 0] += amount
    }

    /// Routes a tap event to keystroke counting and/or the high-res store. Runs on the main run loop.
    func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            handleKeyEvent(event)
        case .flagsChanged:
            let presses = modifierDetector.pressesOnUpdate(flags: event.flags.rawValue)
            if presses > 0 {
                accumulate(.modifier, amount: presses, device: deviceResolver.deviceID(for: event, role: .keyboard))
            }
        case .leftMouseDown:
            let device = deviceResolver.deviceID(for: event, role: .pointer)
            let screen = displayResolver.displayID(at: event.location)
            accumulate(.click, amount: 1, device: device, display: screen)
            switch event.getIntegerValueField(.mouseEventClickState) {
            case 2: accumulate(.doubleClick, amount: 1, device: device, display: screen)
            case 3: accumulate(.tripleClick, amount: 1, device: device, display: screen)
            default: break
            }
        case .rightMouseDown:
            accumulate(.rightClick, amount: 1, device: deviceResolver.deviceID(for: event, role: .pointer),
                       display: displayResolver.displayID(at: event.location))
        case .otherMouseDown:
            let device = deviceResolver.deviceID(for: event, role: .pointer)
            let screen = displayResolver.displayID(at: event.location)
            accumulate(.otherClick, amount: 1, device: device, display: screen)
            // Buttons 3/4 are the near/far thumb buttons on most mice (back/forward in browsers).
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 3: accumulate(.backClick, amount: 1, device: device, display: screen)
            case 4: accumulate(.forwardClick, amount: 1, device: device, display: screen)
            default: break
            }
        case .scrollWheel:
            let device = deviceResolver.deviceID(for: event, role: .pointer)
            let screen = displayResolver.displayID(at: event.location)
            accumulate(.scroll, amount: 1, device: device, display: screen)
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
                accumulate(.scrollMomentum, amount: 1, device: device, display: screen)
            }
            // Axis 2 is horizontal. Pixel deltas are only meaningful for continuous (trackpad /
            // Magic Mouse) scrolling; a notched wheel reports 0 there and only contributes ticks.
            if event.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0 {
                accumulate(.scrollHorizontal, amount: 1, device: device, display: screen)
            }
            let scrollPixels = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                + abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            accumulate(.scrollDistance, amount: Int(scrollPixels), device: device, display: screen)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let dist = Int((dx * dx + dy * dy).squareRoot().rounded())
            let device = deviceResolver.deviceID(for: event, role: .pointer)
            let screen = displayResolver.displayID(at: event.location)
            accumulate(.move, amount: dist, device: device, display: screen)
            if type != .mouseMoved {
                accumulate(.drag, amount: dist, device: device, display: screen)
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            if type.rawValue == GestureEventType.pressureEventType {
                if isForceClick(event) {
                    accumulate(.forceClick, amount: 1, device: deviceResolver.deviceID(for: event, role: .pointer))
                }
            } else if let gesture = GestureEventType(rawValue: type.rawValue), gesture.countsAsGesture(event) {
                let device = deviceResolver.deviceID(for: event, role: .pointer)
                accumulate(.gesture, amount: 1, device: device)
                accumulate(gesture.kind, amount: 1, device: device)
            }
        }
    }

    /// A Force click is a deep press: the pressure stage crosses into 2. Only report the crossing,
    /// since the trackpad streams pressure events continuously while the finger is down.
    private func isForceClick(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        let stage = nsEvent.stage
        defer { lastPressureStage = stage }
        return stage >= 2 && lastPressureStage < 2
    }

    func handleKeyEvent(_ event: CGEvent) {
        checkDayChange()

        // Track which app received this keystroke
        let bundleID = currentAppBundleID
        localAppCounts[bundleID, default: 0] += 1

        // High-res timeseries (local-only). `.key` is the headline count; the rest are overlays:
        // what was pressed (composition) and how (repeat / shortcut / software-injected).
        let device = deviceResolver.deviceID(for: event, role: .keyboard)
        accumulate(.key, amount: 1, device: device)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        accumulate(KeyClass.classify(keyCode: keyCode).kind, amount: 1, device: device)
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            accumulate(.keyRepeat, amount: 1, device: device)
        }
        if InputDeviceResolver.isSynthetic(event) {
            accumulate(.keySynthetic, amount: 1, device: device)
        }
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            accumulate(.keyShortcut, amount: 1, device: device)
        }

        localKeystrokeCount += 1
        totalKeystrokeCount += 1

        // Keep cache current so menu reads never hit disk
        if cachedSyncData.devices[deviceID] == nil {
            cachedSyncData.devices[deviceID] = DeviceData()
        }
        cachedSyncData.devices[deviceID]?.setCount(localKeystrokeCount, for: todayString(), appCounts: localAppCounts.isEmpty ? nil : localAppCounts)

        updateMenuBarTitle()

        if localKeystrokeCount % 50 == 0 {
            saveLocalCount()
        }

        // Flush to iCloud file in background
        if localKeystrokeCount % 1000 == 0 {
            syncToCloud()
        }
    }
}
