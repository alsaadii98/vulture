// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import VultureCore

@Suite struct HistoryTests {
    func report(_ day: Int, apps: Int64, coding: Int64, free: Int64) -> StorageReport {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400)
        return StorageReport(categories: [.init(kind: .apps, bytes: apps), .init(kind: .coding, bytes: coding)],
                             totalBytes: 1_000, freeBytes: free, unreadable: 0, measuredAt: date)
    }

    @Test func explainsWhatChangedThisWeek() throws {
        let fx = try Fixture()
        let history = SpaceHistory(url: fx.url("history.json"))
        try history.record(report(0, apps: 100, coding: 50, free: 500))
        try history.record(report(3, apps: 100, coding: 80, free: 470))
        try history.record(report(8, apps: 110, coding: 190, free: 350))
        let result = try #require(history.changes(overDays: 7))
        #expect(result.freeDelta == -150)
        #expect(result.changes.map(\.kind) == [.coding, .apps])
        #expect(result.changes.first?.delta == 140)
    }

    @Test func keepsOneSnapshotPerDay() throws {
        let fx = try Fixture()
        let history = SpaceHistory(url: fx.url("history.json"))
        try history.record(report(0, apps: 100, coding: 0, free: 500))
        try history.record(report(0, apps: 120, coding: 0, free: 480))
        #expect(history.snapshots().count == 1)
        #expect(history.snapshots().first?.bytes(.apps) == 120)
        #expect(history.changes(overDays: 7) == nil)
    }
}

@Suite struct RegrowthTests {
    let big: Int64 = 200_000_000

    func plan(_ path: String, bytes: Int64) -> CleanupPlan {
        var u = DiskUsage()
        u.bytes = bytes
        let rule = RuleTests.rule(["~/Library/Caches/*"])
        return CleanupPlan(groups: [.init(rule: rule, findings: [Finding(ruleID: rule.id, path: path, usage: u, status: .recommended)])],
                           startedAt: Date(), duration: 0)
    }

    @Test func noticesCachesThatFillUpQuickly() throws {
        let fx = try Fixture()
        let tracker = RegrowthTracker(url: fx.url("regrowth.json"))
        let cleaned = Date(timeIntervalSince1970: 1_790_000_000)
        try tracker.noteCleaned(["/c/chrome": big, "/c/slow": big], at: cleaned)
        let next = cleaned.addingTimeInterval(86_400)
        try tracker.observe(plan("/c/chrome", bytes: big * 8 / 10), now: next)
        #expect(tracker.quicklyRefilling(now: next) == ["/c/chrome"])
    }

    @Test func ignoresChecksTooSoonOrTooLate() throws {
        let fx = try Fixture()
        let tracker = RegrowthTracker(url: fx.url("regrowth.json"))
        let cleaned = Date(timeIntervalSince1970: 1_790_000_000)
        try tracker.noteCleaned(["/c/a": big], at: cleaned)
        try tracker.observe(plan("/c/a", bytes: big), now: cleaned.addingTimeInterval(3600))        // too soon to judge
        try tracker.observe(plan("/c/a", bytes: big), now: cleaned.addingTimeInterval(5 * 86_400))  // too late to say "quickly"
        #expect(tracker.quicklyRefilling(now: cleaned.addingTimeInterval(5 * 86_400)).isEmpty)
    }

    @Test func plannerStopsRecommendingQuickRefills() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.google.Chrome/blob")
        try fx.file("Library/Caches/com.example.App/blob")
        let chrome = fx.url("Library/Caches/com.google.Chrome").standardizedFileURL.path
        let plan = CleanupPlanner(rules: [RuleTests.rule(["~/Library/Caches/*"])], policy: SafetyPolicy(home: fx.home),
                                  runningApps: [], quicklyRefilling: [chrome]).plan()
        let byPath = Dictionary(uniqueKeysWithValues: plan.groups.flatMap(\.findings).map { ($0.path, $0) })
        #expect(byPath[chrome]?.status == .youDecide)
        #expect(byPath[chrome]?.fillsQuickly == true)
        #expect(plan.defaultSelection.count == 1)
    }
}

