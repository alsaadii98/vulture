// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct UpdaterTests {
    @Test func comparesAppVersions() {
        #expect(Updater.isNewer("0.10.0", than: "0.9.2"))
        #expect(Updater.isNewer("1.0", than: "0.99.99"))
        #expect(Updater.isNewer("0.4.1", than: "0.4.0-dev"))
        #expect(!Updater.isNewer("0.4.0", than: "0.4.0"))
        #expect(!Updater.isNewer("0.4.0-dev", than: "0.4.0"))
    }

    @Test func findsTheAppAroundTheAppAndTheCommand() {
        #expect(Updater.app(containing: URL(fileURLWithPath: "/Applications/Vulture.app/Contents/MacOS/Vulture"))?.path == "/Applications/Vulture.app")
        #expect(Updater.app(containing: URL(fileURLWithPath: "/Applications/Vulture.app/Contents/Helpers/vulture"))?.path == "/Applications/Vulture.app")
        #expect(Updater.app(containing: URL(fileURLWithPath: "/usr/local/bin/vulture")) == nil)
    }

    @Test func refusesFeedsAndDownloadsThatDontAddUp() async throws {
        let fx = try Fixture()
        let zip = fx.url("Vulture.zip")
        try Data("not really a zip".utf8).write(to: zip)
        let info = UpdateInfo(version: "9.0.0", url: zip, sha256: String(repeating: "0", count: 64), size: 16, minimumSystemVersion: "14.0")
        let feed = fx.url("update.json")
        try JSONEncoder().encode(info).write(to: feed)
        #expect(try await Updater.check(current: "9.0.0", feed: feed) == nil)
        #expect(try await Updater.check(current: "1.0.0", feed: feed) == info)

        try Data("{}".utf8).write(to: feed)
        await #expect(throws: Updater.Problem.badFeed) { try await Updater.check(current: "1.0.0", feed: feed) }

        var tooNew = info
        tooNew.minimumSystemVersion = "99.0"
        try JSONEncoder().encode(tooNew).write(to: feed)
        await #expect(throws: Updater.Problem.needsNewerMacOS("99.0")) { try await Updater.check(current: "1.0.0", feed: feed) }
    }

    @Test func adHocCopiesDontUpdate() throws {
        // Test runners and development builds are signed ad hoc, so they only match their own exact code.
        let fx = try Fixture()
        try fx.directory("Fake.app/Contents")
        #expect(throws: Updater.Problem.notUpdatable) { try Updater.trustedRequirement(for: fx.url("Fake.app")) }
    }
}
