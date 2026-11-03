// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// What's using space, in the same words people use, with one next step per category.
struct StorageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let report = model.storage {
                content(report)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Measuring your Mac…").font(.title3.weight(.semibold))
                    Text("The first time can take up to a minute.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Storage")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.measureStorage() } }
                    .disabled(model.measuringStorage)
            }
        }
        .task { if model.storage == nil { await model.measureStorage() } }
    }

    private var subtitle: String {
        if model.measuringStorage, model.storage != nil { return "Checking…" }
        return model.storage.map { "Checked \($0.measuredAt.formatted(.relative(presentation: .named)))" } ?? ""
    }

    private func content(_ report: StorageReport) -> some View {
        let shown = report.categories.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        return Screen(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(formatBytes(report.freeBytes)) free").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text("of \(formatBytes(report.totalBytes)) on Macintosh HD").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                StorageBar(report: report, order: shown.map(\.kind))
            }

            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { StorageDivider() }
                    if category.kind == .system {
                        SystemDataRow(category: category, report: report)
                    } else {
                        CategoryRow(category: category)
                    }
                }
                if model.selectedBytes > 0 {
                    StorageDivider()
                    LeftoversRow(bytes: model.selectedBytes)
                }
            }
            .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            WeeklyChangeCard()
        }
    }
}

private struct StorageDivider: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 0.5) }
}

struct StorageBar: View {
    let report: StorageReport
    let order: [StorageReport.Kind]
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(order, id: \.self) { kind in
                    Rectangle().fill(kind.color)
                        .frame(width: max(2, geo.size.width * Double(report.bytes(kind)) / Double(max(report.totalBytes, 1)) - 2))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
            .background(Theme.track)
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("\(formatBytes(report.usedBytes)) used, \(formatBytes(report.freeBytes)) free")
        .onAppear { withAnimation(.spring(duration: 0.9)) { grown = true } }
    }
}

/// One row of the design's storage table: icon, colored dot and name, explanation, size, next step.
private struct StorageRowLayout<Action: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let explanation: String
    let size: String?
    var chevron: Bool? = nil
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 36).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let chevron {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(chevron ? 0 : -90))
                            .accessibilityHidden(true)
                    }
                }
                Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(size ?? "").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            action
                .buttonStyle(.link)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 170, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: StorageReport.Category

    var body: some View {
        StorageRowLayout(symbol: category.kind.symbol, color: category.kind.color, title: category.kind.title,
                         explanation: category.kind.explanation, size: formatBytes(category.bytes)) {
            action
        }
    }

    @ViewBuilder private var action: some View {
        switch category.kind {
        case .apps: Button("Review Apps") { model.section = .apps }
        case .coding:
            Button("Review") {
                let devOn = UserDefaults.standard.object(forKey: "showDeveloperFiles") as? Bool ?? true
                model.section = devOn ? .developer : .clean
            }
        case .appData: Button("Clean Up") { model.section = .clean }
        case .media: Button("Open Photos") { openApp("com.apple.Photos") }
        case .documents: Button("Show Largest Files") { showInMap(model.home) }
        case .otherFiles: Button("Show in Finder") { NSWorkspace.shared.open(model.home) }
        case .system: EmptyView()
        }
    }

    private func showInMap(_ folder: URL) {
        UserDefaults.standard.set(true, forKey: "showStorageMap")
        model.mapFolder = folder
        model.section = .storageMap
    }

    private func openApp(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { NSWorkspace.shared.open(url) }
    }
}