@Suite struct RulePackTests {
    func packDirectory(_ fx: Fixture, title: String = "Test files") throws -> URL {
        let rule = RuleTests.rule(["~/Library/Caches/*"], id: "test.pack", title: title)
        let data = try JSONEncoder().encode(RuleFile(schemaVersion: 1, rules: [rule]))
        try fx.directory("rules")
        try data.write(to: fx.url("rules/test.json"))
        return fx.url("rules")
    }

    @Test func acceptsAPackSignedWithATrustedKey() throws {
        let fx = try Fixture()
        let key = RuleUpdates.makeKey()
        let pack = try RuleUpdates.pack(directory: packDirectory(fx), version: "2099.01.01", privateKey: key.privateKey)
        let (version, rules) = try RuleUpdates.verify(pack, trusted: [key.publicKey])
        #expect(version == "2099.01.01")
        #expect(rules.map(\.id) == ["test.pack"])

        #expect(try RuleUpdates.install(pack, home: fx.home, trusted: [key.publicKey]) == "2099.01.01")
        #expect(RuleUpdates.activeRules(home: fx.home, bundled: [], trusted: [key.publicKey]).rules.map(\.id) == ["test.pack"])
    }

    @Test func refusesTamperedUntrustedOldOrUnsignedPacks() throws {
        let fx = try Fixture()
        let key = RuleUpdates.makeKey(), stranger = RuleUpdates.makeKey()
        let pack = try RuleUpdates.pack(directory: packDirectory(fx), version: "2099.01.01", privateKey: key.privateKey)

        #expect(throws: RuleUpdates.Problem.noTrustedKeys) { try RuleUpdates.verify(pack, trusted: []) }
        #expect(throws: RuleUpdates.Problem.untrustedKey(key.keyID)) { try RuleUpdates.verify(pack, trusted: [stranger.publicKey]) }

        // Change one rule's path inside the signed payload.
        var envelope = try JSONSerialization.jsonObject(with: pack) as! [String: String]
        var payload = String(decoding: Data(base64Encoded: envelope["payload"]!)!, as: UTF8.self)
        payload = payload.replacingOccurrences(of: "Library\\/Caches", with: "Documents")
        envelope["payload"] = Data(payload.utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: RuleUpdates.Problem.badSignature) { try RuleUpdates.verify(tampered, trusted: [key.publicKey]) }

        let old = try RuleUpdates.pack(directory: packDirectory(fx), version: "2020.01.01", privateKey: key.privateKey)
        #expect(throws: RuleUpdates.Problem.notNewer("2020.01.01")) { try RuleUpdates.install(old, home: fx.home, trusted: [key.publicKey]) }
        #expect(throws: RuleUpdates.Problem.notAPack) { try RuleUpdates.verify(Data("{}".utf8), trusted: [key.publicKey]) }
    }

    @Test func signedPacksStillHaveToPassTheRuleChecks() throws {
        let fx = try Fixture()
        let key = Curve25519.Signing.PrivateKey()
        // Hand-build a validly signed payload whose rule points into Documents.
        var rule = RuleTests.rule(["~/Library/Caches/*"], id: "test.evil")
        rule.paths = ["~/Documents/*"]
        let contents = RuleUpdates.Contents(schemaVersion: 1, version: "2099.01.01", files: ["evil.json": RuleFile(schemaVersion: 1, rules: [rule])])
        let payload = try JSONEncoder().encode(contents)
        let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString(),
                        "keyID": RuleUpdates.keyID(key.publicKey)]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        #expect {
            try RuleUpdates.verify(data, trusted: [key.publicKey.rawRepresentation.base64EncodedString()])
        } throws: { error in
            if case .invalidRules = error as? RuleUpdates.Problem { return true }
            return false
        }
    }

    @Test func comparesVersions() {
        #expect(RuleUpdates.isNewer("2026.11.10", than: "2026.11.03"))
        #expect(RuleUpdates.isNewer("2026.11.03.2", than: "2026.11.03"))
        #expect(!RuleUpdates.isNewer("2026.11.03", than: "2026.11.03"))
        #expect(!RuleUpdates.isNewer("2025.12.31", than: "2026.01.01"))
    }
}
