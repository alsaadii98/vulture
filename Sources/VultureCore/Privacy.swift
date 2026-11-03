// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Privacy {
    /// Whether this process has Full Disk Access. Reading the user's privacy database needs it,
    /// and trying doesn't show a prompt.
    public static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let fd = open(home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Folders that hold other apps' private data. Without Full Disk Access, opening one makes macOS ask
    /// the person for permission and blocks until they answer, so scans step around them instead.
    public static func promptingFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Library/Containers", "Library/Group Containers"].map { home.appendingPathComponent($0) }
    }

    /// What a scanner should skip right now.
    public static func foldersToSkip(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        hasFullDiskAccess(home: home) ? [] : promptingFolders(home: home)
    }
}
