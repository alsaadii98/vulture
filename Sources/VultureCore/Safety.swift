// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why an item that a rule matched is left alone.
public enum SkipReason: String, Codable, Sendable {
    /// Inside, or containing, a place Vulture never touches (documents, photos, keychains…).
    case protected
    /// The item is a symbolic link, or the path to it passes through one.
    case symbolicLink
    /// The item isn't inside the home folder.
    case outsideHome
    /// An app that uses these files is open right now.
    case appRunning
}

/// Hard limits that hold no matter what a rule says. Checked at scan time, and again before anything is removed.
public struct SafetyPolicy: Sendable {
    public let home: URL
    /// Home-relative paths that are never offered for removal, nor is anything that contains them.
    public let protectedPaths: [String]

    /// Places that hold a person's own data, or secrets, or another app's shared state.
    public static let standardProtectedPaths: [String] = [
        "Desktop", "Documents", "Pictures", "Movies", "Music", "Public",
        ".Trash",
        ".ssh", ".gnupg", ".aws", ".kube", ".config/gh",
        // AI assistants' chats, memory and settings
        ".claude", ".codex", ".gemini", ".cursor", "Library/Application Support/Claude",
        "Library/Keychains",
        "Library/Mobile Documents",
        "Library/Group Containers",
        "Library/Messages",
        "Library/Mail",
        "Library/Safari",
        "Library/Calendars",
        "Library/Application Support/AddressBook",
        "Library/Application Support/MobileSync",
        "Library/Photos",
        "Library/Preferences",
        // Vulture's own Recently Removed
        "Library/Application Support/Vulture",
    ]

    public init(home: URL, protectedPaths: [String] = SafetyPolicy.standardProtectedPaths) {
        self.home = home.standardizedFileURL
        self.protectedPaths = protectedPaths
    }

    /// The standard protections plus folders the person chose in Settings › Safety › Never Touch These.
    /// Folders outside the home folder are ignored: Vulture never touches anything there anyway.
    public init(home: URL, alsoProtecting folders: [URL]) {
        let base = SafetyPolicy(home: home)
        let extra = folders.compactMap { base.relativePath($0) }
        self.init(home: home, protectedPaths: SafetyPolicy.standardProtectedPaths + extra)
    }

    /// The home-relative form of `url`, or nil when it isn't inside the home folder.
    public func relativePath(_ url: URL) -> String? {
        let base = home.path.hasSuffix("/") ? home.path : home.path + "/"
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base), p.count > base.count else { return nil }
        return String(p.dropFirst(base.count))
    }

    /// True when `relative` equals a protected path, lies inside one, or contains one.
    public func isProtected(relative: String) -> Bool {
        protectedPaths.contains { prot in
            relative == prot || relative.hasPrefix(prot + "/") || prot.hasPrefix(relative + "/")
        }
    }

    /// Returns a reason to leave `url` alone, or nil when it may be offered.
    public func check(_ url: URL) -> SkipReason? {
        guard let rel = relativePath(url) else { return .outsideHome }
        if isProtected(relative: rel) { return .protected }

        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .outsideHome }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .symbolicLink }

        // The real location of the parent must be exactly where the path says it is,
        // so a link somewhere along the way can't redirect us into another folder.
        guard let realHome = realPath(home.path), let realParent = realPath(url.deletingLastPathComponent().path) else {
            return .symbolicLink
        }
        let logicalParent = (rel as NSString).deletingLastPathComponent
        let expected = logicalParent.isEmpty ? realHome : realHome + "/" + logicalParent
        if realParent != expected { return .symbolicLink }
        return nil
    }
}

func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}
