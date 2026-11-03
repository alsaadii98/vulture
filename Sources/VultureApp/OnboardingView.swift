// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import SwiftUI
import VultureCore

/// First launch only: a short welcome, then Full Disk Access explained in plain words.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var step = 0
    @State private var ready = false
    @State private var hasAccess = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            if step == 0 { welcome.transition(.opacity) } else { access.transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.45), value: step)
        .onReceive(poll) { _ in
            if step == 1 { hasAccess = Privacy.hasFullDiskAccess(home: model.home) }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring(duration: 0.4)) { ready = true }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
                .scaleEffect(ready ? 1 : 0.9)
                .accessibilityHidden(true)
            Text("Vulture").font(.system(size: 34, weight: .bold)).padding(.top, 8)
            Text("for Mac").font(.title3).foregroundStyle(.secondary)
            Text("See what's filling up your Mac, and free up space without the worry.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Spacer()
            Group {
                if ready {
                    VStack(spacing: 8) {
                        Button("Get Started") { step = 1 }
                            .buttonStyle(BigButtonStyle())
                            .keyboardShortcut(.defaultAction)
                        Text("Free and open source").font(.caption).foregroundStyle(.secondary)
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 70)
        }
        .padding(40)
    }

    private var access: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: hasAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(hasAccess ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
            Text("Let Vulture See Your Whole Mac").font(.largeTitle.bold())
            Text("To measure every folder, macOS needs you to turn on **Full Disk Access** for Vulture. Vulture only reads what's there. Nothing leaves your Mac, and nothing is removed without asking you first.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click **Open System Settings** below.")
                step(2, "Find **Vulture** in the list and turn it on. If it isn't there, click **+** and choose Vulture.")
                step(3, "Come back here. This page notices by itself.")
            }
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 520)

            Spacer()
            HStack {
                Button("Back") { step = 0 }
                Spacer()
                if hasAccess {
                    Label("Full Disk Access is on", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Button("Skip for Now") { finish() }
                }
                Button(hasAccess ? "Start First Scan" : "Open System Settings") {
                    if hasAccess { finish() } else { openPrivacySettings() }
                }
                .buttonStyle(BigButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 620)
        }
        .padding(40)
        .onAppear { hasAccess = Privacy.hasFullDiskAccess(home: model.home) }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: Circle())
            Text(text)
        }
    }

    private func finish() {
        didOnboard = true
        Task { await model.scan() }
    }
}

func openPrivacySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}
