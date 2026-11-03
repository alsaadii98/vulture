// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One item a rule matched, measured, with the decision Vulture made about it.
public struct Finding: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Selected by default: safe, apps make it again.
        case recommended
        /// Offered but not selected: the person decides.
        case youDecide
        /// Shown so the person knows it exists, but not offered.
        case skipped
    }

    public var ruleID: String
    public var path: String
    public var usage: DiskUsage
    public var status: Status
    public var skipReason: SkipReason?
    /// For `.appRunning`, the app that has to be closed first.
    public var blockingApp: String?
    /// The item's identity when it was measured, so a clean-up can tell if something else took its place since.
    public var fileID: UInt64?
}

/// Everything a scan found, grouped by rule. Nothing is removed while planning.
public struct CleanupPlan: Codable, Sendable {
    public struct Group: Codable, Sendable {
        public var rule: Rule
        public var findings: [Finding]
        public var bytes: Int64 { findings.filter { $0.status != .skipped }.reduce(0) { $0 + $1.usage.bytes } }

        public init(rule: Rule, findings: [Finding]) {
            self.rule = rule
            self.findings = findings
        }
    }

    public init(groups: [Group], startedAt: Date, duration: TimeInterval) {
        self.groups = groups
        self.startedAt = startedAt
        self.duration = duration
    }

    public var groups: [Group]
    public var startedAt: Date
    public var duration: TimeInterval

    public func bytes(_ status: Finding.Status) -> Int64 {
        groups.flatMap(\.findings).filter { $0.status == status }.reduce(0) { $0 + $1.usage.bytes }
    }

    public var unreadable: Int { groups.flatMap(\.findings).reduce(0) { $0 + $1.usage.unreadable } }

    /// What's selected before the person changes anything: only the recommended items.
    public var defaultSelection: Set<String> {
        Set(groups.flatMap(\.findings).filter { $0.status == .recommended }.map(\.path))
    }
}

public struct CleanupPlanner: Sendable {
    public let rules: [Rule]
    public let policy: SafetyPolicy
    /// Bundle identifiers of the apps open right now.
    public let runningApps: Set<String>
    public let now: Date

    public init(rules: [Rule], policy: SafetyPolicy, runningApps: Set<String>, now: Date = Date()) {
        self.rules = rules
        self.policy = policy
        self.runningApps = runningApps
        self.now = now
    }

    public func plan(scanner: DiskScanner = DiskScanner()) -> CleanupPlan {
        let started = Date()
        // Specific rules go first and claim what they match, so a broad rule never reports the same files twice.
        let ordered = rules.enumerated().sorted { ($0.element.priority, -$0.offset) > ($1.element.priority, -$1.offset) }.map(\.element)
        var claimed: [String] = []
        var groups: [CleanupPlan.Group] = []

        for rule in ordered {
            var candidates: [URL] = []
            for pattern in rule.paths {
                for url in Glob.expand(pattern, home: policy.home) {
                    let path = url.standardizedFileURL.path
                    if rule.exclude.contains(where: { Glob.matches($0, url.lastPathComponent) }) { continue }
                    if claimed.contains(where: { overlaps(path, $0) }) { continue }
                    if candidates.contains(url) { continue }
                    candidates.append(url)
                }
            }
            claimed += candidates.map { $0.standardizedFileURL.path }

            var findings: [Finding] = []
            for url in candidates {
                if let finding = evaluate(url, rule: rule, scanner: scanner) { findings.append(finding) }
            }
            if !findings.isEmpty {
                findings.sort { $0.usage.bytes > $1.usage.bytes }
                groups.append(.init(rule: rule, findings: findings))
            }
        }
        // Back in the order the rules were written, which is how they read best.
        let order = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        groups.sort { order[$0.rule.id, default: 0] < order[$1.rule.id, default: 0] }
        return CleanupPlan(groups: groups, startedAt: started, duration: Date().timeIntervalSince(started))
    }

    private func evaluate(_ url: URL, rule: Rule, scanner: DiskScanner) -> Finding? {
        let path = url.standardizedFileURL.path
        if let reason = policy.check(url) {
            // Protected places aren't measured or listed; people only need to hear about things they could act on.
            return reason == .protected ? nil : Finding(ruleID: rule.id, path: path, usage: DiskUsage(), status: .skipped, skipReason: reason)
        }
        var st = stat()
        let fileID = lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
        let usage = scanner.usage(of: url)
        guard usage.bytes > 0 else { return nil }
        if rule.minAgeDays > 0, let newest = usage.newest, now.timeIntervalSince(newest) < Double(rule.minAgeDays) * 86_400 {
            return nil
        }
        let blocker = rule.closeFirst.first { runningApps.contains($0) }
            ?? (rule.entryNameIsBundleID && runningApps.contains(url.lastPathComponent) ? url.lastPathComponent : nil)
        if let blocker {
            return Finding(ruleID: rule.id, path: path, usage: usage, status: .skipped, skipReason: .appRunning, blockingApp: blocker, fileID: fileID)
        }
        return Finding(ruleID: rule.id, path: path, usage: usage, status: rule.safety == .safe ? .recommended : .youDecide, fileID: fileID)
    }

    private func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}
