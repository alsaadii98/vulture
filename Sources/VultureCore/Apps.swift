// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreServices
import Foundation

public struct InstalledApp: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String?
    public var bytes: Int64
    public var lastUsed: Date?
    /// Whether this user can move the app (and the folder it's in). Apps installed for all users by an installer often can't be.
    public var canRemove: Bool

    public var id: String { path }
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

/// Something an app keeps in the home folder: its settings, temporary files, saved windows…
public struct AppFile: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appData, temporaryFiles, settings, savedWindows, webData, logs, background, container, shared
    }

    public var path: String
    public var kind: Kind
    public var usage: DiskUsage
    /// True when the name is exactly the app's bundle identifier. Matches by app name, or shared folders, aren't certain.
    public var certain: Bool
    public var fileID: UInt64?

    public var id: String { path }
}

public enum AppInventory {
    public static func standardRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Apps directly in the Applications folders and one level of subfolders (like Utilities). Apple's own apps are included
    /// so they can be shown, but they can't be removed.
    /// - Parameter home: when given, an app's own files there (saved windows, settings, caches) also tell when it was
    ///   last used, for Macs where Spotlight doesn't record it.
    public static func installedApps(roots: [URL], home: URL? = nil, scanner: DiskScanner) -> [InstalledApp] {
        var bundles: [URL] = []
        for root in roots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    bundles.append(url)
                } else if Glob.isRealDirectory(url) {
                    for inner in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        bundles.append(url.appendingPathComponent(inner))
                    }
                }
            }
        }
        let found = bundles
        var apps = [InstalledApp?](repeating: nil, count: found.count)
        apps.withUnsafeMutableBufferPointer { out in
            let slots = UnsafeSlots(out)
            DispatchQueue.concurrentPerform(iterations: found.count) { i in
                slots.base[i] = describe(found[i], home: home, scanner: scanner)
            }
        }
        return apps.compactMap { $0 }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func describe(_ url: URL, home: URL?, scanner: DiskScanner) -> InstalledApp? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().path
        return InstalledApp(path: url.path, name: name, bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String,
                            bytes: scanner.usage(of: url).bytes, lastUsed: lastUsed(url, bundleID: bundleID, home: home),
                            canRemove: access(url.path, W_OK) == 0 && access(parent, W_OK) == 0)
    }

    /// When the app was last used: what Spotlight remembers, or the last time the app changed its own files.
    static func lastUsed(_ url: URL, bundleID: String, home: URL?) -> Date? {
        var newest = MDItemCreateWithURL(nil, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        guard let home, !bundleID.hasPrefix("com.apple.") else { return newest }
        for relative in ["Library/Saved Application State/\(bundleID).savedState", "Library/Preferences/\(bundleID).plist",
                         "Library/Caches/\(bundleID)", "Library/Application Support/\(bundleID)", "Library/HTTPStorages/\(bundleID)"] {
            var st = stat()
            guard lstat(home.appendingPathComponent(relative).path, &st) == 0 else { continue }
            let d = Date(timespec: st.st_mtimespec)
            if newest.map({ d > $0 }) ?? true { newest = d }
        }
        return newest
    }

    // MARK: - What an app keeps in the home folder

    /// Folders Vulture looks in for an app's files, with what each holds. `{id}` is the bundle identifier.
    static let places: [(pattern: String, kind: AppFile.Kind)] = [
        ("Library/Application Support/{id}", .appData),
        ("Library/Caches/{id}", .temporaryFiles),
        ("Library/HTTPStorages/{id}", .webData),
        ("Library/HTTPStorages/{id}.binarycookies", .webData),
        ("Library/WebKit/{id}", .webData),
        ("Library/Preferences/{id}.plist", .settings),
        ("Library/Saved Application State/{id}.savedState", .savedWindows),
        ("Library/Logs/{id}", .logs),
        ("Library/Containers/{id}", .container),
    ]

    /// Policy for an app's own files: the usual protected places, except the two where apps keep files
    /// named after themselves. Those are only reached through exact bundle-identifier names.
    public static func leftoverPolicy(home: URL) -> SafetyPolicy {
        SafetyPolicy(home: home, protectedPaths: SafetyPolicy.standardProtectedPaths.filter {
            $0 != "Library/Preferences" && $0 != "Library/Group Containers"
        })
    }

    /// Finds the files `app` keeps in the home folder. Containers and shared folders are only looked at with Full Disk
    /// Access, since otherwise macOS would ask the person for permission.
    public static func files(of bundleID: String, name: String, home: URL, scanner: DiskScanner, fullDiskAccess: Bool) -> [AppFile] {
        guard !bundleID.hasPrefix("com.apple."), bundleID.contains(".") else { return [] }
        let policy = leftoverPolicy(home: home)
        var out: [AppFile] = []
        func add(_ relative: String, _ kind: AppFile.Kind, certain: Bool) {
            let url = home.appendingPathComponent(relative)
            var st = stat()
            guard lstat(url.path, &st) == 0, policy.check(url) == nil, !out.contains(where: { $0.path == url.path }) else { return }
            out.append(AppFile(path: url.path, kind: kind, usage: scanner.usage(of: url), certain: certain, fileID: UInt64(st.st_ino)))
        }
        for place in places {
            if place.kind == .container && !fullDiskAccess { continue }
            add(place.pattern.replacingOccurrences(of: "{id}", with: bundleID), place.kind, certain: true)
        }
        // Some apps name their folder after the app instead (Application Support/Figma). Names are less certain.
        if name.count >= 3, !genericNames.contains(name.lowercased()) {
            add("Library/Application Support/\(name)", .appData, certain: false)
            add("Library/Caches/\(name)", .temporaryFiles, certain: false)
            add("Library/Logs/\(name)", .logs, certain: false)
        }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [] where file.hasPrefix(bundleID) && file.hasSuffix(".plist") {
            add("Library/LaunchAgents/\(file)", .background, certain: true)
        }
        if fullDiskAccess {
            let group = home.appendingPathComponent("Library/Group Containers")
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: group.path)) ?? [] where dir.hasSuffix(bundleID) {
                add("Library/Group Containers/\(dir)", .shared, certain: false)
            }
        }
        return out
    }

    /// App names too general to match folders by.
    static let genericNames: Set<String> = ["code", "app", "data", "helper", "update", "updater", "support", "cache", "logs", "google", "microsoft", "adobe"]
}

