// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import VultureCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        Group {
            if didOnboard {
                main.transition(.opacity)
            } else {
                OnboardingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .screenBackground()
                    .hideWindowTitle()
            }
        }
        // Vulture's blue, whatever accent color the Mac uses.
        .tint(Theme.accent)
        .borderlessWindowChrome()
    }

    private var main: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
        } detail: {
            Group {
                switch model.section ?? .home {
                case .home: HomeView()
                case .clean: CleanUpView()
                case .removed: RecentlyRemovedView()
                case .developer: DeveloperView()
                case .apps: AppsView()
                case .storage: StorageView()
                case .startup: StartupView()
                case .storageMap: StorageMapView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: model.section)
        }
        .task { if model.plan == nil, case .idle = model.phase { await model.scan() } }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }
}

extension View {
    /// Like Telegram and the design: no title bar strip, content runs to the top edge, and the
    /// traffic lights sit on the floating sidebar.
    @ViewBuilder
    func borderlessWindowChrome() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

extension View {
    /// No "Vulture" title text in the window's top strip.
    @ViewBuilder
    func hideWindowTitle() -> some View {
        if #available(macOS 15.0, *) { self.toolbar(removing: .title) } else { self }
    }
}

/// The design's sidebar: colored icons, sizes on the right, and how full the disk is at the bottom.
/// On macOS 26 the system draws it as a floating Liquid Glass panel.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showDeveloperFiles") private var showDeveloperFiles = true
    @AppStorage("showStorageMap") private var showStorageMap = false

    var body: some View {
        List {
            Section {
                ForEach([SidebarSection.home, .clean, .apps, .storage, .startup]) { row($0) }
            }
            Section {
                row(.removed)
            }
            if showDeveloperFiles || showStorageMap {
                Section("Extra Tools") {
                    if showDeveloperFiles { row(.developer) }
                    if showStorageMap { row(.storageMap) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { disk }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macintosh HD").foregroundStyle(.secondary)
                Spacer()
                Text("\(formatBytes(model.freeBytes)) free").fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 12))
            ThinBar(fraction: model.usedFraction)
                .accessibilityLabel("Macintosh HD is \(Int(model.usedFraction * 100)) percent full")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 8)
    }

    /// A row with the design's soft gray selection rather than the Mac's accent color.
    private func row(_ section: SidebarSection) -> some View {
        let selected = (model.section ?? .home) == section
        return Button {
            model.section = section
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: section.symbol, color: section.tint, size: 24)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let badge = badge(section) {
                    Text(badge).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Theme.track : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(_ section: SidebarSection) -> String? {
        switch section {
        case .clean where model.selectedBytes > 0: shortBytes(model.selectedBytes)
        case .removed where !model.batches.isEmpty: shortBytes(model.batches.reduce(0) { $0 + $1.bytes })
        default: nil
        }
    }
}

/// "26 GB" rather than "26.4 GB", for tight spots like the sidebar.
func shortBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.isAdaptive = bytes < 10_000_000_000
    return formatter.string(fromByteCount: bytes)
}
