// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Like the Trash, with a Put Back button on every clean-up.
struct RecentlyRemovedView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingEmpty = false

    var body: some View {
        List {
            Section {
                Label("Things Vulture removes that can't come back on their own wait here for 30 days. Put something back and it returns to exactly where it was.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.batches) { BatchRow(batch: $0) }
        }
        .overlay {
            if model.batches.isEmpty {
                ContentUnavailableView("Recently Removed is empty", systemImage: "arrow.uturn.backward",
                                       description: Text("Installers, old downloads and other things that can't come back are kept here for 30 days after a clean-up."))
            }
        }
        .navigationTitle("Recently Removed")
        .navigationSubtitle(model.batches.isEmpty ? "" : formatBytes(model.batches.reduce(0) { $0 + $1.bytes }))
        .toolbar {
            Button("Empty Now…", role: .destructive) { confirmingEmpty = true }
                .disabled(model.batches.isEmpty)
        }
        .confirmationDialog("Remove everything in Recently Removed for good?", isPresented: $confirmingEmpty) {
            Button("Empty Now", role: .destructive) { model.emptyRecentlyRemoved() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(formatBytes(model.batches.reduce(0) { $0 + $1.bytes })). You can't undo it.")
        }
        .onAppear { model.refreshRemoved() }
    }
}

struct BatchRow: View {
    @Environment(AppModel.self) private var model
    let batch: RemovedBatch

    private var daysLeft: Int {
        max(0, Int(ceil(batch.expires(after: model.store.keepDays).timeIntervalSinceNow / 86_400)))
    }

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text("\(batch.removedAt.formatted(date: .abbreviated, time: .shortened)) · \(batch.items.count) \(batch.items.count == 1 ? "item" : "items")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(daysLeft) days left").font(.caption).foregroundStyle(daysLeft <= 3 ? .red : .secondary)
                ProgressView(value: Double(daysLeft), total: Double(model.store.keepDays))
                    .tint(daysLeft <= 3 ? .red : daysLeft <= 15 ? .orange : .green)
                    .frame(width: 140)
            }
            Text(formatBytes(batch.bytes)).font(.body.weight(.semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button("Put Back") { model.putBack(batch.id) }
        }
        .padding(.vertical, 6)
    }

    /// A single item reads better by its own name than as "Clean-up".
    private var title: String {
        batch.items.count == 1 ? URL(fileURLWithPath: batch.items[0].originalPath).lastPathComponent : batch.title
    }

    private var icon: some View {
        let path = batch.items.count == 1
            ? model.store.root.appendingPathComponent(batch.id).appendingPathComponent("\(batch.items[0].id)")
                .appendingPathComponent(URL(fileURLWithPath: batch.items[0].originalPath).lastPathComponent).path
            : "/System/Library/CoreServices/Finder.app"
        return Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}
