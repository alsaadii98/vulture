// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Files left behind by an app that's no longer on this Mac, gathered under its bundle identifier.
public struct LeftoverGroup: Codable, Identifiable, Sendable {
    public var bundleID: String
    public var files: [AppFile]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.usage.bytes } }
    public var lastChanged: Date? { files.compactMap(\.usage.newest).max() }
    public var id: String { bundleID }

    /// A readable guess at the app's name: `com.tinyspeck.slackmacgap` → `Slackmacgap`, `us.zoom.xos` → `Zoom`.
    public var displayName: String {
        let parts = bundleID.split(separator: ".").map(String.init)
        let skip: Set<String> = ["com", "org", "net", "io", "us", "co", "app", "mac", "macos", "osx", "xos", "desktop", "helper", "agent", "client"]
        let meaningful = parts.dropFirst().filter { !skip.contains($0.lowercased()) && $0.count > 1 }
        let pick = meaningful.count > 1 ? meaningful[meaningful.count - 1] : (meaningful.first ?? parts.last ?? bundleID)
        return pick.prefix(1).uppercased() + pick.dropFirst()
    }
}

public enum LeftoverFinder {
    /// Where apps keep files named after their bundle identifier.
    static let places: [(dir: String, suffix: String, kind: AppFile.Kind)] = [
        ("Library/Application Support", "", .appData),
        ("Library/Caches", "", .temporaryFiles),
        ("Library/Preferences", ".plist", .settings),
        ("Library/Saved Application State", ".savedState", .savedWindows),
        ("Library/HTTPStorages", "", .webData),
        ("Library/WebKit", "", .webData),
        ("Library/LaunchAgents", ".plist", .background),
    ]

    static let bundleIDShape = #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+){2,}$"#

    /// Finds files whose names are bundle identifiers of apps that aren't installed.
    ///
    /// - Parameters:
    ///   - installed: bundle identifiers of apps on this Mac. A leftover whose identifier starts with one of these
    ///     (a helper like `com.example.App.helper`) belongs to an installed app and is left alone.
    ///   - isRegistered: asks macOS whether any app anywhere has this identifier.
    ///   - quietDays: only offer apps whose files haven't changed for this long, so a just-uninstalled-to-reinstall app is spared.
    public static func find(home: URL, installed: Set<String>, isRegistered: (String) -> Bool, scanner: DiskScanner,
                            quietDays: Int = 30, now: Date = Date()) -> [LeftoverGroup] {
        let policy = AppInventory.leftoverPolicy(home: home)
        let installedLower = installed.map { $0.lowercased() }
        // Another app from the same maker may share these files, so a maker with an app still installed is left alone.
        let installedMakers = Set(installedLower.map(vendor))
        var groups: [String: [AppFile]] = [:]
        var verdict: [String: Bool] = [:]

        func isLeftover(_ id: String) -> Bool {
            if let v = verdict[id] { return v }
            let lower = id.lowercased()
            let v = !lower.hasPrefix("com.apple.") && !lower.hasPrefix("homebrew.")
                && !installedMakers.contains(vendor(lower))
                && !installedLower.contains { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
                && !isRegistered(id)
            verdict[id] = v
            return v
        }

        for place in places {
            let dir = home.appendingPathComponent(place.dir)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard place.suffix.isEmpty || name.hasSuffix(place.suffix) else { continue }
                let id = place.suffix.isEmpty ? name : String(name.dropLast(place.suffix.count))
                guard id.range(of: bundleIDShape, options: .regularExpression) != nil, isLeftover(id) else { continue }
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0, policy.check(url) == nil else { continue }
                let usage = scanner.usage(of: url)
                groups[id, default: []].append(AppFile(path: url.path, kind: place.kind, usage: usage, certain: false, fileID: UInt64(st.st_ino)))
            }
        }
        return groups.map { LeftoverGroup(bundleID: $0.key, files: $0.value) }
            .filter { group in
                guard let last = group.lastChanged else { return true }
                return now.timeIntervalSince(last) >= Double(quietDays) * 86_400
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// `com.example.App.helper` → `com.example`
    static func vendor(_ bundleID: String) -> String {
        bundleID.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Moves the chosen leftover files into Recently Removed, checking each again first.
    public static func remove(_ files: [AppFile], home: URL, store: RecentlyRemoved, open: OpenFiles, now: Date = Date()) -> CleanupResult {
        var result = CleanupResult()
        let policy = AppInventory.leftoverPolicy(home: home)
        var batch: RemovedBatch?
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            var st = stat()
            if let reason = policy.check(url) { result.failures.append(.init(path: file.path, reason: "safety check: \(reason.rawValue)")); continue }
            guard lstat(url.path, &st) == 0 else { continue }
            if let id = file.fileID, UInt64(st.st_ino) != id { result.failures.append(.init(path: file.path, reason: "it changed since the check")); continue }
            if open.firstOpen(inside: realPath(url.path) ?? url.path) != nil { result.failures.append(.init(path: file.path, reason: "an app is using it")); continue }
            do {
                if batch == nil { batch = try store.begin(title: "Leftovers of removed apps", at: now) }
                try store.keep(url, ruleID: "apps.leftovers", usage: file.usage, in: &batch!)
                result.keptBytes += file.usage.bytes
            } catch {
                result.failures.append(.init(path: file.path, reason: "\(error)"))
            }
        }
        result.batchID = batch?.id
        return result
    }
}
