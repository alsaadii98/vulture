// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// The look from the Vulture design canvas: plain grouped cards on a white window in light mode,
// true black in dark mode, and Liquid Glass for the sidebar, toolbar and floating bars (macOS 26 and later).

extension Color {
    /// A color that follows the system appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        func make(_ hex: UInt32, _ alpha: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? make(dark, darkAlpha) : make(light, lightAlpha)
        })
    }
}

enum Theme {
    /// Window background: white, or pure black in dark mode.
    static let window = Color(light: 0xFFFFFF, dark: 0x000000)
    /// Grouped cards and rows.
    static let group = Color(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// Slightly raised surface inside a card (selected tile, inner well).
    static let raised = Color(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let separator = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.10)
    static let track = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.10)

    static let accent = Color(light: 0x0071E3, dark: 0x0A84FF)
    static let accentText = Color(light: 0x0066CC, dark: 0x4DA3FF)
    static let green = Color(light: 0x1F7A34, dark: 0x32D74B)
    static let orange = Color(light: 0xB25000, dark: 0xFF9F0A)
    static let red = Color(light: 0xC4161C, dark: 0xFF6961)
    static let greenBackground = Color(light: 0xE0F5E6, dark: 0x0F2A17)
    static let orangeBackground = Color(light: 0xFFF0DB, dark: 0x2E200A)
    static let redBackground = Color(light: 0xFFE7E5, dark: 0x2E1312)
    static let blueBackground = Color(light: 0xEAF3FE, dark: 0x0B1D33)

    /// Category colors, in the order the design uses them.
    static let blue = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let purple = Color(light: 0xAF52DE, dark: 0xBF5AF2)
    static let teal = Color(light: 0x30B0C7, dark: 0x40C8E0)
    static let amber = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let pink = Color(light: 0xFF2D55, dark: 0xFF375F)
    static let mint = Color(light: 0x34C759, dark: 0x30D158)
    static let gray = Color(light: 0x8E8E93, dark: 0x98989D)

    static let cardRadius: CGFloat = 12
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26, a material before that.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }

    /// The main call to action: a filled glass capsule.
    @ViewBuilder
    func primaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
    }

    /// A secondary action: a clear glass capsule.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// White in light mode, black in dark mode, under everything including the toolbar.
    func screenBackground() -> some View {
        background(Theme.window.ignoresSafeArea())
    }
}

// MARK: - Building blocks

/// A rounded grouped card.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var background: Color = Theme.group
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Rows in one card, separated by hairlines, like the design's grouped lists.
struct RowsCard<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var dividerInset: CGFloat = 16
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, dividerInset) }
                row(item)
            }
        }
        .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// "Recommended  Safe to remove…" — a colored heading with a quiet note.
struct SectionHeading: View {
    let title: String
    var note: String? = nil
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
    }
}

/// A white SF Symbol on a colored rounded square, like the sidebar and category icons.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The real icon of an app, by bundle ID or path, or a placeholder tile.
struct AppIcon: View {
    var bundleID: String? = nil
    var path: String? = nil
    var size: CGFloat = 32
    var fallback: String = "app.dashed"

    var body: some View {
        Group {
            if let image = Self.image(bundleID: bundleID, path: path) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                IconTile(symbol: fallback, color: Theme.gray, size: size * 0.86)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func image(bundleID: String?, path: String?) -> NSImage? {
        if let path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

/// A small line of help with an icon, like "Cleaned files go to Recently Removed…".
struct InfoNote: View {
    var symbol = "info.circle"
    let text: LocalizedStringKey
    var color: Color = .secondary

    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.system(size: 13))
            .foregroundStyle(color)
    }
}

/// A tinted banner: warnings, results and tips.
struct Banner<Trailing: View>: View {
    enum Kind { case info, success, warning, danger }
    let kind: Kind
    var symbol: String? = nil
    let text: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol ?? defaultSymbol).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
            text.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var defaultSymbol: String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.octagon"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: Theme.accentText
        case .success: Theme.green
        case .warning: Theme.orange
        case .danger: Theme.red
        }
    }

    private var background: Color {
        switch kind {
        case .info: Theme.blueBackground
        case .success: Theme.greenBackground
        case .warning: Theme.orangeBackground
        case .danger: Theme.redBackground
        }
    }
}

extension Banner where Trailing == EmptyView {
    init(kind: Kind, symbol: String? = nil, text: Text) {
        self.init(kind: kind, symbol: symbol, text: text) { EmptyView() }
    }
}

/// A ring showing how full something is, with text in the middle.
struct ProgressRing<Center: View>: View {
    let fraction: Double
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 16
    var size: CGFloat = 176
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.9), value: fraction)
            center
        }
        .frame(width: size, height: size)
    }
}

/// A thin rounded bar, for "Macintosh HD" and days left.
struct ThinBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(height, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// The screen body: scrolls, with the design's spacing, on the window background.
struct Screen<Content: View>: View {
    var spacing: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
    }
}

/// Size text in the design's style: semibold, tabular digits.
struct SizeText: View {
    let bytes: Int64
    var weight: Font.Weight = .semibold
    var size: CGFloat = 15

    var body: some View {
        Text(formatBytes(bytes)).font(.system(size: size, weight: weight)).monospacedDigit()
    }
}

func openPrivacySettings(_ pane: String = "Privacy_AllFiles") {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}
