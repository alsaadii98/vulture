// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import IOKit
import IOKit.ps

/// The menu bar monitor's other numbers: network, battery, graphics, uptime and the busiest apps.
/// All from public kernel and IOKit interfaces, read only while the menu is open.
public enum MachineStats {
    // MARK: Network

    /// Bytes received and sent by all network interfaces except loopback, since they came up.
    public static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return (0, 0) }
        defer { freeifaddrs(first) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        return (received, sent)
    }

    // MARK: Battery

    public struct Battery: Sendable, Equatable {
        /// 0…1
        public var level: Double
        public var charging: Bool
        public var onPower: Bool
        /// Minutes until empty (or full when charging), when macOS knows.
        public var minutesLeft: Int?
    }

    /// nil on Macs without a battery.
    public static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            return Battery(level: Double(current) / Double(max), charging: charging,
                           onPower: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                           minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    // MARK: Graphics

    /// 0…1, how busy the graphics processor is, from its driver's own statistics. nil when the driver doesn't say.
    public static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber else { continue }
            best = max(best ?? 0, percent.doubleValue / 100)
        }
        return best
    }

    // MARK: Uptime and heat

    public static func bootDate() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }

    public enum Heat: String, Sendable { case normal = "Normal", warm = "Warm", hot = "Hot" }

    /// How warm macOS says the Mac is. Vulture never shows made-up degrees.
    public static func heat() -> Heat {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .normal
        case .fair: .warm
        case .serious, .critical: .hot
        @unknown default: .normal
        }
    }
}

/// Which of your processes use the most processor time, measured between two calls.
public final class BusyProcesses: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var name: String
        /// Share of one processor core, 0…n.
        public var cpu: Double
        public var memory: Int64
    }

    private var last: [Int32: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    /// The busiest processes since the previous call (the first call only primes the counters).
    public func sample(top: Int = 3) -> [Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = mach_absolute_time()
        let elapsed = lastTime > 0 ? Double(now - lastTime) * timebase : 0
        var next: [Int32: UInt64] = [:]
        var entries: [Entry] = []
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            next[pid] = cpuTime
            guard elapsed > 0, let before = last[pid], cpuTime >= before else { continue }
            let share = Double(cpuTime - before) * timebase / elapsed
            entries.append(Entry(pid: pid, name: Self.name(of: pid), cpu: share, memory: Int64(usage.ri_phys_footprint)))
        }
        last = next
        lastTime = now
        return Array(entries.sorted { $0.cpu > $1.cpu }.prefix(top))
    }

    static func name(of pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return String(decoding: buffer.prefix(Int(max(0, length))), as: UTF8.self)
    }
}
