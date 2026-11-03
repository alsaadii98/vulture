// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A declarative description of one kind of removable file, written in words a non-technical person understands.
/// Rules never run code: they only name places to look and the conditions under which something there may be removed.
public struct Rule: Codable, Hashable, Sendable {
    /// Stable dotted identifier, e.g. `xcode.derived-data`.
    public var id: String
    /// Short plain-language name shown in the app, e.g. "Xcode build files".
    public var title: String
    /// One or two sentences saying what these files are and what happens if they're removed.
    public var explanation: String
    public var category: Category
    public var safety: Safety
    public var regrows: Regrowth
    /// Home-relative glob patterns, e.g. `~/Library/Developer/Xcode/DerivedData/*`.
    /// `*`, `?` and `[...]` work inside one path component; there's no `**`.
    public var paths: [String]
    /// Name globs; a match that has one of these names is ignored.
    public var exclude: [String]
    /// Only offer an item when nothing inside it changed for this many days.
    public var minAgeDays: Int
    /// Bundle identifiers of apps that must be closed before these files may be touched.
    public var closeFirst: [String]
    /// When true, each matched item's name is a bundle identifier (as in `~/Library/Caches`),
    /// and the item is skipped while that app is running.
    public var entryNameIsBundleID: Bool
    /// Rules with a higher priority claim matching paths first; broad catch-all rules use a negative value.
    public var priority: Int

    public enum Category: String, Codable, CaseIterable, Sendable {
        case appFiles, logs, developer, downloads, mail
    }

    /// How sure Vulture is that removing these files is harmless.
    public enum Safety: String, Codable, CaseIterable, Sendable {
        /// Recommended: apps make these again on their own.
        case safe
        /// You decide: not selected until the person picks it.
        case review
    }

    /// When the space comes back after cleaning, so Vulture can be honest about how long the win lasts.
    public enum Regrowth: String, Codable, CaseIterable, Sendable {
        case never, onNextUse, onNextBuild, onNextInstall
    }

    public init(id: String, title: String, explanation: String, category: Category, safety: Safety, regrows: Regrowth,
                paths: [String], exclude: [String] = [], minAgeDays: Int = 0, closeFirst: [String] = [],
                entryNameIsBundleID: Bool = false, priority: Int = 0) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.category = category
        self.safety = safety
        self.regrows = regrows
        self.paths = paths
        self.exclude = exclude
        self.minAgeDays = minAgeDays
        self.closeFirst = closeFirst
        self.entryNameIsBundleID = entryNameIsBundleID
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, explanation, category, safety, regrows, paths, exclude, minAgeDays, closeFirst, entryNameIsBundleID, priority
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            title: c.decode(String.self, forKey: .title),
            explanation: c.decode(String.self, forKey: .explanation),
            category: c.decode(Category.self, forKey: .category),
            safety: c.decode(Safety.self, forKey: .safety),
            regrows: c.decode(Regrowth.self, forKey: .regrows),
            paths: c.decode([String].self, forKey: .paths),
            exclude: c.decodeIfPresent([String].self, forKey: .exclude) ?? [],
            minAgeDays: c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0,
            closeFirst: c.decodeIfPresent([String].self, forKey: .closeFirst) ?? [],
            entryNameIsBundleID: c.decodeIfPresent(Bool.self, forKey: .entryNameIsBundleID) ?? false,
            priority: c.decodeIfPresent(Int.self, forKey: .priority) ?? 0)
    }
}

/// The on-disk shape of a rule file: `{ "schemaVersion": 1, "rules": [...] }`.
public struct RuleFile: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var rules: [Rule]
}
