// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct SettingsTests {
    func store(_ fx: Fixture, keepDays: Int = 30) -> RecentlyRemoved {
        RecentlyRemoved(root: fx.url("Library/Application Support/Vulture/Recently Removed"), keepDays: keepDays)
    }

    func removed(_ fx: Fixture, _ store: RecentlyRemoved, _ name: String, at date: Date) throws {
        try fx.file("Downloads/\(name)")
        var batch = try store.begin(title: name, at: date)
        var usage = DiskUsage()
        usage.bytes = 10
        try store.keep(fx.url("Downloads/\(name)"), ruleID: nil, usage: usage, in: &batch)
    }

    @Test func keepsRemovedItemsForTheChosenNumberOfDays() throws {
        let fx = try Fixture()
        let week = store(fx, keepDays: 7)
        try removed(fx, week, "a.dmg", at: Date().addingTimeInterval(-10 * 86_400))
        try removed(fx, week, "b.dmg", at: Date().addingTimeInterval(-3 * 86_400))
        try week.empty()
        #expect(week.batches().map(\.title) == ["b.dmg"])
        #expect(RecentlyRemoved.standard(home: fx.home, keepDays: 60).keepDays == 60)
    }

    @Test func emptiesOldestFirstOnlyWhileSpaceIsNeeded() throws {
        let fx = try Fixture()
        let s = store(fx)
        try removed(fx, s, "old.dmg", at: Date().addingTimeInterval(-5 * 86_400))
        try removed(fx, s, "mid.dmg", at: Date().addingTimeInterval(-3 * 86_400))
        try removed(fx, s, "new.dmg", at: Date().addingTimeInterval(-1 * 86_400))
        var rounds = 0
        try s.emptyOldest { rounds += 1; return rounds <= 2 }
        #expect(s.batches().map(\.title) == ["new.dmg"])
    }

    @Test func foldersThePersonProtectsAreNeverOffered() throws {
        let fx = try Fixture()
        try fx.file("Projects/app/node_modules/x/index.js")
        try fx.file("Library/Caches/com.example.App/data")
        let policy = SafetyPolicy(home: fx.home, alsoProtecting: [fx.url("Projects"), URL(fileURLWithPath: "/tmp/elsewhere")])
        #expect(policy.check(fx.url("Projects/app/node_modules")) == .protected)
        #expect(policy.check(fx.url("Library/Caches/com.example.App")) == nil)
        let plan = CleanupPlanner(rules: [RuleTests.rule(["~/Projects/*/node_modules"])], policy: policy, runningApps: []).plan()
        #expect(plan.groups.isEmpty)
    }

    @Test func recentlyUsedThingsThatCantComeBackWaitForAChoice() throws {
        let fx = try Fixture()
        try fx.file("Downloads/Fresh.dmg", daysOld: 1)
        try fx.file("Downloads/Old.dmg", daysOld: 30)
        try fx.file("Library/Caches/com.example.App/data", daysOld: 0)
        var installers = RuleTests.rule(["~/Downloads/*.dmg"], id: "test.installers")
        installers.regrows = .never
        let rules = [installers, RuleTests.rule(["~/Library/Caches/*"])]
        let plan = CleanupPlanner(rules: rules, policy: SafetyPolicy(home: fx.home), runningApps: [], recentlyUsedDays: 7).plan()
        let status = Dictionary(uniqueKeysWithValues: plan.groups.flatMap(\.findings).map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.status) })
        #expect(status["Fresh.dmg"] == .youDecide)
        #expect(status["Old.dmg"] == .recommended)
        #expect(status["com.example.App"] == .recommended) // caches come back, so recent use doesn't matter
    }
}
