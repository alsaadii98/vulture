// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import SwiftUI
import VultureCore

/// First launch only: the splash, Full Disk Access explained in plain words, then the optional menu bar item.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var step = Step.splash

    enum Step: Int { case splash, access, menuBar }

    var body: some View {
        ZStack {
            switch step {
            case .splash: SplashStep { go(.access) }.transition(.opacity)
            case .access: AccessStep(next: { go(.menuBar) }).transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            case .menuBar: MenuBarStep(back: { go(.access) }, finish: finish).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }

    private func go(_ next: Step) {
        withAnimation(.spring(duration: 0.45)) { step = next }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.3)) { didOnboard = true }
        Task { await model.scan() }
    }
}

/// The app icon with a soft shadow, as on the splash and step headers.
private struct AppMark: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size / 7, y: size / 14)
            .accessibilityLabel("Vulture")
    }
}

// MARK: - Splash

private struct SplashStep: View {
    let start: () -> Void
    @State private var ready = false
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppMark(size: 128)
            Text("Vulture").font(.system(size: 34, weight: .bold)).padding(.top, 22)
            Text("for Mac").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 2)
            Text("See what’s filling up your Mac, and free up space without the worry.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).padding(.top, 16)
            Spacer()
            Group {
                if ready {
                    VStack(spacing: 10) {
                        Button("Get Started", action: start)
                            .primaryButton()
                            .keyboardShortcut(.defaultAction)
                        Text("Free and open source").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    VStack(spacing: 10) {
                        ThinBar(fraction: progress, height: 4).frame(width: 220)
                        Text("Getting ready…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Getting ready")
                    .transition(.opacity)
                }
            }
            .frame(height: 70)
            .padding(.bottom, 44)
        }
        .padding(.horizontal, 40)
        .task {
            withAnimation(.easeInOut(duration: 1.4)) { progress = 1 }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.spring(duration: 0.4)) { ready = true }
        }
    }
}

// MARK: - Step 1: Full Disk Access

private struct AccessStep: View {
    @Environment(AppModel.self) private var model
    let next: () -> Void
    @State private var hasAccess = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    HStack(alignment: .top, spacing: 14) {
                        promiseCard(title: "Vulture will", symbol: "checkmark", color: Theme.green,
                                    lines: ["Measure how big files and folders are.", "Remove things only when you click Clean Up."])
                        promiseCard(title: "Vulture won’t", symbol: "lock", color: Theme.red,
                                    lines: ["Read your documents, mail or messages.", "Send anything off this Mac. No account needed."])
                    }
                    HStack(alignment: .top, spacing: 24) {
                        settingsMock.frame(width: 300)
                        VStack(alignment: .leading, spacing: 12) {
                            stepLine(1, "Click Open System Settings below.")
                            stepLine(2, "Find Vulture in the list and turn it on.")
                            stepLine(3, "Come back here. Vulture notices right away.")
                        }
                        .padding(.top, 10)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 34)
                .padding(.bottom, 16)
            }
            bottomBar
        }
        .onAppear { hasAccess = Privacy.hasFullDiskAccess(home: model.home) }
        .onReceive(poll) { _ in
            guard !hasAccess else { return }
            if Privacy.hasFullDiskAccess(home: model.home) {
                withAnimation(.spring(duration: 0.4)) { hasAccess = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    next()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                IconTile(symbol: "lock.shield.fill", color: Theme.gray, size: 64)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                AppMark(size: 64)
            }
            .accessibilityHidden(true)
            Text("Step 1 of 2").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            Text("Let Vulture See Your Whole Disk").font(.system(size: 26, weight: .bold))
            Text("To keep your data private, macOS hides some folders, like Mail and Messages, from apps. Vulture needs to measure them to tell you what’s using space. It only looks at sizes, never at what’s inside your files.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 540).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func promiseCard(title: String, symbol: String, color: Color, lines: [String]) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 13)) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A small picture of the Full Disk Access list, so people know what to look for.
    private var settingsMock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconTile(symbol: "hand.raised.fill", color: Theme.gray, size: 16)
                Text("Privacy & Security › Full Disk Access").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 32)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            mockRow(icon: AnyView(IconTile(symbol: "terminal.fill", color: Theme.gray, size: 18)), name: "Terminal", on: false)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            mockRow(icon: AnyView(AppMark(size: 18).shadow(radius: 0)), name: "Vulture", on: true)
                .background(Theme.accent.opacity(0.10))
        }
        .background(Theme.group, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, turn on Vulture under Privacy and Security, Full Disk Access.")
    }

    private func mockRow(icon: AnyView, name: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            icon
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
            Spacer()
            Capsule().fill(on ? Theme.accent : Color.gray.opacity(0.55)).frame(width: 34, height: 20)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2) }
        }
        .padding(.horizontal, 12).frame(height: 36)
    }

    private func stepLine(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
                .background(Theme.group, in: Circle())
            Text(text).font(.system(size: 13))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if hasAccess {
                Label("Full Disk Access is on", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
                    .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for permission…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Button(hasAccess ? "Continue" : "Skip for Now", action: next).glassButton().controlSize(.large)
            if !hasAccess {
                Button("Open System Settings") { openPrivacySettings() }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 18)
    }
}

// MARK: - Step 2: menu bar

private struct MenuBarStep: View {
    let back: () -> Void
    let finish: () -> Void
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppMark(size: 72)
                Text("Step 2 of 2").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                Text("Keep an Eye on Your Mac").font(.system(size: 26, weight: .bold))
                Text("Vulture can show CPU, memory, disk and battery in the menu bar, even when the app is closed. It’s off unless you turn it on, and you can change it any time in Settings › Menu Bar.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 40)

            menuBarMock.padding(.top, 28)

            Toggle(isOn: $showMenuBarMonitor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Vulture in the menu bar").font(.system(size: 13, weight: .semibold))
                    Text("Click it for a quick look at how your Mac is doing.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .padding(.top, 24)

            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button("Back", action: back).glassButton().controlSize(.large)
                Button("Start First Scan", action: finish)
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 18)
        }
        .padding(.horizontal, 40)
    }

    private var menuBarMock: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "magnifyingglass")
            Image(systemName: "waveform.path.ecg")
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(showMenuBarMonitor ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(showMenuBarMonitor ? .primary : .tertiary)
            Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(width: 420, height: 28)
        .background(Theme.group, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.2), value: showMenuBarMonitor)
        .accessibilityHidden(true)
    }
}
