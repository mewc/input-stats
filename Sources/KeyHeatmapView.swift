import SwiftUI

/// Opt-in keyboard heatmap: per-key totals drawn on the physical key grid.
///
/// Counts only — no sequences, no characters typed, never uploaded. Recording is off until the
/// user turns it on here, and turning it off deletes the history it collected.
struct KeyHeatmapSection: View {
    let rangeDays: Int

    @AppStorage(AppDelegate.keyHeatmapDefaultsKey) private var enabled = false
    @State private var counts: [Int: Int] = [:]
    @State private var hovered: Int?
    @State private var confirmingDisable = false

    private var maxCount: Int { counts.values.max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Key heatmap").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                if enabled {
                    if let hovered, let count = counts[hovered], count > 0 {
                        Text("\(KeyboardLayoutTracker.shared.label(for: hovered)) · \(fullNumber(count))")
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    Button("Turn off") { confirmingDisable = true }
                        .buttonStyle(.link).font(.caption)
                }
            }

            if enabled {
                if counts.isEmpty {
                    TimeseriesPlaceholder(text: "No keys recorded yet — type a little and come back", height: 120)
                } else {
                    keyboard
                }
            } else {
                optIn
            }
        }
        .onAppear(perform: reload)
        .onChange(of: rangeDays) { _ in reload() }
        .onChange(of: enabled) { isOn in
            if isOn { reload() }
        }
        .alert("Delete recorded key counts?", isPresented: $confirmingDisable) {
            Button("Turn off and delete", role: .destructive) {
                enabled = false
                EventStore.shared.clearKeyHeatmap { counts = [:] }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recording stops and the per-key totals collected so far are removed. Your overall key counts are not affected.")
        }
    }

    private var optIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("See which keys you actually use. Counts per key only — never what you type, "
                 + "never the order, and never uploaded. Stays on this Mac and can be deleted at any time.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Turn on key heatmap") { enabled = true }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(KeyboardGrid.rows.indices, id: \.self) { rowIndex in
                GeometryReader { geo in
                    let row = KeyboardGrid.rows[rowIndex]
                    let spacing: Double = 3
                    let units = row.reduce(0.0) { $0 + $1.width }
                    let unit = (geo.size.width - spacing * Double(row.count - 1)) / units
                    HStack(spacing: spacing) {
                        ForEach(row.indices, id: \.self) { i in
                            keyCap(row[i], width: max(8, unit * row[i].width))
                        }
                    }
                }
                .frame(height: 24)
            }
            HStack(spacing: 6) {
                Text("less").font(.caption2).foregroundColor(.secondary)
                ForEach(0..<5) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.12 + Double(step) * 0.22))
                        .frame(width: 16, height: 8)
                }
                Text("more").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("\(fullNumber(counts.values.reduce(0, +))) keys recorded")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private func keyCap(_ key: KeyboardGrid.Key, width: Double) -> some View {
        let count = counts[key.code] ?? 0
        // Square-root scaling: linear shading would leave everything but the space bar blank.
        let intensity = maxCount > 0 ? (Double(count) / Double(maxCount)).squareRoot() : 0
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(count == 0 ? 0.06 : 0.12 + intensity * 0.78))
            .overlay(
                Text(KeyboardLayoutTracker.shared.label(for: key.code))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(intensity > 0.55 ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(hovered == key.code ? 0.6 : 0), lineWidth: 1)
            )
            .frame(width: width, height: 22)
            .onHover { inside in hovered = inside ? key.code : (hovered == key.code ? nil : hovered) }
            .help("\(KeyboardLayoutTracker.shared.label(for: key.code)): \(fullNumber(count))")
    }

    private func reload() {
        guard enabled else { return }
        EventStore.shared.keyPresses(days: rangeDays) { counts = $0 }
    }
}
