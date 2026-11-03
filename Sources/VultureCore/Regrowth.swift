// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Remembers how fast cleaned folders fill up again. A cache that's back to half its size within two days
/// gives space only briefly, so Vulture stops recommending it and says why.
public final class RegrowthTracker: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public var path: String
        public var cleanedAt: Date
        public var cleanedBytes: Int64
        /// Set once the folder has been looked at again, between `checkAfter` and `checkWithin` after cleaning.
        public var regrownBytes: Int64?
        public var checkedAt: Date?

        public var fillsQuickly: Bool {
            guard let regrownBytes, cleanedBytes > 0 else { return false }
            return Double(regrownBytes) >= Double(cleanedBytes) * RegrowthTracker.quickShare
        }
    }

    /// Back to this share of its size…
    public static let quickShare = 0.5
    /// …when looked at again between these two times after cleaning, counts as filling up quickly.
    public static let checkAfter: TimeInterval = 6 * 3600
    public static let checkWithin: TimeInterval = 2 * 86_400
    /// How long a verdict is remembered.
    public static let rememberDays = 90
    /// Folders smaller than this when cleaned aren't worth tracking.
    public static let minimumBytes: Int64 = 50_000_000

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RegrowthTracker {
        RegrowthTracker(url: VultureData.folder(home: home).appendingPathComponent("regrowth.json"))
    }

    public func records() -> [Record] { VultureData.load([Record].self, from: url) ?? [] }

    /// Notes what a clean-up removed for good (items moved to Recently Removed don't regrow).
    public func noteCleaned(_ removed: [String: Int64], at date: Date = Date()) throws {
        let worth = removed.filter { $0.value >= Self.minimumBytes }
        guard !worth.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var list = records().filter { !worth.keys.contains($0.path) || $0.checkedAt != nil }
        list += worth.map { Record(path: $0.key, cleanedAt: date, cleanedBytes: $0.value) }
        try save(list, now: date)
    }

    /// Compares a new scan with earlier clean-ups. Call after every scan.
    public func observe(_ plan: CleanupPlan, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        let sizes = Dictionary(plan.groups.flatMap(\.findings).map { ($0.path, $0.usage.bytes) }, uniquingKeysWith: max)
        var list = records()
        var changed = false
        for i in list.indices where list[i].checkedAt == nil {
            let elapsed = now.timeIntervalSince(list[i].cleanedAt)
            guard elapsed >= Self.checkAfter, elapsed <= Self.checkWithin else { continue }
            list[i].regrownBytes = sizes[list[i].path] ?? 0
            list[i].checkedAt = now
            changed = true
        }
        if changed { try save(list, now: now) }
    }

    /// Folders seen filling up quickly in the last `rememberDays` days.
    public func quicklyRefilling(now: Date = Date()) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Double(Self.rememberDays) * 86_400)
        return Set(records().filter { $0.fillsQuickly && $0.cleanedAt >= cutoff }.map(\.path))
    }

    private func save(_ list: [Record], now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(Self.rememberDays) * 86_400)
        try VultureData.save(list.filter { $0.cleanedAt >= cutoff }, to: url)
    }
}
