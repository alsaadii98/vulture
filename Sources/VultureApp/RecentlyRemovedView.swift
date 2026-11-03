// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// Like the Trash, with a Put Back button on every clean-up.
struct RecentlyRemovedView: View {
    @Environment(AppModel.self) private var model

    private var total: Int64 { model.batches.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        @Bindable var model = model
        Screen(spacing: 16) {
            InfoNote(text: "Everything Vulture removes that can't come back on its own waits here for \(model.store.keepDays) days, like the Trash. Put something back and it returns to exactly where it was.",
                     color: .secondary)
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 4)
            if model.batches.isEmpty {
                ContentUnavailableView("Recently Removed is empty", systemImage: "arrow.uturn.backward",
                                       description: Text("Installers, old downloads and other things that can't come back are kept here for \(model.store.keepDays) days after a clean-up."))
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                RowsCard(items: model.batches, dividerInset: 16) { RemovedBatchRow(batch: $0) }
            }
        }
        .navigationTitle("Recently Removed")
        .navigationSubtitle(model.batches.isEmpty ? "" : formatBytes(total))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty Now…", role: .destructive) { model.confirmingEmpty = true }
                    .foregroundStyle(Theme.red)
                    .disabled(model.batches.isEmpty)
            }
        }
        .confirmationDialog("Remove everything in Recently Removed for good?", isPresented: $model.confirmingEmpty) {
            Button("Empty Now", role: .destructive) { model.emptyRecentlyRemoved() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(formatBytes(total)). You can't undo it.")
        }
        .onAppear { model.refreshRemoved() }
    }
}

struct RemovedBatchRow: View {
    @Environment(AppModel.self) private var model
    let batch: RemovedBatch

    private var daysLeft: Int {
        max(0, Int(ceil(batch.expires(after: model.store.keepDays).timeIntervalSinceNow / 86_400)))
    }

    private var color: Color {
        daysLeft <= 3 ? Theme.red : daysLeft <= 14 ? Theme.orange : Theme.green
    }

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(daysLeft == 1 ? "1 day left" : "\(daysLeft) days left")
                    .font(.system(size: 12))
                    .foregroundStyle(daysLeft > 14 ? Color.secondary : color)
                ThinBar(fraction: Double(daysLeft) / Double(max(1, model.store.keepDays)), color: color, height: 4)
            }
            .frame(width: 170)
            .accessibilityElement(children: .combine)
            SizeText(bytes: batch.bytes)
                .frame(width: 84, alignment: .trailing)
            Button("Put Back") { model.putBack(batch.id) }
                .glassButton()
                .accessibilityLabel("Put back \(title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// A single item reads better by its own name than as "Clean-up".
    private var title: String {
        batch.items.count == 1 ? URL(fileURLWithPath: batch.items[0].originalPath).deletingPathExtension().lastPathComponent : batch.title
    }

    private var subtitle: String {
        let when: String
        if Calendar.current.isDateInToday(batch.removedAt) {
            when = "Today, \(batch.removedAt.formatted(date: .omitted, time: .shortened))"
        } else if Calendar.current.isDateInYesterday(batch.removedAt) {
            when = "Yesterday, \(batch.removedAt.formatted(date: .omitted, time: .shortened))"
        } else {
            when = batch.removedAt.formatted(.dateTime.month(.abbreviated).day())
        }
        let count = batch.items.count
        return "\(when) · \(count) \(count == 1 ? "item" : "items")"
    }

    /// Where an item is kept while it's in Recently Removed.
    private func storedPath(_ item: RemovedBatch.Item) -> String {
        model.store.root.appendingPathComponent(batch.id).appendingPathComponent("\(item.id)")
            .appendingPathComponent(URL(fileURLWithPath: item.originalPath).lastPathComponent).path
    }

    @ViewBuilder private var icon: some View {
        if let app = batch.items.first(where: { $0.originalPath.hasSuffix(".app") }) {
            AppIcon(path: storedPath(app), size: 36, fallback: "arrow.uturn.backward")
        } else if batch.items.count == 1 {
            AppIcon(path: storedPath(batch.items[0]), size: 36, fallback: "arrow.uturn.backward")
        } else {
            IconTile(symbol: "arrow.uturn.backward", color: Theme.gray, size: 32).frame(width: 36, height: 36)
        }
    }
}
