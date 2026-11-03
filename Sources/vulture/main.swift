// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import VultureCore

let version = "0.1.0-dev"

let usage = """
    vulture \(version): see what's filling up your Mac, and free up space without the worry.

    Usage:
      vulture scan [--json] [--rules DIR]     Find files that can be cleaned up, and explain each one
      vulture clean [--include RULE]... [--yes] [--json]
                                              Clean up the recommended items (add "you decide" rules with --include)
      vulture removed [--json]                List what's in Recently Removed
      vulture restore ID [--yes]              Put back everything from one clean-up
      vulture empty [--all] [--yes]           Remove expired clean-ups for good (--all: everything)
      vulture storage [--json]                What's using space on this Mac, by kind
      vulture size [PATH] [--json] [--top N]  Measure a folder (default: your home folder)
      vulture rules [--json] [--rules DIR]    List the cleaning rules
      vulture check-rules DIR                 Check rule files for mistakes (for contributors)
      vulture --version

    """

struct UsageError: Error { let message: String }

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

func option(_ name: String) throws -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { throw UsageError(message: "\(name) needs a value") }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

func loadRules() throws -> [Rule] {
    if let dir = try option("--rules") {
        return try RuleLoader.load(directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
    }
    guard let dir = RuleLoader.bundledRulesDirectory() else { throw UsageError(message: "the built-in rules are missing from this build") }
    return try RuleLoader.load(directory: dir)
}

func runningBundleIDs() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value))
    print()
}

func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func padded(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func appName(_ bundleID: String) -> String {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
}

// MARK: - Commands

func scan(json: Bool) throws {
    let rules = try loadRules()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let planner = CleanupPlanner(rules: rules, policy: SafetyPolicy(home: home), runningApps: runningBundleIDs())
    let plan = planner.plan(scanner: DiskScanner(skipping: Privacy.foldersToSkip()))
    if json { return try printJSON(plan) }

    let recommended = plan.bytes(.recommended), review = plan.bytes(.youDecide)
    print("Vulture found \(size(recommended + review)) you could free up. Nothing was removed.\n")
    for (status, heading, hint, mark) in [(Finding.Status.recommended, "Recommended", "safe, apps make these again", "✓"),
                                          (.youDecide, "You decide", "have a look first", "○")] {
        let groups = plan.groups.filter { $0.findings.contains { $0.status == status } }
        guard !groups.isEmpty else { continue }
        print("\(padded("\(heading) (\(hint))", 56)) \(size(plan.bytes(status)))")
        for group in groups {
            let items = group.findings.filter { $0.status == status }
            let bytes = items.reduce(0) { $0 + $1.usage.bytes }
            let count = items.count == 1 ? "" : "  (\(items.count) items)"
            print("  \(mark) \(padded(group.rule.title, 52)) \(size(bytes))\(count)")
            print("      \(group.rule.explanation)")
        }
        print()
    }
    let skipped = plan.groups.flatMap { g in g.findings.filter { $0.status == .skipped }.map { (g.rule, $0) } }
    if !skipped.isEmpty {
        print("Left alone for now")
        var shown: Set<String> = []
        for (rule, finding) in skipped {
            let why: String
            switch finding.skipReason {
            case .appRunning: why = "\(appName(finding.blockingApp ?? "")) is open"
            case .symbolicLink: why = "it's a link to somewhere else"
            default: why = "it's outside your home folder"
            }
            let line = "  – \(rule.title): \(why)"
            if finding.skipReason == .appRunning {
                if shown.insert(line).inserted { print(line) }
            } else {
                print("\(line) (\(tilde(finding.path)))")
            }
        }
        print()
    }
    if plan.unreadable > 0 {
        print("Some folders couldn't be read. Give your terminal Full Disk Access in System Settings › Privacy & Security to see everything.")
    }
    print(String(format: "Checked in %.1f seconds.", plan.duration))
}

func sizeCommand(json: Bool) throws {
    let top = try option("--top").map { value -> Int in
        guard let n = Int(value), n > 0 else { throw UsageError(message: "--top needs a positive number") }
        return n
    } ?? 15
    let path = arguments.first.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.homeDirectoryForCurrentUser.path
    let url = URL(fileURLWithPath: path)
    guard isDirectory(url) else { throw UsageError(message: "\(path) isn't a folder") }

    let started = Date()
    let entries = DiskScanner(skipping: Privacy.foldersToSkip()).children(of: url)
    let elapsed = Date().timeIntervalSince(started)
    var total = DiskUsage()
    for e in entries { total.bytes += e.usage.bytes; total.files += e.usage.files; total.unreadable += e.usage.unreadable }

    struct Report: Encodable { let path: String; let total: DiskUsage; let seconds: Double; let children: [DiskEntry] }
    if json { return try printJSON(Report(path: url.path, total: total, seconds: elapsed, children: entries)) }

    print("\(tilde(url.path)): \(size(total.bytes)) in \(total.files.formatted()) files (measured in \(String(format: "%.1f", elapsed)) s)\n")
    for e in entries.prefix(top) {
        let share = total.bytes > 0 ? Double(e.usage.bytes) / Double(total.bytes) : 0
        let bar = String(repeating: "█", count: Int((share * 30).rounded()))
        print("  \(padded(e.name + (e.isDirectory ? "/" : ""), 36)) \(padded(size(e.usage.bytes), 10)) \(bar)")
    }
    if entries.count > top { print("  … and \(entries.count - top) more") }
    if total.unreadable > 0 {
        print("\n\(total.unreadable) folders couldn't be read. Give your terminal Full Disk Access to measure everything.")
    }
}

func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

func storage(json: Bool) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let report = StorageAnalyzer.analyze(home: home, scanner: DiskScanner(skipping: Privacy.foldersToSkip(home: home)))
    if json { return try printJSON(report) }
    let names: [StorageReport.Kind: String] = [
        .apps: "Apps", .documents: "Documents and downloads", .media: "Photos, music and videos", .coding: "Coding apps' files",
        .appData: "App data", .otherFiles: "Other files in your home folder", .system: "macOS and System Data",
    ]
    print("\(size(report.freeBytes)) free of \(size(report.totalBytes))\n")
    for c in report.categories.sorted(by: { $0.bytes > $1.bytes }) where c.bytes > 0 {
        let share = report.usedBytes > 0 ? Int((Double(c.bytes) / Double(report.usedBytes) * 100).rounded()) : 0
        print("  \(padded(names[c.kind] ?? c.kind.rawValue, 34)) \(padded(size(c.bytes), 10)) \(share)%")
    }
    if report.unreadable > 0 {
        print("\n\(report.unreadable) folders couldn't be read; their space is counted under macOS and System Data.")
    }
}

