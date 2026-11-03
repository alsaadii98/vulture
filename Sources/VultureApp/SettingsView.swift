// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

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
