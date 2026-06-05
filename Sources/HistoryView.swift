import SwiftUI
import Charts
import Cocoa
import Combine

// MARK: - Data Store for Reactive Updates

class HistoryDataStore: ObservableObject {
    @Published var syncData: SyncData
    let dataFileURL: URL?
    private let fileCoordinator = NSFileCoordinator()
    
    init(syncData: SyncData, dataFileURL: URL?) {
        self.syncData = syncData
        self.dataFileURL = dataFileURL
    }
    
    func reload() {
        guard let url = dataFileURL else { return }
        var coordinatorError: NSError?
        
        // Note: fileCoordinator.coordinate may call its closure on a background thread,
        // so we dispatch the @Published property update to main thread for thread safety
        fileCoordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            guard FileManager.default.fileExists(atPath: coordURL.path),
                  let data = try? Data(contentsOf: coordURL),
                  let newSyncData = try? JSONDecoder().decode(SyncData.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.syncData = newSyncData
            }
        }
    }
}

// MARK: - Data Models

struct AppBreakdown: Identifiable, Equatable {
    let id: String  // Use bundleID as stable ID
    let bundleID: String
    let displayName: String
    let count: Int
    let color: Color

    init(bundleID: String, displayName: String, count: Int, color: Color) {
        self.id = bundleID
        self.bundleID = bundleID
        self.displayName = displayName
        self.count = count
        self.color = color
    }

    static func == (lhs: AppBreakdown, rhs: AppBreakdown) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.count == rhs.count
    }
}

struct DailyDataWithApps: Identifiable, Equatable {
    let id: String  // Use dateString as stable ID
    let date: Date
    let dateString: String
    let totalCount: Int
    let appBreakdown: [AppBreakdown]

    init(date: Date, dateString: String, totalCount: Int, appBreakdown: [AppBreakdown]) {
        self.id = dateString
        self.date = date
        self.dateString = dateString
        self.totalCount = totalCount
        self.appBreakdown = appBreakdown
    }

    static func == (lhs: DailyDataWithApps, rhs: DailyDataWithApps) -> Bool {
        lhs.dateString == rhs.dateString && lhs.totalCount == rhs.totalCount && lhs.appBreakdown == rhs.appBreakdown
    }
}

// MARK: - App Color & Name Utilities

struct AppColorManager {
    // Reverse rainbow colors starting from red
    static let colors: [Color] = [
        .red,
        .orange,
        .yellow,
        .green,
        .cyan,
        .blue,
        .indigo,
        .purple,
        .pink,
        .mint
    ]

    static let othersColor = Color.gray

    static func color(for index: Int) -> Color {
        if index < colors.count {
            return colors[index]
        }
        return othersColor
    }
}

class AppDisplayNameCache {
    static let shared = AppDisplayNameCache()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    func displayName(for bundleID: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[bundleID] {
            return cached
        }

        let name = resolveDisplayName(for: bundleID)
        cache[bundleID] = name
        return name
    }

    private func resolveDisplayName(for bundleID: String) -> String {
        if bundleID == "unknown" {
            return "Unknown"
        }
        if bundleID == "others" {
            return "Others"
        }

        // Try to get the running application's localized name
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }

        // Try to get app name from bundle URL
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: bundleURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }

        // Fallback: extract app name from bundle ID
        let components = bundleID.components(separatedBy: ".")
        if let lastComponent = components.last {
            return lastComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
        return bundleID
    }
}

func getAppDisplayName(for bundleID: String) -> String {
    AppDisplayNameCache.shared.displayName(for: bundleID)
}

// MARK: - Chart Section (Isolated to prevent re-renders)

struct ChartSection: View, Equatable {
    let chartData: [DailyDataWithApps]
    let selectedDays: Int
    @State private var hoveredDay: DailyDataWithApps?
    @State private var tooltipPosition: CGPoint = .zero

    static func == (lhs: ChartSection, rhs: ChartSection) -> Bool {
        lhs.chartData == rhs.chartData && lhs.selectedDays == rhs.selectedDays
    }

