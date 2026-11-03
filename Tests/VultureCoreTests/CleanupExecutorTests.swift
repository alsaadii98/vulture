// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct CleanupExecutorTests {
    let fx: Fixture
    let store: RecentlyRemoved
    let policy: SafetyPolicy

    init() throws {
        fx = try Fixture()
        store = RecentlyRemoved(root: fx.url("Library/Application Support/Vulture/Recently Removed"))
        policy = SafetyPolicy(home: fx.home)
    }

    var cacheRule: Rule { RuleTests.rule(["~/Library/Caches/*"], id: "test.caches") }
    var installerRule: Rule {
        var r = RuleTests.rule(["~/Downloads/*.dmg"], id: "test.installers")
        r.regrows = .never
        r.safety = .review
        return r
    }

    func executor(running: Set<String> = []) -> CleanupExecutor {
        CleanupExecutor(policy: policy, store: store, runningApps: { running })
    }

    func plan(_ rules: [Rule]) -> CleanupPlan {
        CleanupPlanner(rules: rules, policy: policy, runningApps: []).plan()
    }

    func everything(_ plan: CleanupPlan) -> Set<String> {
        Set(plan.groups.flatMap(\.findings).map(\.path))
    }

    @Test func deletesWhatAppsMakeAgainAndKeepsTheRest() throws {
        try fx.file("Library/Caches/com.example.App/blob", bytes: 50_000)
        try fx.file("Downloads/Setup.dmg", bytes: 80_000)
        let p = plan([cacheRule, installerRule])
        let result = executor().run(p, selected: everything(p))

        #expect(result.failures.isEmpty)
        #expect(result.freedBytes > 0 && result.keptBytes > 0)
        #expect(!Glob.exists(fx.url("Library/Caches/com.example.App")))
        #expect(!Glob.exists(fx.url("Downloads/Setup.dmg")))

        let batch = try store.batch(try #require(result.batchID))
        #expect(batch.items.map(\.originalPath) == [fx.url("Downloads/Setup.dmg").standardizedFileURL.path])
    }

    @Test func onlyTouchesWhatWasSelected() throws {
        try fx.file("Library/Caches/com.example.A/x")
        try fx.file("Library/Caches/com.example.B/x")
        let p = plan([cacheRule])
        let a = fx.url("Library/Caches/com.example.A").standardizedFileURL.path
        _ = executor().run(p, selected: [a])
        #expect(!Glob.exists(fx.url("Library/Caches/com.example.A")))
        #expect(Glob.exists(fx.url("Library/Caches/com.example.B")))
    }

    @Test func putBackRestoresExactlyWhereItWas() throws {
        let original = try fx.file("Downloads/Setup.dmg", bytes: 30_000)
        let before = try Data(contentsOf: original)
        let p = plan([installerRule])
        let result = executor().run(p, selected: everything(p))
        let failures = try store.putBack(batchID: try #require(result.batchID))
        #expect(failures.isEmpty)
        #expect(try Data(contentsOf: original) == before)
        #expect(store.batches().isEmpty)
    }

    @Test func putBackNeverOverwritesSomethingNew() throws {
        try fx.file("Downloads/Setup.dmg", bytes: 30_000)
        let p = plan([installerRule])
        let id = try #require(executor().run(p, selected: everything(p)).batchID)
        try fx.file("Downloads/Setup.dmg", bytes: 7)  // a new download with the same name
        let failures = try store.putBack(batchID: id)
        #expect(failures.count == 1)
        #expect(try Data(contentsOf: fx.url("Downloads/Setup.dmg")).count == 7)
        #expect(try store.batch(id).items.count == 1)  // still kept, nothing lost
    }

    @Test func checksAgainRightBeforeCleaning() throws {
        try fx.file("Library/Caches/com.example.Swapped/x")
        try fx.file("Library/Caches/com.example.Opened/x")
        var rule = cacheRule
        rule.entryNameIsBundleID = true
        let p = plan([rule])

        // Between the scan and the clean-up, one folder is replaced by a link to Documents
        // and the other's app is opened.
        try fx.file("Documents/keep.txt")
        try FileManager.default.removeItem(at: fx.url("Library/Caches/com.example.Swapped"))
        try fx.link("Library/Caches/com.example.Swapped", to: fx.url("Documents").path)

        let result = executor(running: ["com.example.Opened"]).run(p, selected: everything(p))
        #expect(result.failures.count == 2)
        #expect(Glob.exists(fx.url("Documents/keep.txt")))
        #expect(Glob.exists(fx.url("Library/Caches/com.example.Opened/x")))
    }

    @Test func emptyingRemovesOnlyExpiredCleanUps() throws {
        try fx.file("Downloads/Old.dmg")
        try fx.file("Downloads/New.dmg")
        let old = Date().addingTimeInterval(-31 * 86_400)
        var oldBatch = try store.begin(title: "Old", at: old)
        try store.keep(fx.url("Downloads/Old.dmg"), ruleID: nil, usage: DiskUsage(), in: &oldBatch)
        var newBatch = try store.begin(title: "New")
        try store.keep(fx.url("Downloads/New.dmg"), ruleID: nil, usage: DiskUsage(), in: &newBatch)

        try store.empty()
        #expect(store.batches().map(\.title) == ["New"])
    }

    @Test func recentlyRemovedIsNeverOfferedForCleaning() throws {
        var batch = try store.begin(title: "Kept")
        try store.keep(try fx.file("Downloads/a.dmg"), ruleID: nil, usage: DiskUsage(), in: &batch)
        let broad = RuleTests.rule(["~/Library/Application Support/*"], id: "test.broad")
        #expect(plan([broad]).groups.isEmpty)
    }
}
