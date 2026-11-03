// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import VultureCore

let version = "0.1.0-dev"

let usage = """
    vulture \(version): see what's filling up your Mac. Nothing is ever removed by this version.

    Usage:
      vulture scan [--json] [--rules DIR]     Find files that can be cleaned up, and explain each one
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

// MARK: - Entry point

do {
    if flag("--version") { print(version); exit(0) }
    if flag("--help") || flag("-h") || arguments.isEmpty { print(usage); exit(0) }
    let command = arguments.removeFirst()
    let json = flag("--json")
    switch command {
    case "scan": try scan(json: json)
    case "size": try sizeCommand(json: json)
    case "rules": try rulesCommand(json: json)
    case "check-rules": try checkRules()
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