    var body: some View {
        Chart {
            ForEach(chartData) { day in
                ForEach(day.appBreakdown) { app in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Count", app.count)
                    )
                    .foregroundStyle(app.color)
                    .opacity(hoveredDay == nil || hoveredDay?.id == day.id ? 1.0 : 0.3)
                }
            }
            if let day = hoveredDay {
                RuleMark(x: .value("Date", day.date, unit: .day))
                    .foregroundStyle(.gray.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .frame(height: 150)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, selectedDays / 7))) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let date: Date = proxy.value(atX: location.x) else {
                                hoveredDay = nil
                                return
                            }
                            let calendar = Calendar.current
                            hoveredDay = chartData.first { item in
                                calendar.isDate(item.date, inSameDayAs: date)
                            }
                            tooltipPosition = CGPoint(x: location.x, y: 0)
                        case .ended:
                            hoveredDay = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let day = hoveredDay {
                ChartTooltip(day: day)
                    .offset(x: max(0, min(tooltipPosition.x - 70, 400)), y: -4)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ChartTooltip: View {
    let day: DailyDataWithApps

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipDateFormatter.string(from: day.date))
                .font(.system(size: 10, weight: .semibold))
            ForEach(day.appBreakdown) { app in
                HStack(spacing: 4) {
                    Circle()
                        .fill(app.color)
                        .frame(width: 6, height: 6)
                    Text(app.displayName)
                        .font(.system(size: 9))
                    Spacer()
                    Text("\(day.totalCount > 0 ? Int(round(Double(app.count) / Double(day.totalCount) * 100)) : 0)%")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                }
            }
            HStack {
                Text("Total")
                    .font(.system(size: 9, weight: .medium))
                Spacer()
                Text("\(day.totalCount)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
            }
            .padding(.top, 1)
        }
        .padding(6)
        .frame(width: 140)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 4)
    }
}

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var dataStore: HistoryDataStore
    @State private var tab = 0       // 0 = Keys, 1 = Mouse
    @State private var viewMode = 0  // 0 = Daily, 1 = Timeseries
    @State private var selectedDays = 7
    @State private var hiddenApps: Set<String> = []  // bundleIDs to hide from stats
    @State private var expandedDays: Set<String> = []  // dateStrings of expanded rows
    @State private var cachedTopApps: [(bundleID: String, count: Int, color: Color)] = []

    // Top 5 apps for current period + Others (including untracked)
    private func computeTopAppsForPeriod() -> [(bundleID: String, count: Int, color: Color)] {
        let appCounts = dataStore.syncData.totalAppCounts(forDays: selectedDays, from: Date())
        let sorted = appCounts.sorted { $0.value > $1.value }
        
        // Calculate total keystrokes vs tracked keystrokes for the period
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var totalKeystrokes = 0
        var trackedKeystrokes = 0
        for i in 0..<selectedDays {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateString = formatter.string(from: date)
            totalKeystrokes += dataStore.syncData.totalCount(for: dateString)
            trackedKeystrokes += dataStore.syncData.totalAppCounts(for: dateString).values.reduce(0, +)
        }
        let untrackedCount = totalKeystrokes - trackedKeystrokes
        
        var result: [(bundleID: String, count: Int, color: Color)] = []
        var othersCount = 0
        
        for (index, item) in sorted.enumerated() {
            if index < 5 {
                result.append((item.key, item.value, AppColorManager.color(for: index)))
            } else {
                othersCount += item.value
            }
        }
        
        // Include untracked keystrokes in "Others"
        othersCount += untrackedCount
        
        if othersCount > 0 {
            result.append(("others", othersCount, AppColorManager.othersColor))
        }
        
        return result
    }

    private func updateCachedTopApps() {
        cachedTopApps = computeTopAppsForPeriod()
    }

    private var dailyData: [DailyDataWithApps] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        // Use cached top apps for consistent colors (avoids redundant computation)
        let topApps = cachedTopApps.map { $0.bundleID }
        
        var data: [DailyDataWithApps] = []
        for i in 0..<selectedDays {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateString = formatter.string(from: date)
            let totalCount = dataStore.syncData.totalCount(for: dateString)
            let dayAppCounts = dataStore.syncData.totalAppCounts(for: dateString)
            
            var breakdown: [AppBreakdown] = []
            var othersCount = 0
            
            // Group into top 5 + others
            for (bundleID, count) in dayAppCounts {
                if let index = topApps.firstIndex(of: bundleID), index < 5 {
                    if !hiddenApps.contains(bundleID) {
                        breakdown.append(AppBreakdown(
                            bundleID: bundleID,
                            displayName: getAppDisplayName(for: bundleID),
                            count: count,
                            color: AppColorManager.color(for: index)
                        ))
                    }
                } else {
                    if !hiddenApps.contains("others") {
                        othersCount += count
                    }
                }
            }
            
            // Calculate sum of tracked app counts and add untracked to others
            let trackedTotal = dayAppCounts.values.reduce(0, +)
            let untrackedCount = totalCount - trackedTotal
            if untrackedCount > 0 && !hiddenApps.contains("others") {
                othersCount += untrackedCount
            }
            
            if othersCount > 0 {
                breakdown.append(AppBreakdown(
                    bundleID: "others",
                    displayName: "Others",
                    count: othersCount,
                    color: AppColorManager.othersColor
                ))
            }
            
            // If no app data at all, use the total count as "All Apps" (legacy data)
            // Only show if "others" is not hidden (legacy data is effectively untracked)
            if breakdown.isEmpty && totalCount > 0 && !hiddenApps.contains("others") {
                breakdown.append(AppBreakdown(
                    bundleID: "others",
                    displayName: "Others",
                    count: totalCount,
                    color: AppColorManager.othersColor
                ))
            }
            
            // Calculate displayed total (respecting hidden apps filter)
            let displayedTotal = breakdown.reduce(0) { $0 + $1.count }
            
            data.append(DailyDataWithApps(
                date: date,
                dateString: dateString,
                totalCount: displayedTotal,
                appBreakdown: breakdown.sorted { $0.count > $1.count }
            ))
        }
        return data
    }
    
    private var chartData: [DailyDataWithApps] {
        Array(dailyData.reversed())
    }
    
    private let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Keys").tag(0)
                    Text("Mouse").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Picker("", selection: $viewMode) {
                    Text("Daily").tag(0)
                    Text("Timeseries").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 6)

            if tab == 0 {
                if viewMode == 0 {
                    dailyContent
                } else {
                    KeysTimeseriesSection()
                }
            } else {
                if viewMode == 0 {
                    MouseDailySection()
                } else {
                    MouseTimeseriesSection()
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Open Data Folder") {
                    if let url = dataStore.dataFileURL {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
                .buttonStyle(.link)
                .padding()
            }
        }
        .frame(width: 540, height: 600)
        .onAppear {
            updateCachedTopApps()
        }
        .onChange(of: selectedDays) { _ in
            updateCachedTopApps()
        }
        .onReceive(dataStore.$syncData) { _ in
            updateCachedTopApps()
        }
    }

    @ViewBuilder
    private var dailyContent: some View {
        // Chart section
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Keystroke History")
                    .font(.headline)
                Spacer()
                Picker("", selection: $selectedDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Stacked bar chart (isolated to prevent flicker on row expand)
            EquatableView(content: ChartSection(chartData: chartData, selectedDays: selectedDays))

            // Legend with toggle filtering (uses cached top apps)
            HStack(spacing: 16) {
                ForEach(cachedTopApps, id: \.bundleID) { app in
                    LegendItem(
                        bundleID: app.bundleID,
                        displayName: getAppDisplayName(for: app.bundleID),
                        color: app.color,
                        count: app.count,
                        isHidden: hiddenApps.contains(app.bundleID)
                    ) {
                        if hiddenApps.contains(app.bundleID) {
                            hiddenApps.remove(app.bundleID)
                        } else {
                            hiddenApps.insert(app.bundleID)
                        }
                    }
                }
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding()

        Divider()

        // List section with expandable rows
        List(dailyData) { item in
            DayRow(
                item: item,
                isExpanded: expandedDays.contains(item.dateString),
                displayFormatter: displayFormatter,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedDays.contains(item.dateString) {
                            expandedDays.remove(item.dateString)
                        } else {
                            expandedDays.insert(item.dateString)
                        }
                    }
                }
            )
        }
    }

    private func formatNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Legend Item

