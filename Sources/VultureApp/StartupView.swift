// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// What starts by itself, in plain words, with a switch for each of the person's own items.
struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingRemove = false

    private var items: [LaunchItem] { model.launchItems ?? [] }
    private var yours: [LaunchItem] { items.filter { $0.scope == .user } }
    private var everyone: [LaunchItem] { items.filter { $0.scope != .user } }
    private var leftBehind: [LaunchItem] { yours.filter(\.isLeftBehind) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(items.filter { !$0.disabled && !$0.isLeftBehind }.count) things start by themselves").font(.title.bold())
                    Text("Turning one off doesn't delete anything. It just stops it from starting on its own, and you can turn it back on here.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if !leftBehind.isEmpty {
                Section {
                    Notice(symbol: "exclamationmark.triangle", text: "**\(leftBehind.count) left behind by apps you removed.** macOS keeps trying to start them, but their app is gone.") {
                        Button("Remove Them…") { confirmingRemove = true }
                    }
                }
            }
            Section("Yours") {
                if yours.isEmpty { Text("Nothing of yours starts by itself.").foregroundStyle(.secondary) }
                ForEach(yours) { StartupRow(item: $0, editable: true) }
            }
            if !everyone.isEmpty {
                Section {
                    ForEach(everyone) { StartupRow(item: $0, editable: false) }
                } header: {
                    Text("For All Users")
                } footer: {
                    Text("Changing these needs an administrator. Turn them off in System Settings › General › Login Items & Extensions.")
                }
            }
            Section {
                HStack {
                    Text("Apps that open their window when you log in are listed in System Settings.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
            }
        }
        .overlay { if model.launchItems == nil { ProgressView() } }
        .navigationTitle("Startup")
        .navigationSubtitle("Apps and helpers that start by themselves")
        .toolbar {
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.loadStartup() } }
        }
        .task { if model.launchItems == nil { await model.loadStartup() } }
        .confirmationDialog("Remove \(leftBehind.count) left-behind items?", isPresented: $confirmingRemove) {
            Button("Remove") { Task { await model.removeLeftBehindItems() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're stopped and moved to Recently Removed, where you can put them back for 30 days.")
        }
    }
}

struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    let editable: Bool

    private var appURL: URL? {
        if let path = item.appPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        for id in item.associatedBundleIDs { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url } }
        return nil
    }

    private var name: String {
        appURL?.deletingPathExtension().lastPathComponent
            ?? item.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? homebrewName
            ?? item.label
    }

    /// `homebrew.mxcl.ollama` → "Ollama (Homebrew service)"
    private var homebrewName: String? {
        guard item.label.hasPrefix("homebrew.mxcl."), let last = item.label.split(separator: ".").last else { return nil }
        return last.prefix(1).uppercased() + last.dropFirst() + " (Homebrew service)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable()
                } else {
                    Image(systemName: "gearshape.2").font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(item.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            effect
            if editable && !item.isLeftBehind {
                Toggle("Let \(name) start by itself", isOn: Binding(get: { !item.disabled }, set: { on in Task { await model.setStartup(item, on: on) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var effect: some View {
        let (text, color): (String, Color) = {
            if item.isLeftBehind { return ("Left behind", .red) }
            if item.disabled { return ("Turned off", .secondary) }
            if item.keepsRunning { return ("Always running", .orange) }
            if let s = item.intervalSeconds { return (s >= 3600 ? "Runs every \(s / 3600) h" : "Runs every \(max(1, s / 60)) min", .orange) }
            if item.runsAtLogin { return ("Starts when you log in", .secondary) }
            return ("Starts when needed", .green)
        }()
        Label(text, systemImage: "circle.fill")
            .labelStyle(EffectLabelStyle(color: color))
            .font(.callout)
    }
}

struct EffectLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title.foregroundStyle(color == .secondary ? Color.secondary : color)
        }
    }
}
