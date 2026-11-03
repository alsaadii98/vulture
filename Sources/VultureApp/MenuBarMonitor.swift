// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI
import VultureCore

/// Samples every few seconds, only while the menu bar item is turned on. To stay well under 1% CPU it only redraws
/// when the number shown changes, and reads memory and disk only while the menu is open.
@MainActor @Observable
final class MonitorModel {
    var cpu = 0.0
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var freeDisk: Int64 = 0
    var menuOpen = false {
        didSet { if menuOpen { refresh() } }
    }

    private let stats = SystemStats()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh() {
        let s = stats.sample()
        let rounded = (s.cpu * 100).rounded() / 100
        if rounded != cpu { cpu = rounded }
        guard menuOpen else { return }
        memoryUsed = s.memoryUsed
        memoryTotal = s.memoryTotal
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeDisk = values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

struct MonitorMenu: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Mac right now").font(.headline)
            gauge("CPU", value: monitor.cpu, text: monitor.cpu.formatted(.percent.precision(.fractionLength(0))),
                  note: monitor.cpu > 0.8 ? "Working hard" : "Fine")
            let mem = monitor.memoryTotal > 0 ? Double(monitor.memoryUsed) / Double(monitor.memoryTotal) : 0
            gauge("Memory", value: mem, text: "\(formatBytes(monitor.memoryUsed)) of \(formatBytes(monitor.memoryTotal))",
                  note: mem > 0.9 ? "Nearly full" : "Fine")
            HStack {
                Text("Free space").foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(monitor.freeDisk)).monospacedDigit()
            }
            Divider()
            Button("Open Vulture") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Quit Vulture") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { monitor.start(); monitor.menuOpen = true }
        .onDisappear { monitor.menuOpen = false }
    }

    private func gauge(_ title: String, value: Double, text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(text).monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1)).tint(value > 0.85 ? .orange : .accentColor)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MonitorLabel: View {
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg")
            Text(monitor.cpu.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