struct LegendItem: View {
    let bundleID: String
    let displayName: String
    let color: Color
    let count: Int
    let isHidden: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isHidden ? Color.gray.opacity(0.3) : color)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(color, lineWidth: isHidden ? 1 : 0)
                    )
                Text(displayName)
                    .font(.caption)
                    .foregroundColor(isHidden ? .secondary : .primary)
                    .strikethrough(isHidden)
            }
        }
        .buttonStyle(.plain)
        .help("\(displayName): \(formatCount(count)) keystrokes")
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Day Row (Expandable)

struct DayRow: View {
    let item: DailyDataWithApps
    let isExpanded: Bool
    let displayFormatter: DateFormatter
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - clickable header
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text(displayFormatter.string(from: item.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatNumber(item.totalCount))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content - app breakdown
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.appBreakdown) { app in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(app.color)
                                .frame(width: 8, height: 8)
                            Text(app.displayName)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatNumber(app.count))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }
    }

    private func formatNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Window Controller with Auto-Refresh

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let frameKey = "HistoryWindowFrame"
    private var dataStore: HistoryDataStore?
    private var refreshTimer: Timer?
    
    convenience init(syncData: SyncData, dataFileURL: URL?) {
        let store = HistoryDataStore(syncData: syncData, dataFileURL: dataFileURL)
        let hostingController = NSHostingController(rootView: HistoryView(dataStore: store))
        let window = NSWindow(contentViewController: hostingController)
        window.title = isDevBuild ? "Input Stats History (Dev)" : "Input Stats History"
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 420, height: 450)
        
        if let frameString = UserDefaults.standard.string(forKey: HistoryWindowController.frameKey) {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.setContentSize(NSSize(width: 540, height: 550))
            window.center()
        }
        
        self.init(window: window)
        self.dataStore = store
        window.delegate = self
        
        // Start periodic refresh timer (every 5 minutes)
        startRefreshTimer()
    }
    
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.dataStore?.reload()
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh data when window gains focus
        dataStore?.reload()
    }
    
    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: HistoryWindowController.frameKey)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Timeseries (high-resolution drilldown)

