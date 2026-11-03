// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VultureCore

/// Checks GitHub for a newer Vulture once a day and installs it when the person agrees.
@MainActor @Observable
final class UpdateModel {
    enum State: Equatable { case idle, checking, installing, upToDate, failed(String) }

    var state: State = .idle
    var available: UpdateInfo?
    /// Shows the "new version" sheet.
    var prompting = false

    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private let checkEvery: TimeInterval = 24 * 3600
    private var timer: Timer?

    let app: URL? = Bundle.main.executableURL.flatMap(Updater.app(containing:))
    var currentVersion: String { app.flatMap(Updater.version(of:)) ?? "dev" }

    init() {
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
    }

    /// Called at launch: checks now if a day has passed, and keeps checking while Vulture stays open.
    func start() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.autoCheckKey), app != nil, state == .idle || state == .upToDate else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= checkEvery else { return }
        Task { await check(userAsked: false) }
    }

    func check(userAsked: Bool) async {
        guard state != .checking, state != .installing else { return }
        guard app != nil else {
            if userAsked { state = .failed(Updater.Problem.notInstalled.description) }
            return
        }
        state = .checking
        do {
            let info = try await Updater.check(current: currentVersion)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            available = info
            state = info == nil ? .upToDate : .idle
            if info != nil { prompting = true }
        } catch {
            // Quiet when checking in the background: no network is normal.
            state = userAsked ? .failed(String(describing: error)) : .idle
        }
    }

    func installAndRelaunch() async {
        guard let info = available, let app else { return }
        state = .installing
        do {
            try await Updater.install(info, replacing: app)
            try Updater.relaunch(app, after: ProcessInfo.processInfo.processIdentifier)
            NSApp.terminate(nil)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// "A new version of Vulture is available."
struct UpdateSheet: View {
    @Environment(UpdateModel.self) private var updates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vulture \(updates.available?.version ?? "") is available").font(.title3.weight(.semibold))
                    Text("You have \(updates.currentVersion). Vulture will update itself and reopen. Your settings, history and Recently Removed stay as they are.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notes = updates.available?.notesURL {
                        Link("What's new", destination: notes).padding(.top, 2)
                    }
                }
            }
            if case .failed(let why) = updates.state {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if case .installing = updates.state {
                    ProgressView().controlSize(.small)
                    Text("Downloading and checking…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.state == .installing)
                Button("Install and Relaunch") { Task { await updates.installAndRelaunch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updates.state == .installing)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

/// Vulture › Check for Updates…
struct CheckForUpdatesButton: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        Button("Check for Updates…") {
            Task {
                await updates.check(userAsked: true)
                switch updates.state {
                case .upToDate:
                    alert("You're up to date", "Vulture \(updates.currentVersion) is the newest version.")
                case .failed(let why):
                    alert("Couldn't check for updates", why)
                    updates.state = .idle
                default: break
                }
            }
        }
        .disabled(updates.state == .checking || updates.state == .installing)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
