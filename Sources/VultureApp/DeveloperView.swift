// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Files coding tools make: Xcode, Docker and package managers, plus build folders in old projects.
struct DeveloperView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var includeSimulators = false
    @State private var includeDocker = false
    @State private var confirming = false

    var body: some View {
        Screen {
            InfoNote(text: "Shown because Vulture found coding tools on your Mac. These files come back by themselves when a project needs them. Hide this section any time in Settings › General.")
                .frame(maxWidth: 720, alignment: .leading)
            status
            if model.dev == nil {
                Card { ProgressView("Looking at your coding tools…").frame(maxWidth: .infinity) }
            } else {
                tools
                projects
            }
        }
        .navigationTitle("Developer Files")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selectedBytes > 0 ? "Clean Up \(formatBytes(selectedBytes))" : "Clean Up") { confirming = true }
                    .primaryButton()
                    .disabled(selectedBytes == 0 && !includeDocker || model.devBusy != nil)
            }
        }
        .task { if model.dev == nil { await model.loadDev() } }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Clean Up") { Task { await clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if let busy = model.devBusy {
            Banner(kind: .info, symbol: "arrow.triangle.2.circlepath", text: Text(busy).bold()) { ProgressView().controlSize(.small) }
        } else if let result = model.lastProjectResult {
            Banner(kind: .success, text: Text(resultText(result))) {
                Button("Dismiss") { model.lastProjectResult = nil }.glassButton()
            }
        }
    }

    private func resultText(_ result: CleanupResult) -> String {
        var parts: [String] = []
        if result.freedBytes > 0 { parts.append("Freed \(formatBytes(result.freedBytes)).") }
        if result.keptBytes > 0 { parts.append("\(formatBytes(result.keptBytes)) is in Recently Removed for 30 days.") }
        if !result.failures.isEmpty { parts.append("\(result.failures.count) items were left because something changed.") }
        return parts.isEmpty ? "Nothing needed removing." : parts.joined(separator: " ")
    }

    // MARK: Tool cards

    private var xcodeRows: [ToolRowData] {
        rows(for: ["xcode.derived-data", "xcode.simulator-caches", "xcode.device-support", "xcode.archives"])
    }

    private var packageRows: [ToolRowData] {
        rows(for: ["packages.npm", "packages.pnpm", "packages.yarn", "packages.homebrew", "packages.pip", "packages.go-build",
                   "packages.cargo", "packages.gradle"])
    }

    private var hasXcode: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil || !xcodeRows.isEmpty
            || !(model.dev?.simulators?.unavailable.isEmpty ?? true)
    }

    private var dockerLines: [DockerReport.Line] {
        (model.dev?.docker?.lines ?? []).filter { !$0.type.lowercased().contains("volume") }
    }

    private var tools: some View {
        let count = max(1, [hasXcode, model.dev?.docker != nil, !packageRows.isEmpty].filter { $0 }.count)
        // One column per tool, sharing the width like the design's three cards.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count),
                         alignment: .leading, spacing: 16) {
            if hasXcode { xcodeCard }
            if model.dev?.docker != nil { dockerCard }
            if !packageRows.isEmpty { packagesCard }
        }
    }

    private var xcodeCard: some View {
        let sims = model.dev?.simulators
        let total = xcodeRows.reduce(0) { $0 + $1.bytes } + (sims?.bytes ?? 0)
        return ToolCard(bundleID: "com.apple.dt.Xcode", symbol: "hammer.fill", name: "Xcode", detail: "Apple’s app for making apps", total: total) {
            ForEach(xcodeRows) { RuleCheckRow(data: $0) }
            if let sims, !sims.unavailable.isEmpty {
                CheckRow(title: "Simulators for old iOS", bytes: sims.bytes, pill: nil, isOn: $includeSimulators,
                         help: "\(sims.unavailable.count) simulators whose iOS version was removed from Xcode, so they can’t be opened.")
            }
            if xcodeRows.isEmpty && (sims?.unavailable.isEmpty ?? true) {
                Text("Nothing to tidy up in Xcode right now.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
        } footer: { EmptyView() }
    }

    private var dockerCard: some View {
        let reclaimable = model.dev?.docker?.reclaimableBytes ?? 0
        return ToolCard(bundleID: "com.docker.docker", symbol: "shippingbox.fill", name: "Docker", detail: "Runs software in containers", total: reclaimable) {
            ForEach(dockerLines, id: \.type) { line in
                HStack {
                    Text(dockerTitle(line.type)).font(.system(size: 13))
                    Spacer()
                    SizeText(bytes: line.reclaimableBytes, weight: .regular, size: 13).foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
            }
            if reclaimable > 0 {
                Toggle(isOn: $includeDocker) {
                    Text("Tidy up Docker").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 6)
            }
        } footer: {
            Text(reclaimable > 0
                 ? "Vulture asks Docker to clean up, then Docker gives the space back to macOS. Volumes, which hold your data, are never touched."
                 : "Docker is already tidy.")
        }
    }

    private var packagesCard: some View {
        ToolCard(bundleID: nil, symbol: "shippingbox.and.arrow.backward.fill", name: "Code Packages", detail: "Downloads from npm, Homebrew and more",
                 total: packageRows.reduce(0) { $0 + $1.bytes }) {
            ForEach(packageRows) { RuleCheckRow(data: $0) }
        } footer: {
            Text("Your AI assistants’ chats and memory are never touched.")
        }
    }

    private func dockerTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "images": "Images you don’t use"
        case "containers": "Stopped containers"
        case "build cache": "Build leftovers"
        default: type
        }
    }

    private func rows(for ids: [String]) -> [ToolRowData] {
        let groups = model.groups
        return ids.compactMap { id in
            guard let group = groups.first(where: { $0.rule.id == id }) else { return nil }
            let usable = group.findings.filter { $0.status != .skipped }
            let bytes = model.bytes(of: usable)
            guard bytes > 0 else { return nil }
            return ToolRowData(group: group, title: Self.shortTitle[id] ?? group.rule.title, bytes: bytes)
        }
    }

    static let shortTitle: [String: String] = [
        "xcode.derived-data": "Build files", "xcode.simulator-caches": "Simulator temporary files",
        "xcode.device-support": "Old iPhone debugging files", "xcode.archives": "Old app archives",
        "packages.npm": "npm", "packages.pnpm": "pnpm", "packages.yarn": "Yarn", "packages.homebrew": "Homebrew",
        "packages.pip": "Python packages", "packages.go-build": "Go build files", "packages.cargo": "Rust packages",
        "packages.gradle": "Gradle",
    ]

    // MARK: Old projects

    private var projectFindings: [(rule: Rule, finding: Finding)] {
        let all = (model.dev?.projects ?? []).flatMap { g in g.findings.map { (g.rule, $0) } }
            .sorted { $0.1.usage.bytes > $1.1.usage.bytes }
        guard !search.isEmpty else { return all }
        return all.filter { ProjectName.of($0.1.path).localizedCaseInsensitiveContains(search) }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Old Projects You Haven’t Opened").font(.system(size: 13, weight: .bold))
                Spacer()
                Picker("Not opened for", selection: Binding(get: { model.projectDays }, set: { days in Task { await model.reloadProjects(days: days) } })) {
                    Text("30 days or more").tag(30)
                    Text("60 days or more").tag(60)
                    Text("90 days or more").tag(90)
                    Text("6 months or more").tag(180)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            projectTable
            Text("Only folders a project’s tools make again are removed, like node_modules or build files. Your code is never touched.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var projectTable: some View {
        let items = projectFindings
        if model.loadingProjects {
            Card { ProgressView("Looking for old projects…").frame(maxWidth: .infinity) }
        } else if items.isEmpty {
            Card {
                Text(search.isEmpty ? "No build folders in projects you haven’t opened for \(daysText(model.projectDays))." : "No projects match “\(search)”.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle("Select all projects", isOn: Binding(
                        get: { items.allSatisfy { model.projectSelection.contains($0.finding.path) } },
                        set: { on in
                            let paths = items.map(\.finding.path)
                            if on { model.projectSelection.formUnion(paths) } else { model.projectSelection.subtract(paths) }
                        }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text("Project").padding(.leading, 40)
                    Spacer()
                    Text("Not opened for").frame(width: 130, alignment: .leading)
                    Text("Size").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 30)
                ForEach(items, id: \.finding.path) { item in
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    ProjectRow(rule: item.rule, finding: item.finding)
                }
            }
            .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    private func daysText(_ days: Int) -> String { days >= 180 ? "6 months" : "\(days) days" }

    // MARK: Totals and cleaning

    private var ruleSelection: Set<String> {
        let paths = (xcodeRows + packageRows).flatMap { $0.group.findings.filter { $0.status != .skipped }.map(\.path) }
        return model.selection.intersection(paths)
    }

    private var ruleSelectedBytes: Int64 {
        model.bytes(of: model.groups.flatMap(\.findings).filter { ruleSelection.contains($0.path) })
    }

    private var selectedBytes: Int64 {
        ruleSelectedBytes + model.projectSelectedBytes + (includeSimulators ? model.dev?.simulators?.bytes ?? 0 : 0)
            + (includeDocker ? model.dev?.docker?.reclaimableBytes ?? 0 : 0)
    }

    private var subtitle: String {
        guard model.dev != nil else { return "" }
        let tools = (xcodeRows + packageRows).reduce(0) { $0 + $1.bytes } + (model.dev?.simulators?.bytes ?? 0)
            + (model.dev?.docker?.reclaimableBytes ?? 0)
        let projectsTotal = (model.dev?.projects ?? []).flatMap(\.findings).reduce(0) { $0 + $1.usage.bytes }
        let selected = selectedBytes > 0 ? "\(formatBytes(selectedBytes)) selected" : "Nothing selected"
        return "\(formatBytes(tools + projectsTotal)) in coding tools · \(selected)"
    }

    private var confirmTitle: String { "Clean up \(formatBytes(selectedBytes))?" }

    private var confirmMessage: String {
        var lines: [String] = []
        if ruleSelectedBytes > 0 || model.projectSelectedBytes > 0 {
            lines.append("Build files and downloads are removed right away. The tools make them again the next time you build or install.")
        }
        if includeSimulators { lines.append("Xcode removes simulators that can’t be opened. Simulators that still work are kept.") }
        if includeDocker { lines.append("Docker removes images no container uses, stopped containers and build leftovers. Volumes are kept.") }
        return lines.joined(separator: "\n\n")
    }

    private func clean() async {
        let rules = ruleSelection
        if !rules.isEmpty { await model.cleanPlanItems(rules, title: "Developer files") }
        if !model.projectSelection.isEmpty { await model.cleanProjects() }
        if includeSimulators { await model.removeSimulators(); includeSimulators = false }
        if includeDocker { await model.tidyDocker(); includeDocker = false }
    }
}

// MARK: - Pieces

struct ToolRowData: Identifiable {
    var id: String { group.rule.id }
    let group: CleanupPlan.Group
    let title: String
    let bytes: Int64
}

/// A tool's card: icon, name, what it is, total, then checkbox rows.
private struct ToolCard<Rows: View, Footer: View>: View {
    let bundleID: String?
    let symbol: String
    let name: String
    let detail: String
    let total: Int64
    @ViewBuilder var rows: Rows
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let bundleID, AppIcon.image(bundleID: bundleID, path: nil) != nil {
                    AppIcon(bundleID: bundleID, size: 40)
                } else {
                    IconTile(symbol: symbol, color: Theme.teal, size: 38)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 16, weight: .bold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if total > 0 { SizeText(bytes: total, weight: .bold, size: 16) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                Group { rows }
            }
            footer.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// A rule-backed row: checking it selects the same items Clean Up would.
private struct RuleCheckRow: View {
    @Environment(AppModel.self) private var model
    let data: ToolRowData

    private var paths: [String] { data.group.findings.filter { $0.status != .skipped }.map(\.path) }

    var body: some View {
        CheckRow(title: data.title, bytes: data.bytes, pill: pill,
                 isOn: Binding(get: { !paths.isEmpty && paths.allSatisfy { model.selection.contains($0) } },
                               set: { model.toggle(data.group, on: $0) }),
                 help: data.group.rule.explanation)
            .onTapGesture { model.focusedPath = paths.first }
    }

    private var pill: String? {
        switch data.group.rule.regrows {
        case .onNextBuild: "Next build"
        case .onNextInstall: "Next install"
        default: nil
        }
    }
}

private struct CheckRow: View {
    let title: String
    let bytes: Int64
    let pill: String?
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox).font(.system(size: 13))
            Spacer(minLength: 6)
            if let pill {
                Label(pill, systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.orangeBackground, in: Capsule())
                    .help("Comes back by itself the next time you \(pill == "Next build" ? "build" : "install")")
            }
            SizeText(bytes: bytes, weight: .regular, size: 13).frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .help(help)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
    }
}

enum ProjectName {
    /// "pose-helper › ios" reads better than a bare "ios" for apps with one folder per platform.
    static func of(_ path: String) -> String {
        let project = URL(fileURLWithPath: path).deletingLastPathComponent()
        let generic: Set<String> = ["ios", "android", "macos", "app", "web", "frontend", "backend", "client", "server", "mobile"]
        let last = project.lastPathComponent
        return generic.contains(last.lowercased()) ? "\(project.deletingLastPathComponent().lastPathComponent) › \(last)" : last
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let finding: Finding

    private var project: URL { URL(fileURLWithPath: finding.path).deletingLastPathComponent() }
    private var folder: String { URL(fileURLWithPath: finding.path).lastPathComponent }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Include \(ProjectName.of(finding.path))", isOn: Binding(
                get: { model.projectSelection.contains(finding.path) },
                set: { if $0 { model.projectSelection.insert(finding.path) } else { model.projectSelection.remove(finding.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: project.path)).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(ProjectName.of(finding.path)).font(.system(size: 13, weight: .semibold))
                Text("\(rule.title) (\(folder))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(age).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            SizeText(bytes: finding.usage.bytes, weight: .semibold, size: 13).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.focusedPath = finding.path }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) }
        }
    }

    private var age: String {
        guard let touched = finding.usage.newest else { return "—" }
        let days = Int(Date().timeIntervalSince(touched) / 86_400)
        if days < 60 { return "\(days) days" }
        let months = days / 30
        return months >= 24 ? "\(months / 12) years" : "\(months) months"
    }
}