extension EventKind {
    var color: Color {
        switch self {
        case .key: return .blue
        case .click: return .green
        case .scroll: return .orange
        case .move: return .pink
        }
    }
}

/// A selectable time window for the drilldown chart.
enum TimeSpan: Int, CaseIterable, Identifiable {
    case hour1, hour6, day1, day7, day30

    var id: Int { rawValue }

    var seconds: Int {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var label: String {
        switch self {
        case .hour1: return "1h"
        case .hour6: return "6h"
        case .day1: return "24h"
        case .day7: return "7d"
        case .day30: return "30d"
        }
    }

    /// Resolutions offered for this span, finest first. Gated so a chart never exceeds ~720 points
    /// (so you can't, e.g., ask for 5s blocks over a week and kill the machine).
    var allowedResolutions: [Int] {
        let candidates = [5, 60, 300, 3600, 21600, 86400]
        let maxPoints = 720
        let minPoints = 6
        return candidates.filter { res in
            let points = seconds / res
            return points >= minPoints && points <= maxPoints
        }
    }

    var defaultResolution: Int { allowedResolutions.first ?? 3600 }
}

func resolutionLabel(_ seconds: Int) -> String {
    switch seconds {
    case 5: return "5s"
    case 60: return "1m"
    case 300: return "5m"
    case 3600: return "1h"
    case 21600: return "6h"
    case 86400: return "1d"
    default:
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}


// MARK: - Shared timeseries helpers

/// A single charted point for a labelled series (used for both per-app and per-kind charts).
struct ChartLinePoint: Identifiable {
    let id = UUID()
    let date: Date
    let label: String
    let value: Int
}

/// Span + drilldown-resolution pickers, shared by the timeseries views.
struct SpanResolutionControls: View {
    @Binding var span: TimeSpan
    @Binding var resolution: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $span) {
                    ForEach(TimeSpan.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Spacer()
                Text(resolutionLabel(resolution) + " blocks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                Text("Resolution")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $resolution) {
                    ForEach(span.allowedResolutions, id: \.self) { res in
                        Text(resolutionLabel(res)).tag(res)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Spacer()
            }
        }
    }
}

struct TimeseriesPlaceholder: View {
    let text: String
    var height: CGFloat = 200
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06))
            Text(text).font(.caption).foregroundColor(.secondary)
        }
        .frame(height: height)
    }
}

