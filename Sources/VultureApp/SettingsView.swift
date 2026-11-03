// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import ServiceManagement
import SwiftUI
import VultureCore

/// Settings, in the design's six tabs. Every control changes what Vulture actually does.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, safety, rules, schedule, menuBar, updates
        var id: String { rawValue }
    }

    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            SafetySettings().tabItem { Label("Safety", systemImage: "shield") }.tag(Tab.safety)
            RuleSettings().tabItem { Label("What to Clean", systemImage: "list.bullet") }.tag(Tab.rules)
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }.tag(Tab.schedule)
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "waveform.path.ecg") }.tag(Tab.menuBar)
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(Tab.updates)
        }
        .frame(width: 640, height: 560)
        .onAppear { Preferences.register() }
    }
}

// MARK: - Building blocks

/// A settings page: headed groups of rows on the window background, and the footer.
private struct SettingsPage<Content: View>: View {
    var footer = true
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
                if footer {
                    Text("Vulture for Mac · Free and open source · Your files never leave this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .screenBackground()
    }
}

/// "Extra Tools in the Sidebar" and its rows in one card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).padding(.horizontal, 4)
            VStack(spacing: 0) {
                if #available(macOS 15.0, *) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 14) }
                            row
                        }
                    }
                } else {
                    content
                }
            }
            .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
    }
}

/// A row: title and optional caption on the left, a control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, caption == nil ? 10 : 8)
        .frame(minHeight: 44)
    }
}