func rulesCommand(json: Bool) throws {
    let rules = try loadRules()
    if json { return try printJSON(rules) }
    for rule in rules {
        let safety = rule.safety == .safe ? "recommended" : "you decide"
        print("\(rule.id)  [\(safety)]\n  \(rule.title): \(rule.explanation)")
        for p in rule.paths { print("    \(p)") }
    }
}

func checkRules() throws {
    guard let dir = arguments.first else { throw UsageError(message: "check-rules needs a folder") }
    let rules = try RuleLoader.load(directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
    print("\(rules.count) rules, no problems found.")
}

func confirm(_ question: String) -> Bool {
    if flag("--yes") { return true }
    print("\(question) Type yes to continue: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

func options(_ name: String) throws -> [String] {
    var values: [String] = []
    while let v = try option(name) { values.append(v) }
    return values
}

func clean(json: Bool) throws {
    let includes = Set(try options("--include"))
    let rules = try loadRules()
    if let unknown = includes.first(where: { id in !rules.contains { $0.id == id } }) {
        throw UsageError(message: "there's no rule called \(unknown); see vulture rules")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let policy = SafetyPolicy(home: home)
    let store = RecentlyRemoved.standard(home: home)
    try store.empty()  // clean-ups past their 30 days go first

    let plan = CleanupPlanner(rules: rules, policy: policy, runningApps: runningBundleIDs())
        .plan(scanner: DiskScanner(skipping: Privacy.foldersToSkip()))
    var selected = plan.defaultSelection
    for group in plan.groups where includes.contains(group.rule.id) {
        selected.formUnion(group.findings.filter { $0.status == .youDecide }.map(\.path))
    }
    let chosen = plan.groups.flatMap { g in g.findings.filter { selected.contains($0.path) }.map { (g.rule, $0) } }
    guard !chosen.isEmpty else {
        if json { return try printJSON(CleanupResult()) }
        return print("Nothing to clean up right now.")
    }

    if !json {
        let now = chosen.filter { $0.0.regrows != .never }.reduce(0) { $0 + $1.1.usage.bytes }
        let kept = chosen.filter { $0.0.regrows == .never }.reduce(0) { $0 + $1.1.usage.bytes }
        print("About to clean up:")
        for group in plan.groups {
            let items = group.findings.filter { selected.contains($0.path) }
            guard !items.isEmpty else { continue }
            let where_ = group.rule.regrows == .never ? "to Recently Removed" : "removed, apps make these again"
            print("  \(padded(group.rule.title, 44)) \(padded(size(items.reduce(0) { $0 + $1.usage.bytes }), 10)) \(where_)")
        }
        print()
        if now > 0 { print("\(size(now)) is freed right away.") }
        if kept > 0 { print("\(size(kept)) goes to Recently Removed, where you can put it back for 30 days.") }
        guard confirm("Clean up?") else { return print("Nothing was changed.") }
    }

    let executor = CleanupExecutor(policy: policy, store: store, runningApps: { runningBundleIDs() })
    let result = executor.run(plan, selected: selected)
    if json { return try printJSON(result) }

    print("\nDone. You freed \(size(result.freedBytes)).")
    if let id = result.batchID {
        print("\(size(result.keptBytes)) is in Recently Removed. To put it back: vulture restore \(id)")
    }
    if !result.failures.isEmpty {
        print("\nLeft alone:")
        for f in result.failures { print("  – \(tilde(f.path)): \(f.reason)") }
    }
}

func removed(json: Bool) throws {
    let store = RecentlyRemoved.standard()
    let batches = store.batches()
    if json { return try printJSON(batches) }
    guard !batches.isEmpty else { return print("Recently Removed is empty.") }
    let date = DateFormatter()
    date.dateStyle = .medium
    date.timeStyle = .short
    for b in batches {
        let left = max(0, Int(ceil(b.expires(after: store.keepDays).timeIntervalSinceNow / 86_400)))
        print("\(b.id)  \(b.title), \(date.string(from: b.removedAt))  \(size(b.bytes))  \(left) days left")
        for item in b.items.prefix(5) { print("    \(tilde(item.originalPath))") }
        if b.items.count > 5 { print("    … and \(b.items.count - 5) more") }
    }
}

func restore() throws {
    guard let id = arguments.first(where: { !$0.hasPrefix("-") }) else { throw UsageError(message: "restore needs the id shown by vulture removed") }
    let store = RecentlyRemoved.standard()
    let batch = try store.batch(id)
    guard confirm("Put back \(batch.items.count) items (\(size(batch.bytes)))?") else { return print("Nothing was changed.") }
    let failures = try store.putBack(batchID: id)
    print("Put back \(batch.items.count - failures.count) of \(batch.items.count) items.")
    for (item, error) in failures { print("  – \(tilde(item.originalPath)): \(error)") }
}

func emptyCommand() throws {
    let store = RecentlyRemoved.standard()
    if flag("--all") {
        let total = store.batches().reduce(0) { $0 + $1.bytes }
        guard total > 0 else { return print("Recently Removed is already empty.") }
        guard confirm("Remove \(size(total)) for good? This can't be undone.") else { return print("Nothing was changed.") }
        print("Freed \(size(try store.emptyAll())).")
    } else {
        print("Removed expired clean-ups for good, freeing \(size(try store.empty())).")
    }
}

// MARK: - Entry point

do {
    if flag("--version") { print(version); exit(0) }
    if flag("--help") || flag("-h") || arguments.isEmpty { print(usage); exit(0) }
    let command = arguments.removeFirst()
    let json = flag("--json")
    switch command {
    case "scan": try scan(json: json)
    case "size": try sizeCommand(json: json)
    case "storage": try storage(json: json)
    case "rules": try rulesCommand(json: json)
    case "check-rules": try checkRules()
    case "clean": try clean(json: json)
    case "removed": try removed(json: json)
    case "restore": try restore()
    case "empty": try emptyCommand()
    case "help": print(usage)
    default: throw UsageError(message: "unknown command `\(command)`")
    }
} catch let error as UsageError {
    FileHandle.standardError.write(Data("vulture: \(error.message)\n\n\(usage)".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("vulture: \(error)\n".utf8))
    exit(1)
}
