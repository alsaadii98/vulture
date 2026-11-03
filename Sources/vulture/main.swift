// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import VultureCore

/// The app's version when this tool runs from inside Vulture.app, otherwise a development build.
let version: String = {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
    let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "dev"
}()

let usage = """
    vulture \(version): see what's filling up your Mac, and free up space without the worry.

    Usage:
      vulture scan [--json] [--rules DIR]     Find files that can be cleaned up, and explain each one
      vulture clean [--include RULE]... [--projects] [--yes] [--json]
                                              Clean up the recommended items (add "you decide" rules with --include,
                                              and build folders of old projects with --projects)
      vulture projects [--days N] [--json]    Build folders in projects untouched for N days (default 90)
      vulture dev [--json]                    Xcode simulators, Docker and old projects at a glance
      vulture dev remove-simulators [--yes]   Remove simulators whose iOS version is gone
      vulture dev tidy-docker [--yes]         Remove unused Docker images, stopped containers and build cache
      vulture apps [--unused DAYS] [--json]   List apps, largest first (or only those unused for DAYS)
      vulture uninstall NAME [--yes]          Remove an app and everything it keeps, to Recently Removed
      vulture leftovers [--clean] [--yes] [--json]
                                              Files left behind by apps that are already gone
      vulture startup [--json]                What starts by itself, and what's left behind
      vulture startup off|on LABEL            Stop one of your items from starting by itself, or let it again
      vulture removed [--json]                List what's in Recently Removed
      vulture restore ID [--yes]              Put back everything from one clean-up
      vulture empty [--all] [--yes]           Remove expired clean-ups for good (--all: everything)
      vulture storage [--json]                What's using space on this Mac, by kind
      vulture size [PATH] [--json] [--top N]  Measure a folder (default: your home folder)
      vulture history [--days N]              What changed on your disk over the last N days (default 7)
      vulture rules [--json] [--rules DIR]    List the cleaning rules in use
      vulture rules install FILE              Install a signed rule pack
      vulture check-rules DIR                 Check rule files for mistakes (for contributors)
      vulture rules keygen --out DIR          Make a rule-signing key (maintainers)
      vulture rules pack DIR --version V --key FILE --out FILE
                                              Sign rule files into a pack (maintainers)
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
    return RuleUpdates.activeRules(home: FileManager.default.homeDirectoryForCurrentUser, bundled: try RuleLoader.load(directory: dir)).rules
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
    let regrowth = RegrowthTracker.standard(home: home)
    let planner = CleanupPlanner(rules: rules, policy: SafetyPolicy(home: home), runningApps: runningBundleIDs(),
                                 quicklyRefilling: regrowth.quicklyRefilling())
    let plan = planner.plan(scanner: DiskScanner(skipping: Privacy.foldersToSkip()))
    try? regrowth.observe(plan)
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
    try? SpaceHistory.standard(home: home).record(report)
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

func history() throws {
    let days = try option("--days").map { v -> Int in
        guard let n = Int(v), n > 0 else { throw UsageError(message: "--days needs a positive number") }
        return n
    } ?? 7
    guard let result = SpaceHistory.standard().changes(overDays: days) else {
        return print("Not enough history yet. Vulture keeps one measurement a day; run vulture storage on different days, or open Storage in the app.")
    }
    let names: [StorageReport.Kind: String] = [
        .apps: "Apps", .documents: "Documents and downloads", .media: "Photos, music and videos", .coding: "Coding apps' files",
        .appData: "App data", .otherFiles: "Other files in your home folder", .system: "macOS and System Data",
    ]
    let free = result.freeDelta
    print("Since \(result.since.formatted(date: .abbreviated, time: .omitted)): free space \(free >= 0 ? "went up" : "went down") by \(size(abs(free))).\n")
    for c in result.changes {
        print("  \(padded(names[c.kind] ?? c.kind.rawValue, 34)) \(c.delta >= 0 ? "+" : "−")\(size(abs(c.delta)))")
    }
}

func rulesSubcommand(_ verb: String) throws {
    switch verb {
    case "install":
        guard let file = arguments.first(where: { !$0.hasPrefix("-") }) else { throw UsageError(message: "rules install needs a pack file") }
        let version = try RuleUpdates.install(Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)),
                                              home: FileManager.default.homeDirectoryForCurrentUser)
        print("Installed rules version \(version). They're used from the next scan.")
    case "keygen":
        guard let out = try option("--out") else { throw UsageError(message: "rules keygen needs --out DIR") }
        let dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = RuleUpdates.makeKey()
        let privateURL = dir.appendingPathComponent("vulture-rules-\(key.keyID).key")
        guard !FileManager.default.fileExists(atPath: privateURL.path) else { throw UsageError(message: "\(privateURL.path) already exists") }
        FileManager.default.createFile(atPath: privateURL.path, contents: Data(key.privateKey.utf8), attributes: [.posixPermissions: 0o600])
        print("Private key: \(privateURL.path)  (keep it secret and offline; never commit it)")
        print("Public key \(key.keyID): \(key.publicKey)")
        print("Add the public key to RuleUpdates.trustedKeys to let Vulture accept packs signed with it.")
    case "pack":
        guard let dir = arguments.first(where: { !$0.hasPrefix("-") }) else { throw UsageError(message: "rules pack needs a folder of rule files") }
        guard let version = try option("--version"), let keyFile = try option("--key"), let out = try option("--out") else {
            throw UsageError(message: "rules pack needs --version, --key and --out")
        }
        let key = try String(contentsOfFile: (keyFile as NSString).expandingTildeInPath, encoding: .utf8)
        let data = try RuleUpdates.pack(directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath), version: version, privateKey: key)
        try data.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        print("Signed rules version \(version) into \(out).")
    default:
        throw UsageError(message: "unknown rules command `\(verb)`")
    }
}

func rulesCommand(json: Bool) throws {
    if let verb = arguments.first, ["install", "keygen", "pack"].contains(verb) {
        arguments.removeFirst()
        return try rulesSubcommand(verb)
    }
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

    let withProjects = flag("--projects")
    let days = try option("--days").map { Int($0) ?? 90 } ?? 90
    let scanner = DiskScanner(skipping: Privacy.foldersToSkip())
    let regrowth = RegrowthTracker.standard(home: home)
    var plan = CleanupPlanner(rules: rules, policy: policy, runningApps: runningBundleIDs(), quicklyRefilling: regrowth.quicklyRefilling())
        .plan(scanner: scanner)
    try? regrowth.observe(plan)
    var selected = plan.defaultSelection
    if withProjects {
        let projects = ProjectFinder(home: home, untouchedDays: days).groups(policy: policy, scanner: scanner)
        plan.groups += projects
        selected.formUnion(projects.flatMap(\.findings).map(\.path))
    }
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
    try? regrowth.noteCleaned(result.removedForGood)
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

func projects(json: Bool) throws {
    let days = try option("--days").map { v -> Int in
        guard let n = Int(v), n >= 0 else { throw UsageError(message: "--days needs a number") }
        return n
    } ?? 90
    let home = FileManager.default.homeDirectoryForCurrentUser
    let groups = ProjectFinder(home: home, untouchedDays: days)
        .groups(policy: SafetyPolicy(home: home), scanner: DiskScanner(skipping: Privacy.foldersToSkip()))
    if json { return try printJSON(groups) }
    guard !groups.isEmpty else { return print("No build folders in projects untouched for \(days) days.") }
    let total = groups.reduce(0) { $0 + $1.bytes }
    print("\(size(total)) in build folders of projects untouched for \(days)+ days. Their tools make them again when needed.\n")
    for g in groups {
        print("\(padded(g.rule.title, 46)) \(size(g.bytes))")
        for f in g.findings.prefix(8) {
            let age = f.usage.newest.map { "\(Int(Date().timeIntervalSince($0) / 86_400)) days" } ?? ""
            print("    \(padded(tilde(f.path), 60)) \(padded(size(f.usage.bytes), 10)) \(age)")
        }
        if g.findings.count > 8 { print("    … and \(g.findings.count - 8) more") }
    }
    print("\nTo clean these up: vulture clean --projects")
}

func dev(json: Bool) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let sub = arguments.first(where: { !$0.hasPrefix("-") }) {
        switch sub {
        case "remove-simulators":
            guard let report = Simulators.report(home: home, scanner: DiskScanner()), !report.unavailable.isEmpty else {
                return print("No simulators to remove.")
            }
            guard confirm("Remove \(report.unavailable.count) simulators whose iOS version is gone (\(size(report.bytes)))?") else { return print("Nothing was changed.") }
            print(Simulators.deleteUnavailable() ? "Removed. Simulators that still work were kept." : "Xcode couldn't remove them.")
        case "tidy-docker":
            guard let report = Docker.report() else { return print("Docker isn't running. Open Docker and try again.") }
            guard confirm("Remove unused images, stopped containers and build cache (about \(size(report.reclaimableBytes)))? Volumes, which hold data, are kept.") else { return print("Nothing was changed.") }
            print(Docker.tidy() ? "Done. Docker Desktop gives the space back to macOS gradually." : "Docker couldn't finish tidying up.")
        default:
            throw UsageError(message: "unknown dev command `\(sub)`")
        }
        return
    }
    let scanner = DiskScanner(skipping: Privacy.foldersToSkip())
    let sims = Simulators.report(home: home, scanner: scanner)
    let docker = Docker.report()
    let projects = ProjectFinder(home: home).groups(policy: SafetyPolicy(home: home), scanner: scanner)
    struct Report: Encodable { let simulators: SimulatorReport?; let docker: DockerReport?; let oldProjects: [CleanupPlan.Group] }
    if json { return try printJSON(Report(simulators: sims, docker: docker, oldProjects: projects)) }

    print("Xcode simulators")
    if let sims { print(sims.unavailable.isEmpty ? "  All simulators work." : "  \(sims.unavailable.count) can't be opened anymore: \(size(sims.bytes)). Remove: vulture dev remove-simulators") }
    else { print("  Xcode isn't set up on this Mac.") }
    print("\nDocker")
    if let docker { print("  About \(size(docker.reclaimableBytes)) can be given back. Tidy up: vulture dev tidy-docker") }
    else { print("  Not installed, or not running.") }
    print("\nOld projects (untouched for 90+ days)")
    let total = projects.reduce(0) { $0 + $1.bytes }
    print(total > 0 ? "  \(size(total)) in build folders. Details: vulture projects" : "  Nothing found.")
}

func isRegistered(_ bundleID: String) -> Bool {
    !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).isEmpty
}

func ago(_ date: Date?) -> String {
    guard let date else { return "no sign of use" }
    let days = Int(Date().timeIntervalSince(date) / 86_400)
    switch days {
    case 0: return "used today"
    case 1..<14: return "used \(days) days ago"
    case 14..<60: return "used \(days / 7) weeks ago"
    default: return "not used in \(days / 30) months"
    }
}

func apps(json: Bool) throws {
    let unused = try option("--unused").map { v -> Int in
        guard let n = Int(v), n >= 0 else { throw UsageError(message: "--unused needs a number of days") }
        return n
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    var list = AppInventory.installedApps(roots: AppInventory.standardRoots(home: home), home: home, scanner: DiskScanner()).filter { !$0.isApple }
    if let unused {
        list = list.filter { app in app.lastUsed.map { Date().timeIntervalSince($0) > Double(unused) * 86_400 } ?? true }
    }
    list.sort { $0.bytes > $1.bytes }
    if json { return try printJSON(list) }
    print("\(list.count) apps, \(size(list.reduce(0) { $0 + $1.bytes })) in all\n")
    for app in list {
        let note = app.canRemove ? "" : "  (needs an administrator to remove)"
        print("  \(padded(app.name, 34)) \(padded(size(app.bytes), 10)) \(ago(app.lastUsed))\(note)")
    }
}

func uninstall() throws {
    guard let query = arguments.first(where: { !$0.hasPrefix("-") }) else { throw UsageError(message: "uninstall needs an app name") }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = AppInventory.standardRoots(home: home)
    let matches = AppInventory.installedApps(roots: roots, scanner: DiskScanner())
        .filter { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame || $0.bundleID == query }
    guard matches.count == 1, let app = matches.first else {
        throw UsageError(message: matches.isEmpty ? "no app called \(query); see vulture apps" : "more than one app is called \(query); use its bundle identifier")
    }
    let files = AppInventory.files(of: app.bundleID, name: app.name, home: home, scanner: DiskScanner(), fullDiskAccess: Privacy.hasFullDiskAccess(home: home))
    let certain = files.filter(\.certain), unsure = files.filter { !$0.certain }
    print("\(app.name) \(app.version ?? "")  \(size(app.bytes))  \(tilde(app.path))")
    for f in certain { print("  + \(padded(tilde(f.path), 70)) \(size(f.usage.bytes))") }
    for f in unsure { print("  ? \(padded(tilde(f.path), 70)) \(size(f.usage.bytes))  (named like the app; kept unless you add --all)") }
    let chosen = flag("--all") ? files : certain
    let total = app.bytes + chosen.reduce(0) { $0 + $1.usage.bytes }
    guard confirm("\nMove \(app.name) and \(chosen.count) of its files (\(size(total))) to Recently Removed?") else { return print("Nothing was changed.") }
    let (batch, failures) = try AppRemover.remove(app, files: chosen, roots: roots, home: home, store: RecentlyRemoved.standard(home: home),
                                                  running: runningBundleIDs(), open: OpenFiles.snapshot())
    print("Removed \(app.name). To put it back: vulture restore \(batch.id)")
    for f in failures { print("  – left \(tilde(f.path)): \(f.reason)") }
    print("The space is freed when Recently Removed is emptied (after 30 days, or with vulture empty --all).")
}

func leftovers(json: Bool) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let installed = Set(AppInventory.installedApps(roots: AppInventory.standardRoots(home: home), scanner: DiskScanner()).map(\.bundleID))
    let groups = LeftoverFinder.find(home: home, installed: installed, isRegistered: isRegistered, scanner: DiskScanner())
    if json { return try printJSON(groups) }
    guard !groups.isEmpty else { return print("No leftovers from removed apps.") }
    let total = groups.reduce(0) { $0 + $1.bytes }
    print("\(groups.count) apps that are no longer on this Mac left \(size(total)) behind.\n")
    for g in groups {
        let last = g.lastChanged.map { "last changed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        print("  \(padded(g.displayName, 22)) \(padded(g.bundleID, 40)) \(padded(size(g.bytes), 10)) \(last)")
    }
    guard flag("--clean") else { return print("\nLook through these, then: vulture leftovers --clean") }
    guard confirm("\nMove all of these to Recently Removed?") else { return print("Nothing was changed.") }
    let result = LeftoverFinder.remove(groups.flatMap(\.files), home: home, store: RecentlyRemoved.standard(home: home), open: OpenFiles.snapshot())
    if let id = result.batchID { print("Moved \(size(result.keptBytes)) to Recently Removed. To put it back: vulture restore \(id)") }
    for f in result.failures { print("  – left \(tilde(f.path)): \(f.reason)") }
}

func startup(json: Bool) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let verb = arguments.first, verb == "on" || verb == "off" {
        guard arguments.count >= 2 else { throw UsageError(message: "startup \(verb) needs the item's label; see vulture startup") }
        let label = arguments[1]
        guard let item = LaunchItems.list(home: home, includeAllUsers: false).first(where: { $0.label == label }) else {
            throw UsageError(message: "\(label) isn't one of your items")
        }
        guard LaunchItems.setEnabled(item, verb == "on") else { throw UsageError(message: "macOS didn't accept the change") }
        return print(verb == "on" ? "\(label) can start by itself again." : "\(label) won't start by itself anymore. Nothing was deleted; turn it back on with vulture startup on \(label)")
    }
    let items = LaunchItems.list(home: home)
    if json { return try printJSON(items) }
    func describe(_ i: LaunchItem) -> String {
        if i.isLeftBehind { return "left behind: its app is gone" }
        if i.disabled { return "turned off" }
        var parts: [String] = []
        if i.keepsRunning { parts.append("always running") } else if i.runsAtLogin { parts.append("starts when you log in") }
        if let s = i.intervalSeconds { parts.append(s >= 3600 ? "runs every \(s / 3600) h" : "runs every \(max(1, s / 60)) min") }
        return parts.isEmpty ? "starts when needed" : parts.joined(separator: ", ")
    }
    for (title, scope) in [("Yours (you can turn these off)", LaunchItem.Scope.user), ("For all users (needs an administrator)", .allUsersAgent), ("System helpers from apps (needs an administrator)", .allUsersDaemon)] {
        let group = items.filter { $0.scope == scope }
        guard !group.isEmpty else { continue }
        print(title)
        for i in group {
            let owner = i.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
            print("  \(padded(i.label, 48)) \(padded(owner, 18)) \(describe(i))")
        }
        print()
    }
    print("Apps that open at login are listed in System Settings › General › Login Items.")
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
    // Only as the first word, so options like `rules pack --version 2026.12.01` still work.
    if arguments.first == "--version" { print(version); exit(0) }
    if arguments.isEmpty || ["--help", "-h"].contains(arguments[0]) { print(usage); exit(0) }
    let command = arguments.removeFirst()
    let json = flag("--json")
    switch command {
    case "scan": try scan(json: json)
    case "size": try sizeCommand(json: json)
    case "storage": try storage(json: json)
    case "history": try history()
    case "projects": try projects(json: json)
    case "dev": try dev(json: json)
    case "apps": try apps(json: json)
    case "uninstall": try uninstall()
    case "leftovers": try leftovers(json: json)
    case "startup": try startup(json: json)
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
