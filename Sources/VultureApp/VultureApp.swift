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
    @State private var updates = UpdateModel()
    /// Off unless the person turns it on (Settings › Menu Bar, or first run).
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = false

    var body: some Scene {
        Window("Vulture", id: "main") {
            ContentView()
                .environment(model)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 600)
                .task { updates.start() }
                .debugPreviewHook()
                .sheet(isPresented: $updates.prompting) { UpdateSheet().environment(updates) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton().environment(updates)
            }
            CommandGroup(after: .newItem) {
                Button("Scan Again") { Task { await model.scan() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Clean") {
                Button("Scan Again") { Task { await model.scan() } }
                Divider()
                Button("Review Clean Up") { model.section = .clean }
                Button("Clean Up Selected…") {
                    model.section = .clean
                    model.confirmingClean = true
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
                Button("Select All Safe Items") { model.selectAllSafe() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(model.plan == nil)
                Button("Skip Item") { model.skipFocused() }
                    .disabled(model.focusedPath.map { !model.selection.contains($0) } ?? true)
                Divider()
                Button("Show in Finder") { model.revealFocused() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.focusedPath == nil)
                Button("Show in Storage Map") { model.showFocusedInMap() }
                    .keyboardShortcut("d")
                    .disabled(model.focusedPath == nil)
                Divider()
                Button("Open Recently Removed") { model.section = .removed }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Button("Empty Recently Removed…") { model.confirmingEmpty = true }
                    .disabled(model.batches.isEmpty)
                Divider()
                Button("Undo Clean Up") { model.undoLastClean() }
                    .keyboardShortcut("z")
                    .disabled(model.lastCleanBatch == nil)
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(model.visibleSections.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
            }
        }

        Settings {
            SettingsView().environment(updates).environment(model).tint(Theme.accent)
        }

        MenuBarExtra(isInserted: $showMenuBarMonitor) {
            MonitorMenu().environment(monitor).tint(Theme.accent)
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
        #if DEBUG
        DebugPreview.applyAppearance()
        #endif
    }

    /// Keep running for the menu bar item when it's on; otherwise closing the window quits, like before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBarMonitor")
    }
}
