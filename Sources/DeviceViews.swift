import SwiftUI
import Charts

// MARK: - Shared

enum InputFamily {
    case keys, mouse
}

enum DeviceViewMode {
    case daily, timeseries
}

/// The single metric charted when the history is split by device.
enum DeviceMetric: Int, CaseIterable, Identifiable {
    case keys, clicks, scroll, movement

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .keys: return "Keys"
        case .clicks: return "Clicks"
        case .scroll: return "Scroll"
        case .movement: return "Movement"
        }
    }

    var kinds: [EventKind] {
        switch self {
        case .keys: return [.key]
        case .clicks: return EventKind.clickKinds
        case .scroll: return [.scroll]
        case .movement: return [.move]
        }
    }

    var unit: String {
        switch self {
        case .keys: return "keystrokes"
        case .clicks: return "clicks"
        case .scroll: return "scroll ticks"
        case .movement: return "px"
        }
    }

    static func options(for family: InputFamily) -> [DeviceMetric] {
        family == .keys ? [.keys] : [.clicks, .scroll, .movement]
    }
}

/// "12%" of a whole, or "—" when there is nothing to divide by.
func percentLabel(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "—" }
    return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
}

private func deviceLegendID(_ id: Int) -> String { "dev:\(id)" }

private func startBucket(daysBack: Int) -> Int {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today) ?? today
    return EventStore.bucket(for: start)
}

// MARK: - Daily / Timeseries split by device

/// Replaces the rolled-up Keys/Mouse charts with one metric split per physical device.
/// Reuses the keystroke chart's stacked-bar / legend / expandable-row components, with devices
/// standing in for apps.
struct DeviceSplitSection: View {
    let family: InputFamily
    let mode: DeviceViewMode

    @State private var metric: DeviceMetric = .keys
    @State private var dayRange = 7
    @State private var span: TimeSpan = .day1
    @State private var resolution: Int = TimeSpan.day1.defaultResolution
    @State private var hiddenDevices: Set<String> = []
    @State private var expandedDays: Set<String> = []
    @State private var devices: [Int: InputDevice] = [:]
    /// Devices ordered by total for the current window; index drives the color.
    @State private var deviceOrder: [Int] = []
    @State private var deviceTotals: [Int: Int] = [:]
    @State private var rawDaily: [Date: [Int: Int]] = [:]
    @State private var rawSeries: [Int: [Int: Int]] = [:]  // device -> bucket -> value
    @State private var seriesWindow: (start: Int, end: Int, res: Int) = (0, 0, 60)
    @State private var refreshTimer: Timer?

    private let listFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    private func color(for device: Int) -> Color {
        guard let index = deviceOrder.firstIndex(of: device) else { return AppColorManager.othersColor }
        return AppColorManager.color(for: index)
    }

    private func name(for device: Int) -> String {
        devices[device]?.displayName ?? "Device \(device)"
    }

    private var legend: [(id: Int, name: String, color: Color, count: Int)] {
        deviceOrder.map { ($0, name(for: $0), color(for: $0), deviceTotals[$0] ?? 0) }
    }

