// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// What starts by itself, in plain words, with a switch for each of the person's own items.
struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingRemove = false
    @State private var showingAll = false

    private static let collapsedCount = 8

    private var items: [LaunchItem] { model.launchItems ?? [] }
    private var leftBehind: [LaunchItem] { items.filter { $0.scope == .user && $0.isLeftBehind } }
    /// Your own items first, then ones for all users; left-behind ones are handled by the banner.
    private var listed: [LaunchItem] {
        let rest = items.filter { !($0.scope == .user && $0.isLeftBehind) }
        return rest.filter { $0.scope == .user } + rest.filter { $0.scope != .user }
    }
    private var active: [LaunchItem] { items.filter { !$0.disabled && !$0.isLeftBehind } }
    private var shown: [LaunchItem] { showingAll ? listed : Array(listed.prefix(Self.collapsedCount)) }

    var body: some View {
        Screen(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text(subheadline).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !leftBehind.isEmpty {
                Banner(kind: .warning, text: leftBehindText) {
                    Button("Remove Them…") { confirmingRemove = true }.glassButton()
                }
            }
            if model.launchItems != nil {
                if listed.isEmpty {
                    Card { Text("Nothing starts by itself. Your Mac starts with only what macOS needs.").foregroundStyle(.secondary) }
                } else {
                    RowsCard(items: shown) { StartupRow(item: $0) }
                    if listed.count > Self.collapsedCount {
                        Button(showingAll ? "Show Fewer" : "Show All \(listed.count) Items") {
                            withAnimation(.snappy) { showingAll.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
                HStack(spacing: 6) {
                    InfoNote(text: "Items for all users need an administrator. Apps that open a window when you log in are listed in System Settings.")
                    Button("Open Login Items") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .overlay { if model.launchItems == nil { ProgressView("Looking at what starts by itself…") } }
        .navigationTitle("Startup")
        .navigationSubtitle("Apps that start by themselves")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.loadStartup() } }
            }
        }
        .task { if model.launchItems == nil { await model.loadStartup() } }
        .confirmationDialog("Remove \(leftBehind.count) left-behind \(leftBehind.count == 1 ? "item" : "items")?", isPresented: $confirmingRemove) {
            Button("Remove") { Task { await model.removeLeftBehindItems() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're stopped and moved to Recently Removed, where you can put them back for 30 days.")
        }
    }

    private var headline: String {
        guard model.launchItems != nil else { return "Startup" }
        switch active.count {
        case 0: return "Nothing starts by itself"
        case 1: return "1 app starts by itself"
        default: return "\(active.count) apps start by themselves"
        }
    }

    private var subheadline: String {
        let running = active.filter(\.keepsRunning)
        var parts: [String] = []
        if let first = running.first {
            let names = running.prefix(2).map(\.displayName).joined(separator: " and ")
            parts.append(running.count == 1 ? "\(first.displayName) keeps running all the time." :
                running.count == 2 ? "\(names) keep running all the time." : "\(names) and \(running.count - 2) more keep running all the time.")
        }
        parts.append("Turning an app off doesn't delete it.")
        return parts.joined(separator: " ")
    }

    private var leftBehindText: Text {
        let names = leftBehind.prefix(3).map(\.displayName).joined(separator: ", ")
        let count = leftBehind.count
        return Text("**\(count) \(count == 1 ? "helper is" : "helpers are") still set to start from apps you deleted** (\(names)\(count > 3 ? " and more" : "")).")
    }
}

struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem

    private var editable: Bool { item.scope == .user && !item.isLeftBehind }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let url = item.ownerAppURL {
                    AppIcon(path: url.path, size: 36)
                } else {
                    IconTile(symbol: "gearshape.2.fill", color: Theme.gray, size: 32).frame(width: 36, height: 36)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item.plainDescription).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(item.label)
            Spacer(minLength: 12)
            effect.frame(width: 190, alignment: .leading)
            Group {
                if editable {
                    Toggle("Let \(item.displayName) start by itself",
                           isOn: Binding(get: { !item.disabled }, set: { on in Task { await model.setStartup(item, on: on) } }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.tertiary)
                        .help("Set up for all users. Changing it needs an administrator, in System Settings › General › Login Items & Extensions.")
                        .accessibilityLabel("Needs an administrator")
                }
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var effect: some View {
        let (text, color) = item.effect
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }
}

extension LaunchItem {
    var ownerAppURL: URL? {
        if let path = appPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        for id in associatedBundleIDs { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url } }
        return nil
    }

    var displayName: String {
        ownerAppURL?.deletingPathExtension().lastPathComponent
            ?? appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? homebrewName
            ?? label
    }

    /// `homebrew.mxcl.ollama` → "Ollama (Homebrew service)"
    private var homebrewName: String? {
        guard label.hasPrefix("homebrew.mxcl."), let last = label.split(separator: ".").last else { return nil }
        return last.prefix(1).uppercased() + last.dropFirst() + " (Homebrew service)"
    }

    /// What it does, from its launch settings.
    var plainDescription: String {
        if isLeftBehind { return "Its app isn't on this Mac anymore" }
        if keepsRunning { return "Keeps running after you close it" }
        if let s = intervalSeconds { return s >= 3600 ? "Runs every \(s / 3600) hours" : "Runs every \(max(1, s / 60)) minutes" }
        if runsAtLogin { return scope == .allUsersDaemon ? "Starts when your Mac turns on" : "Opens when you turn on your Mac" }
        return "Runs in the background when an app needs it"
    }

    /// A short label with a color, only from facts in its launch settings.
    var effect: (String, Color) {
        if isLeftBehind { return ("Left behind", Theme.red) }
        if disabled { return ("Turned off", .secondary) }
        if keepsRunning { return ("Always running", Theme.orange) }
        if intervalSeconds != nil { return ("Runs on a schedule", Theme.orange) }
        if runsAtLogin { return ("Starts with your Mac", Theme.accentText) }
        return ("Only when needed", Theme.green)
    }
}
