// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Vulture's own small files: history and what it learned. Kept in Application Support, never sent anywhere.
public enum VultureData {
    public static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Vulture")
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// One day's picture of the disk, by category.
public struct SpaceSnapshot: Codable, Sendable {
    public var date: Date
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var categories: [String: Int64]

    public func bytes(_ kind: StorageReport.Kind) -> Int64 { categories[kind.rawValue] ?? 0 }
}

/// A daily record of what's using space, so Vulture can answer "what ate 40 GB this week?".
public final class SpaceHistory: @unchecked Sendable {
    public static let keepDays = 400
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SpaceHistory {
        SpaceHistory(url: VultureData.folder(home: home).appendingPathComponent("history.json"))
    }

    public func snapshots() -> [SpaceSnapshot] {
        (VultureData.load([SpaceSnapshot].self, from: url) ?? []).sorted { $0.date < $1.date }
    }

    /// Saves today's numbers, replacing an earlier measurement from the same day.
    public func record(_ report: StorageReport, calendar: Calendar = .current) throws {
        lock.lock()
        defer { lock.unlock() }
        var list = snapshots().filter { !calendar.isDate($0.date, inSameDayAs: report.measuredAt) }
        list.append(SpaceSnapshot(date: report.measuredAt, freeBytes: report.freeBytes, totalBytes: report.totalBytes,
                                  categories: Dictionary(uniqueKeysWithValues: report.categories.map { ($0.kind.rawValue, $0.bytes) })))
        let cutoff = report.measuredAt.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        try VultureData.save(list.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }, to: url)
    }

    public struct Change: Sendable {
        public var kind: StorageReport.Kind
        public var delta: Int64
    }

    /// How each category changed between the latest snapshot and the newest one at least `days` older.
    /// Nil until there's history that old. Largest growth first.
    public func changes(overDays days: Int) -> (since: Date, freeDelta: Int64, changes: [Change])? {
        let list = snapshots()
        guard let latest = list.last else { return nil }
        let target = latest.date.addingTimeInterval(-Double(days) * 86_400)
        guard let base = list.last(where: { $0.date <= target }) else { return nil }
        let changes = StorageReport.Kind.allCases.map { Change(kind: $0, delta: latest.bytes($0) - base.bytes($0)) }
            .filter { $0.delta != 0 }
            .sorted { $0.delta > $1.delta }
        return (base.date, latest.freeBytes - base.freeBytes, changes)
    }
}
