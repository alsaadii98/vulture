// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Live CPU and memory numbers straight from the kernel: no helper tools, no shell, cheap enough to read every few seconds.
public final class SystemStats: @unchecked Sendable {
    public struct Sample: Sendable {
        /// 0…1, all cores together, since the previous sample.
        public var cpu: Double
        /// Memory apps are using (active, wired and compressed), in bytes.
        public var memoryUsed: Int64
        public var memoryTotal: Int64
    }

    private var lastTicks: (busy: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> Sample {
        Sample(cpu: cpuUsage(), memoryUsed: memoryUsed(), memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let page = Int64(getpagesize())
        return (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
    }
}
