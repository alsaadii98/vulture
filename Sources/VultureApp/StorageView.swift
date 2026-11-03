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
        .navigationSubtitle(model.storage.map { "Measured \($0.measuredAt.formatted(.relative(presentation: .named)))" } ?? "")
        .toolbar {
            Button("Measure Again", systemImage: "arrow.clockwise") { Task { await model.measureStorage() } }
                .disabled(model.measuringStorage)
        }
        .task { if model.storage == nil { await model.measureStorage() } }
    }

    private func content(_ report: StorageReport) -> some View {
        let shown = report.categories.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(formatBytes(report.freeBytes)) free").font(.largeTitle.bold())
                    Text("of \(formatBytes(report.totalBytes)) on Macintosh HD").font(.title3).foregroundStyle(.secondary)
                }
                StorageBar(report: report, order: shown.map(\.kind))

                WeeklyChangeCard()

                let cleanable = model.selectedBytes
                if cleanable > 0 {
                    Notice(symbol: "sparkles", text: "\(formatBytes(cleanable)) of this is leftovers you can safely remove.") {
                        Button("Clean Up") { model.section = .clean }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, category in
                        if index > 0 { Divider().padding(.leading, 66) }
                        CategoryRow(category: category, share: report.usedBytes > 0 ? Double(category.bytes) / Double(report.usedBytes) : 0)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

                if !model.snapshots.isEmpty {
                    Notice(symbol: "clock.arrow.circlepath", text: "macOS is keeping \(model.snapshots.count) Time Machine \(model.snapshots.count == 1 ? "copy" : "copies") on this Mac, the newest from \(model.snapshots[0].formatted(date: .abbreviated, time: .shortened)). They're part of System Data, and macOS removes them by itself when space runs low.") {
                        EmptyView()
                    }
                }

                if report.unreadable > 0 && !model.hasFullDiskAccess {
                    Notice(symbol: "lock.shield", text: "Some folders couldn't be measured, so their space is counted under macOS and System Data. Full Disk Access fixes this.") {
                        Button("Open Settings") { openPrivacySettings() }
                    }
                }
            }
            .padding(24)
        }
    }
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
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("\(formatBytes(report.usedBytes)) used, \(formatBytes(report.freeBytes)) free")
        .onAppear { withAnimation(.spring(duration: 0.9)) { grown = true } }
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: StorageReport.Category
    let share: Double

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.kind.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(category.kind.color.gradient, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.kind.title).font(.body.weight(.semibold))
                Text(category.kind.explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(category.bytes)).font(.body.weight(.semibold)).monospacedDigit()
                Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
            action.frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var action: some View {
        switch category.kind {
        case .apps: Button("Review Apps") { model.section = .apps }.buttonStyle(.link)
        case .coding, .appData: Button("Clean Up") { model.section = .clean }.buttonStyle(.link)
        case .media: Button("Open Photos") { open("com.apple.Photos") }.buttonStyle(.link)
        case .documents: Button("Show in Finder") { NSWorkspace.shared.open(model.home.appendingPathComponent("Documents")) }.buttonStyle(.link)
        case .system: SystemDataHelp()
        case .otherFiles: Button("Show in Finder") { NSWorkspace.shared.open(model.home) }.buttonStyle(.link)
        }
    }

    private func open(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { NSWorkspace.shared.open(url) }
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
        case .documents: "Your own files, including mail, messages and iCloud Drive files kept on this Mac. Vulture never removes these unless you ask."
        case .media: "Your Photos library, music and movies."
        case .coding: "Made by Xcode, Docker and package managers. Much of it can be made again."
        case .appData: "Settings, caches and files apps keep for you."
        case .otherFiles: "Anything else in your home folder."
        case .system: "macOS itself, plus things it keeps for itself, like Time Machine copies and memory overflow."
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
        case .apps: .blue
        case .documents: .teal
        case .media: .orange
        case .coding: .purple
        case .appData: .pink
        case .otherFiles: .brown
        case .system: .gray
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Since \(week.since.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                    Spacer()
                    Text(week.freeDelta >= 0 ? "\(formatBytes(week.freeDelta)) more free space" : "\(formatBytes(-week.freeDelta)) less free space")
                        .foregroundStyle(week.freeDelta >= 0 ? Color.green : Color.orange)
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
                    .font(.callout)
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
