// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Files coding tools make: old projects' build folders, simulators that can't open anymore, and Docker's leftovers.
struct DeveloperView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: Action?

    enum Action: Identifiable {
        case projects, simulators, docker
        var id: Self { self }
    }

    var body: some View {
        List {
            Section {
                Label("Shown because Vulture found coding tools on your Mac. These files come back by themselves when a project needs them. Hide this section in Settings.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let busy = model.devBusy {
                Section { Working(text: busy, detail: "This can take a minute.") }
            }
            if let result = model.lastProjectResult {
                Section { DoneBanner(result: result) }
            }
            if let dev = model.dev {
                projectsSection(dev.projects)
                simulatorsSection(dev.simulators)
                dockerSection(dev.docker)
            }
        }
        .overlay {
            if model.dev == nil { ProgressView("Looking at your coding tools…") }
        }
        .navigationTitle("Developer Files")
        .toolbar {
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.loadDev() } }
                .disabled(model.loadingDev || model.devBusy != nil)
        }
        .task { if model.dev == nil { await model.loadDev() } }
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { action in
            Button(button(action)) {
                Task {
                    switch action {
                    case .projects: await model.cleanProjects()
                    case .simulators: await model.removeSimulators()
                    case .docker: await model.tidyDocker()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(message(action))
        }
    }

    // MARK: Sections

    @ViewBuilder private func projectsSection(_ groups: [CleanupPlan.Group]) -> some View {
        Section {
            if groups.isEmpty {
                Text("No build folders in projects untouched for 90 days.").foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.rule.id) { group in
                ForEach(group.findings, id: \.path) { finding in
                    ProjectRow(rule: group.rule, finding: finding)
                }
            }
        } header: {
            HStack {
                Text("Old Projects You Haven't Opened").font(.headline)
                Spacer()
                if !groups.isEmpty {
                    Button(model.projectSelection.isEmpty ? "Clean Up" : "Clean Up \(formatBytes(model.projectSelectedBytes))") { confirming = .projects }
                        .disabled(model.projectSelection.isEmpty || model.devBusy != nil)
                }
            }
        } footer: {
            Text("Only folders the project's tools make again are removed, like node_modules or build files. Your code is never touched.")
        }
    }

    @ViewBuilder private func simulatorsSection(_ report: SimulatorReport?) -> some View {
        Section("Xcode Simulators") {
            ToolRow(app: "com.apple.dt.Xcode", fallback: "iphone") {
                if let report {
                    if report.unavailable.isEmpty {
                        Text("All your simulators still work.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(report.unavailable.count) simulators can't be opened anymore").fontWeight(.semibold)
                            Text("Their iOS version was removed from Xcode, so they just take up \(formatBytes(report.bytes)).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Xcode isn't set up on this Mac.").foregroundStyle(.secondary)
                }
            } action: {
                if let report, !report.unavailable.isEmpty {
                    Button("Remove…") { confirming = .simulators }.disabled(model.devBusy != nil)
                }
            }
        }
    }

    @ViewBuilder private func dockerSection(_ report: DockerReport?) -> some View {
        Section("Docker") {
            ToolRow(app: "com.docker.docker", fallback: "shippingbox") {
                if let report {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.reclaimableBytes > 0 ? "About \(formatBytes(report.reclaimableBytes)) can be given back" : "Docker is already tidy")
                            .fontWeight(.semibold)
                        Text("Images no container uses, stopped containers and build leftovers. Volumes, which hold your data, are never touched.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Open Docker to see what can be tidied up.").foregroundStyle(.secondary)
                }
            } action: {
                if let report, report.reclaimableBytes > 0 {
                    Button("Tidy Up…") { confirming = .docker }.disabled(model.devBusy != nil)
                }
            }
        }
    }

    // MARK: Confirmation text

    private var title: String {
        switch confirming {
        case .projects: "Remove \(formatBytes(model.projectSelectedBytes)) of build folders?"
        case .simulators: "Remove simulators that can't be opened?"
        case .docker: "Tidy up Docker?"
        case nil: ""
        }
    }

    private func button(_ action: Action) -> String {
        switch action {
        case .projects: "Clean Up"
        case .simulators: "Remove"
        case .docker: "Tidy Up"
        }
    }

    private func message(_ action: Action) -> String {
        switch action {
        case .projects: "They're removed right away. Each project's tools make them again the next time you build or install."
        case .simulators: "Xcode removes them. Simulators that still work are kept."
        case .docker: "Docker removes unused images, stopped containers and build cache. Images download again if you need them. Docker gives the space back to macOS gradually."
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let finding: Finding

    private var project: URL { URL(fileURLWithPath: finding.path).deletingLastPathComponent() }

    /// "pose-helper › ios" reads better than a bare "ios" for apps with one folder per platform.
    private var name: String {
        let generic: Set<String> = ["ios", "android", "macos", "app", "web", "frontend", "backend", "client", "server", "mobile"]
        let last = project.lastPathComponent
        return generic.contains(last.lowercased()) ? "\(project.deletingLastPathComponent().lastPathComponent) › \(last)" : last
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Include \(name)", isOn: Binding(
                get: { model.projectSelection.contains(finding.path) },
                set: { if $0 { model.projectSelection.insert(finding.path) } else { model.projectSelection.remove(finding.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: project.path)).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(rule.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let touched = finding.usage.newest {
                Text("Not opened for \(Int(Date().timeIntervalSince(touched) / 86_400)) days").font(.caption).foregroundStyle(.secondary)
            }
            Text(formatBytes(finding.usage.bytes)).fontWeight(.semibold).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

struct ToolRow<Content: View, Action: View>: View {
    let app: String
    let fallback: String
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 12) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: fallback).font(.title2).frame(width: 36, height: 36)
            }
            content
            Spacer()
            action
        }
        .padding(.vertical, 4)
    }
}