/// X-axis labels: time-of-day for intraday spans, month/day for multi-day spans.
private func axisLabelFormat(for span: TimeSpan) -> Date.FormatStyle {
    span.seconds <= 86400 ? .dateTime.hour().minute() : .dateTime.month().day()
}

/// Emit a point for EVERY bucket in [start, end) (0 where there's no data), so line/area
/// charts drop to zero during inactivity instead of drawing a straight line across the gap.
func denseSeries(label: String, byBucket: [Int: Int], start: Int, end: Int, resolution: Int) -> [ChartLinePoint] {
    var out: [ChartLinePoint] = []
    var b = (start / resolution) * resolution
    while b < end {
        out.append(ChartLinePoint(date: Date(timeIntervalSince1970: TimeInterval(b)),
                                  label: label, value: byBucket[b] ?? 0))
        b += resolution
    }
    return out
}

/// Compact axis/legend number ("1.2k", "3.4M").
func compactNumber(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
    return "\(count)"
}

/// Manual legend for the dual-axis clicks(left)/scroll(right) charts.
struct DualAxisLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Circle().fill(EventKind.click.color).frame(width: 9, height: 9)
                Text("Clicks (left)").font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(EventKind.scroll.color).frame(width: 9, height: 9)
                Text("Scroll (right)").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

/// Dual y-axis: leading shows real clicks values, trailing maps scaled positions back to scroll values.
@AxisContentBuilder
func dualAxisMarks(factor: Double) -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisValueLabel {
            if let d = value.as(Double.self) { Text(compactNumber(Int(d.rounded()))) }
        }
    }
    AxisMarks(position: .trailing) { value in
        AxisValueLabel {
            if let d = value.as(Double.self), factor > 0 {
                Text(compactNumber(Int((d / factor).rounded())))
            }
        }
    }
}

// MARK: - Keys › Timeseries (per-app lines)

struct KeysTimeseriesSection: View {
    @State private var span: TimeSpan = .day1
    @State private var resolution: Int = TimeSpan.day1.defaultResolution
    @State private var points: [ChartLinePoint] = []
    @State private var domain: [String] = []
    @State private var range: [Color] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keys over time").font(.headline)
                Spacer()
                Text("This Mac").font(.caption).foregroundColor(.secondary)
            }
            SpanResolutionControls(span: $span, resolution: $resolution)

            if points.isEmpty {
                TimeseriesPlaceholder(text: "No keystrokes in this window")
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Keys", p.value))
                            .foregroundStyle(by: .value("App", p.label))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(domain: domain, range: range)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: axisLabelFormat(for: span))
                    }
                }
                .frame(height: 210)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { resolution = span.defaultResolution; reload(); startTimer() }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: span) { ns in
            if !ns.allowedResolutions.contains(resolution) { resolution = ns.defaultResolution }
            reload()
        }
        .onChange(of: resolution) { _ in reload() }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in reload() }
    }

    private func reload() {
        let end = EventStore.bucket() + EventStore.baseBucketSeconds
        let start = end - span.seconds
        let res = resolution
        EventStore.shared.topApps(kind: .key, startBucket: start, endBucket: end) { tops in
            let top5 = Array(tops.prefix(5)).map { $0.app }
            let topSet = Set(top5)
            EventStore.shared.seriesByApp(kind: .key, startBucket: start, endBucket: end, resolution: res) { raw in
                // Aggregate into top-5 apps + "others", keyed by bucket epoch.
                var agg: [String: [Int: Int]] = [:]
                for p in raw {
                    let key = topSet.contains(p.app) ? p.app : "others"
                    agg[key, default: [:]][Int(p.date.timeIntervalSince1970), default: 0] += p.value
                }
                var dom: [String] = []
                var rng: [Color] = []
                var flat: [ChartLinePoint] = []
                for (i, app) in top5.enumerated() where agg[app] != nil {
                    let label = getAppDisplayName(for: app)
                    dom.append(label); rng.append(AppColorManager.color(for: i))
                    // Zero-fill so each app's line drops to 0 during inactivity instead of bridging.
                    flat += denseSeries(label: label, byBucket: agg[app]!, start: start, end: end, resolution: res)
                }
                if let others = agg["others"] {
                    dom.append("Others"); rng.append(AppColorManager.othersColor)
                    flat += denseSeries(label: "Others", byBucket: others, start: start, end: end, resolution: res)
                }
                self.domain = dom
                self.range = rng
                self.points = flat
            }
        }
    }
}

