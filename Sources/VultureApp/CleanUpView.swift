// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Two groups: Recommended (selected) and You Decide (not selected), plus what was left alone and why.
struct CleanUpView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSkipped = false

    var body: some View {
        @Bindable var model = model
        Screen(spacing: 20) {
            switch model.phase {
            case .cleaning:
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Cleaning up…").font(.system(size: 14, weight: .semibold))
                        }
                        ProgressView().progressViewStyle(.linear).frame(maxWidth: 420)
                        Text("You can keep using your Mac while this runs.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            case .done(let result):
                HomeDoneBanner(result: result)
            default:
                EmptyView()
            }
            if case .scanning = model.phase, model.plan == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking your Mac…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else if model.plan != nil, offered.isEmpty {
                ContentUnavailableView("Nothing to clean up", systemImage: "checkmark.circle",
                                       description: Text("Vulture didn't find anything worth removing."))
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if model.plan == nil, !isDone {
                ContentUnavailableView {
                    Label("Not checked yet", systemImage: "magnifyingglass")
                } description: {
                    Text("Check your Mac to see what can be cleaned up.")
                } actions: {
                    Button("Check My Mac") { Task { await model.scan() } }.primaryButton()
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
            group("Recommended", note: "Safe to remove. Apps make these again when needed.", color: Theme.green, status: .recommended)
            group("You Decide", note: "Not selected. Have a look first.", color: Theme.orange, status: .youDecide)
            if model.plan != nil, !offered.isEmpty { footer }
        }
        .navigationTitle("Clean Up")
        .navigationSubtitle(model.selectedBytes > 0 ? "\(formatBytes(model.selectedBytes)) selected" : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.selectedBytes > 0 ? "Clean Up \(formatBytes(model.selectedBytes))" : "Clean Up") { model.confirmingClean = true }
                    .cleanUpProminent()
                    .disabled(model.selection.isEmpty || isCleaning)
            }
        }
        .confirmationDialog("Clean up \(formatBytes(model.selectedBytes))?", isPresented: $model.confirmingClean) {
            Button("Clean Up") {
                model.section = .home
                Task { await model.clean() }
            }
            .disabled(model.selection.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var isCleaning: Bool {
        if case .cleaning = model.phase { return true }
        return false
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    /// Groups with something on offer.
    private var offered: [CleanupPlan.Group] {
        model.groups.filter { $0.findings.contains { $0.status != .skipped } }
    }

    private var confirmMessage: String {
        let split = model.selectedSplit
        var parts: [String] = []
        if split.now > 0 { parts.append("\(formatBytes(split.now)) is freed right away. Apps make these files again when they need them.") }
        if split.kept > 0 { parts.append("\(formatBytes(split.kept)) goes to Recently Removed, where you can put it back for 30 days.") }
        return parts.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func group(_ title: String, note: String, color: Color, status: Finding.Status) -> some View {
        let items = model.groups
            .filter { $0.findings.contains { $0.status == status } }
            .map { CleanRowItem(group: $0, status: status) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: title, note: note, color: color)
                RowsCard(items: items, dividerInset: 16) { CleanRuleRow(item: $0) }
            }
        }
    }

    private var skipped: [(rule: Rule, finding: Finding)] {
        model.groups.flatMap { g in g.findings.filter { $0.status == .skipped }.map { (g.rule, $0) } }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoNote(symbol: "checkmark.shield",
                     text: "Files apps make again are removed right away, so you get the space now. Anything else goes to Recently Removed for 30 days, so you can put it back.")
            let skipped = self.skipped
            if !skipped.isEmpty {
                HStack(spacing: 6) {
                    InfoNote(text: "\(skipped.count) \(skipped.count == 1 ? "thing was" : "things were") left alone for now.")
                    Button("Show") { showingSkipped = true }
                        .buttonStyle(.link)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accentText)
                        .popover(isPresented: $showingSkipped, arrowEdge: .bottom) {
                            CleanSkippedList(items: skipped)
                        }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// One rule in one section, as a row.
struct CleanRowItem: Identifiable {
    let group: CleanupPlan.Group
    let status: Finding.Status
    var id: String { group.rule.id + "|" + status.rawValue }
    var findings: [Finding] { group.findings.filter { $0.status == status } }
}

struct CleanRuleRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanRowItem
    @State private var showingItems = false

    private var isOn: Bool { item.findings.allSatisfy { model.selection.contains($0.path) } }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Include \(item.group.rule.title)", isOn: Binding(get: { isOn }, set: { model.toggle(item.group, on: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            RuleIcon(rule: item.group.rule)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.group.rule.title).font(.system(size: 14, weight: .semibold))
                Text(item.group.rule.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if item.findings.contains(where: { $0.fillsQuickly == true }) {
                    Label("Filled up again within two days last time, so cleaning it only helps briefly.", systemImage: "arrow.clockwise")
                        .font(.system(size: 12)).foregroundStyle(Theme.orange)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: model.bytes(of: item.findings))
                if item.findings.count > 1 {
                    Text("\(item.findings.count) items").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button { showingItems = true } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show what's in \(item.group.rule.title)")
            .popover(isPresented: $showingItems, arrowEdge: .trailing) {
                CleanItemsList(rule: item.group.rule, findings: item.findings)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedPath = item.findings.first?.path
            model.toggle(item.group, on: !isOn)
        }
    }
}

/// What a rule found, one line per folder or file.
struct CleanItemsList: View {
    let rule: Rule
    let findings: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rule.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(findings.sorted { $0.usage.bytes > $1.usage.bytes }, id: \.path) { finding in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: finding.path))
                                .resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                            Text(tildePath(finding.path)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(formatBytes(finding.usage.bytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                            .accessibilityLabel("Show \(URL(fileURLWithPath: finding.path).lastPathComponent) in Finder")
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// Why some things weren't offered.
struct CleanSkippedList: View {
    let items: [(rule: Rule, finding: Finding)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Left Alone for Now").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.finding.path) { rule, finding in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.title).font(.system(size: 13, weight: .semibold))
                                Text(reason(finding)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func reason(_ f: Finding) -> String {
        switch f.skipReason {
        case .appRunning:
            let name = f.blockingApp.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName } ?? f.blockingApp ?? "an app"
            return "\(name) is open. Quit it and check again."
        case .symbolicLink: return "It's a link to somewhere else."
        case .protected: return "It's in a place Vulture never touches."
        default: return "It's outside your home folder."
        }
    }
}

/// `~/Library/Caches/…` instead of the full path.
func tildePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

extension View {
    /// The filled toolbar button for the screen's main action.
    @ViewBuilder
    func cleanUpProminent() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// The owning app's real icon when the rule names one, otherwise a symbol for its kind.
struct RuleIcon: View {
    let rule: Rule

    var body: some View {
        Group {
            if let id = rule.closeFirst.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                IconTile(symbol: symbol, color: tint, size: 32)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch rule.category {
        case .appFiles: "square.stack.3d.up.fill"
        case .logs: "doc.text.fill"
        case .developer: "hammer.fill"
        case .downloads: "arrow.down.circle.fill"
        case .mail: "paperclip"
        }
    }

    private var tint: Color {
        switch rule.category {
        case .appFiles: Theme.blue
        case .logs: Theme.gray
        case .developer: Theme.teal
        case .downloads: Theme.amber
        case .mail: Theme.purple
        }
    }
}
