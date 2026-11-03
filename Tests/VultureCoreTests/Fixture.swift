// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A throwaway home folder built from a description, so tests never touch real files.
final class Fixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vulture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000, daysOld: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        if daysOld > 0 { try age(relative, days: daysOld) }
        return url
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func link(_ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func age(_ relative: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let path = home.appendingPathComponent(relative).path
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        // The scanner also counts "date added" as activity, so move that back too.
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = 0x1000_0000 // ATTR_CMN_ADDEDTIME
        var added = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        guard setattrlist(path, &request, &added, MemoryLayout<timespec>.size, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
}
