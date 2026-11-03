// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Pick apps by their icon and remove them together with everything they keep, in one step you can undo.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetails = false
    @State private var showingLeftovers = false
    @State private var confirming = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let busy = model.appsBusy { Working(text: busy, detail: "") }
                    if let done = model.lastAppsResult {
                        Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if !model.leftovers.isEmpty {
                        Notice(symbol: "trash", text: "**\(model.leftovers.count) apps you already deleted left \(formatBytes(model.leftovers.reduce(0) { $0 + $1.bytes })) behind.** Dragging an app to the Trash doesn't remove its settings and helpers.") {
                            Button("Review Leftovers") { showingLeftovers = true }
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.visibleApps) { AppTile(app: $0) }
                    }
                }
                .padding(24)
            }
            .overlay {
                if model.apps == nil { ProgressView("Finding your apps…") }
                else if model.visibleApps.isEmpty { ContentUnavailableView.search(text: model.appSearch) }
            }
            if !model.appSelection.isEmpty { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.3), value: model.appSelection.isEmpty)
        .navigationTitle("Apps")
        .navigationSubtitle(model.apps.map { "\($0.filter { !$0.isApple }.count) apps on this Mac" } ?? "")
        .searchable(text: $model.appSearch, placement: .toolbar, prompt: "Search Apps")
        .toolbar {
            Picker("Show", selection: $model.appFilter) {
                ForEach(AppModel.AppFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        .task { if model.apps == nil { await model.loadApps() } }
        .sheet(isPresented: $showingDetails) { RemovalDetails() }
        .sheet(isPresented: $showingLeftovers) { LeftoversSheet() }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Remove") { Task { await model.removeSelectedApps() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They move to Recently Removed with the files they keep, so you can put them back for 30 days. The space is freed when Recently Removed is emptied.")
        }
    }

    private var confirmTitle: String {
        let apps = model.selectedApps
        return apps.count == 1 ? "Remove \(apps[0].name)?" : "Remove \(apps.count) apps?"
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(model.selectedApps.prefix(4)) { app in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 32, height: 32)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.selectedApps.count) \(model.selectedApps.count == 1 ? "app" : "apps") selected · \(formatBytes(model.appRemovalBytes))")
                    .font(.body.weight(.semibold))
                Text("Includes the settings and helpers they keep. You can put them back for 30 days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("See What Will Be Removed") { showingDetails = true }.buttonStyle(.link)
            Button(model.selectedApps.count == 1 ? "Remove \(model.selectedApps[0].name)…" : "Remove \(model.selectedApps.count) Apps…") { confirming = true }
                .buttonStyle(BigButtonStyle())
                .disabled(model.appsBusy != nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding([.horizontal, .bottom], 16)
    }
}

struct AppTile: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp

    private var selected: Bool { model.appSelection.contains(app.path) }

    var body: some View {
        Button { if app.canRemove { model.toggleApp(app) } } label: {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 60, height: 60)
                Text(app.name).font(.callout.weight(.semibold)).lineLimit(1).padding(.top, 4)
                Text(formatBytes(app.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                usage
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Color.accentColor).padding(8)
                } else if !app.canRemove {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).padding(10)
                        .help("Installed for all users. Removing it needs an administrator: drag it to the Trash in Finder.")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(app.name), \(formatBytes(app.bytes))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var usage: some View {
        if AppModel.isUnused(app) {
            Text(app.lastUsed.map { "Not used in \(max(2, Int(Date().timeIntervalSince($0) / 86_400 / 30))) months" } ?? "No sign of use")
                .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        } else if let used = app.lastUsed {
            Text("Used \(used.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Everything that goes with each selected app, with a checkbox per file. Files named exactly after the app start ticked.
struct RemovalDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.selectedApps) { app in
                    Section {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                            Text("The app itself")
                            Spacer()
                            Text(formatBytes(app.bytes)).monospacedDigit()
                        }
                        ForEach(model.appFiles[app.path] ?? []) { file in
                            Toggle(isOn: Binding(get: { model.appFileSelection.contains(file.path) },
                                                 set: { if $0 { model.appFileSelection.insert(file.path) } else { model.appFileSelection.remove(file.path) } })) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.kind.title)
                                        Text(file.path.replacingOccurrences(of: model.home.path, with: "~")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !file.certain {
                                        Text("Check first").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(formatBytes(file.usage.bytes)).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    } header: {
                        Text(app.name)
                    }
                }
            }
            HStack {
                Text("“Check first” items are named like the app, but might belong to something else.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 480)
    }
}

struct LeftoversSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text("These apps aren't on this Mac anymore, but some of their files are. Look through them: some may belong to tools that aren't apps.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.leftovers) { group in
                    let paths = Set(group.files.map(\.path))
                    Toggle(isOn: Binding(get: { paths.isSubset(of: model.leftoverSelection) },
                                         set: { if $0 { model.leftoverSelection.formUnion(paths) } else { model.leftoverSelection.subtract(paths) } })) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.displayName).fontWeight(.semibold)
                                Text("\(group.bundleID) · \(group.files.count) \(group.files.count == 1 ? "item" : "items")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let last = group.lastChanged {
                                Text("Last changed \(last.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(formatBytes(group.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Move \(formatBytes(selectedBytes)) to Recently Removed") {
                    dismiss()
                    Task { await model.cleanLeftovers() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.leftoverSelection.isEmpty)
            }
            .padding()
        }
        .frame(width: 680, height: 520)
    }

    private var selectedBytes: Int64 {
        model.leftovers.flatMap(\.files).filter { model.leftoverSelection.contains($0.path) }.reduce(0) { $0 + $1.usage.bytes }
    }
}

extension AppFile.Kind {
    var title: String {
        switch self {
        case .appData: "App data"
        case .temporaryFiles: "Temporary files"
        case .settings: "Settings"
        case .savedWindows: "Saved windows"
        case .webData: "Website data"
        case .logs: "Activity records"
        case .background: "Runs in the background"
        case .container: "App's private folder"
        case .shared: "Shared with the maker's other apps"
        }
    }
}