/// "macOS and System Data", opening to show what Vulture actually knows about it.
struct SystemDataRow: View {
    @Environment(AppModel.self) private var model
    let category: StorageReport.Category
    let report: StorageReport
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            StorageRowLayout(symbol: category.kind.symbol, color: category.kind.color, title: category.kind.title,
                             explanation: expanded ? "Things macOS keeps for itself. Here's what Vulture can tell:" : category.kind.explanation,
                             size: formatBytes(category.bytes), chevron: expanded) {
                SystemDataHelp()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Hides what's inside" : "Shows what's inside")
            .accessibilityAction { withAnimation(.snappy) { expanded.toggle() } }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(subRows) { row in
                        StorageDivider().padding(.leading, 70)
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.system(size: 13))
                                Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Group {
                                if let action = row.action {
                                    Button(action.title, action: action.run)
                                        .buttonStyle(.link)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .frame(width: 170, alignment: .trailing)
                        }
                        .padding(.leading, 70)
                        .padding(.trailing, 16)
                        .padding(.vertical, 10)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private struct SubRow: Identifiable {
        struct Action { let title: String; let run: () -> Void }
        let id: String
        let title: String
        let detail: String
        var action: Action? = nil
    }

    private var subRows: [SubRow] {
        var rows: [SubRow] = []
        if let newest = model.snapshots.first {
            let count = model.snapshots.count
            rows.append(SubRow(id: "tm", title: "Time Machine copies",
                               detail: "\(count) \(count == 1 ? "copy" : "copies"), the newest from \(newest.formatted(date: .abbreviated, time: .shortened)). macOS removes these by itself when space runs low."))
        }
        if report.unreadable > 0 && !model.hasFullDiskAccess {
            rows.append(SubRow(id: "unreadable", title: "Folders Vulture couldn't measure",
                               detail: "\(report.unreadable) \(report.unreadable == 1 ? "folder is" : "folders are") counted here for now. With Full Disk Access, Vulture puts them where they belong.",
                               action: .init(title: "Open Settings") { openPrivacySettings() }))
        }
        rows.append(SubRow(id: "swap", title: "Memory overflow and downloaded updates",
                           detail: "macOS clears these by itself. Restarting your Mac often makes System Data smaller."))
        rows.append(SubRow(id: "macos", title: "Files macOS and apps need",
                           detail: "Leave these alone. macOS manages them."))
        return rows
    }
}

/// Leftovers Clean Up found, already counted in the categories above.
private struct LeftoversRow: View {
    @Environment(AppModel.self) private var model
    let bytes: Int64

    var body: some View {
        StorageRowLayout(symbol: "sparkles", color: Theme.mint, title: "Leftovers you can remove",
                         explanation: "Part of the space above: temporary files and things apps make again.",
                         size: formatBytes(bytes)) {
            Button("Clean Up") { model.section = .clean }
        }
    }
}

extension StorageReport.Kind {
    var title: String {
        switch self {
        case .apps: "Apps"
        case .documents: "Documents and downloads"
        case .media: "Photos, music and videos"
        case .coding: "Coding apps' files"
        case .appData: "App data"
        case .otherFiles: "Other files in your home folder"
        case .system: "macOS and System Data"
        }
    }

    var explanation: String {
        switch self {
        case .apps: "Everything in your Applications folder."
        case .documents: "Your own files. Vulture never removes these unless you ask."
        case .media: "Your Photos library, music and movies."
        case .coding: "Made by Xcode, Docker and package managers. Much of it can be made again."
        case .appData: "Settings, caches and files apps keep for you."
        case .otherFiles: "Anything else in your home folder."
        case .system: "macOS itself, plus things it keeps for itself."
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2.fill"
        case .documents: "doc.fill"
        case .media: "photo.fill"
        case .coding: "hammer.fill"
        case .appData: "shippingbox.fill"
        case .otherFiles: "folder.fill"
        case .system: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .apps: Theme.blue
        case .documents: Theme.teal
        case .media: Theme.amber
        case .coding: Theme.purple
        case .appData: Theme.pink
        case .otherFiles: Color(light: 0xA2845E, dark: 0xAC8E68)
        case .system: Theme.gray
        }
    }
}

struct SystemDataHelp: View {
    @State private var showing = false

    var body: some View {
        Button("What's This?") { showing = true }
            .buttonStyle(.link)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS and System Data").font(.headline)
                    Text("This is macOS itself plus things it keeps for its own use: hourly Time Machine copies when your backup drive isn't connected, memory overflow files, downloaded updates, and files in places apps keep private.")
                    Text("macOS removes Time Machine copies and memory overflow by itself when space runs low. A restart often makes this smaller.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(width: 320)
                .padding()
            }
    }
}

/// "What ate my space this week?" — the biggest changes since a week ago, once there's a week of history.
struct WeeklyChangeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let week = model.weeklyChange, !week.changes.isEmpty {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Since \(week.since.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text(week.freeDelta >= 0 ? "\(formatBytes(week.freeDelta)) more free space" : "\(formatBytes(-week.freeDelta)) less free space")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(week.freeDelta >= 0 ? Theme.green : Theme.orange)
                    }
                    ForEach(week.changes.prefix(4), id: \.kind) { change in
                        HStack {
                            Circle().fill(change.kind.color).frame(width: 8, height: 8)
                            Text(change.kind.title)
                            Spacer()
                            Text("\(change.delta >= 0 ? "+" : "−")\(formatBytes(abs(change.delta)))")
                                .monospacedDigit()
                                .foregroundStyle(change.delta > 0 ? .primary : .secondary)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
        }
    }
}
