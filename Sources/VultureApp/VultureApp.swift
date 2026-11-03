// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@main
struct VultureApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var monitor = MonitorModel()
    /// Off unless the person turns it on (Settings › Menu Bar, or first run).
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = false

    var body: some Scene {
        Window("Vulture", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check Again") { Task { await model.scan() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Clean") {
                Button("Clean Up Selected…") {
                    model.section = .clean
                    model.confirmingClean = true
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Open Recently Removed") { model.section = .removed }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBarMonitor) {
            MonitorMenu().environment(monitor)
        } label: {
            MonitorLabel().environment(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from the command line (swift run) there's no app bundle, so ask to be a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Keep running for the menu bar item when it's on; otherwise closing the window quits, like before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBarMonitor")
    }
}
