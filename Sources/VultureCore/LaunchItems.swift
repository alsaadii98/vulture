// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Something launchd starts on its own: at login, on a timer, or kept running all the time.
public struct LaunchItem: Codable, Hashable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// `~/Library/LaunchAgents`: this user's, and Vulture can turn it off.
        case user
        /// `/Library/LaunchAgents` or `/Library/LaunchDaemons`: for everyone; changing it needs an administrator.
        case allUsersAgent, allUsersDaemon
    }

    public var label: String
    public var plistPath: String
    public var scope: Scope
    /// The program it runs, when the file says so directly.
    public var program: String?
    /// The app it belongs to, if its program lives inside an app or the file names one.
    public var appPath: String?
    public var associatedBundleIDs: [String]
    public var runsAtLogin: Bool
    public var keepsRunning: Bool
    public var intervalSeconds: Int?
    public var disabled: Bool

    public var id: String { plistPath }
    public var isApple: Bool { label.hasPrefix("com.apple.") }

    /// Its program is gone, usually because the app was removed. Nothing will ever run, but macOS keeps trying.
    public var isLeftBehind: Bool {
        guard let program, program.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }
}

public enum LaunchItems {
    static let launchctl = "/bin/launchctl"

    public static func list(home: URL, includeAllUsers: Bool = true) -> [LaunchItem] {
        var places: [(URL, LaunchItem.Scope)] = [(home.appendingPathComponent("Library/LaunchAgents"), .user)]
        if includeAllUsers {
            places += [(URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsersAgent), (URL(fileURLWithPath: "/Library/LaunchDaemons"), .allUsersDaemon)]
        }
        let disabled = disabledLabels()
        var items: [LaunchItem] = []
        for (dir, scope) in places {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where name.hasSuffix(".plist") {
                if let item = parse(dir.appendingPathComponent(name), scope: scope, disabled: disabled) { items.append(item) }
            }
        }
        return items.filter { !$0.isApple }
    }

    static func parse(_ url: URL, scope: LaunchItem.Scope, disabled: Set<String>) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        var appPath: String?
        if let program, let range = program.range(of: ".app/") {
            appPath = String(program[..<range.lowerBound]) + ".app"
        }
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let b as Bool: keepAlive = b
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        let isDisabledInFile = plist["Disabled"] as? Bool ?? false
        return LaunchItem(label: label, plistPath: url.path, scope: scope, program: program, appPath: appPath,
                          associatedBundleIDs: associated, runsAtLogin: plist["RunAtLoad"] as? Bool ?? false,
                          keepsRunning: keepAlive, intervalSeconds: plist["StartInterval"] as? Int,
                          disabled: isDisabledInFile || disabled.contains(label))
    }

    /// Labels this user has turned off with `launchctl disable`.
    static func disabledLabels() -> Set<String> {
        guard let out = runTool(launchctl, ["print-disabled", "gui/\(getuid())"], timeout: 10) else { return [] }
        var labels: Set<String> = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1] == "disabled" || parts[1] == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    /// Turns one of this user's items off or back on. Nothing is deleted: launchd remembers the choice, and turning it
    /// back on restores it exactly.
    @discardableResult
    public static func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> Bool {
        guard item.scope == .user else { return false }
        let target = "gui/\(getuid())/\(item.label)"
        if enabled {
            guard runTool(launchctl, ["enable", target], timeout: 10) != nil else { return false }
            _ = runTool(launchctl, ["bootstrap", "gui/\(getuid())", item.plistPath], timeout: 10) // fine if already loaded
        } else {
            guard runTool(launchctl, ["disable", target], timeout: 10) != nil else { return false }
            _ = runTool(launchctl, ["bootout", target], timeout: 10) // fine if it wasn't running
        }
        return true
    }

    /// Stops a left-behind item of this user's and moves its file to Recently Removed.
    public static func removeLeftBehind(_ items: [LaunchItem], home: URL, store: RecentlyRemoved, now: Date = Date()) -> CleanupResult {
        var result = CleanupResult()
        let policy = AppInventory.leftoverPolicy(home: home)
        var batch: RemovedBatch?
        for item in items where item.scope == .user && item.isLeftBehind {
            let url = URL(fileURLWithPath: item.plistPath)
            if let reason = policy.check(url) { result.failures.append(.init(path: item.plistPath, reason: "safety check: \(reason.rawValue)")); continue }
            _ = runTool(launchctl, ["bootout", "gui/\(getuid())/\(item.label)"], timeout: 10)
            do {
                if batch == nil { batch = try store.begin(title: "Background items left behind", at: now) }
                try store.keep(url, ruleID: "startup.left-behind", usage: DiskUsage(), in: &batch!)
            } catch {
                result.failures.append(.init(path: item.plistPath, reason: "\(error)"))
            }
        }
        result.batchID = batch?.id
        return result
    }
}
