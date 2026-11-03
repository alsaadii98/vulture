// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Remover {
    /// Deletes `url` and everything inside it. Links inside are removed as links; what they point to is untouched.
    public static func removeForGood(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct CleanupResult: Codable, Sendable {
    public struct Failure: Codable, Sendable {
        public var path: String
        public var reason: String
    }

    /// Space freed right away: files apps make again were deleted.
    public var freedBytes: Int64 = 0
    /// Space held in Recently Removed: files that can't come back, kept for put back.
    public var keptBytes: Int64 = 0
    public var batchID: String?
    public var failures: [Failure] = []
    /// What was removed for good, by path, so Vulture can later see whether it filled up again.
    public var removedForGood: [String: Int64] = [:]

    public init() {}
}

/// Carries out a clean-up the person reviewed. Everything is checked again right before it's touched,
/// because minutes may have passed since the scan.
///
/// Files apps make again (the rule's `regrows` isn't `never`) are deleted, so the space comes back now.
/// Files that can't come back go to Recently Removed and can be put back for 30 days.
public struct CleanupExecutor: Sendable {
    public let policy: SafetyPolicy
    public let store: RecentlyRemoved
    /// Asked again at the moment of cleaning, not reused from the scan.
    public let runningApps: @Sendable () -> Set<String>
    /// Files any process has open, also asked at the moment of cleaning.
    public let openFiles: @Sendable () -> OpenFiles

    public init(policy: SafetyPolicy, store: RecentlyRemoved, runningApps: @escaping @Sendable () -> Set<String>,
                openFiles: @escaping @Sendable () -> OpenFiles = { OpenFiles.snapshot() }) {
        self.policy = policy
        self.store = store
        self.runningApps = runningApps
        self.openFiles = openFiles
    }

    public func run(_ plan: CleanupPlan, selected: Set<String>, title: String = "Clean-up", now: Date = Date()) -> CleanupResult {
        var result = CleanupResult()
        let running = runningApps()
        let open = openFiles()
        var batch: RemovedBatch?

        for group in plan.groups {
            for finding in group.findings where selected.contains(finding.path) {
                let url = URL(fileURLWithPath: finding.path)
                if let reason = problem(with: finding, rule: group.rule, running: running, open: open) {
                    result.failures.append(.init(path: finding.path, reason: reason))
                    continue
                }
                do {
                    if group.rule.regrows == .never {
                        if batch == nil { batch = try store.begin(title: title, at: now) }
                        try store.keep(url, ruleID: group.rule.id, usage: finding.usage, in: &batch!)
                        result.keptBytes += finding.usage.bytes
                    } else {
                        try Remover.removeForGood(url)
                        result.freedBytes += finding.usage.bytes
                        result.removedForGood[finding.path] = finding.usage.bytes
                    }
                } catch {
                    result.failures.append(.init(path: finding.path, reason: "\(error)"))
                }
            }
        }
        result.batchID = batch?.id
        return result
    }

    private func problem(with finding: Finding, rule: Rule, running: Set<String>, open: OpenFiles) -> String? {
        if finding.status == .skipped { return "it was left alone in the scan" }
        let url = URL(fileURLWithPath: finding.path)
        if let reason = policy.check(url) { return "safety check: \(reason.rawValue)" }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "it's gone already" }
        if let id = finding.fileID, UInt64(st.st_ino) != id { return "it changed since the scan" }
        if let app = rule.closeFirst.first(where: running.contains) { return "\(app) is open" }
        if rule.entryNameIsBundleID, running.contains(url.lastPathComponent) { return "\(url.lastPathComponent) is open" }
        if open.firstOpen(inside: realPath(url.path) ?? url.path) != nil { return "an app is using a file inside it" }
        return nil
    }
}
