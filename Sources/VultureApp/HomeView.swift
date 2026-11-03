// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

/// One answer and one button: how full the Mac is, and how much can be freed safely.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                    .padding(28)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                if !model.hasFullDiskAccess {
                    Notice(symbol: "lock.shield", text: "Vulture can't see everything yet. Give it Full Disk Access in System Settings › Privacy & Security to find more.") {
                        Button("Open Settings") { openPrivacySettings() }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Home")
        .navigationSubtitle(model.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .toolbar {
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.scan() } }
                .disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    private var hero: some View {
        HStack(spacing: 36) {
            DiskRing(fraction: model.usedFraction, free: model.freeBytes, total: model.totalBytes)
            VStack(alignment: .leading, spacing: 12) {
                switch model.phase {
                case .idle:
                    Text("Let's see what's taking up space").font(.title.bold())
                    Button("Check My Mac") { Task { await model.scan() } }
                        .buttonStyle(BigButtonStyle())
                case .scanning:
                    Working(text: "Checking your Mac…", detail: "This usually takes a few seconds.")
                case .ready:
                    readyContent
                case .cleaning:
                    Working(text: "Cleaning up…", detail: "You can keep using your Mac while this runs.")
                case .done(let result):
                    DoneBanner(result: result)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.spring(duration: 0.4), value: phaseKey)
    }

    @ViewBuilder private var readyContent: some View {
        if model.selectedBytes > 0 {
            Label("Your Mac is in good shape", systemImage: "checkmark")
                .font(.callout.weight(.semibold)).foregroundStyle(.green)
            Text("You can free up \(formatBytes(model.selectedBytes))").font(.largeTitle.bold())
            Text("These are leftover files that apps make again on their own. Your photos, documents and messages are never touched.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button {
                    model.confirmingClean = true
                    model.section = .clean
                } label: {
                    Label("Free Up \(formatBytes(model.selectedBytes))", systemImage: "sparkles")
                }
                .buttonStyle(BigButtonStyle())
                Button("See What's Included") { model.section = .clean }
                    .buttonStyle(.link)
            }
            .padding(.top, 6)
        } else {
            Label("Nothing to clean up right now", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(.green)
            Text("Vulture checked the places where leftover files usually pile up and found nothing worth removing.")
                .foregroundStyle(.secondary)
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

struct DiskRing: View {
    let fraction: Double
    let free: Int64
    let total: Int64
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 16)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(formatBytes(free)).font(.title.bold()).monospacedDigit().contentTransition(.numericText())
                Text("free of \(formatBytes(total))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(formatBytes(free)) free of \(formatBytes(total))")
        .onAppear { withAnimation(.spring(duration: 1.0)) { shown = fraction } }
        .onChange(of: fraction) { _, new in withAnimation(.spring(duration: 0.8)) { shown = new } }
    }
}

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

/// What a finished clean-up did, said honestly: what was freed, and what's waiting in Recently Removed.
struct DoneBanner: View {
    @Environment(AppModel.self) private var model
    let result: CleanupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All done. You freed \(formatBytes(result.freedBytes)).", systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
            if let id = result.batchID {
                HStack {
                    Text("\(formatBytes(result.keptBytes)) is in Recently Removed. Changed your mind? Put it back any time in the next 30 days.")
                        .foregroundStyle(.secondary)
                    Button("Put Back") { model.putBack(id) }
                }
            }
            if !result.failures.isEmpty {
                Text("\(result.failures.count) items were left alone because something changed since the check.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
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
