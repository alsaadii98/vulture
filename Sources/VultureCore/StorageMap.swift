// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Treemap layout

/// Lays out boxes whose areas match their sizes, as close to square as possible (Bruls, Huizing and van Wijk's
/// "squarified" treemap), so big items are easy to spot and click.
public enum Treemap {
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var area: Double { width * height }
    }

    /// One rectangle per value, in the same order. Values should be sorted largest first; zero and negative
    /// values get empty rectangles.
    public static func squarify(_ values: [Double], in rect: Rect) -> [Rect] {
        var result = [Rect](repeating: Rect(x: rect.x, y: rect.y, width: 0, height: 0), count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = rect.area / total
        var items = values.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }
        var free = rect

        while !items.isEmpty {
            let side = min(free.width, free.height)
            var row: [(index: Int, area: Double)] = [items.removeFirst()]
            while let next = items.first, worst(row + [next], side: side) <= worst(row, side: side) {
                row.append(items.removeFirst())
            }
            let rowArea = row.reduce(0) { $0 + $1.area }
            if free.width >= free.height {
                // A column on the left.
                let w = rowArea / free.height
                var y = free.y
                for item in row {
                    let h = item.area / w
                    result[item.index] = Rect(x: free.x, y: y, width: w, height: h)
                    y += h
                }
                free = Rect(x: free.x + w, y: free.y, width: max(0, free.width - w), height: free.height)
            } else {
                // A row along the top.
                let h = rowArea / free.width
                var x = free.x
                for item in row {
                    let w = item.area / h
                    result[item.index] = Rect(x: x, y: free.y, width: w, height: h)
                    x += w
                }
                free = Rect(x: free.x, y: free.y + h, width: free.width, height: max(0, free.height - h))
            }
        }
        return result
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0 else { return .infinity }
        let biggest = row.map(\.area).max() ?? 0, smallest = row.map(\.area).min() ?? 0
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * biggest / sum2, sum2 / (s2 * smallest))
    }
}

// MARK: - Folder sizes

/// One item in a folder, measured.
public struct MapItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var bytes: Int64
    public var newest: Date?

    public init(name: String, path: String, isDirectory: Bool, bytes: Int64, newest: Date?) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.bytes = bytes; self.newest = newest
    }
}

/// Measures folders for the Storage Map and remembers the answers, so going back up is instant.
public final class FolderSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [MapItem]] = [:]
    private let skipping: [URL]

    public init(skipping: [URL] = []) { self.skipping = skipping }

    /// What's directly inside `folder`, largest first. Measured once, then served from memory.
    public func children(of folder: URL) -> [MapItem] {
        let key = folder.standardizedFileURL.path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let entries = DiskScanner(skipping: skipping).children(of: folder)
        let items = entries.map {
            MapItem(name: $0.name, path: (key as NSString).appendingPathComponent($0.name), isDirectory: $0.isDirectory,
                    bytes: $0.usage.bytes, newest: $0.usage.newest)
        }
        lock.lock()
        cache[key] = items
        lock.unlock()
        return items
    }

    public func isCached(_ folder: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache[folder.standardizedFileURL.path] != nil
    }

    /// Forgets everything, so the next look measures again.
    public func reset() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}

// MARK: - Explaining an item

/// Plain-language answers for the Storage Map's detail panel.
public enum MapGuide {
    public enum Kind: String, Sendable, CaseIterable {
        case appData, developer, media, documents, temporary, mail, apps, system, other
    }

