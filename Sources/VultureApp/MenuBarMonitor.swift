// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import SwiftUI
import VultureCore

/// The menu bar item. To stay well under 1% CPU, the label samples every 5 seconds and only redraws when what it
/// shows changes; everything else is read every 2 seconds, and only while the menu is open.
@MainActor @Observable
final class MonitorModel {
    // Always (for the label)
    var cpu = 0.0
    var memoryFraction = 0.0
    var freeDisk: Int64 = 0
    var downRate = 0.0
    var upRate = 0.0

    // While the menu is open
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var gpu: Double?
    var battery: MachineStats.Battery?
    var heat = MachineStats.Heat.normal
    var bootDate: Date?
    var cleanable: Int64 = 0
    var busiest: [BusyProcesses.Entry] = []
    /// Last ~60 seconds of download and upload speed, oldest first.
    var downHistory: [Double] = []
    var upHistory: [Double] = []

    var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            restart()
        }
    }

    private let stats = SystemStats()
    private let processes = BusyProcesses()
    private var lastNet: (bytes: (received: UInt64, sent: UInt64), at: Date)?
    private var task: Task<Void, Never>?
    private var running = false

    func start() {
        running = true
        if task == nil { restart() }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    private func restart() {
        task?.cancel()
        guard running || menuOpen else { task = nil; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .seconds(self.menuOpen ? 2 : 5))
            }
        }
    }

    private func refresh() {
        let s = stats.sample()
        let shown = Preferences.menuStats
        set(&cpu, (s.cpu * 100).rounded() / 100)
        let mem = s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0
        if menuOpen || shown.contains(.memory) { set(&memoryFraction, (mem * 100).rounded() / 100) }
        if menuOpen || shown.contains(.disk) { set(&freeDisk, Self.freeSpace()) }
        if menuOpen || shown.contains(.network) { sampleNetwork() }
        guard menuOpen else { return }
        memoryUsed = s.memoryUsed
        memoryTotal = s.memoryTotal
        gpu = MachineStats.gpuUtilization()
        battery = MachineStats.battery()
        heat = MachineStats.heat()
        bootDate = bootDate ?? MachineStats.bootDate()
        cleanable = Int64(UserDefaults.standard.integer(forKey: Preferences.lastCleanable))
        busiest = processes.sample(top: 3)
    }

    private func sampleNetwork() {
        let bytes = MachineStats.networkBytes(), now = Date()
        defer { lastNet = (bytes, now) }
        guard let last = lastNet, now > last.at else { return }
        let seconds = now.timeIntervalSince(last.at)
        let down = bytes.received >= last.bytes.received ? Double(bytes.received - last.bytes.received) / seconds : 0
        let up = bytes.sent >= last.bytes.sent ? Double(bytes.sent - last.bytes.sent) / seconds : 0
        set(&downRate, down.rounded())
        set(&upRate, up.rounded())
        if menuOpen {
            downHistory = Array((downHistory + [down]).suffix(30))
            upHistory = Array((upHistory + [up]).suffix(30))
        }
    }

    /// Assigns only when the value changes, so SwiftUI doesn't redraw for nothing.
    private func set<T: Equatable>(_ target: inout T, _ value: T) {
        if target != value { target = value }
    }

    static func freeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: How the Mac is doing

    struct Status { let text: String; let good: Bool }

    var status: Status {
        if freeDisk > 0, freeDisk < Preferences.almostFull { return Status(text: "Low on Space", good: false) }
        if heat == .hot { return Status(text: "Running Hot", good: false) }
        if memoryFraction > 0.92 { return Status(text: "Memory Is Full", good: false) }
        if cpu > 0.85 { return Status(text: "Working Hard", good: false) }
        return Status(text: "All Good", good: true)
    }

    var statusDetail: String {
        switch status.text {
        case "Low on Space": "Free up some space soon"
        case "Running Hot": "macOS is slowing things down to cool off"
        case "Memory Is Full": "Quitting an app you’re not using will help"
        case "Working Hard": "Something is keeping the processor busy"
        default: "Everything is running smoothly"
        }
    }
}

func formatRate(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}

// MARK: - The menu

