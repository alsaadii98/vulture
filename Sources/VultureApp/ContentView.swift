// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        if didOnboard {
            main.transition(.opacity)
        } else {
            OnboardingView()
        }
    }

    private var main: some View {
        @Bindable var model = model
        return NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.section ?? .home {
                case .home: HomeView()
                case .clean: CleanUpView()
                case .removed: RecentlyRemovedView()
                case .developer: DeveloperView()
                case .apps: AppsView()
                case .storage: StorageView()
                case .startup: StartupView()
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: model.section)
        }
        .task { if model.plan == nil, case .idle = model.phase { await model.scan() } }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showDeveloperFiles") private var showDeveloperFiles = true

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            ForEach([SidebarSection.home, .clean, .apps, .storage, .startup]) { row($0) }
            Divider()
            row(.removed)
            if showDeveloperFiles {
                Section("Extra Tools") { row(.developer) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Macintosh HD").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formatBytes(model.freeBytes)) free").fontWeight(.semibold).monospacedDigit()
                }
                .font(.caption)
                ProgressView(value: model.usedFraction)
                    .accessibilityLabel("\(Int(model.usedFraction * 100)) percent full")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if let badge = badge(section) {
                    Text(badge).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: section.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
        .tag(section)
    }

    private func badge(_ section: SidebarSection) -> String? {
        switch section {
        case .clean where model.selectedBytes > 0: formatBytes(model.selectedBytes)
        case .removed where !model.batches.isEmpty: formatBytes(model.batches.reduce(0) { $0 + $1.bytes })
        default: nil
        }
    }
}

struct ComingSoon: View {
    let section: SidebarSection
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.symbol)
        } description: {
            Text(text)
            Text("Coming in a later version.").foregroundStyle(.tertiary)
        }
        .navigationTitle(section.title)
    }
}

struct SettingsView: View {
    @AppStorage("showDeveloperFiles") private var showDeveloperFiles = true
    @AppStorage("notifyWhenLow") private var notifyWhenLow = true
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = false
    @AppStorage(UpdateModel.autoCheckKey) private var checkForUpdates = true
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        Form {
            Section("Extra Tools in the Sidebar") {
                Toggle("Developer Files", isOn: $showDeveloperFiles)
                Text("Xcode, Docker and code packages.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu Bar") {
                Toggle("Show Vulture in the menu bar", isOn: $showMenuBarMonitor)
                Text("A quick look at CPU, memory and free space, even when the window is closed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Reminders") {
                Toggle("Tell me when there's a lot to clean", isOn: $notifyWhenLow)
            }
            Section("Updates") {
                Toggle("Check for new versions every day", isOn: $checkForUpdates)
                Text("Vulture asks before installing anything. Checking only reads a small file from GitHub. You have version \(updates.currentVersion).")
                    .font(.caption).foregroundStyle(.secondary)
                CheckForUpdatesButton()
            }
            Section {
                Text("Vulture for Mac · Free and open source · Your files never leave this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical)
    }
}