// MARK: - Mouse › Timeseries (per-event-type lines + movement)

struct MouseTimeseriesSection: View {
    @State private var span: TimeSpan = .day1
    @State private var resolution: Int = TimeSpan.day1.defaultResolution
    @State private var clickPts: [ChartLinePoint] = []   // dense (0-filled)
    @State private var scrollPts: [ChartLinePoint] = []  // dense (0-filled)
    @State private var movePts: [ChartLinePoint] = []    // dense (0-filled)
    @State private var refreshTimer: Timer?

    private var hasCounts: Bool {
        clickPts.contains { $0.value > 0 } || scrollPts.contains { $0.value > 0 }
    }
    private var hasMove: Bool { movePts.contains { $0.value > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mouse over time").font(.headline)
                Spacer()
                Text("This Mac").font(.caption).foregroundColor(.secondary)
            }
            SpanResolutionControls(span: $span, resolution: $resolution)

            if !hasCounts {
                TimeseriesPlaceholder(text: "No clicks or scrolling in this window", height: 150)
            } else {
                let maxClicks = max(1, clickPts.map { $0.value }.max() ?? 0)
                let maxScroll = max(1, scrollPts.map { $0.value }.max() ?? 0)
                let factor = Double(maxClicks) / Double(maxScroll)  // scale scroll into clicks range
                Chart {
                    ForEach(clickPts) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Clicks", Double(p.value)))
                            .foregroundStyle(EventKind.click.color)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(scrollPts) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Scroll", Double(p.value) * factor))
                            .foregroundStyle(EventKind.scroll.color)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...Double(maxClicks))
                .chartYAxis { dualAxisMarks(factor: factor) }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: axisLabelFormat(for: span))
                    }
                }
                .frame(height: 150)
                DualAxisLegend()
            }

            Text("Pointer movement (px)").font(.caption).foregroundColor(.secondary)
            if !hasMove {
                TimeseriesPlaceholder(text: "No movement in this window", height: 90)
            } else {
                Chart {
                    ForEach(movePts) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("Pixels", p.value))
                            .foregroundStyle(EventKind.move.color.opacity(0.5))
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: axisLabelFormat(for: span))
                    }
                }
                .frame(height: 90)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { resolution = span.defaultResolution; reload(); startTimer() }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: span) { ns in
            if !ns.allowedResolutions.contains(resolution) { resolution = ns.defaultResolution }
            reload()
        }
        .onChange(of: resolution) { _ in reload() }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in reload() }
    }

    private func reload() {
        let end = EventStore.bucket() + EventStore.baseBucketSeconds
        let start = end - span.seconds
        let res = resolution
        EventStore.shared.series(startBucket: start, endBucket: end, resolution: res,
                                 kinds: [.click, .scroll]) { pts in
            var clickB: [Int: Int] = [:]
            var scrollB: [Int: Int] = [:]
            for p in pts {
                let b = Int(p.date.timeIntervalSince1970)
                if p.kind == .click { clickB[b] = p.value } else if p.kind == .scroll { scrollB[b] = p.value }
            }
            self.clickPts = denseSeries(label: "Clicks", byBucket: clickB, start: start, end: end, resolution: res)
            self.scrollPts = denseSeries(label: "Scroll", byBucket: scrollB, start: start, end: end, resolution: res)
        }
        EventStore.shared.series(startBucket: start, endBucket: end, resolution: res,
                                 kinds: [.move]) { pts in
            var b: [Int: Int] = [:]
            for p in pts { b[Int(p.date.timeIntervalSince1970)] = p.value }
            self.movePts = denseSeries(label: "Movement", byBucket: b, start: start, end: end, resolution: res)
        }
    }
}

// MARK: - Mouse › Daily (stacked bars by event type + movement + list)

private struct MouseDay: Identifiable {
    let id: String
    let date: Date
    let clicks: Int
    let scroll: Int
    let move: Int
}

struct MouseDailySection: View {
    @State private var dayRange = 7
    @State private var clickDays: [ChartLinePoint] = []
    @State private var scrollDays: [ChartLinePoint] = []
    @State private var movePoints: [ChartLinePoint] = []
    @State private var days: [MouseDay] = []
    @State private var refreshTimer: Timer?

