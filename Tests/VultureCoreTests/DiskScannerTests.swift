// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct DiskScannerTests {
    @Test func addsUpEveryFileAtAnyDepth() throws {
        let fx = try Fixture()
        for i in 0..<40 { try fx.file("root/a/b/c\(i % 4)/file\(i)", bytes: 4096 * (i + 1)) }
        let usage = DiskScanner().usage(of: fx.url("root"))
        #expect(usage.files == 40)
        // Allocated size is at least the content and at most one extra block per file.
        let content = (1...40).reduce(0) { $0 + Int64(4096 * $1) }
        #expect(usage.bytes >= content)
        #expect(usage.bytes <= content + 40 * 16_384)
    }

    @Test func matchesStatForASingleFile() throws {
        let fx = try Fixture()
        let url = try fx.file("one.bin", bytes: 123_457)
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        let usage = DiskScanner().usage(of: url)
        #expect(usage.bytes == Int64(st.st_blocks) * 512)
        #expect(usage.files == 1)
    }

    @Test func countsHardLinkedFilesOnce() throws {
        let fx = try Fixture()
        let original = try fx.file("root/original", bytes: 200_000)
        #expect(link(original.path, fx.url("root/again").path) == 0)
        let usage = DiskScanner().usage(of: fx.url("root"))
        #expect(usage.files == 1)
        #expect(usage.bytes < 400_000)
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let fx = try Fixture()
        try fx.file("elsewhere/big", bytes: 1_000_000)
        try fx.file("root/small", bytes: 1_000)
        try fx.link("root/shortcut", to: fx.url("elsewhere").path)
        let usage = DiskScanner().usage(of: fx.url("root"))
        #expect(usage.files == 1)
        #expect(usage.bytes < 100_000)
    }

    @Test func reportsNewestModificationInside() throws {
        let fx = try Fixture()
        try fx.file("root/old", daysOld: 40)
        try fx.file("root/deep/newer", daysOld: 3)
        let newest = try #require(DiskScanner().usage(of: fx.url("root")).newest)
        let days = Date().timeIntervalSince(newest) / 86_400
        #expect(days > 2.9 && days < 3.1)
    }

    @Test func listsChildrenLargestFirst() throws {
        let fx = try Fixture()
        try fx.file("root/small/a", bytes: 10_000)
        try fx.file("root/large/a", bytes: 500_000)
        try fx.file("root/loose", bytes: 100_000)
        let names = DiskScanner().children(of: fx.url("root")).map(\.name)
        #expect(names == ["large", "loose", "small"])
    }

    @Test func stepsAroundSkippedFolders() throws {
        let fx = try Fixture()
        try fx.file("root/open/a", bytes: 10_000)
        try fx.file("root/private/b", bytes: 10_000)
        let usage = DiskScanner(skipping: [fx.url("root/private")]).usage(of: fx.url("root"))
        #expect(usage.files == 1)
        #expect(usage.unreadable == 1)
    }

    @Test func survivesLargeDirectories() throws {
        // More entries than fit in one getattrlistbulk buffer.
        let fx = try Fixture()
        try fx.directory("wide")
        for i in 0..<3_000 {
            FileManager.default.createFile(atPath: fx.url("wide/f\(i)-\(String(repeating: "x", count: 60))").path, contents: Data([1]))
        }
        #expect(DiskScanner().usage(of: fx.url("wide")).files == 3_000)
    }
}
