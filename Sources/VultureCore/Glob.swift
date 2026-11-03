// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum Glob {
    static func hasWildcard(_ component: String) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// Whether `name` matches `pattern`. A leading dot must be matched explicitly, so `*` skips hidden items.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD) == 0
    }

    /// Expands a `~/`-relative pattern into the items that exist right now.
    /// Never descends through a symbolic link; the final items themselves may be links (the safety check reports those).
    static func expand(_ pattern: String, home: URL) -> [URL] {
        guard pattern.hasPrefix("~/") else { return [] }
        let parts = pattern.dropFirst(2).split(separator: "/").map(String.init)
        var current = [home]
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var next: [URL] = []
            for dir in current {
                if hasWildcard(part) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    for name in names.sorted() where matches(part, name) {
                        let url = dir.appendingPathComponent(name)
                        if isLast || isRealDirectory(url) { next.append(url) }
                    }
                } else {
                    let url = dir.appendingPathComponent(part)
                    if isLast ? exists(url) : isRealDirectory(url) { next.append(url) }
                }
            }
            current = next
        }
        return current
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