    private let listFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mouse Activity").font(.headline)
                Text("This Mac").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $dayRange) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            if clickDays.isEmpty && scrollDays.isEmpty {
                TimeseriesPlaceholder(text: "No clicks or scrolling yet", height: 150)
            } else {
                let maxClicks = max(1, clickDays.map { $0.value }.max() ?? 0)
                let maxScroll = max(1, scrollDays.map { $0.value }.max() ?? 0)
                let factor = Double(maxClicks) / Double(maxScroll)  // scale scroll into clicks range
                Chart {
                    ForEach(clickDays) { p in
                        BarMark(x: .value("Date", p.date, unit: .day), y: .value("Clicks", Double(p.value)))
                            .foregroundStyle(EventKind.click.color)
                    }
                    ForEach(scrollDays) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Scroll", Double(p.value) * factor))
                            .foregroundStyle(EventKind.scroll.color)
                            .symbol(.circle)
                    }
                }
                .chartYScale(domain: 0...Double(maxClicks))
                .chartYAxis { dualAxisMarks(factor: factor) }
                .frame(height: 150)
                DualAxisLegend()
            }

            Text("Pointer movement (px)").font(.caption).foregroundColor(.secondary)
            if movePoints.isEmpty {
                TimeseriesPlaceholder(text: "No movement yet", height: 80)
            } else {
                Chart {
                    ForEach(movePoints) { p in
                        BarMark(x: .value("Date", p.date, unit: .day), y: .value("Pixels", p.value))
                            .foregroundStyle(EventKind.move.color.opacity(0.6))
                    }
                }
                .frame(height: 80)
            }

            Divider()

            List(days) { day in
                HStack {
                    Text(listFormatter.string(from: day.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(formatNumber(day.clicks)) clicks")
                        .font(.callout).monospacedDigit().foregroundColor(.secondary)
                        .frame(width: 120, alignment: .trailing)
                    Text("\(formatNumber(day.scroll)) scroll")
                        .font(.callout).monospacedDigit().foregroundColor(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
            }
            .frame(minHeight: 120)
        }
        .padding()
        .onAppear { reload(); startTimer() }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: dayRange) { _ in reload() }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in reload() }
    }

    private func reload() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDay = cal.date(byAdding: .day, value: -(dayRange - 1), to: today) else { return }
        let start = EventStore.bucket(for: startDay)
        let end = EventStore.bucket() + EventStore.baseBucketSeconds

        // Query hourly and fold into local days (avoids UTC-day misalignment of 86400s buckets).
        EventStore.shared.series(startBucket: start, endBucket: end, resolution: 3600,
                                 kinds: [.click, .scroll, .move]) { pts in
            var perDay: [Date: [EventKind: Int]] = [:]
            for p in pts {
                let day = cal.startOfDay(for: p.date)
                perDay[day, default: [:]][p.kind, default: 0] += p.value
            }

            var clicksOut: [ChartLinePoint] = []
            var scrollOut: [ChartLinePoint] = []
            var moves: [ChartLinePoint] = []
            var rows: [MouseDay] = []
            let dateKey = DateFormatter(); dateKey.dateFormat = "yyyy-MM-dd"

            for offset in 0..<dayRange {
                guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                let kinds = perDay[day] ?? [:]
                let clicks = kinds[.click] ?? 0
                let scroll = kinds[.scroll] ?? 0
                let move = kinds[.move] ?? 0
                // Emit every day (incl. zeros) so the scroll line drops to 0 instead of bridging gaps.
                clicksOut.append(ChartLinePoint(date: day, label: EventKind.click.label, value: clicks))
                scrollOut.append(ChartLinePoint(date: day, label: EventKind.scroll.label, value: scroll))
                moves.append(ChartLinePoint(date: day, label: EventKind.move.label, value: move))
                rows.append(MouseDay(id: dateKey.string(from: day), date: day, clicks: clicks, scroll: scroll, move: move))
            }

            self.clickDays = clicksOut
            self.scrollDays = scrollOut
            self.movePoints = moves
            self.days = rows
        }
    }

    private func formatNumber(_ count: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
