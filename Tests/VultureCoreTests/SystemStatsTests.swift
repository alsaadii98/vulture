// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VultureCore

@Suite struct SystemStatsTests {
    @Test func readsSensibleNumbers() {
        let stats = SystemStats()
        _ = stats.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let s = stats.sample()
        #expect(s.cpu >= 0 && s.cpu <= 1)
        #expect(s.memoryTotal > 0)
        #expect(s.memoryUsed > 0 && s.memoryUsed <= s.memoryTotal)
    }
}
