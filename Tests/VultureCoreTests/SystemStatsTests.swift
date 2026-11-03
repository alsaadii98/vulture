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

@Suite struct MachineStatsTests {
    @Test func readsMachineNumbers() throws {
        let boot = try #require(MachineStats.bootDate())
        #expect(boot < Date())
        let net = MachineStats.networkBytes()
        #expect(net.received >= 0)
        if let battery = MachineStats.battery() { #expect((0...1).contains(battery.level)) }
        if let gpu = MachineStats.gpuUtilization() { #expect(gpu >= 0) }
        let busy = BusyProcesses()
        _ = busy.sample()
        var spin = 0.0
        for i in 0..<2_000_000 { spin += Double(i) }
        #expect(spin > 0)
        let top = busy.sample(top: 5)
        #expect(top.count <= 5)
        #expect(top.allSatisfy { !$0.name.isEmpty || $0.pid > 0 })
    }
}
