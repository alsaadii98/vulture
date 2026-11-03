// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import SwiftUI
import VultureCore

enum SidebarSection: String, CaseIterable, Identifiable {
    case home, clean, apps, storage, startup, removed, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .clean: "Clean Up"
        case .apps: "Apps"
        case .storage: "Storage"
        case .startup: "Startup"
        case .removed: "Recently Removed"
        case .developer: "Developer Files"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .clean: "sparkles"
        case .apps: "square.grid.2x2.fill"
        case .storage: "chart.pie.fill"
        case .startup: "gauge.with.needle.fill"
        case .removed: "arrow.uturn.backward"
        case .developer: "hammer.fill"
        }
    }

    var tint: Color {
        switch self {
        case .home: .blue
        case .clean: .green
        case .apps: .purple
        case .storage: .orange
        case .startup: .pink
        case .removed: .gray
        case .developer: .indigo
        }
    }
}

/// The app's state. All disk work runs off the main thread through VultureCore.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case idle, scanning, ready, cleaning
        case done(CleanupResult)
    }

    var section: SidebarSection? = .home
    /// Asks "Clean up?" before anything is touched.
    var confirmingClean = false
    var phase: Phase = .idle
    var plan: CleanupPlan?
    var selection: Set<String> = []
    var batches: [RemovedBatch] = []
    var problem: String?
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var lastChecked: Date?

    let home = FileManager.default.homeDirectoryForCurrentUser
    let store = RecentlyRemoved.standard()
    private(set) var rules: [Rule] = []

    init() {
        do {
            guard let dir = RuleLoader.bundledRulesDirectory() else { throw CocoaError(.fileNoSuchFile) }
            rules = try RuleLoader.load(directory: dir)
        } catch {
            problem = "Vulture couldn't read its cleaning rules: \(error)"
        }
        refreshDisk()
        refreshRemoved()
    }

    // MARK: - Derived values

    var groups: [CleanupPlan.Group] { plan?.groups ?? [] }

    func bytes(of findings: [Finding]) -> Int64 { findings.reduce(0) { $0 + $1.usage.bytes } }

    var selectedBytes: Int64 { bytes(of: groups.flatMap(\.findings).filter { selection.contains($0.path) }) }

    /// What the selection splits into: freed now (apps make it again) vs. kept in Recently Removed.
    var selectedSplit: (now: Int64, kept: Int64) {
        var now: Int64 = 0, kept: Int64 = 0
        for g in groups {
            let b = bytes(of: g.findings.filter { selection.contains($0.path) })
            if g.rule.regrows == .never { kept += b } else { now += b }
        }
        return (now, kept)
    }

    var usedFraction: Double { totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0 }

    var hasFullDiskAccess: Bool { Privacy.hasFullDiskAccess(home: home) }

    // MARK: - Actions

    func scan() async {
        if case .scanning = phase { return }
        phase = .scanning
        let rules = rules, home = home, running = Self.runningApps()
        let plan = await Task.detached(priority: .userInitiated) {
            CleanupPlanner(rules: rules, policy: SafetyPolicy(home: home), runningApps: running)
                .plan(scanner: DiskScanner(skipping: Privacy.foldersToSkip(home: home)))
        }.value
        self.plan = plan
        selection = plan.defaultSelection
        lastChecked = Date()
        phase = .ready
        refreshDisk()
    }

    func clean() async {
        guard let plan, !selection.isEmpty else { return }
        phase = .cleaning
        let selected = selection, home = home, store = store
        _ = try? store.empty() // clean-ups past their 30 days
        async let result = Task.detached(priority: .userInitiated) {
            CleanupExecutor(policy: SafetyPolicy(home: home), store: store, runningApps: { AppModel.runningApps() })
                .run(plan, selected: selected)
        }.value
        // Long enough to see that something happened, even when it's instant.
        try? await Task.sleep(for: .milliseconds(900))
        phase = await .done(result)
        self.plan = nil
        selection = []
        refreshDisk()
        refreshRemoved()
    }

    var storage: StorageReport?
    var measuringStorage = false
    var snapshots: [Date] = []

    // MARK: Developer Files

    struct DevReport: Sendable {
        var simulators: SimulatorReport?
        var docker: DockerReport?
        var projects: [CleanupPlan.Group]
    }

    var dev: DevReport?
    var loadingDev = false
    var devBusy: String?
    var projectSelection: Set<String> = []
    var lastProjectResult: CleanupResult?

    func loadDev() async {
        guard !loadingDev else { return }
        loadingDev = true
        let home = home
        let report = await Task.detached(priority: .userInitiated) {
            let scanner = DiskScanner(skipping: Privacy.foldersToSkip(home: home))
            return DevReport(simulators: Simulators.report(home: home, scanner: scanner),
                             docker: Docker.report(),
                             projects: ProjectFinder(home: home).groups(policy: SafetyPolicy(home: home), scanner: scanner))
        }.value
        dev = report
        // "You decide" items start unselected, as in Clean Up.
        projectSelection.formIntersection(report.projects.flatMap(\.findings).map(\.path))
        loadingDev = false
    }

    var projectSelectedBytes: Int64 {
        bytes(of: (dev?.projects ?? []).flatMap(\.findings).filter { projectSelection.contains($0.path) })
    }

    func cleanProjects() async {
        guard let groups = dev?.projects, !projectSelection.isEmpty else { return }
        devBusy = "Removing build folders…"
        let plan = CleanupPlan(groups: groups, startedAt: Date(), duration: 0)
        let selected = projectSelection, home = home, store = store
        lastProjectResult = await Task.detached(priority: .userInitiated) {
            CleanupExecutor(policy: SafetyPolicy(home: home), store: store, runningApps: { AppModel.runningApps() })
                .run(plan, selected: selected, title: "Old project build folders")
        }.value
        devBusy = nil
        refreshDisk()
        await loadDev()
    }

    func removeSimulators() async {
        devBusy = "Removing simulators…"
        let ok = await Task.detached { Simulators.deleteUnavailable() }.value
        if !ok { problem = "Xcode couldn't remove the simulators." }
        devBusy = nil
        refreshDisk()
        await loadDev()
    }

    func tidyDocker() async {
        devBusy = "Tidying up Docker…"
        let ok = await Task.detached { Docker.tidy() }.value
        if !ok { problem = "Docker couldn't finish tidying up. Is it still running?" }
        devBusy = nil
        refreshDisk()
        await loadDev()
    }

    func measureStorage() async {
        guard !measuringStorage else { return }
        measuringStorage = true
        let home = home
        storage = await Task.detached(priority: .userInitiated) {
            StorageAnalyzer.analyze(home: home, scanner: DiskScanner(skipping: Privacy.foldersToSkip(home: home)))
        }.value
        snapshots = await Task.detached { TimeMachine.localSnapshots() }.value
        measuringStorage = false
        refreshDisk()
    }

    func putBack(_ batchID: String) {
        do {
            let failures = try store.putBack(batchID: batchID)
            if let first = failures.first { problem = "Some items couldn't be put back: \(first.1)" }
        } catch {
            problem = "\(error)"
        }
        refreshRemoved()
        refreshDisk()
        if case .done = phase { phase = .idle }
    }

    func emptyRecentlyRemoved() {
        do { _ = try store.emptyAll() } catch { problem = "\(error)" }
        refreshRemoved()
        refreshDisk()
    }

    func toggle(_ group: CleanupPlan.Group, on: Bool) {
        let paths = group.findings.filter { $0.status != .skipped }.map(\.path)
        if on { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    func refreshRemoved() { batches = store.batches() }

    func refreshDisk() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        totalBytes = Int64(values?.volumeTotalCapacity ?? 0)
    }

    nonisolated static func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
