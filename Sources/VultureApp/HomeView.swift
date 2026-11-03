// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// One answer and one button: how full the Mac is, and how much can be freed safely.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen {
            hero
            if !model.hasFullDiskAccess {
                Banner(kind: .warning, symbol: "lock.shield",
                       text: Text("**Vulture can't see everything yet.** Give it Full Disk Access to find more.")) {
                    Button("Open System Settings") { openPrivacySettings() }.glassButton()
                }
            }
            HomeWorthALook()
        }
        .navigationTitle("Home")
        .navigationSubtitle(model.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.scan() } }
                    .labelStyle(.titleAndIcon)
                    .disabled(isBusy)
            }
        }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    private var hero: some View {
        Card(padding: 0) {
            HStack(spacing: 36) {
                ProgressRing(fraction: model.usedFraction) {
                    VStack(spacing: 2) {
                        Text(formatBytes(model.freeBytes))
                            .font(.system(size: 26, weight: .bold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("free of \(formatBytes(model.totalBytes))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Macintosh HD: \(formatBytes(model.freeBytes)) free of \(formatBytes(model.totalBytes))")
                VStack(alignment: .leading, spacing: 12) { heroContent }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 32)
        }
        .animation(.spring(duration: 0.4), value: phaseKey)
    }

    @ViewBuilder private var heroContent: some View {
        switch model.phase {
        case .idle:
            Text("Let's see what's taking up space").font(.system(size: 28, weight: .bold))
            Text("Vulture checks the places where leftover files pile up. Nothing is removed until you say so.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await model.scan() } } label: {
                Label("Check My Mac", systemImage: "magnifyingglass").fontWeight(.semibold)
            }
            .primaryButton()
            .padding(.top, 6)
        case .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your Mac…").font(.system(size: 20, weight: .semibold))
            }
            Text("This usually takes a few seconds.").font(.system(size: 14)).foregroundStyle(.secondary)
        case .ready:
            readyContent
        case .cleaning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Cleaning up…").font(.system(size: 14, weight: .semibold))
            }
            ProgressView().progressViewStyle(.linear).frame(maxWidth: 420)
            Text("You can keep using your Mac while this runs.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .done(let result):
            HomeDoneBanner(result: result)
        }
    }

    @ViewBuilder private var readyContent: some View {
        Label("Your Mac is in good shape", systemImage: "checkmark")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
        if model.selectedBytes > 0 {
            Text("You can free up \(formatBytes(model.selectedBytes))")
                .font(.system(size: 28, weight: .bold))
                .contentTransition(.numericText())
            Text("These are leftover files that apps make again on their own. Your photos, documents and messages are never touched.")
                .font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button {
                    model.section = .clean
                    model.confirmingClean = true
                } label: {
                    Label("Free Up \(formatBytes(model.selectedBytes))", systemImage: "sparkles").fontWeight(.semibold)
                }
                .primaryButton()
                Button("See What's Included") { model.section = .clean }
                    .buttonStyle(.link)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.top, 6)
        } else {
            Text("Nothing to clean up right now").font(.system(size: 28, weight: .bold))
            Text("Vulture checked the places where leftover files usually pile up and found nothing worth removing.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.groups.isEmpty {
                Button("See What Vulture Found") { model.section = .clean }
                    .buttonStyle(.link).fontWeight(.semibold).foregroundStyle(Theme.accentText)
            }
        }
    }

    private var phaseKey: Int {
        switch model.phase {
        case .idle: 0
        case .scanning: 1
        case .ready: 2
        case .cleaning: 3
        case .done: 4
        }
    }
}

/// "All done. You freed 26.4 GB." Honest about what Undo can bring back: only what went to Recently Removed.
struct HomeDoneBanner: View {
    @Environment(AppModel.self) private var model
    let result: CleanupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.window)
                    .frame(width: 30, height: 30)
                    .background(Theme.green, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.system(size: 14, weight: .bold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.lastCleanBatch != nil {
                    Button("Undo") { model.undoLastClean() }.glassButton()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.greenBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            if !result.failures.isEmpty {
                Text("\(result.failures.count) \(result.failures.count == 1 ? "item was" : "items were") left alone because something changed since the check.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Check Again") { Task { await model.scan() } }
                .buttonStyle(.link).fontWeight(.semibold).foregroundStyle(Theme.accentText)
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// Files in Recently Removed still use space until it's emptied, so they aren't counted as freed.
    private var headline: String {
        if result.freedBytes > 0 { return "All done. You freed \(formatBytes(result.freedBytes))." }
        return "All done. \(formatBytes(result.keptBytes)) moved to Recently Removed."
    }

    private var detail: String {
        if result.keptBytes > 0, model.lastCleanBatch != nil {
            if result.freedBytes > 0 {
                return "Changed your mind? \(formatBytes(result.keptBytes)) more is in Recently Removed and can be put back for 30 days."
            }
            return "Changed your mind? Everything can be put back for 30 days."
        }
        return "Apps make these files again when they need them."
    }
}

/// "Also Worth a Look": short tips built only from what Vulture actually found.
struct HomeWorthALook: View {
    @Environment(AppModel.self) private var model

    private struct Tip: Identifiable {
        let id: String
        let icon: AnyView
        let title: String
        let text: String
        let button: String
        let section: SidebarSection
    }

    var body: some View {
        let tips = self.tips
        VStack(alignment: .leading, spacing: 6) {
            Text("Also Worth a Look").font(.system(size: 13, weight: .bold)).padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
                ForEach(tips) { tip in card(tip) }
            }
        }
        .task {
            if model.apps == nil { await model.loadApps() }
            if model.launchItems == nil { await model.loadStartup() }
        }
    }

    private func card(_ tip: Tip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tip.icon.frame(width: 40, height: 40)
            Text(tip.title).font(.system(size: 15, weight: .bold)).padding(.top, 4)
            Text(tip.text).font(.system(size: 13)).lineSpacing(2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(tip.button) { model.section = tip.section }
                .glassButton()
                .padding(.top, 6)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var tips: [Tip] {
        var list: [Tip] = []
        let unused = (model.apps ?? [])
            .filter { !$0.isApple && $0.canRemove && AppModel.isUnused($0) }
            .sorted { $0.bytes > $1.bytes }
        if !unused.isEmpty {
            let names = unused.prefix(2).map(\.name)
            let who: String
            switch unused.count {
            case 1: who = "\(names[0]) hasn't"
            case 2: who = "\(names[0]) and \(names[1]) haven't"
            default: who = "\(names[0]), \(names[1]) and \(unused.count - 2) more haven't"
            }
            let bytes = unused.reduce(0) { $0 + $1.bytes }
            list.append(Tip(id: "apps", icon: AnyView(AppIcon(path: unused[0].path, size: 40)),
                            title: "\(unused.count) \(unused.count == 1 ? "app" : "apps") you don't use",
                            text: "\(who) been opened in over two months. Removing \(unused.count == 1 ? "it" : "them") frees \(formatBytes(bytes)).",
                            button: "Review Apps", section: .apps))
        }
        let items = model.launchItems ?? []
        let leftBehind = items.filter(\.isLeftBehind)
        let starting = items.filter { !$0.disabled && ($0.runsAtLogin || $0.keepsRunning) && !$0.isLeftBehind }
        if !leftBehind.isEmpty {
            list.append(Tip(id: "startup", icon: AnyView(IconTile(symbol: "exclamationmark.triangle.fill", color: Theme.amber, size: 40)),
                            title: "\(leftBehind.count) \(leftBehind.count == 1 ? "helper" : "helpers") from deleted apps",
                            text: "macOS keeps trying to start \(leftBehind.count == 1 ? "it" : "them"), but the app is gone. You can remove \(leftBehind.count == 1 ? "it" : "them") safely.",
                            button: "Manage Startup", section: .startup))
        } else if !starting.isEmpty {
            let withApp = starting.first { $0.appPath != nil }
            let icon: AnyView = withApp.map { AnyView(AppIcon(path: $0.appPath, size: 40)) }
                ?? AnyView(IconTile(symbol: SidebarSection.startup.symbol, color: Theme.pink, size: 40))
            list.append(Tip(id: "startup", icon: icon,
                            title: "\(starting.count) \(starting.count == 1 ? "helper starts" : "helpers start") with your Mac",
                            text: "Turning off the ones you don't need can help your Mac start faster. Turning one off doesn't delete anything.",
                            button: "Manage Startup", section: .startup))
        }
        list.append(Tip(id: "storage", icon: AnyView(IconTile(symbol: SidebarSection.storage.symbol, color: Theme.amber, size: 40)),
                        title: "See what's using space",
                        text: "Apps, photos, downloads and the rest, explained in plain words.",
                        button: "View Storage", section: .storage))
        return list
    }
}

// MARK: - Shared with other screens

/// Older name, still used by other screens.
typealias DoneBanner = HomeDoneBanner

struct Working: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).font(.title3.weight(.semibold))
            }
            Text(detail).foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }
}

struct Notice<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(LocalizedStringKey(text)).frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The one main action on a screen: larger than a toolbar button so it reads as the next step.
struct BigButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(Color.accentColor, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
