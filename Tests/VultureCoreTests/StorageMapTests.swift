// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct TreemapTests {
    let box = Treemap.Rect(x: 10, y: 20, width: 600, height: 400)

    @Test func areasMatchSizesAndFillTheBox() {
        let values: [Double] = [60, 30, 20, 10, 5, 3, 2]
        let rects = Treemap.squarify(values, in: box)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            #expect(abs(rect.area - box.area * value / total) < 0.001)
            #expect(rect.x >= box.x - 0.001 && rect.y >= box.y - 0.001)
            #expect(rect.x + rect.width <= box.x + box.width + 0.001)
            #expect(rect.y + rect.height <= box.y + box.height + 0.001)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.area } - box.area) < 0.01)
    }

    @Test func boxesDontOverlap() {
        let rects = Treemap.squarify([40, 25, 15, 10, 6, 4], in: box)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let overlapW = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapH = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                #expect(overlapW <= 0.001 || overlapH <= 0.001)
            }
        }
    }

    @Test func keepsBoxesReasonablySquare() {
        let rects = Treemap.squarify([10, 10, 10, 10], in: Treemap.Rect(x: 0, y: 0, width: 200, height: 200))
        for r in rects { #expect(max(r.width / r.height, r.height / r.width) < 1.01) }
    }

    @Test func emptyAndZeroValues() {
        #expect(Treemap.squarify([], in: box).isEmpty)
        let rects = Treemap.squarify([5, 0, 5], in: box)
        #expect(rects[1].area == 0)
        #expect(abs(rects[0].area - rects[2].area) < 0.001)
    }
}

@Suite struct MapGuideTests {
    let home = URL(fileURLWithPath: "/Users/someone")
    var policy: SafetyPolicy { SafetyPolicy(home: home) }

    @Test func sortsItemsIntoKinds() {
        #expect(MapGuide.kind(of: "/Users/someone/Library/Caches/com.example", home: home) == .temporary)
        #expect(MapGuide.kind(of: "/Users/someone/Library/Developer/Xcode", home: home) == .developer)
        #expect(MapGuide.kind(of: "/Users/someone/Pictures/Photos Library.photoslibrary", home: home) == .media)
        #expect(MapGuide.kind(of: "/Users/someone/Documents/Taxes", home: home) == .documents)
        #expect(MapGuide.kind(of: "/Users/someone/Library/Mail", home: home) == .mail)
        #expect(MapGuide.kind(of: "/Users/someone/Library/Application Support/Foo", home: home) == .appData)
        #expect(MapGuide.kind(of: "/usr/lib", home: home) == .system)
    }

    @Test func warnsAboutThingsNotToDelete() {
        let docker = "/Users/someone/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        #expect(MapGuide.warning(for: docker, home: home, policy: policy)?.contains("Docker") == true)
        #expect(MapGuide.warning(for: "/Users/someone/Library/Mail/V10", home: home, policy: policy) != nil)
        #expect(MapGuide.warning(for: "/Users/someone/Documents", home: home, policy: policy) != nil)
        // Library only contains protected places; looking through it is fine.
        #expect(MapGuide.warning(for: "/Users/someone/Library", home: home, policy: policy) == nil)
        #expect(MapGuide.warning(for: "/Users/someone/Library/Caches/com.example", home: home, policy: policy) == nil)
    }

    @Test func findsTheRuleThatCoversAnItem() {
        let rule = RuleTests.rule(["~/Library/Caches/*"], id: "test.caches")
        let rules = [rule]
        #expect(MapGuide.rule(covering: "/Users/someone/Library/Caches/com.example", rules: rules, home: home)?.id == "test.caches")
        #expect(MapGuide.rule(covering: "/Users/someone/Library/Caches/com.example/deep/file", rules: rules, home: home)?.id == "test.caches")
        #expect(MapGuide.rule(covering: "/Users/someone/Library/Caches", rules: rules, home: home) == nil)
        #expect(MapGuide.rule(covering: "/Users/someone/Documents", rules: rules, home: home) == nil)
    }

    @Test func guessesTheAppFromThePath() {
        #expect(MapGuide.bundleIDs(in: "/Users/someone/Library/Containers/com.docker.docker/Data").first == "com.docker.docker")
        #expect(MapGuide.bundleIDs(in: "/Users/someone/Documents/notes").isEmpty)
    }

    @Test func remembersFolderSizes() throws {
        let fx = try Fixture()
        try fx.file("a/big", bytes: 50_000)
        try fx.file("b/small", bytes: 1_000)
        let sizes = FolderSizes()
        #expect(!sizes.isCached(fx.home))
        let items = sizes.children(of: fx.home)
        #expect(items.map(\.name).prefix(2) == ["a", "b"])
        #expect(sizes.isCached(fx.home))
        try FileManager.default.removeItem(at: fx.url("a"))
        #expect(sizes.children(of: fx.home).first?.name == "a") // served from memory
        sizes.reset()
        #expect(!sizes.children(of: fx.home).contains { $0.name == "a" })
    }

    @Test func readsDockerSizes() {
        let line = DockerReport.Line(type: "Images", size: "18.4GB", reclaimable: "6.1GB (33%)")
        #expect(line.bytes == 18_400_000_000)
        #expect(line.reclaimableBytes == 6_100_000_000)
    }
}

@Suite struct TreemapEdgeTests {
    @Test func neverProducesInfiniteOrNegativeBoxes() {
        // One huge item and many tiny ones exhaust the space through rounding.
        let values = [1e12] + Array(repeating: 1.0, count: 200) + [0, -5]
        let rects = Treemap.squarify(values, in: .init(x: 0, y: 0, width: 700, height: 500))
        #expect(rects.count == values.count)
        for r in rects {
            #expect(r.x.isFinite && r.y.isFinite && r.width.isFinite && r.height.isFinite)
            #expect(r.width >= 0 && r.height >= 0)
            #expect(r.x + r.width <= 700.5 && r.y + r.height <= 500.5)
        }
    }
}
