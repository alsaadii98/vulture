// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VultureCore

/// A map of every folder: bigger boxes use more space. Click to learn what something is, double-click to look inside.
struct StorageMapView: View {
    enum Mode: String, CaseIterable { case boxes = "Boxes", rings = "Rings", list = "List" }

    @Environment(AppModel.self) private var model
    @State private var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var items: [MapItem] = []
    /// Contents of the biggest folders, shown nested inside their boxes and as the outer ring.
    @State private var nested: [String: [MapItem]] = [:]
    @State private var selected: MapItem?
    @State private var loading = false
    @State private var mode: Mode = .boxes
    @State private var confirmingDocker = false

    private var home: URL { model.home }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            breadcrumb
            InfoNote(text: "Bigger boxes use more space. Click a box to see what it is and whether it’s safe to remove. Double-click to look inside.")
            HStack(alignment: .top, spacing: 20) {
                map.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView { detail }
                    .scrollIndicators(.never)
                    .frame(width: 290)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .screenBackground()
        .navigationTitle("Storage Map")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("View as", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Choose a Folder", systemImage: "folder") { chooseFolder() }
                    .help("Choose a folder to map")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Measure Again", systemImage: "arrow.clockwise") {
                    model.folderSizes.reset()
                    Task { await open(folder) }
                }
                .help("Measure again")
                .disabled(loading)
            }
        }
        .task { await open(model.mapFolder ?? folder); model.mapFolder = nil }
        .onChange(of: model.mapFolder) { _, new in
            guard let new else { return }
            model.mapFolder = nil
            Task { await open(new) }
        }
        .confirmationDialog("Tidy up Docker?", isPresented: $confirmingDocker) {
            Button("Tidy Up") { Task { await model.tidyDocker() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Docker removes images no container uses, stopped containers and build leftovers. Volumes, which hold your data, are kept.")
        }
    }

    // MARK: Breadcrumb

    private var crumbs: [(title: String, url: URL?)] {
        let path = folder.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        var list: [(String, URL?)] = [("Macintosh HD", nil)]
        if path == homePath || path.hasPrefix(homePath + "/") {
            list.append(("Your Home Folder", home))
            var url = home
            for part in path.dropFirst(homePath.count).split(separator: "/") {
                url.appendPathComponent(String(part))
                list.append((String(part), url))
            }
        } else {
            var url = URL(fileURLWithPath: "/")
            for part in path.split(separator: "/") {
                url.appendPathComponent(String(part))
                list.append((String(part), url))
            }
        }
        return list
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let list = crumbs
            ForEach(Array(list.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                if index == list.count - 1 || crumb.url == nil {
                    Text(crumb.title).font(.system(size: 12, weight: index == list.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == list.count - 1 ? .primary : .secondary)
                } else {
                    Button(crumb.title) { Task { await open(crumb.url!) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
    }

    // MARK: The map

    @ViewBuilder private var map: some View {
        if blocked(folder) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Vulture needs Full Disk Access to look in here").font(.system(size: 15, weight: .bold))
                    Text("macOS keeps other apps’ private data in this folder. Vulture only measures sizes, never reads what’s inside.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Open System Settings") { openPrivacySettings() }.glassButton()
                }
            }
        } else if loading && items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring \(folderName(folder))…").font(.system(size: 13, weight: .semibold))
                Text("This can take a minute the first time.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        } else if shown.isEmpty {
            Text("This folder is empty, or Vulture can’t read it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        } else {
            switch mode {
            case .boxes: BoxesView(items: shown, nested: nested, selected: selected?.path, home: home, select: select, open: openItem)
            case .rings: RingsView(items: shown, nested: nested, selected: selected?.path, total: total, title: folderName(folder),
                                   home: home, select: select, open: openItem)
            case .list: MapList(items: shown, total: total, selected: selected?.path, select: select, open: openItem)
            }
        }
    }

    private var total: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// The biggest items, with the smallest ones folded into "Everything else" so each box stays clickable.
    private var shown: [MapItem] { Self.fold(items, parent: folder.path) }

    static func fold(_ items: [MapItem], parent: String, limit: Int = 18) -> [MapItem] {
        let visible = items.filter { $0.bytes > 0 }
        guard visible.count > limit else { return visible }
        let total = visible.reduce(0) { $0 + $1.bytes }
        var kept: [MapItem] = []
        var running: Int64 = 0
        for item in visible where kept.count < limit - 1 && (Double(running) < Double(total) * 0.97 || kept.count < 6) {
            kept.append(item)
            running += item.bytes
        }
        let rest = visible.dropFirst(kept.count)
        kept.append(MapItem(name: "Everything else", path: parent + "/\u{0}rest", isDirectory: false,
                            bytes: rest.reduce(0) { $0 + $1.bytes }, newest: rest.compactMap(\.newest).max()))
        return kept
    }

    // MARK: Detail panel

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = selected, !item.path.hasSuffix("\u{0}rest") {
                ItemDetail(item: item, home: home, confirmingDocker: $confirmingDocker, open: { Task { await open(URL(fileURLWithPath: item.path)) } })
            } else {
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folderName(folder)).font(.system(size: 17, weight: .bold)).lineLimit(1)
                                Text(loading && items.isEmpty ? "Measuring…" : "\(formatBytes(total)) · \(items.count) items")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Text(selected == nil ? "Click a box to see what it is." : "Lots of small items, grouped so the map stays readable. Use List to see each one.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private func select(_ item: MapItem) {
        selected = item
        if !item.path.hasSuffix("\u{0}rest") { model.focusedPath = item.path }
    }

    private func openItem(_ item: MapItem) {
        guard item.isDirectory else { select(item); return }
        Task { await open(URL(fileURLWithPath: item.path)) }
    }

    private func blocked(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return Privacy.foldersToSkip(home: home).contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    private func open(_ url: URL) async {
        let target = url.standardizedFileURL
        folder = target
        selected = nil
        nested = [:]
        guard !blocked(target) else { items = []; return }
        loading = true
        let sizes = model.folderSizes
        let list = await Task.detached(priority: .userInitiated) { sizes.children(of: target) }.value
        guard folder == target else { return }
        items = list
        loading = false
        // Look one level into the biggest folders, for nested boxes and the outer ring.
        let total = Double(max(1, list.reduce(0) { $0 + $1.bytes }))
        for item in list.prefix(4) where item.isDirectory && Double(item.bytes) / total > 0.12 && !blocked(URL(fileURLWithPath: item.path)) {
            let inner = await Task.detached(priority: .utility) { sizes.children(of: URL(fileURLWithPath: item.path)) }.value
            guard folder == target else { return }
            nested[item.path] = Self.fold(inner, parent: item.path, limit: 8)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Map This Folder"
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }

    private func folderName(_ url: URL) -> String {
        url.standardizedFileURL.path == home.standardizedFileURL.path ? "Your Home Folder" : FileManager.default.displayName(atPath: url.path)
    }
}

// MARK: - Colors

extension MapGuide.Kind {
    var color: Color {
        switch self {
        case .appData: Theme.blue
        case .developer: Theme.purple
        case .media: Theme.pink
        case .documents: Theme.amber
        case .temporary: Theme.mint
        case .mail: Theme.amber
        case .apps: Theme.teal
        case .system, .other: Theme.gray
        }
    }
}

private func kindColor(_ item: MapItem, home: URL) -> Color {
    item.path.hasSuffix("\u{0}rest") ? Theme.gray : MapGuide.kind(of: item.path, home: home).color
}

// MARK: - Boxes

private struct BoxesView: View {
    let items: [MapItem]
    let nested: [String: [MapItem]]
    let selected: String?
    let home: URL
    let select: (MapItem) -> Void
    let open: (MapItem) -> Void

    var body: some View {
        GeometryReader { geo in
            let rects = Treemap.squarify(items.map { Double($0.bytes) }, in: .init(x: 0, y: 0, width: geo.size.width, height: geo.size.height))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(items, rects)), id: \.0.path) { item, rect in
                    if let inner = nested[item.path], rect.width > 220, rect.height > 160, !inner.isEmpty {
                        container(item, inner: inner, rect: rect)
                    } else {
                        box(item, rect: rect, depth: 0)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private func container(_ item: MapItem, inner: [MapItem], rect: Treemap.Rect) -> some View {
        let color = kindColor(item, home: home)
        let gap = 3.0, header = 22.0
        let innerRect = Treemap.Rect(x: rect.x + gap + 3, y: rect.y + header, width: max(0, rect.width - 2 * gap - 6),
                                     height: max(0, rect.height - header - gap - 3))
        let innerRects = Treemap.squarify(inner.map { Double($0.bytes) }, in: innerRect)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected == item.path ? Theme.accent : .clear, lineWidth: 2))
                .frame(width: max(0, rect.width - gap), height: max(0, rect.height - gap))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(item) }
                .onTapGesture { select(item) }
                .accessibilityLabel("\(item.name), \(formatBytes(item.bytes))")
                .accessibilityAddTraits(.isButton)
                .position(x: rect.x + (rect.width - gap) / 2, y: rect.y + (rect.height - gap) / 2)
            Text("\(item.name) · \(formatBytes(item.bytes))")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: max(0, rect.width - gap), height: 18, alignment: .leading)
                .position(x: rect.x + (rect.width - gap) / 2, y: rect.y + 13)
                .allowsHitTesting(false)
            ForEach(Array(zip(inner, innerRects)), id: \.0.path) { child, r in
                box(child, rect: r, depth: 1)
            }
        }
    }

    private func box(_ item: MapItem, rect: Treemap.Rect, depth: Int) -> some View {
        let color = kindColor(item, home: home)
        let isSelected = selected == item.path
        let gap = 3.0
        return VStack(alignment: .leading, spacing: 1) {
            if rect.width > 60 && rect.height > 30 {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if rect.height > 46 { Text(formatBytes(item.bytes)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(width: max(0, rect.width - gap), height: max(0, rect.height - gap), alignment: .topLeading)
        .background(color.opacity(depth == 0 ? 0.22 : 0.26), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { select(item) }
        .help("\(item.name) · \(formatBytes(item.bytes))")
        .accessibilityLabel("\(item.name), \(formatBytes(item.bytes))")
        .accessibilityAddTraits(.isButton)
        .position(x: rect.x + (rect.width - gap) / 2, y: rect.y + (rect.height - gap) / 2)
    }
}

// MARK: - Rings

private struct RingSegment: Shape {
    var start: Angle, end: Angle, inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct RingsView: View {
    let items: [MapItem]
    let nested: [String: [MapItem]]
    let selected: String?
    let total: Int64
    let title: String
    let home: URL
    let select: (MapItem) -> Void
    let open: (MapItem) -> Void

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2 - 8
            let hole = radius * 0.34, mid = radius * 0.67
            let sum = Double(max(1, items.reduce(0) { $0 + $1.bytes }))
            ZStack {
                ForEach(Array(segments(sum: sum).enumerated()), id: \.offset) { _, seg in
                    segment(seg.item, start: seg.start, end: seg.end, inner: hole, outer: mid - 2)
                    if let inner = nested[seg.item.path] {
                        let innerSum = Double(max(1, inner.reduce(0) { $0 + $1.bytes }))
                        let span = seg.end - seg.start
                        ForEach(Array(cumulative(inner, sum: innerSum).enumerated()), id: \.offset) { _, child in
                            segment(child.item, start: seg.start + span * child.from, end: seg.start + span * child.to,
                                    inner: mid, outer: radius, child: true)
                        }
                    }
                }
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(formatBytes(total)).font(.system(size: 20, weight: .bold)).monospacedDigit()
                }
                .frame(width: hole * 1.7)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func segments(sum: Double) -> [(item: MapItem, start: Angle, end: Angle)] {
        cumulative(items, sum: sum).map { ($0.item, .degrees(-90 + 360 * $0.from), .degrees(-90 + 360 * $0.to)) }
    }

    private func cumulative(_ list: [MapItem], sum: Double) -> [(item: MapItem, from: Double, to: Double)] {
        var at = 0.0
        return list.map { item in
            let from = at
            at += Double(item.bytes) / sum
            return (item, from, at)
        }
    }

    private func segment(_ item: MapItem, start: Angle, end: Angle, inner: CGFloat, outer: CGFloat, child: Bool = false) -> some View {
        let shape = RingSegment(start: start, end: end, inner: inner, outer: outer)
        let color = kindColor(item, home: home)
        return shape
            .fill(color.opacity(child ? 0.30 : 0.55))
            .overlay(shape.stroke(Theme.window, lineWidth: 1.5))
            .overlay(shape.stroke(selected == item.path ? Theme.accent : .clear, lineWidth: 2.5))
            .contentShape(shape)
            .onTapGesture(count: 2) { open(item) }
            .onTapGesture { select(item) }
            .help("\(item.name) · \(formatBytes(item.bytes))")
            .accessibilityLabel("\(item.name), \(formatBytes(item.bytes))")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - List

private struct MapList: View {
    let items: [MapItem]
    let total: Int64
    let selected: String?
    let select: (MapItem) -> Void
    let open: (MapItem) -> Void
    @State private var byName = false

    private var sorted: [MapItem] {
        byName ? items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : items.sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { byName = true } label: { Text(byName ? "Name ▲" : "Name") }
                    .accessibilityLabel("Sort by name")
                Spacer()
                Button { byName = false } label: { Text(byName ? "Size" : "Size ▼") }
                    .accessibilityLabel("Sort by size")
                    .frame(width: 220, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 30)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { item in
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                        HStack(spacing: 10) {
                            if item.path.hasSuffix("\u{0}rest") {
                                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 22)
                            } else {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 22, height: 22)
                            }
                            Text(item.name).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            ThinBar(fraction: total > 0 ? Double(item.bytes) / Double(total) : 0).frame(width: 110)
                            SizeText(bytes: item.bytes, weight: .semibold, size: 13).frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(selected == item.path ? Theme.accent.opacity(0.14) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(item) }
                        .onTapGesture { select(item) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .background(Theme.group, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

// MARK: - Detail

private struct ItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: MapItem
    let home: URL
    @Binding var confirmingDocker: Bool
    let open: () -> Void

    private var rule: Rule? { MapGuide.rule(covering: item.path, rules: model.rules, home: home) }
    private var warning: String? { MapGuide.warning(for: item.path, home: home, policy: Preferences.safetyPolicy(home: home)) }
    private var isDocker: Bool { item.path.contains("com.docker.docker") || item.name == "Docker.raw" }

    private var app: String? {
        for id in MapGuide.bundleIDs(in: item.path) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 17, weight: .bold)).lineLimit(2)
                            Text([formatBytes(item.bytes), app.map { "used by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Text(rule?.explanation ?? MapGuide.explanation(for: MapGuide.kind(of: item.path, home: home), isDirectory: item.isDirectory))
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        fact("Last changed", item.newest.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                        fact(item.isDirectory ? "Folder name" : "File name", item.name)
                    }
                }
            }
            if let warning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Don’t delete this", systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.orange)
                    Text(warning).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.orangeBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                if isDocker && model.dev?.docker != nil || item.name == "Docker.raw" {
                    Button("Tidy Up Docker") { confirmingDocker = true }.primaryButton(.regular)
                        .disabled(model.devBusy != nil)
                }
                if rule != nil && warning == nil {
                    Button("Review in Clean Up") { model.section = .clean }.primaryButton(.regular)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    if item.isDirectory { Button("Look Inside") { open() } }
                }
                .glassButton()
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
    }
}