private struct ToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, caption: caption) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Preferences.showDeveloperFiles) private var showDeveloperFiles = true
    @AppStorage(Preferences.showStorageMap) private var showStorageMap = false
    @AppStorage(Preferences.notifyWhenLots) private var notifyWhenLots = true
    @AppStorage(Preferences.lowSpaceGB) private var lowSpaceGB = 20
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Extra Tools in the Sidebar") {
                ToggleRow(title: "Developer Files", caption: "Xcode, Docker and code packages.", isOn: $showDeveloperFiles)
                ToggleRow(title: "Storage Map", caption: "A detailed map of every folder, for when you want to dig in.", isOn: $showStorageMap)
            }
            SettingsGroup(title: "Reminders") {
                ToggleRow(title: "Tell me when there’s a lot to clean", caption: "A quiet notification, at most once a week", isOn: $notifyWhenLots)
                SettingRow(title: "Remind me when free space is below") {
                    Picker("Remind me when free space is below", selection: $lowSpaceGB) {
                        Text("Never").tag(0)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsGroup(title: "Startup", note: loginProblem) {
                ToggleRow(title: "Open Vulture when you log in", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
            }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = "macOS didn’t accept this: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            loginProblem = "Turn Vulture on in System Settings › General › Login Items to finish."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Safety

private struct SafetySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.keepDays) private var keepDays = RecentlyRemoved.defaultKeepDays
    @AppStorage(Preferences.emptyEarly) private var emptyEarly = true
    @AppStorage(Preferences.recentDays) private var recentDays = 7
    @AppStorage(Preferences.chooseCheckFirst) private var chooseCheckFirst = true
    @State private var folders = Preferences.neverTouchFolders
    @State private var selectedFolder: URL?
    @State private var hasAccess = false

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Recently Removed") {
                SettingRow(title: "Keep removed items for") {
                    Picker("Keep removed items for", selection: $keepDays) {
                        ForEach([7, 14, 30, 60], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Empty early if the disk is almost full", caption: "Oldest first, only when less than 10 GB is free", isOn: $emptyEarly)
            }
            SettingsGroup(title: "Before Cleaning") {
                SettingRow(title: "Skip files that are open in an app", caption: "Vulture never removes a file while it’s being used") {
                    Label("Always on", systemImage: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                SettingRow(title: "Skip files used in the last",
                           caption: "For things that can’t come back, like downloads. They wait for you to choose them.") {
                    Picker("Skip files used in the last", selection: $recentDays) {
                        Text("Off").tag(0)
                        Text("1 day").tag(1)
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Let me choose “Check first” items myself", caption: "They stay unselected until you pick them", isOn: $chooseCheckFirst)
            }
            SettingsGroup(title: "Never Touch These", note: "Changes apply from the next check.") {
                ForEach(folders, id: \.self) { folder in
                    protectedRow(name: folder.lastPathComponent, detail: "Added by you", symbol: "folder.fill", color: Theme.accent)
                        .background(selectedFolder == folder ? Theme.accent.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFolder = folder }
                        .help(folder.path)
                }
                protectedRow(name: "Your documents, desktop, photos, music and movies", detail: "Always protected", symbol: "doc.fill", color: Theme.blue)
                protectedRow(name: "AI assistant chats and memory", detail: "Always protected", symbol: "sparkles", color: Theme.purple)
                protectedRow(name: "Photos, Mail, Messages and Keychain", detail: "Always protected", symbol: "lock.fill", color: Theme.gray)
                HStack(spacing: 4) {
                    Button { addFolder() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .accessibilityLabel("Add a folder to protect")
                    Button { removeFolder() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .accessibilityLabel("Stop protecting the selected folder")
                        .disabled(selectedFolder == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            SettingsGroup(title: "Permissions") {
                SettingRow(title: "Full Disk Access", caption: "Lets Vulture measure Mail, Messages and other private folders. It never reads what’s inside.") {
                    if hasAccess {
                        Label("Allowed", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.greenBackground, in: Capsule())
                    } else {
                        Button("Open System Settings") { openPrivacySettings() }.glassButton()
                    }
                }
            }
        }
        .onAppear { hasAccess = model.hasFullDiskAccess }
        .onChange(of: keepDays) { model.refreshRemoved() }
    }

    private func protectedRow(name: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 20)
            Text(name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).frame(minHeight: 36)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.home
        panel.prompt = "Protect"
        panel.message = "Vulture will never offer to remove anything in these folders."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url) { folders.append(url) }
        Preferences.neverTouchFolders = folders
    }

    private func removeFolder() {
        guard let selectedFolder else { return }
        folders.removeAll { $0 == selectedFolder }
        self.selectedFolder = nil
        Preferences.neverTouchFolders = folders
    }
}

// MARK: - What to Clean

private struct RuleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var disabled = Preferences.disabledRuleIDs

    var body: some View {
        SettingsPage {
            Text("Turn off anything you’d rather Vulture never offers. Changes apply from the next check.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(Rule.Category.allCases, id: \.self) { category in
                let rules = model.allRules.filter { $0.category == category }
                if !rules.isEmpty {
                    SettingsGroup(title: Self.title(category)) {
                        ForEach(rules, id: \.id) { rule in
                            ToggleRow(title: rule.title, caption: rule.explanation, isOn: Binding(
                                get: { !disabled.contains(rule.id) },
                                set: { on in
                                    if on { disabled.remove(rule.id) } else { disabled.insert(rule.id) }
                                    Preferences.disabledRuleIDs = disabled
                                }))
                        }
                    }
                }
            }
        }
    }

    static func title(_ category: Rule.Category) -> String {
        switch category {
        case .appFiles: "App Files"
        case .logs: "Activity Records"
        case .developer: "Coding Apps"
        case .downloads: "Downloads"
        case .mail: "Mail"
        }
    }
}

// MARK: - Schedule

private struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.autoCheck) private var autoCheck = Preferences.AutoCheck.never.rawValue
    @AppStorage(Preferences.notifyWhenLots) private var notifyWhenLots = true

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Automatic Checks",
                          note: "Checks run while Vulture or its menu bar item is open. Vulture never cleans anything on its own.") {
                SettingRow(title: "Check my Mac automatically") {
                    Picker("Check my Mac automatically", selection: $autoCheck) {
                        ForEach(Preferences.AutoCheck.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Tell me when there’s a lot to clean", caption: "A quiet notification, at most once a week", isOn: $notifyWhenLots)
                SettingRow(title: "Last check") {
                    Text(lastCheck).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: autoCheck) { Task { await model.checkIfScheduled() } }
    }

    private var lastCheck: String {
        guard let date = UserDefaults.standard.object(forKey: Preferences.lastAutoCheck) as? Date else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Menu Bar

private struct MenuBarSettings: View {
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = false
    @AppStorage(Preferences.menuBarStats) private var stats = "cpu"

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Menu Bar") {
                ToggleRow(title: "Show Vulture in the menu bar",
                          caption: "A quick look at your Mac, even when the window is closed. Click it for more.", isOn: $showMenuBarMonitor)
            }
            SettingsGroup(title: "Show Next to the Icon") {
                ForEach(Preferences.MenuStat.allCases) { stat in
                    ToggleRow(title: stat.title, isOn: Binding(
                        get: { Preferences.menuStats.contains(stat) },
                        set: { on in
                            var set = Preferences.menuStats
                            if on { set.insert(stat) } else { set.remove(stat) }
                            Preferences.menuStats = set
                            stats = UserDefaults.standard.string(forKey: Preferences.menuBarStats) ?? ""
                        }))
                }
            }
            .disabled(!showMenuBarMonitor)
            SettingsGroup(title: "Preview") {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                    MonitorLabelPreview(stats: Preferences.menuStats)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent.opacity(showMenuBarMonitor ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 5))
                        .opacity(showMenuBarMonitor ? 1 : 0.4)
                    Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: 36)
                .id(stats)
            }
        }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @AppStorage(UpdateModel.autoCheckKey) private var checkForUpdates = true
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Updates",
                          note: "Vulture asks before installing anything. Checking only reads a small file from GitHub and sends nothing about you.") {
                ToggleRow(title: "Check for new versions every day", isOn: $checkForUpdates)
                SettingRow(title: "Version", caption: "Every update is checked against Vulture’s release key before it’s used.") {
                    Text(updates.currentVersion).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                SettingRow(title: "Look for an update now") {
                    CheckForUpdatesButton().glassButton()
                }
            }
        }
    }
}
