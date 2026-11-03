// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct RuleTests {
    static func rule(_ paths: [String], id: String = "test.rule", title: String = "Test files",
                     explanation: String = "Files for testing.") -> Rule {
        Rule(id: id, title: title, explanation: explanation, category: .appFiles, safety: .safe, regrows: .onNextUse, paths: paths)
    }

    @Test func bundledRulesAreValid() throws {
        let dir = try #require(RuleLoader.bundledRulesDirectory())
        let rules = try RuleLoader.load(directory: dir)
        #expect(rules.count >= 10)
    }

    @Test(arguments: [
        "/Library/Caches/*",              // outside home
        "~/Library/../Documents/*",       // escapes with ..
        "~/*/Caches",                     // wildcard first folder
        "~/Downloads",                    // a whole home folder
        "~/Documents/old/*",              // protected
        "~/Library/Keychains/*",          // protected
        "~/Library/Caches/**",            // unsupported
    ])
    func rejectsUnsafePatterns(_ pattern: String) {
        #expect(!RuleLoader.validate(Self.rule([pattern])).isEmpty)
    }

    @Test func acceptsANormalPattern() {
        #expect(RuleLoader.validate(Self.rule(["~/Library/Caches/*"])).isEmpty)
    }

    @Test func rejectsBadIDsAndWordyText() {
        #expect(!RuleLoader.validate(Self.rule(["~/Library/Caches/*"], id: "NoDots")).isEmpty)
        #expect(!RuleLoader.validate(Self.rule(["~/Library/Caches/*"], title: String(repeating: "a", count: 41))).isEmpty)
        #expect(!RuleLoader.validate(Self.rule(["~/Library/Caches/*"], explanation: "")).isEmpty)
    }

    @Test func loaderReportsDuplicateIDsAndBadFiles() throws {
        let fx = try Fixture()
        let one = #"{"schemaVersion":1,"rules":[{"id":"a.b","title":"T","explanation":"E","category":"logs","safety":"safe","regrows":"never","paths":["~/Library/Logs/*"]}]}"#
        try Data(one.utf8).write(to: fx.url("one.json"))
        try Data(one.utf8).write(to: fx.url("two.json"))
        try Data(#"{"schemaVersion":1,"rules":[{"id":"x.y"}]}"#.utf8).write(to: fx.url("three.json"))
        #expect {
            try RuleLoader.load(directory: fx.home)
        } throws: { error in
            let problems = (error as? RuleValidationError)?.problems ?? []
            return problems.contains { $0.message.contains("more than one rule") } && problems.contains { $0.file == "three.json" }
        }
    }
}