struct MonitorMenu: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rings
            internet
            tiles
            if !monitor.busiest.isEmpty { busiest }
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            HStack(spacing: 10) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Text("Open Vulture").frame(maxWidth: .infinity)
                }
                .primaryButton()
                SettingsLink {
                    Image(systemName: "gearshape").frame(width: 18, height: 18)
                }
                .glassButton()
                .accessibilityLabel("Settings")
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.window)
        .onAppear { monitor.menuOpen = true }
        .onDisappear { monitor.menuOpen = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "Your Mac").font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(monitor.statusDetail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Label(monitor.status.text, systemImage: monitor.status.good ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(monitor.status.good ? Theme.green : Theme.orange)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(monitor.status.good ? Theme.greenBackground : Theme.orangeBackground, in: Capsule())
        }
    }

    private var rings: some View {
        Card(padding: 14) {
            HStack {
                ring("Processor", monitor.cpu, Theme.blue)
                Spacer()
                ring("Memory", monitor.memoryFraction, Theme.mint)
                if let gpu = monitor.gpu {
                    Spacer()
                    ring("Graphics", gpu, Theme.purple)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func ring(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 6) {
            ProgressRing(fraction: value, color: color, lineWidth: 7, size: 62) {
                Text(value.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 13, weight: .bold)).monospacedDigit()
            }
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(Int(value * 100)) percent")
    }

    private var internet: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Internet").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(formatRate(monitor.downRate))").foregroundStyle(Theme.accentText)
                    Text("↑ \(formatRate(monitor.upRate))").foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                SpeedChart(down: monitor.downHistory, up: monitor.upHistory).frame(height: 36)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Internet: downloading \(formatRate(monitor.downRate)), uploading \(formatRate(monitor.upRate))")
    }

    private var tiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("Storage", "\(formatBytes(monitor.freeDisk)) free",
                     monitor.cleanable > 0 ? "\(formatBytes(monitor.cleanable)) can be cleaned" : "Open Vulture to check")
                if let battery = monitor.battery {
                    tile("Battery", battery.level.formatted(.percent.precision(.fractionLength(0))), batteryDetail(battery))
                } else {
                    tile("Memory", formatBytes(monitor.memoryUsed), "of \(formatBytes(monitor.memoryTotal)) in use")
                }
            }
            GridRow {
                tile("Temperature", monitor.heat.rawValue, monitor.heat == .normal ? "Cool enough" : "macOS is easing off to cool down")
                tile("On for", uptime, uptimeDays >= 7 ? "Restart to free memory" : "Since you last restarted")
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit().lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func batteryDetail(_ b: MachineStats.Battery) -> String {
        if b.charging { return b.minutesLeft.map { "Full in \(duration($0))" } ?? "Charging" }
        if b.onPower { return "Plugged in" }
        return b.minutesLeft.map { "About \(duration($0)) left" } ?? "On battery"
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) hours" + (minutes % 60 >= 30 ? " 30 min" : "") : "\(minutes) min"
    }

    private var uptimeDays: Int {
        guard let boot = monitor.bootDate else { return 0 }
        return Int(Date().timeIntervalSince(boot) / 86_400)
    }

    private var uptime: String {
        guard let boot = monitor.bootDate else { return "—" }
        let hours = Int(Date().timeIntervalSince(boot) / 3600)
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return uptimeDays == 1 ? "1 day" : "\(uptimeDays) days"
    }

    private var busiest: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Using the Most Right Now").font(.system(size: 12, weight: .bold))
            ForEach(monitor.busiest, id: \.pid) { entry in
                let app = NSRunningApplication(processIdentifier: entry.pid)
                HStack(spacing: 8) {
                    if let icon = app?.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        IconTile(symbol: "gearshape.fill", color: Theme.gray, size: 18)
                    }
                    Text(app?.localizedName ?? entry.name).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text("\(Int((entry.cpu * 100).rounded()))% · \(formatBytes(entry.memory))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Two small lines: download in blue, upload in gray, scaled to the busiest moment shown.
private struct SpeedChart: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        GeometryReader { geo in
            let top = max(1, (down + up).max() ?? 1)
            ZStack {
                line(up, top: top, size: geo.size).stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                line(down, top: top, size: geo.size).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func line(_ values: [Double], top: Double, size: CGSize) -> Path {
        Path { p in
            guard values.count > 1 else {
                p.move(to: CGPoint(x: 0, y: size.height - 1))
                p.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                return
            }
            let step = size.width / CGFloat(29)
            let start = CGFloat(30 - values.count) * step
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: start + CGFloat(i) * step, y: size.height - 1 - CGFloat(v / top) * (size.height - 2))
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
    }
}

// MARK: - The label

struct MonitorLabel: View {
    @Environment(MonitorModel.self) private var monitor
    @AppStorage(Preferences.menuBarStats) private var stats = "cpu"

    var body: some View {
        MonitorLabelText(stats: Preferences.menuStats, cpu: monitor.cpu, memory: monitor.memoryFraction,
                         free: monitor.freeDisk, down: monitor.downRate)
            .id(stats)
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }
}

/// The icon and the chosen numbers, as they appear in the menu bar.
struct MonitorLabelText: View {
    let stats: Set<Preferences.MenuStat>
    var cpu: Double
    var memory: Double
    var free: Int64
    var down: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
            if stats.contains(.cpu) { Text(cpu.formatted(.percent.precision(.fractionLength(0)))) }
            if stats.contains(.memory) { Text("M " + memory.formatted(.percent.precision(.fractionLength(0)))) }
            if stats.contains(.disk) { Text(shortBytes(free)) }
            if stats.contains(.network) { Text("↓" + formatRate(down)) }
        }
        .monospacedDigit()
    }
}

/// Settings › Menu Bar preview, with example numbers.
struct MonitorLabelPreview: View {
    let stats: Set<Preferences.MenuStat>

    var body: some View {
        MonitorLabelText(stats: stats, cpu: 0.23, memory: 0.68, free: 278_000_000_000, down: 4_200_000)
            .accessibilityLabel("Example of the menu bar item")
    }
}
