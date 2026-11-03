// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finds folders that build tools and package managers create inside people's projects
/// (node_modules, target, .venv…) in projects nobody has touched for a while.
/// The project's own files are never offered; only the folder its tools can make again.
public struct ProjectFinder: Sendable {
    /// A kind of folder a tool makes inside a project, recognised by a file that sits next to it.
    public struct Kind: Sendable {
        public var folder: String
        public var marker: [String]
        public var rule: Rule
    }

    public static let kinds: [Kind] = [
        kind("node_modules", ["package.json"], "projects.node-modules", "JavaScript packages",
             "Packages a JavaScript project downloaded. Running npm install in the project downloads them again.", .onNextInstall),
        kind(".next", ["package.json"], "projects.next-build", "Next.js build files",
             "Files Next.js makes when it builds the site. It makes them again on the next build.", .onNextBuild),
        kind("target", ["Cargo.toml"], "projects.rust-target", "Rust build files",
             "Files Cargo makes when it builds a Rust project. It makes them again on the next build.", .onNextBuild),
        kind(".venv", ["pyvenv.cfg"], "projects.python-venv", "Python environments",
             "A private copy of Python and packages for one project. It can be made again from the project's requirements.", .onNextInstall, markerInside: true),
        kind("venv", ["pyvenv.cfg"], "projects.python-venv-plain", "Python environments",
             "A private copy of Python and packages for one project. It can be made again from the project's requirements.", .onNextInstall, markerInside: true),
        kind("build", ["build.gradle", "build.gradle.kts"], "projects.gradle-build", "Android and Gradle build files",
             "Files Gradle makes when it builds an Android or Java project. It makes them again on the next build.", .onNextBuild),
        kind(".build", ["Package.swift"], "projects.swiftpm-build", "Swift package build files",
             "Files Swift makes when it builds a package. It makes them again on the next build.", .onNextBuild),
        kind("Pods", ["Podfile"], "projects.cocoapods", "CocoaPods libraries",
             "Libraries CocoaPods downloaded for an iPhone or Mac project. Running pod install downloads them again.", .onNextInstall),
    ]

    private static func kind(_ folder: String, _ marker: [String], _ id: String, _ title: String, _ explanation: String,
                             _ regrows: Rule.Regrowth, markerInside: Bool = false) -> Kind {
        Kind(folder: folder, marker: markerInside ? marker.map { "\(folder)/\($0)" } : marker,
             rule: Rule(id: id, title: title, explanation: explanation, category: .developer, safety: .review,
                        regrows: regrows, paths: ["~/…/\(folder)"]))
    }

    /// Folders in the home folder where people usually keep code. Documents and Desktop are protected and never searched.
    public static let standardRoots = ["Development", "Developer", "Projects", "projects", "Code", "code", "src", "repos", "workspace", "GitHub", "Sites"]

    public let home: URL
    public let roots: [String]
    /// Only projects where nothing changed for this many days.
    public let untouchedDays: Int
    public let maxDepth: Int

    public init(home: URL, roots: [String] = ProjectFinder.standardRoots, untouchedDays: Int = 90, maxDepth: Int = 6) {
        self.home = home
        self.roots = roots
        self.untouchedDays = untouchedDays
        self.maxDepth = maxDepth
    }

    /// Finds and measures the folders, grouped like a cleanup plan so the same review and clean-up flow applies.
    public func groups(policy: SafetyPolicy, scanner: DiskScanner, now: Date = Date()) -> [CleanupPlan.Group] {
        var found: [String: [Finding]] = [:]
        var seenRoots: Set<String> = []
        for root in roots {
            let url = home.appendingPathComponent(root)
            guard Glob.isRealDirectory(url), let real = realPath(url.path), seenRoots.insert(real).inserted else { continue }
            walk(url, depth: 0) { project, kind in
                let target = project.appendingPathComponent(kind.folder)
                guard policy.check(target) == nil else { return }
                guard let touched = lastTouched(project, ignoring: kind.folder),
                      now.timeIntervalSince(touched) >= Double(untouchedDays) * 86_400 else { return }
                var st = stat()
                guard lstat(target.path, &st) == 0 else { return }
                let usage = scanner.usage(of: target)
                guard usage.bytes > 0 else { return }
                var u = usage
                u.newest = touched // "last touched" here means the project, which is what people care about
                found[kind.rule.id, default: []].append(Finding(ruleID: kind.rule.id, path: target.standardizedFileURL.path, usage: u,
                                                               status: .youDecide, fileID: UInt64(st.st_ino)))
            }
        }
        return Self.kinds.compactMap { kind in
            guard let findings = found[kind.rule.id], !findings.isEmpty else { return nil }
            return CleanupPlan.Group(rule: kind.rule, findings: findings.sorted { $0.usage.bytes > $1.usage.bytes })
        }
    }

    private func walk(_ dir: URL, depth: Int, _ hit: (URL, Kind) -> Void) {
        guard depth <= maxDepth else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let present = Set(names)
        var claimed: Set<String> = []
        for kind in Self.kinds where present.contains(kind.folder) && !claimed.contains(kind.folder) {
            if kind.marker.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }),
               Glob.isRealDirectory(dir.appendingPathComponent(kind.folder)) {
                claimed.insert(kind.folder)
                hit(dir, kind)
            }
        }
        for name in names.sorted() where !claimed.contains(name) && !name.hasPrefix(".") && name != "node_modules" {
            let child = dir.appendingPathComponent(name)
            if Glob.isRealDirectory(child) { walk(child, depth: depth + 1, hit) }
        }
    }

    /// The newest change among the project's own top-level items (and its git state), leaving out the tool's folder.
    private func lastTouched(_ project: URL, ignoring folder: String) -> Date? {
        var newest: Date?
        func note(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let d = Date(timespec: st.st_mtimespec)
            if newest.map({ d > $0 }) ?? true { newest = d }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        for name in names where name != folder && name != ".DS_Store" {
            note(project.appendingPathComponent(name).path)
        }
        // A build folder deep inside a repository (an app's ios/Pods, say) belongs to the whole repository:
        // any git activity there counts as the project being used.
        var dir = project
        while dir.path.count > home.path.count {
            note(dir.appendingPathComponent(".git/index").path)
            note(dir.appendingPathComponent(".git/HEAD").path)
            if Glob.exists(dir.appendingPathComponent(".git")) { break }
            dir = dir.deletingLastPathComponent()
        }
        return newest
    }
}
