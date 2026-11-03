// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct AppsTests {
    let fx: Fixture
    let apps: Fixture  // stands in for /Applications
    let store: RecentlyRemoved

    init() throws {
        fx = try Fixture()
        apps = try Fixture()
        store = RecentlyRemoved(root: fx.url("Library/Application Support/Vulture/Recently Removed"))
    }

    @discardableResult
    func makeApp(_ name: String, id: String, in folder: String = "") throws -> URL {
        let path = (folder.isEmpty ? "" : folder + "/") + "\(name).app"
        try apps.file("\(path)/Contents/MacOS/\(name)", bytes: 200_000)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
        info.write(to: apps.url("\(path)/Contents/Info.plist"), atomically: true)
        return apps.url(path)
    }

    func inventory() -> [InstalledApp] { AppInventory.installedApps(roots: [apps.home], scanner: DiskScanner()) }

    @Test func listsAppsIncludingOneFolderDown() throws {
        try makeApp("Figma", id: "com.figma.Desktop")
        try makeApp("Disk Helper", id: "com.example.helper", in: "Utilities")
        let list = inventory()
        #expect(list.map(\.name) == ["Disk Helper", "Figma"])
        #expect(list.first { $0.name == "Figma" }?.bytes ?? 0 >= 200_000)
    }

    @Test func findsWhatAnAppKeepsInTheHomeFolder() throws {
        try fx.file("Library/Application Support/com.figma.Desktop/state.db")
        try fx.file("Library/Caches/com.figma.Desktop/blob")
        try fx.file("Library/Preferences/com.figma.Desktop.plist")
        try fx.file("Library/Saved Application State/com.figma.Desktop.savedState/windows.plist")
        try fx.file("Library/Application Support/Figma/fonts.json")
        try fx.file("Library/LaunchAgents/com.figma.Desktop.agent.plist")
        try fx.file("Library/Preferences/com.other.App.plist")
        let files = AppInventory.files(of: "com.figma.Desktop", name: "Figma", home: fx.home, scanner: DiskScanner(), fullDiskAccess: false)
        let names = Set(files.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(names == ["com.figma.Desktop", "com.figma.Desktop.plist", "com.figma.Desktop.savedState", "Figma", "com.figma.Desktop.agent.plist"])
        #expect(files.first { $0.path.hasSuffix("Application Support/Figma") }?.certain == false)
    }

    @Test func neverTouchesProtectedPlacesEvenForApps() throws {
        try fx.file("Library/Messages/chat.db")
        #expect(AppInventory.files(of: "com.example.Messages", name: "Messages", home: fx.home, scanner: DiskScanner(), fullDiskAccess: true)
            .allSatisfy { !$0.path.contains("Library/Messages") })
        #expect(AppInventory.files(of: "com.apple.Safari", name: "Safari", home: fx.home, scanner: DiskScanner(), fullDiskAccess: true).isEmpty)
    }

    @Test func removingAnAppIsOneUndoableStep() throws {
        let appURL = try makeApp("Figma", id: "com.figma.Desktop")
        let prefs = try fx.file("Library/Preferences/com.figma.Desktop.plist")
        try fx.file("Library/Caches/com.figma.Desktop/blob")
        let app = try #require(inventory().first)
        let files = AppInventory.files(of: app.bundleID, name: app.name, home: fx.home, scanner: DiskScanner(), fullDiskAccess: false)

        let (batch, failures) = try AppRemover.remove(app, files: files, roots: [apps.home], home: fx.home, store: store,
                                                      running: [], open: OpenFiles(paths: []))
        #expect(failures.isEmpty)
        #expect(batch.items.count == 3)
        #expect(!Glob.exists(appURL) && !Glob.exists(prefs))

        #expect(try store.putBack(batchID: batch.id).isEmpty)
        #expect(Glob.exists(appURL.appendingPathComponent("Contents/Info.plist")))
        #expect(Glob.exists(prefs))
    }

    @Test func refusesOpenAppsAppleAppsAndOtherFolders() throws {
        try makeApp("Figma", id: "com.figma.Desktop")
        let app = try #require(inventory().first)
        #expect(throws: AppRemover.Problem.running) {
            try AppRemover.remove(app, files: [], roots: [apps.home], home: fx.home, store: store, running: ["com.figma.Desktop"], open: OpenFiles(paths: []))
        }
        var apple = app
        apple.bundleID = "com.apple.Safari"
        #expect(throws: AppRemover.Problem.appleApp) {
            try AppRemover.remove(apple, files: [], roots: [apps.home], home: fx.home, store: store, running: [], open: OpenFiles(paths: []))
        }
        let elsewhere = try Fixture()
        #expect(throws: AppRemover.Problem.notInApplications) {
            try AppRemover.remove(app, files: [], roots: [elsewhere.home], home: fx.home, store: store, running: [], open: OpenFiles(paths: []))
        }
        #expect(Glob.exists(URL(fileURLWithPath: app.path)))
    }

    @Test func findsLeftoversOfDeletedAppsOnly() throws {
        try fx.file("Library/Application Support/us.zoom.xos/data.db", daysOld: 120)
        try fx.file("Library/Preferences/us.zoom.xos.plist", daysOld: 120)
        try fx.file("Library/Caches/com.figma.Desktop.helper/blob", daysOld: 120)  // helper of an installed app
        try fx.file("Library/Caches/com.recent.Removed/blob", daysOld: 2)          // too recent to be sure
        try fx.file("Library/Caches/com.apple.Safari/blob", daysOld: 120)
        try fx.file("Library/Application Support/Some Folder/x", daysOld: 120)    // not a bundle identifier
        let groups = LeftoverFinder.find(home: fx.home, installed: ["com.figma.Desktop"], isRegistered: { _ in false }, scanner: DiskScanner())
        #expect(groups.map(\.bundleID) == ["us.zoom.xos"])
        #expect(groups.first?.files.count == 2)
        #expect(groups.first?.displayName == "Zoom")
    }

    @Test func sameMakerAndHomebrewAreNotLeftovers() throws {
        try fx.file("Library/Preferences/com.runningwithcrayons.Alfred-Preferences.plist", daysOld: 120)
        try fx.file("Library/LaunchAgents/homebrew.mxcl.ollama.plist", daysOld: 120)
        let groups = LeftoverFinder.find(home: fx.home, installed: ["com.runningwithcrayons.Alfred"], isRegistered: { _ in false }, scanner: DiskScanner())
        #expect(groups.isEmpty)
    }

    @Test func lastUsedComesFromTheAppsOwnFiles() throws {
        try fx.file("Library/Saved Application State/com.figma.Desktop.savedState/windows.plist")
        try fx.age("Library/Saved Application State/com.figma.Desktop.savedState", days: 40)
        // A path Spotlight doesn't know, so only the app's own files speak. (Spotlight reports a freshly made bundle as just used.)
        let used = AppInventory.lastUsed(URL(fileURLWithPath: "/nonexistent/Figma.app"), bundleID: "com.figma.Desktop", home: fx.home)
        let days = Date().timeIntervalSince(try #require(used)) / 86_400
        #expect(days > 39 && days < 41)
    }

    @Test func appsMacOSStillKnowsAreNotLeftovers() throws {
        try fx.file("Library/Caches/com.example.Elsewhere/blob", daysOld: 120)
        let groups = LeftoverFinder.find(home: fx.home, installed: [], isRegistered: { $0 == "com.example.Elsewhere" }, scanner: DiskScanner())
        #expect(groups.isEmpty)
    }

    @Test func readsBackgroundItems() throws {
        let agent: NSDictionary = ["Label": "com.example.updater", "ProgramArguments": ["/nonexistent/Example.app/Contents/MacOS/updater", "--check"],
                                   "RunAtLoad": true, "StartInterval": 3600]
        let alive: NSDictionary = ["Label": "com.example.sync", "Program": "/bin/sh", "KeepAlive": ["SuccessfulExit": false]]
        let apple: NSDictionary = ["Label": "com.apple.something", "Program": "/bin/sh"]
        try fx.directory("Library/LaunchAgents")
        agent.write(to: fx.url("Library/LaunchAgents/com.example.updater.plist"), atomically: true)
        alive.write(to: fx.url("Library/LaunchAgents/com.example.sync.plist"), atomically: true)
        apple.write(to: fx.url("Library/LaunchAgents/com.apple.something.plist"), atomically: true)

        let items = LaunchItems.list(home: fx.home, includeAllUsers: false)
        #expect(items.map(\.label) == ["com.example.sync", "com.example.updater"])
        let updater = try #require(items.first { $0.label == "com.example.updater" })
        #expect(updater.isLeftBehind && updater.runsAtLogin && updater.intervalSeconds == 3600)
        #expect(updater.appPath == "/nonexistent/Example.app")
        let sync = try #require(items.first { $0.label == "com.example.sync" })
        #expect(sync.keepsRunning && !sync.isLeftBehind)
    }
}