    /// Newest-first day rows, each broken down by device (hidden devices removed).
    private var dailyRows: [DailyDataWithApps] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dateKey = DateFormatter(); dateKey.dateFormat = "yyyy-MM-dd"
        var rows: [DailyDataWithApps] = []
        for offset in 0..<dayRange {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let byDevice = rawDaily[day] ?? [:]
            var breakdown: [AppBreakdown] = []
            for device in deviceOrder {
                let legendID = deviceLegendID(device)
                guard let count = byDevice[device], count > 0, !hiddenDevices.contains(legendID) else { continue }
                breakdown.append(AppBreakdown(bundleID: legendID, displayName: name(for: device),
                                              count: count, color: color(for: device)))
            }
            rows.append(DailyDataWithApps(date: day, dateString: dateKey.string(from: day),
                                          totalCount: breakdown.reduce(0) { $0 + $1.count },
                                          appBreakdown: breakdown.sorted { $0.count > $1.count }))
        }
        return rows
    }

    private var timeseriesPoints: (points: [ChartLinePoint], domain: [String], range: [Color]) {
        var points: [ChartLinePoint] = []
        var domain: [String] = []
        var range: [Color] = []
        for device in deviceOrder where !hiddenDevices.contains(deviceLegendID(device)) {
            guard let byBucket = rawSeries[device] else { continue }
            let label = name(for: device)
            domain.append(label); range.append(color(for: device))
            points += denseSeries(label: label, byBucket: byBucket, start: seriesWindow.start,
                                  end: seriesWindow.end, resolution: seriesWindow.res)
        }
        return (points, domain, range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(family == .keys ? "Keys by device" : "Mouse by device").font(.headline)
                Text("This Mac").font(.caption).foregroundColor(.secondary)
                Spacer()
                if mode == .daily {
                    Picker("", selection: $dayRange) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            if family == .mouse {
                Picker("", selection: $metric) {
                    ForEach(DeviceMetric.options(for: family)) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if mode == .timeseries {
                SpanResolutionControls(span: $span, resolution: $resolution)
            }

            if deviceOrder.isEmpty {
                TimeseriesPlaceholder(text: "No \(metric.label.lowercased()) attributed to a device yet", height: 150)
            } else if mode == .daily {
                EquatableView(content: ChartSection(chartData: Array(dailyRows.reversed()), selectedDays: dayRange))
            } else {
                let ts = timeseriesPoints
                if ts.points.isEmpty {
                    TimeseriesPlaceholder(text: "No \(metric.label.lowercased()) in this window")
                } else {
                    Chart {
                        ForEach(ts.points) { p in
                            LineMark(x: .value("Time", p.date), y: .value(metric.label, p.value))
                                .foregroundStyle(by: .value("Device", p.label))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartForegroundStyleScale(domain: ts.domain, range: ts.range)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisGridLine()
                            AxisValueLabel(format: span.seconds <= 86400 ? .dateTime.hour().minute() : .dateTime.month().day())
                        }
                    }
                    .frame(height: 210)
                }
            }

            // Device legend doubles as a filter, like the app legend.
            HStack(spacing: 16) {
                ForEach(legend, id: \.id) { entry in
                    let legendID = deviceLegendID(entry.id)
                    LegendItem(bundleID: legendID, displayName: entry.name, color: entry.color,
                               count: entry.count, isHidden: hiddenDevices.contains(legendID),
                               unit: metric.unit) {
                        if hiddenDevices.contains(legendID) {
                            hiddenDevices.remove(legendID)
                        } else {
                            hiddenDevices.insert(legendID)
                        }
                    }
                }
                Spacer()
            }

            if mode == .daily {
                Divider()
                List(dailyRows) { item in
                    DayRow(item: item,
                           isExpanded: expandedDays.contains(item.dateString),
                           displayFormatter: listFormatter) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedDays.contains(item.dateString) {
                                expandedDays.remove(item.dateString)
                            } else {
                                expandedDays.insert(item.dateString)
                            }
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding()
        .onAppear {
            metric = DeviceMetric.options(for: family).first ?? .keys
            resolution = span.defaultResolution
            reload()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in reload() }
        }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: metric) { _ in reload() }
        .onChange(of: dayRange) { _ in reload() }
        .onChange(of: span) { ns in
            if !ns.allowedResolutions.contains(resolution) { resolution = ns.defaultResolution }
            reload()
        }
        .onChange(of: resolution) { _ in reload() }
    }

    private func reload() {
        EventStore.shared.devices { devs in
            self.devices = devs
            switch mode {
            case .daily: loadDaily()
            case .timeseries: loadTimeseries()
            }
        }
    }

    private func loadDaily() {
        let cal = Calendar.current
        let start = startBucket(daysBack: dayRange)
        let end = EventStore.bucket() + EventStore.baseBucketSeconds
        // Hourly query folded into local days, like the mouse daily view.
        EventStore.shared.seriesByDevice(kinds: metric.kinds, startBucket: start, endBucket: end, resolution: 3600) { pts in
            var perDay: [Date: [Int: Int]] = [:]
            var totals: [Int: Int] = [:]
            for p in pts {
                perDay[cal.startOfDay(for: p.date), default: [:]][p.device, default: 0] += p.value
                totals[p.device, default: 0] += p.value
            }
            self.rawDaily = perDay
            self.applyTotals(totals)
        }
    }

    private func loadTimeseries() {
        let end = EventStore.bucket() + EventStore.baseBucketSeconds
        let start = end - span.seconds
        let res = resolution
        EventStore.shared.seriesByDevice(kinds: metric.kinds, startBucket: start, endBucket: end, resolution: res) { pts in
            var series: [Int: [Int: Int]] = [:]
            var totals: [Int: Int] = [:]
            for p in pts {
                series[p.device, default: [:]][Int(p.date.timeIntervalSince1970), default: 0] += p.value
                totals[p.device, default: 0] += p.value
            }
            self.rawSeries = series
            self.seriesWindow = (start, end, res)
            self.applyTotals(totals)
        }
    }

    private func applyTotals(_ totals: [Int: Int]) {
        deviceTotals = totals
        deviceOrder = totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { $0.key }
    }
}

// MARK: - Breakdown (granular stats)

private struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit())
            Text(subtitle ?? " ").font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// Repeats / shortcuts / composition for keys; double-clicks / drag / momentum / gestures for the
/// mouse. Optionally a per-device table when the history is split by device.
struct BreakdownSection: View {
    let family: InputFamily
    let byDevice: Bool

    @State private var rangeDays = 7  // 1 = today
    @State private var totals: [EventKind: Int] = [:]
    @State private var perDevice: [(device: InputDevice, totals: [EventKind: Int])] = []
    @State private var refreshTimer: Timer?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func total(_ kind: EventKind) -> Int { totals[kind] ?? 0 }

    private var clicksTotal: Int { EventKind.clickKinds.reduce(0) { $0 + total($1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(family == .keys ? "Keyboard breakdown" : "Mouse breakdown").font(.headline)
                Text("This Mac").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $rangeDays) {
                    Text("Today").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if family == .keys {
                        keyTiles
                        composition
                    } else {
                        mouseTiles
                    }
                    if byDevice {
                        deviceTable
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding()
        .onAppear {
            reload()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in reload() }
        }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: rangeDays) { _ in reload() }
    }

    private var keyTiles: some View {
        let keys = total(.key)
        return LazyVGrid(columns: columns, spacing: 8) {
            StatTile(title: "Keys", value: fullNumber(keys), color: EventKind.key.color)
            StatTile(title: "Held repeats", value: fullNumber(total(.keyRepeat)),
                     subtitle: "\(percentLabel(total(.keyRepeat), of: keys)) of keys", color: .indigo)
            StatTile(title: "Shortcuts", value: fullNumber(total(.keyShortcut)),
                     subtitle: "\(percentLabel(total(.keyShortcut), of: keys)) with ⌘ ⌃ ⌥", color: .teal)
            StatTile(title: "Software-typed", value: fullNumber(total(.keySynthetic)),
                     subtitle: "\(percentLabel(total(.keySynthetic), of: keys)) injected by apps", color: .gray)
            StatTile(title: "Modifier presses", value: fullNumber(total(.modifier)),
                     subtitle: "not counted as keys", color: .cyan)
            StatTile(title: "Backspace rate", value: percentLabel(total(.keyBackspace), of: keys),
                     subtitle: "\(fullNumber(total(.keyBackspace))) deletes", color: EventKind.keyBackspace.color)
        }
    }

    private var composition: some View {
        let kinds = EventKind.keyCompositionKinds.filter { total($0) > 0 }
        let sum = kinds.reduce(0) { $0 + total($1) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("What you press").font(.subheadline).foregroundColor(.secondary)
            if kinds.isEmpty {
                TimeseriesPlaceholder(text: "No keystrokes in this window", height: 40)
            } else {
                Chart {
                    ForEach(kinds) { kind in
                        BarMark(x: .value("Count", total(kind)), y: .value("", "keys"))
                            .foregroundStyle(by: .value("Class", kind.label))
                    }
                }
                .chartForegroundStyleScale(domain: kinds.map { $0.label }, range: kinds.map { $0.color })
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 22)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: 4) {
                    ForEach(kinds) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(kind.color).frame(width: 7, height: 7)
                            Text(kind.label).font(.caption)
                            Spacer(minLength: 2)
                            Text(percentLabel(total(kind), of: sum))
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .help("\(kind.label): \(fullNumber(total(kind)))")
                    }
                }
            }
        }
    }

    private var mouseTiles: some View {
        let clicks = clicksTotal
        return LazyVGrid(columns: columns, spacing: 8) {
            StatTile(title: "Clicks", value: fullNumber(clicks),
                     subtitle: "\(compactNumber(total(.click))) left · \(compactNumber(total(.rightClick))) right · \(compactNumber(total(.otherClick))) other",
                     color: EventKind.click.color)
            StatTile(title: "Double clicks", value: fullNumber(total(.doubleClick)),
                     subtitle: "\(percentLabel(total(.doubleClick), of: total(.click))) of left clicks", color: .mint)
            StatTile(title: "Gestures", value: fullNumber(total(.gesture)),
                     subtitle: "pinch · rotate · swipe · smart zoom", color: EventKind.gesture.color)
            StatTile(title: "Scroll ticks", value: fullNumber(total(.scroll)), color: EventKind.scroll.color)
            StatTile(title: "Momentum scroll", value: fullNumber(total(.scrollMomentum)),
                     subtitle: "\(percentLabel(total(.scrollMomentum), of: total(.scroll))) coasting after a flick", color: .yellow)
            StatTile(title: "Movement", value: "\(compactNumber(total(.move))) px", color: EventKind.move.color)
            StatTile(title: "Dragging", value: "\(compactNumber(total(.drag))) px",
                     subtitle: "\(percentLabel(total(.drag), of: total(.move))) of movement", color: .red)
        }
    }

    private var deviceTable: some View {
        let rows = perDevice.filter { entry in
            family == .keys
                ? (entry.totals[.key] ?? 0) > 0
                : EventKind.clickKinds.contains { (entry.totals[$0] ?? 0) > 0 }
                    || (entry.totals[.scroll] ?? 0) > 0 || (entry.totals[.move] ?? 0) > 0
        }
        let keysSum = rows.reduce(0) { $0 + ($1.totals[.key] ?? 0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("By device").font(.subheadline).foregroundColor(.secondary)
            if rows.isEmpty {
                TimeseriesPlaceholder(text: "Nothing attributed to a device in this window", height: 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.device.id) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.device.displayName).font(.callout).lineLimit(1)
                                Text(entry.device.connectionLabel).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if family == .keys {
                                let keys = entry.totals[.key] ?? 0
                                Text(fullNumber(keys)).font(.callout.monospacedDigit())
                                Text(percentLabel(keys, of: keysSum))
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            } else {
                                let clicks = EventKind.clickKinds.reduce(0) { $0 + (entry.totals[$1] ?? 0) }
                                Text("\(compactNumber(clicks)) clicks")
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                                Text("\(compactNumber(entry.totals[.scroll] ?? 0)) scroll")
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                                Text("\(compactNumber(entry.totals[.move] ?? 0)) px")
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func reload() {
        let start = startBucket(daysBack: rangeDays)
        let end = EventStore.bucket() + EventStore.baseBucketSeconds
        EventStore.shared.devices { devs in
            EventStore.shared.totalsByDevice(startBucket: start, endBucket: end) { byDevice in
                var sum: [EventKind: Int] = [:]
                var rows: [(device: InputDevice, totals: [EventKind: Int])] = []
                for (deviceID, kinds) in byDevice {
                    for (kind, value) in kinds { sum[kind, default: 0] += value }
                    rows.append((devs[deviceID] ?? .unattributed, kinds))
                }
                let primary: [EventKind] = family == .keys ? [.key] : EventKind.clickKinds
                rows.sort { a, b in
                    primary.reduce(0) { $0 + (a.totals[$1] ?? 0) } > primary.reduce(0) { $0 + (b.totals[$1] ?? 0) }
                }
                self.totals = sum
                self.perDevice = rows
            }
        }
    }
}