/// Each parallel task writes only its own index, so sharing the buffer is safe.
struct UnsafeSlots<T>: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<T>
    init(_ base: UnsafeMutableBufferPointer<T>) { self.base = base }
}

// MARK: - Removing an app

public enum AppRemover {
    public enum Problem: Error, CustomStringConvertible, Equatable {
        case appleApp, running, notInApplications, notAnApp, needsAdmin

        public var description: String {
            switch self {
            case .appleApp: "Apps that come with macOS can't be removed."
            case .running: "The app is open. Quit it first."
            case .notInApplications: "Vulture only removes apps from the Applications folders."
            case .notAnApp: "That isn't an app."
            case .needsAdmin: "This app was installed for all users, so removing it needs an administrator. Drag it to the Trash in Finder instead."
            }
        }
    }

    /// Moves the app and the chosen files into one Recently Removed batch, so the whole removal can be put back at once.
    /// Each file is checked again right before it moves.
    public static func remove(_ app: InstalledApp, files: [AppFile], roots: [URL], home: URL, store: RecentlyRemoved,
                              running: Set<String>, open: OpenFiles, now: Date = Date()) throws -> (batch: RemovedBatch, failures: [CleanupResult.Failure]) {
        let url = URL(fileURLWithPath: app.path)
        guard !app.isApple else { throw Problem.appleApp }
        guard !running.contains(app.bundleID) else { throw Problem.running }
        guard url.pathExtension == "app" else { throw Problem.notAnApp }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let allowed = roots.flatMap { root in
            [root.standardizedFileURL.path] + ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .map { root.appendingPathComponent($0).standardizedFileURL.path }
        }
        guard allowed.contains(parent) else { throw Problem.notInApplications }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw Problem.notAnApp }
        guard access(url.path, W_OK) == 0, access(parent, W_OK) == 0 else { throw Problem.needsAdmin }
        if let file = open.firstOpen(inside: realPath(url.path) ?? url.path) { _ = file; throw Problem.running }

        var batch = try store.begin(title: "Removed \(app.name)", at: now)
        try store.keep(url, ruleID: "apps.uninstall", usage: { var u = DiskUsage(); u.bytes = app.bytes; return u }(), in: &batch)

        let policy = AppInventory.leftoverPolicy(home: home)
        var failures: [CleanupResult.Failure] = []
        for file in files {
            let f = URL(fileURLWithPath: file.path)
            var fst = stat()
            if let reason = policy.check(f) { failures.append(.init(path: file.path, reason: "safety check: \(reason.rawValue)")); continue }
            guard lstat(f.path, &fst) == 0 else { continue }
            if let id = file.fileID, UInt64(fst.st_ino) != id { failures.append(.init(path: file.path, reason: "it changed since the check")); continue }
            if open.firstOpen(inside: realPath(f.path) ?? f.path) != nil { failures.append(.init(path: file.path, reason: "an app is using it")); continue }
            do { try store.keep(f, ruleID: "apps.uninstall", usage: file.usage, in: &batch) }
            catch { failures.append(.init(path: file.path, reason: "\(error)")) }
        }
        return (batch, failures)
    }
}
