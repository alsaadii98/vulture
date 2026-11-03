// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One clean-up's worth of files kept so they can be put back, like the Trash but per clean-up.
public struct RemovedBatch: Codable, Hashable, Identifiable, Sendable {
    public struct Item: Codable, Hashable, Identifiable, Sendable {
        public var id: Int
        public var originalPath: String
        public var ruleID: String?
        public var usage: DiskUsage
    }

    public var id: String
    public var title: String
    public var removedAt: Date
    public var items: [Item]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.usage.bytes } }

    public func expires(after days: Int) -> Date {
        removedAt.addingTimeInterval(Double(days) * 86_400)
    }
}

public enum RecentlyRemovedError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case otherDisk(String)
    case destinationTaken(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .notFound(let id): return "nothing called \(id) in Recently Removed"
        case .otherDisk(let path): return "\(path) is on another disk, so it can't be kept in Recently Removed"
        case .destinationTaken(let path): return "something new is already at \(path)"
        case .system(let path, let code): return "\(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Files are moved here with `rename`, which is instant and keeps them on the same disk.
/// Putting back is the same move in reverse. Nothing is copied.
///
/// Layout: `<root>/<batch id>/manifest.json` and `<root>/<batch id>/<item id>/<original name>`.
public final class RecentlyRemoved: @unchecked Sendable {
    public static let defaultKeepDays = 30
    public let root: URL
    public let keepDays: Int
    private let lock = NSLock()

    public init(root: URL, keepDays: Int = RecentlyRemoved.defaultKeepDays) {
        self.root = root
        self.keepDays = keepDays
    }

    /// `~/Library/Application Support/Vulture/Recently Removed`
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RecentlyRemoved {
        RecentlyRemoved(root: home.appendingPathComponent("Library/Application Support/Vulture/Recently Removed"))
    }

    // MARK: - Reading

    public func batches() -> [RemovedBatch] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? manifest(at: $0) }.sorted { $0.removedAt > $1.removedAt }
    }

    public func batch(_ id: String) throws -> RemovedBatch {
        guard let b = try? manifest(at: root.appendingPathComponent(id)) else { throw RecentlyRemovedError.notFound(id) }
        return b
    }

    // MARK: - Moving in and out

    /// Starts a new batch. Items are added one by one so a failure halfway leaves an accurate record.
    public func begin(title: String, at date: Date = Date()) throws -> RemovedBatch {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let id = "\(f.string(from: date))-\(UUID().uuidString.prefix(4).lowercased())"
        let batch = RemovedBatch(id: id, title: title, removedAt: date, items: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        try save(batch)
        return batch
    }

    /// Moves `url` into `batch`. Refuses rather than copying when the file is on another disk.
    public func keep(_ url: URL, ruleID: String?, usage: DiskUsage, in batch: inout RemovedBatch) throws {
        lock.lock()
        defer { lock.unlock() }
        let itemID = (batch.items.map(\.id).max() ?? 0) + 1
        let holder = root.appendingPathComponent(batch.id).appendingPathComponent(String(itemID))
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let destination = holder.appendingPathComponent(url.lastPathComponent)
        if rename(url.path, destination.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: holder)
            throw code == EXDEV ? RecentlyRemovedError.otherDisk(url.path) : RecentlyRemovedError.system(url.path, code)
        }
        batch.items.append(.init(id: itemID, originalPath: url.path, ruleID: ruleID, usage: usage))
        try save(batch)
    }

    /// Puts items back where they were. Returns the items that couldn't be put back, with why;
    /// those stay in Recently Removed.
    @discardableResult
    public func putBack(batchID: String, items itemIDs: Set<Int>? = nil) throws -> [(RemovedBatch.Item, RecentlyRemovedError)] {
        lock.lock()
        defer { lock.unlock() }
        var batch = try batch(batchID)
        var failures: [(RemovedBatch.Item, RecentlyRemovedError)] = []
        var remaining: [RemovedBatch.Item] = []
        for item in batch.items {
            guard itemIDs?.contains(item.id) ?? true else { remaining.append(item); continue }
            let holder = root.appendingPathComponent(batch.id).appendingPathComponent(String(item.id))
            let stored = holder.appendingPathComponent(URL(fileURLWithPath: item.originalPath).lastPathComponent)
            let original = URL(fileURLWithPath: item.originalPath)
            if Glob.exists(original) {
                failures.append((item, .destinationTaken(item.originalPath)))
                remaining.append(item)
                continue
            }
            try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rename(stored.path, original.path) != 0 {
                failures.append((item, .system(item.originalPath, errno)))
                remaining.append(item)
                continue
            }
            try? FileManager.default.removeItem(at: holder)
        }
        batch.items = remaining
        if remaining.isEmpty {
            try FileManager.default.removeItem(at: root.appendingPathComponent(batch.id))
        } else {
            try save(batch)
        }
        return failures
    }

    /// Removes batches for good. With no ids, removes those older than `keepDays`.
    /// Returns the space freed.
    @discardableResult
    public func empty(batchIDs: [String]? = nil, now: Date = Date()) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let targets = try batchIDs.map { try $0.map { try batch($0) } } ?? batches().filter { $0.expires(after: keepDays) <= now }
        var freed: Int64 = 0
        for b in targets {
            try Remover.removeForGood(root.appendingPathComponent(b.id))
            freed += b.bytes
        }
        return freed
    }

    public func emptyAll() throws -> Int64 {
        try empty(batchIDs: batches().map(\.id))
    }

    // MARK: - Manifest

    private func manifest(at dir: URL) throws -> RemovedBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemovedBatch.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    }

    private func save(_ batch: RemovedBatch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: root.appendingPathComponent(batch.id).appendingPathComponent("manifest.json"), options: .atomic)
    }
}