    /// A rough kind, used for the box color and a fallback explanation.
    public static func kind(of path: String, home: URL) -> Kind {
        let rel = relative(path, home: home) ?? path
        let lower = rel.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        if lower.hasPrefix("library/mail") || lower.hasPrefix("library/containers/com.apple.mail") { return .mail }
        if lower.hasPrefix("library/caches") || lower.hasPrefix("library/logs") || name == "tmp" || name.hasSuffix(".tmp")
            || name == "caches" { return .temporary }
        if lower.hasPrefix("library/developer") || lower.contains("deriveddata") || lower.hasPrefix(".npm") || lower.hasPrefix(".gradle")
            || lower.hasPrefix(".cargo") || lower.hasPrefix(".docker") || name == "node_modules" || name == "docker.raw"
            || lower.contains("com.docker.docker") || ["development", "developer", "projects", "code", "src", "repos"].contains(lower) {
            return .developer
        }
        if ["pictures", "movies", "music"].contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) || name.hasSuffix(".photoslibrary") {
            return .media
        }
        if ["desktop", "documents", "downloads", "library/mobile documents"].contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) {
            return .documents
        }
        if path.hasPrefix("/Applications") || lower.hasPrefix("applications") || name.hasSuffix(".app") { return .apps }
        if lower.hasPrefix("library/") || lower == "library" { return .appData }
        if !path.hasPrefix(home.path) { return .system }
        return .other
    }

    /// Why this item must not be deleted by hand, or nil when nothing special is known.
    public static func warning(for path: String, home: URL, policy: SafetyPolicy) -> String? {
        let name = (path as NSString).lastPathComponent
        if name == "Docker.raw" {
            return "Deleting it would erase everything inside Docker. Vulture can safely remove the parts Docker no longer uses instead."
        }
        if name.hasSuffix(".photoslibrary") {
            return "This is your Photos library. Deleting it removes your photos. To make it smaller, use Photos or iCloud Photos."
        }
        if name.hasSuffix(".app") {
            return "This is an app. To remove it with its settings and helpers, use Apps in Vulture."
        }
        guard let rel = relative(path, home: home) else {
            return "This belongs to macOS or another user. Vulture leaves it alone."
        }
        // Only things that are, or are inside, a protected place. Folders that merely contain one (like Library)
        // are fine to look through.
        if let prot = policy.protectedPaths.first(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
            switch prot {
            case "Library/Mail": return "Mail keeps your messages here. Deleting files here can lose email. Remove large attachments from Mail instead."
            case "Library/Messages": return "Your messages and their attachments live here. Delete conversations in Messages instead."
            case "Library/Keychains": return "Your passwords are stored here. Never delete these files."
            case "Library/Photos": return "Photos keeps its data here. Manage your photos in the Photos app instead."
            case "Library/Mobile Documents": return "These are your iCloud Drive files. Deleting them here deletes them on your other devices too."
            default: return "Vulture never removes anything here, because it holds your own files or another app's private data."
            }
        }
        return nil
    }

    /// A fallback explanation by kind, for items no cleaning rule covers.
    public static func explanation(for kind: Kind, isDirectory: Bool) -> String {
        switch kind {
        case .appData: "Settings and data apps keep for themselves."
        case .developer: "Files made by coding tools. Much of it can be made again."
        case .media: "Your photos, music and videos."
        case .documents: "Your own files. Vulture never removes these unless you ask."
        case .temporary: "Temporary files apps make while they work. Apps make new ones when needed."
        case .mail: "Your email and its attachments."
        case .apps: "Apps and what they need to run."
        case .system: "Part of macOS or shared with other users."
        case .other: isDirectory ? "A folder in your home folder." : "A file in your home folder."
        }
    }

    /// The cleaning rule that covers `path`, if any: the path is an item a rule matches, or inside one.
    public static func rule(covering path: String, rules: [Rule], home: URL) -> Rule? {
        guard let rel = relative(path, home: home) else { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        for rule in rules {
            for pattern in rule.paths where pattern.hasPrefix("~/") {
                let pp = pattern.dropFirst(2).split(separator: "/").map(String.init)
                guard parts.count >= pp.count else { continue }
                if zip(pp, parts).allSatisfy({ Glob.matches($0, $1) }) { return rule }
            }
        }
        return nil
    }

    /// The app that made an item, guessed from bundle-ID-like names in its path (`com.docker.docker`).
    public static func bundleIDs(in path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { component in
            let parts = component.split(separator: ".")
            return parts.count >= 3 && ["com", "org", "io", "net", "dev", "app", "us", "de", "co"].contains(parts[0].lowercased())
                && !component.hasSuffix(".plist") && !component.contains(" ")
        }.reversed()
    }

    static func relative(_ path: String, home: URL) -> String? {
        let base = home.standardizedFileURL.path
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}

// MARK: - Docker sizes

extension DockerReport.Line {
    /// Total size Docker reports for this kind of thing.
    public var bytes: Int64 { Docker.parseSize(size) }
    /// What Docker says it can give back.
    public var reclaimableBytes: Int64 { Docker.parseSize(reclaimable) }
}
