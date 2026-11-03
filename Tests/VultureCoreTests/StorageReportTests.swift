// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct StorageReportTests {
    @Test func sortsHomeIntoPlainCategories() throws {
        let fx = try Fixture()
        try fx.file("Documents/report.pages", bytes: 100_000)
        try fx.file("Library/Mobile Documents/com~apple~CloudDocs/notes.txt", bytes: 50_000)
        try fx.file("Pictures/holiday.heic", bytes: 200_000)
        try fx.file("Library/Developer/Xcode/DerivedData/x", bytes: 300_000)
        try fx.file(".npm/_cacache/y", bytes: 40_000)
        try fx.file("Library/Caches/com.example/z", bytes: 60_000)
        try fx.file("random/thing", bytes: 10_000)
        let apps = try Fixture()  // /Applications lives outside the home folder
        try apps.file("Example.app/Contents/MacOS/Example", bytes: 500_000)

        let report = StorageAnalyzer.analyze(home: fx.home, applications: [apps.home], scanner: DiskScanner())
        func approx(_ kind: StorageReport.Kind, _ expected: Int64) -> Bool {
            let b = report.bytes(kind)
            return b >= expected && b < expected + 40_000
        }
        #expect(approx(.documents, 150_000))
        #expect(approx(.media, 200_000))
        #expect(approx(.coding, 340_000))
        #expect(approx(.appData, 60_000))
        #expect(approx(.otherFiles, 10_000))
        #expect(approx(.apps, 500_000))
        #expect(report.categories.reduce(0) { $0 + $1.bytes } <= report.usedBytes)
    }
}
