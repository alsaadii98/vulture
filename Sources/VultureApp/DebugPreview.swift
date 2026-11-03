// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import AppKit
import SwiftUI

/// Development builds only: launch options for checking screens without clicking through them.
///   open build/Vulture.app --args -VultureSection storage -VultureAppearance light
///   -VulturePreview settings | menubar      (with -settingsTab safety)
enum DebugPreview {
    static var section: SidebarSection? {
        UserDefaults.standard.string(forKey: "VultureSection").flatMap(SidebarSection.init(rawValue:))
    }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "VultureAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    static var preview: String? { UserDefaults.standard.string(forKey: "VulturePreview") }

    @MainActor private static var window: NSWindow?

    /// Shows the menu bar panel in an ordinary window.
    @MainActor static func showMenuBarPanel() {
        let host = NSHostingView(rootView: MonitorMenu().environment(MonitorModel()).tint(Theme.accent))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Menu Bar Panel"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct DebugPreviewHook: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            switch DebugPreview.preview {
            case "settings": openSettings()
            case "menubar": DebugPreview.showMenuBarPanel()
            default: break
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func debugPreviewHook() -> some View {
        #if DEBUG
        self.modifier(DebugPreviewHook())
        #else
        self
        #endif
    }
}
