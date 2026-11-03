// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct ProjectFinderTests {
    let fx: Fixture
    init() throws { fx = try Fixture() }

    /// Makes a project whose own files were last changed `days` ago.
    func project(_ path: String, marker: String, folder: String, days: Double, markerInside: Bool = false) throws {
        try fx.file("\(path)/\(folder)/payload/lib.bin", bytes: 100_000)
        try fx.file(markerInside ? "\(path)/\(folder)/\(marker)" : "\(path)/\(marker)", daysOld: days)
        try fx.file("\(path)/README.md", daysOld: days)
        for item in (try FileManager.default.contentsOfDirectory(atPath: fx.url(path).path)) where item != folder {
            try fx.age("\(path)/\(item)", days: days)
        }
    }

    func found(days: Int = 90) -> [String: [String]] {
        let groups = ProjectFinder(home: fx.home, untouchedDays: days).groups(policy: SafetyPolicy(home: fx.home), scanner: DiskScanner())
        return Dictionary(uniqueKeysWithValues: groups.map { g in
            (g.rule.id, g.findings.map { String($0.path.dropFirst(fx.home.standardizedFileURL.path.count + 1)) })
        })
    }

    @Test func findsBuildFoldersInOldProjects() throws {
        try project("Development/shop", marker: "package.json", folder: "node_modules", days: 200)
        try project("Development/tools/cli", marker: "Cargo.toml", folder: "target", days: 120)
        try project("Projects/notebooks", marker: "pyvenv.cfg", folder: ".venv", days: 300, markerInside: true)
        let result = found()
        #expect(result["projects.node-modules"] == ["Development/shop/node_modules"])
        #expect(result["projects.rust-target"] == ["Development/tools/cli/target"])
        #expect(result["projects.python-venv"] == ["Projects/notebooks/.venv"])
    }

    @Test func leavesRecentProjectsAlone() throws {
        try project("Development/active", marker: "package.json", folder: "node_modules", days: 3)
        #expect(found().isEmpty)
    }

    @Test func countsGitActivityInTheEnclosingRepository() throws {
        // A Flutter app: Pods lives in ios/, which rarely changes, but the repository is in daily use.
        try project("Development/app/ios", marker: "Podfile", folder: "Pods", days: 200)
        try fx.file("Development/app/.git/index", daysOld: 2)
        try fx.file("Development/app/.git/HEAD", daysOld: 2)
        #expect(found().isEmpty)
    }

    @Test func needsTheMarkerFile() throws {
        // A folder called "target" with no Cargo.toml next to it could be anything.
        try fx.file("Development/photos/target/shot.jpg", bytes: 50_000, daysOld: 400)
        try fx.age("Development/photos", days: 400)
        #expect(found().isEmpty)
    }

    @Test func neverLooksInDocumentsOrDesktop() throws {
        try project("Documents/old-site", marker: "package.json", folder: "node_modules", days: 400)
        #expect(ProjectFinder(home: fx.home, roots: ["Documents", "Desktop"]).groups(policy: SafetyPolicy(home: fx.home), scanner: DiskScanner()).isEmpty)
    }

    @Test func doesNotDescendIntoNodeModules() throws {
        try project("Development/app", marker: "package.json", folder: "node_modules", days: 200)
        // A package inside node_modules has its own node_modules; it must not be listed separately.
        try fx.file("Development/app/node_modules/dep/package.json")
        try fx.file("Development/app/node_modules/dep/node_modules/x/index.js")
        #expect(found()["projects.node-modules"] == ["Development/app/node_modules"])
    }

    @Test func cleanUpRemovesOnlyTheToolFolder() throws {
        try project("Development/shop", marker: "package.json", folder: "node_modules", days: 200)
        let policy = SafetyPolicy(home: fx.home)
        let groups = ProjectFinder(home: fx.home).groups(policy: policy, scanner: DiskScanner())
        let plan = CleanupPlan(groups: groups, startedAt: Date(), duration: 0)
        let store = RecentlyRemoved(root: fx.url("Library/Application Support/Vulture/Recently Removed"))
        let result = CleanupExecutor(policy: policy, store: store, runningApps: { [] }, openFiles: { OpenFiles(paths: []) })
            .run(plan, selected: Set(groups.flatMap(\.findings).map(\.path)))
        #expect(result.failures.isEmpty && result.freedBytes > 0)
        #expect(!Glob.exists(fx.url("Development/shop/node_modules")))
        #expect(Glob.exists(fx.url("Development/shop/package.json")))
        #expect(Glob.exists(fx.url("Development/shop/README.md")))
    }

    @Test func parsesToolOutput() {
        #expect(Docker.parseSize("1.2GB (35%)") == 1_200_000_000)
        #expect(Docker.parseSize("512.5MB") == 512_500_000)
        #expect(Docker.parseSize("0B") == 0)
        #expect(Simulators.readable("com.apple.CoreSimulator.SimRuntime.iOS-17-2") == "iOS 17.2")
    }
}
