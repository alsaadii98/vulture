// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// One list in two groups: Recommended (selected) and You Decide (not selected), plus what was left alone.
struct CleanUpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            if case .done(let result) = model.phase {
                DoneBanner(result: result).padding(.vertical, 8)
            }
            groupSection("Recommended", note: "Safe to remove. Apps make these again when needed.", color: .green, status: .recommended)
            groupSection("You Decide", note: "Not selected. Have a look first.", color: .orange, status: .youDecide)
            skippedSection
            Section {
                Label("Files apps make again are removed right away, so you get the space now. Anything that can't come back goes to Recently Removed for 30 days.",
                      systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if case .scanning = model.phase, model.plan == nil {
                ProgressView("Checking your Mac…")
            } else if model.plan != nil, model.groups.isEmpty {
                ContentUnavailableView("Nothing to clean up", systemImage: "checkmark.circle", description: Text("Vulture didn't find anything worth removing."))
            }
        }
        .navigationTitle("Clean Up")
        .navigationSubtitle(model.selectedBytes > 0 ? "\(formatBytes(model.selectedBytes)) selected" : "")
        .toolbar {
            Button("Clean Up \(formatBytes(model.selectedBytes))") { model.confirmingClean = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || isCleaning)
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

    private var confirmMessage: String {
        let split = model.selectedSplit
        var parts: [String] = []
        if split.now > 0 { parts.append("\(formatBytes(split.now)) is freed right away. Apps make these files again when they need them.") }
        if split.kept > 0 { parts.append("\(formatBytes(split.kept)) goes to Recently Removed, where you can put it back for 30 days.") }
        return parts.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func groupSection(_ title: String, note: String, color: Color, status: Finding.Status) -> some View {
        let groups = model.groups.filter { $0.findings.contains { $0.status == status } }
        if !groups.isEmpty {
            Section {
                ForEach(groups, id: \.rule.id) { RuleRow(group: $0, status: status) }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).foregroundStyle(color)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var skippedSection: some View {
        let skipped = model.groups.flatMap { g in g.findings.filter { $0.status == .skipped }.map { (g.rule, $0) } }
        if !skipped.isEmpty {
            Section("Left Alone for Now") {
                ForEach(skipped, id: \.1.path) { rule, finding in
                    Label {
                        Text("\(rule.title): \(reason(finding))").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reason(_ f: Finding) -> String {
        switch f.skipReason {
        case .appRunning:
            let name = f.blockingApp.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName } ?? f.blockingApp ?? "an app"
            return "\(name) is open"
        case .symbolicLink: return "it's a link to somewhere else"
        default: return "it's outside your home folder"
        }
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let group: CleanupPlan.Group
    let status: Finding.Status

    private var items: [Finding] { group.findings.filter { $0.status == status } }
    private var isOn: Bool { items.allSatisfy { model.selection.contains($0.path) } }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Include \(group.rule.title)", isOn: Binding(get: { isOn }, set: { model.toggle(group, on: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            RuleIcon(rule: group.rule)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.rule.title).font(.body.weight(.semibold))
                Text(group.rule.explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(model.bytes(of: items))).font(.body.weight(.semibold)).monospacedDigit()
                if items.count > 1 { Text("\(items.count) items").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(group, on: !isOn) }
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
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch rule.category {
        case .appFiles: "square.stack.3d.up"
        case .logs: "doc.text"
        case .developer: "hammer"
        case .downloads: "arrow.down.circle"
        case .mail: "paperclip"
        }
    }

    private var tint: Color {
        switch rule.category {
        case .appFiles: .blue
        case .logs: .gray
        case .developer: .indigo
        case .downloads: .teal
        case .mail: .cyan
        }
    }
}
