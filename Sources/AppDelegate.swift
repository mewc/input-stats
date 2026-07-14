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
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastSyncTime: Date?
    // in-memory cache; disk syncs happen async
    private var cachedSyncData = SyncData()
    private var updateChecker = UpdateChecker.shared
    private var updateCheckTimer: Timer?
    private var updateDotLayer: CALayer?

    // High-resolution local timeseries (keys + mouse/trackpad). Local-only, never synced.
    private let eventStore = EventStore.shared
    private var currentBucket: Int = 0
    private var bucketAccum: [EventStore.BucketKey: Int] = [:]
    private var bucketFlushTimer: Timer?
    // Cached frontmost app bundle ID, refreshed on app-activation (avoids per-event lookups).
    private var currentAppBundleID: String = "unknown"

    // Per-day local totals for clicks and pointer movement (px), keyed by "yyyy-MM-dd".
    // Refreshed async from EventStore when the menu opens; powers the menu's Clicks/Distance sections.
    private var clickDaily: [String: Int] = [:]
    private var moveDaily: [String: Int] = [:]

    // The day our in-memory counts belong to. Lets `checkDayChange()` detect a midnight rollover
    // with a cheap string compare instead of decoding JSON from UserDefaults on every keystroke.
    private var activeDay: String = ""

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

        coordinatedSync(to: url) { syncData in
            var updated = syncData
            let today = self.todayString()

            if updated.devices[self.deviceID] == nil {
                updated.devices[self.deviceID] = DeviceData()
            }

            let existingCount = updated.devices[self.deviceID]?.count(for: today) ?? 0

            if self.localKeystrokeCount == 0 {
                // Fresh start for today - reset cloud to 0, don't pull corrupted data
                updated.devices[self.deviceID]?.setCount(0, for: today, appCounts: nil)
            } else if self.localKeystrokeCount > existingCount {
                updated.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts)
            } else {
                self.localKeystrokeCount = existingCount
                // Also load app counts from cloud if available
                let cloudAppCounts = updated.devices[self.deviceID]?.appCounts(for: today) ?? [:]
                if !cloudAppCounts.isEmpty {
                    self.localAppCounts = cloudAppCounts
                }
            }

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
        guard let url = syncFileURL else { return }

        checkDayChange()

        let today = todayString()
        let currentLocalCount = localKeystrokeCount
        let currentAppCounts = localAppCounts

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            self.coordinatedSync(to: url) { existingData in
                var syncData = existingData

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

            if let cloudDeviceData = syncData.devices[self.deviceID] {
                let cloudCount = cloudDeviceData.count(for: today)
                if cloudCount > self.localKeystrokeCount {
                    DispatchQueue.main.async {
                        self.localKeystrokeCount = cloudCount
                        self.saveLocalCount()
                    }
                }
            }

            DispatchQueue.main.async {
                self.cachedSyncData = syncData
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
            }
        }
    }

    // MARK: - Timers

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.syncToCloud()
        }
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
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: "%.2fM", m)
        } else if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "%.2fk", k)
        }
        return "\(count)"
    }

    private func formatCountFull(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
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

    func menuWillOpen(_ menu: NSMenu) {
        checkDayChange()
        // Re-check live so a grant that read false at launch never leaves a stale CTA in the menu.
        if !hasAccessibilityPermission && AXIsProcessTrusted() {
            handlePermissionGranted()
        }
        rebuildMenu()
        // Clicks/Distance come from the local SQLite store; fetch async and re-render in place.
        eventStore.dailyTotals(kinds: [.click, .move]) { [weak self] totals in
            guard let self = self else { return }
            self.clickDaily = totals[.click] ?? [:]
            self.moveDaily = totals[.move] ?? [:]
            self.rebuildMenu()
        }
    }

    // The menu-bar icons never change at runtime (they depend only on permission state), so build
    // each once and reuse it — recreating an NSImage + drawingHandler on every keystroke was pure churn.
    private lazy var keyboardIcon: NSImage = createKeyboardIcon()
    private lazy var warningIcon: NSImage = createWarningIcon()
    private static let menuBarFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func updateMenuBarTitle() {
        let title = formatCount(totalKeystrokeCount) + (isDevBuild ? " (dev)" : "")

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
            cachedSyncData.devices[deviceID]?.setCount(0, for: today, appCounts: nil)
            totalKeystrokeCount = cachedSyncData.totalCount(for: today)
            updateMenuBarTitle()

            // Write reset to iCloud file async
            if let url = syncFileURL {
                syncQueue.async {
                    self.coordinatedSync(to: url, forceMerge: false) { existingData in
                        var syncData = existingData
                        if syncData.devices[self.deviceID] == nil {
                            syncData.devices[self.deviceID] = DeviceData()
                        }
                        syncData.devices[self.deviceID]?.setCount(0, for: today, appCounts: nil)
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
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        var eventMask: CGEventMask = 0
        for type in trackedTypes {
            eventMask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }

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

    /// Add `amount` of `kind` (count, or pixels for `.move`) to the current bucket for the frontmost app.
    private func accumulate(_ kind: EventKind, amount: Int) {
        guard amount != 0 else { return }
        rolloverBucketIfNeeded()
        let key = EventStore.BucketKey(kind: kind.rawValue, app: currentAppBundleID)
        bucketAccum[key, default: 0] += amount
    }

    /// Routes a tap event to keystroke counting and/or the high-res store. Runs on the main run loop.
    func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            handleKeyEvent()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            accumulate(.click, amount: 1)
        case .scrollWheel:
            accumulate(.scroll, amount: 1)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let dist = Int((dx * dx + dy * dy).squareRoot().rounded())
            accumulate(.move, amount: dist)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    func handleKeyEvent() {
        checkDayChange()

        // Track which app received this keystroke
        let bundleID = currentAppBundleID
        localAppCounts[bundleID, default: 0] += 1

        // High-res timeseries (local-only)
        accumulate(.key, amount: 1)

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
