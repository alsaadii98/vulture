// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct CleanupPlannerTests {
    func plan(_ fx: Fixture, _ rules: [Rule], running: Set<String> = []) -> CleanupPlan {
        CleanupPlanner(rules: rules, policy: SafetyPolicy(home: fx.home), runningApps: running).plan()
    }

    func findings(_ plan: CleanupPlan) -> [String: Finding] {
        Dictionary(uniqueKeysWithValues: plan.groups.flatMap(\.findings).map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
    }

    @Test func offersMatchesWithTheRulesSafety() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.App/data")
        var review = RuleTests.rule(["~/Downloads/*.dmg"], id: "test.installers")
        review.safety = .review
        try fx.file("Downloads/Setup.dmg")
        let found = findings(plan(fx, [RuleTests.rule(["~/Library/Caches/*"]), review]))
        #expect(found["com.example.App"]?.status == .recommended)
        #expect(found["Setup.dmg"]?.status == .youDecide)
    }

    @Test func skipsItemsChangedRecently() throws {
        let fx = try Fixture()
        try fx.file("Library/Logs/Old/a.log", daysOld: 30)
        try fx.age("Library/Logs/Old", days: 30)
        try fx.file("Library/Logs/Mixed/a.log", daysOld: 30)
        try fx.file("Library/Logs/Mixed/b.log", daysOld: 1)
        var rule = RuleTests.rule(["~/Library/Logs/*"])
        rule.minAgeDays = 14
        let found = findings(plan(fx, [rule]))
        #expect(found["Old"] != nil)
        #expect(found["Mixed"] == nil)
    }

    @Test func leavesFilesOfRunningAppsAlone() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.Open/data")
        try fx.file("Library/Caches/com.example.Closed/data")
        var rule = RuleTests.rule(["~/Library/Caches/*"])
        rule.entryNameIsBundleID = true
        let found = findings(plan(fx, [rule], running: ["com.example.Open"]))
        #expect(found["com.example.Open"]?.status == .skipped)
        #expect(found["com.example.Open"]?.skipReason == .appRunning)
        #expect(found["com.example.Closed"]?.status == .recommended)

        var xcode = RuleTests.rule(["~/Library/Developer/Xcode/DerivedData/*"], id: "test.xcode")
        xcode.closeFirst = ["com.apple.dt.Xcode"]
        try fx.file("Library/Developer/Xcode/DerivedData/App-abc/x")
        #expect(findings(plan(fx, [xcode], running: ["com.apple.dt.Xcode"]))["App-abc"]?.blockingApp == "com.apple.dt.Xcode")
    }

    @Test func neverOffersLinksOrWhatTheyPointTo() throws {
        let fx = try Fixture()
        try fx.file("Documents/thesis.pages")
        try fx.link("Library/Caches/sneaky", to: fx.url("Documents").path)
        let found = findings(plan(fx, [RuleTests.rule(["~/Library/Caches/*"])]))
        #expect(found["sneaky"]?.status == .skipped)
        #expect(found["sneaky"]?.skipReason == .symbolicLink)
        #expect(found["sneaky"]?.usage.bytes == 0)
    }

    @Test func neverOffersProtectedPlaces() throws {
        let fx = try Fixture()
        try fx.file("Library/Mobile Documents/com~apple~CloudDocs/notes.txt")
        try fx.file("Library/Messages/chat.db")
        let found = findings(plan(fx, [RuleTests.rule(["~/Library/*"])]))
        #expect(found["Mobile Documents"] == nil)
        #expect(found["Messages"] == nil)
    }

    @Test func specificRulesClaimFilesBeforeBroadOnes() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/Homebrew/downloads/x.tar.gz")
        try fx.file("Library/Caches/com.example.App/data")
        var broad = RuleTests.rule(["~/Library/Caches/*"], id: "test.broad")
        broad.priority = -10
        let specific = RuleTests.rule(["~/Library/Caches/Homebrew/*"], id: "test.homebrew")
        let result = plan(fx, [broad, specific])
        let byRule = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.rule.id, $0.findings.map { URL(fileURLWithPath: $0.path).lastPathComponent }) })
        #expect(byRule["test.homebrew"] == ["downloads"])
        #expect(byRule["test.broad"] == ["com.example.App"])
    }

    @Test func excludesNamedItems() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.apple.Safari/data")
        try fx.file("Library/Caches/com.example.App/data")
        var rule = RuleTests.rule(["~/Library/Caches/*"])
        rule.exclude = ["com.apple.*"]
        let found = findings(plan(fx, [rule]))
        #expect(found["com.apple.Safari"] == nil)
        #expect(found["com.example.App"] != nil)
    }

    @Test func emptyFoldersAreNotReported() throws {
        let fx = try Fixture()
        try fx.directory("Library/Caches/com.example.Empty")
        #expect(plan(fx, [RuleTests.rule(["~/Library/Caches/*"])]).groups.isEmpty)
    }
}
