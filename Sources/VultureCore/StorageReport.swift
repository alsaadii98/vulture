// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What's using space on the startup disk, sorted into the words people use for it.
public struct StorageReport: Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case apps, documents, media, coding, appData, otherFiles, system
    }

    public struct Category: Codable, Identifiable, Sendable {
        public var kind: Kind
        public var bytes: Int64
        public var id: Kind { kind }
    }

    public var categories: [Category]
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// Folders that couldn't be read; their space ends up counted under `system`.
    public var unreadable: Int
    public var measuredAt: Date

    public var usedBytes: Int64 { totalBytes - freeBytes }

    public func bytes(_ kind: Kind) -> Int64 { categories.first { $0.kind == kind }?.bytes ?? 0 }
}

public enum StorageAnalyzer {
    /// Home-folder items that are developer tools' data.
    static let codingDotFolders: Set<String> = [
        ".npm", ".pnpm-store", ".yarn", ".bun", ".cargo", ".rustup", ".gradle", ".m2", ".android", ".nvm", ".pyenv",
        ".conda", ".docker", ".colima", ".orbstack", ".cocoapods", ".swiftpm", ".dartServer", ".pub-cache", ".expo", ".deno",
        // downloaded AI models
        ".ollama", ".lmstudio",
    ]

    /// Sorts one item directly inside the home folder.
    static func kind(ofHomeItem name: String) -> StorageReport.Kind {
        switch name {
        case "Desktop", "Documents", "Downloads", "Public": .documents
        case "Pictures", "Movies", "Music": .media
        case "Applications": .apps
        case "go": .coding  // Go's module and build files; people's own projects stay under other files
        default: codingDotFolders.contains(name) ? .coding : .otherFiles
        }
    }

    /// Sorts one item directly inside `~/Library`.
    static func kind(ofLibraryItem name: String) -> StorageReport.Kind {
        switch name {
        case "Developer", "Android": .coding
        case "Mobile Documents", "Mail", "Messages": .documents
        case "Photos": .media
        default: .appData
        }
    }

    /// Measures the home folder and the Applications folder, and counts everything else that's used as macOS and System Data.
    public static func analyze(home: URL, applications: [URL] = [URL(fileURLWithPath: "/Applications")],
                               volume: URL = URL(fileURLWithPath: "/"), scanner: DiskScanner) -> StorageReport {
        var sums: [StorageReport.Kind: Int64] = [:]
        var unreadable = 0

        for entry in scanner.children(of: home, skipping: ["Library"]) {
            sums[kind(ofHomeItem: entry.name), default: 0] += entry.usage.bytes
            unreadable += entry.usage.unreadable
        }
        for entry in scanner.children(of: home.appendingPathComponent("Library")) {
            sums[kind(ofLibraryItem: entry.name), default: 0] += entry.usage.bytes
            unreadable += entry.usage.unreadable
        }
        for folder in applications {
            let usage = scanner.usage(of: folder)
            sums[.apps, default: 0] += usage.bytes
            unreadable += usage.unreadable
        }

        let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let measured = sums.values.reduce(0, +)
        sums[.system] = max(0, total - free - measured)

        let categories = StorageReport.Kind.allCases.map { StorageReport.Category(kind: $0, bytes: sums[$0] ?? 0) }
        return StorageReport(categories: categories, totalBytes: total, freeBytes: free, unreadable: unreadable, measuredAt: Date())
    }
}
