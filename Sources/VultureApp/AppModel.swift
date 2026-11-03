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
            rules = RuleUpdates.activeRules(home: home, bundled: try RuleLoader.load(directory: dir)).rules
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
            let regrowth = RegrowthTracker.standard(home: home)
            let plan = CleanupPlanner(rules: rules, policy: SafetyPolicy(home: home), runningApps: running,
                                      quicklyRefilling: regrowth.quicklyRefilling())
                .plan(scanner: DiskScanner(skipping: Privacy.foldersToSkip(home: home)))
            try? regrowth.observe(plan)
            return plan
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
            let result = CleanupExecutor(policy: SafetyPolicy(home: home), store: store, runningApps: { AppModel.runningApps() })
                .run(plan, selected: selected)
            try? RegrowthTracker.standard(home: home).noteCleaned(result.removedForGood)
            return result
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
    var weeklyChange: (since: Date, freeDelta: Int64, changes: [SpaceHistory.Change])?

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
        if let storage {
            let history = SpaceHistory.standard(home: home)
            try? history.record(storage)
            weeklyChange = history.changes(overDays: 7)
        }
        measuringStorage = false
        refreshDisk()
    }

    // MARK: Apps

    enum AppFilter: String, CaseIterable { case all = "All Apps", unused = "Not Used Lately", largest = "Largest" }

    var apps: [InstalledApp]?
    var loadingApps = false
    var appFilter: AppFilter = .all
    var appSearch = ""
    var appSelection: Set<String> = []
    /// Files of each selected app, found when it's selected.
    var appFiles: [String: [AppFile]] = [:]
    /// Which of those files go with the app. Files named exactly after the app start selected.
    var appFileSelection: Set<String> = []
    var leftovers: [LeftoverGroup] = []
    var leftoverSelection: Set<String> = []
    var appsBusy: String?
    var lastAppsResult: String?

    var visibleApps: [InstalledApp] {
        var list = (apps ?? []).filter { !$0.isApple }
        if !appSearch.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(appSearch) } }
        switch appFilter {
        case .all: break
        case .unused: list = list.filter { Self.isUnused($0) }.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .largest: list.sort { $0.bytes > $1.bytes }
        }
        return list
    }

    static func isUnused(_ app: InstalledApp) -> Bool {
        guard let used = app.lastUsed else { return true }
        return Date().timeIntervalSince(used) > 60 * 86_400
    }

    var selectedApps: [InstalledApp] { (apps ?? []).filter { appSelection.contains($0.path) } }

    var appRemovalBytes: Int64 {
        selectedApps.reduce(0) { total, app in
            total + app.bytes + (appFiles[app.path] ?? []).filter { appFileSelection.contains($0.path) }.reduce(0) { $0 + $1.usage.bytes }
        }
    }

    func loadApps() async {
        guard !loadingApps else { return }
        loadingApps = true
        let home = home
        let (list, found) = await Task.detached(priority: .userInitiated) {
            let list = AppInventory.installedApps(roots: AppInventory.standardRoots(home: home), home: home, scanner: DiskScanner())
            let found = LeftoverFinder.find(home: home, installed: Set(list.map(\.bundleID)), isRegistered: {
                !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).isEmpty
            }, scanner: DiskScanner())
            return (list, found)
        }.value
        apps = list
        leftovers = found
        appSelection.formIntersection(list.map(\.path))
        loadingApps = false
    }

    func toggleApp(_ app: InstalledApp) {
        if appSelection.remove(app.path) != nil { return }
        appSelection.insert(app.path)
        guard appFiles[app.path] == nil else { return }
        let home = home, fda = hasFullDiskAccess
        Task {
            let files = await Task.detached {
                AppInventory.files(of: app.bundleID, name: app.name, home: home, scanner: DiskScanner(), fullDiskAccess: fda)
            }.value
            appFiles[app.path] = files
            appFileSelection.formUnion(files.filter(\.certain).map(\.path))
        }
    }

    func removeSelectedApps() async {
        let chosen = selectedApps
        guard !chosen.isEmpty else { return }
        appsBusy = "Removing \(chosen.count == 1 ? chosen[0].name : "\(chosen.count) apps")…"
        let home = home, store = store, files = appFiles, picked = appFileSelection
        let messages = await Task.detached(priority: .userInitiated) { () -> [String] in
            let running = AppModel.runningApps(), open = OpenFiles.snapshot()
            return chosen.map { app in
                do {
                    let mine = (files[app.path] ?? []).filter { picked.contains($0.path) }
                    let (_, failures) = try AppRemover.remove(app, files: mine, roots: AppInventory.standardRoots(home: home), home: home,
                                                              store: store, running: running, open: open)
                    return failures.isEmpty ? "" : "\(app.name): \(failures.count) files were left because something changed."
                } catch {
                    return "\(app.name): \(error)"
                }
            }
        }.value
        let problems = messages.filter { !$0.isEmpty }
        if !problems.isEmpty { problem = problems.joined(separator: "\n") }
        lastAppsResult = "Moved to Recently Removed. You can put \(chosen.count == 1 ? "it" : "them") back for 30 days."
        appSelection = []
        appsBusy = nil
        refreshRemoved()
        await loadApps()
    }

    func cleanLeftovers() async {
        let files = leftovers.flatMap(\.files).filter { leftoverSelection.contains($0.path) }
        guard !files.isEmpty else { return }
        appsBusy = "Moving leftovers…"
        let home = home, store = store
        let result = await Task.detached { LeftoverFinder.remove(files, home: home, store: store, open: OpenFiles.snapshot()) }.value
        lastAppsResult = "Moved \(formatBytes(result.keptBytes)) of leftovers to Recently Removed."
        leftoverSelection = []
        appsBusy = nil
        refreshRemoved()
        await loadApps()
    }

    // MARK: Startup

    var launchItems: [LaunchItem]?

    func loadStartup() async {
        let home = home
        launchItems = await Task.detached { LaunchItems.list(home: home) }.value
    }

    func setStartup(_ item: LaunchItem, on: Bool) async {
        let ok = await Task.detached { LaunchItems.setEnabled(item, on) }.value
        if !ok { problem = "macOS didn't accept the change for \(item.label)." }
        await loadStartup()
    }

    func removeLeftBehindItems() async {
        let items = (launchItems ?? []).filter { $0.scope == .user && $0.isLeftBehind }
        let home = home, store = store
        let result = await Task.detached { LaunchItems.removeLeftBehind(items, home: home, store: store) }.value
        if let f = result.failures.first { problem = "\(f.path): \(f.reason)" }
        refreshRemoved()
        await loadStartup()
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
