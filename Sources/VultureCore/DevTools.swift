// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Runs a tool and returns what it printed, or nil if it's missing, fails, or takes too long.
/// Arguments are passed directly, never through a shell.
func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    var data = Data()
    // Read while waiting so a large output can't fill the pipe and stall the tool.
    let reader = out.fileHandleForReading
    while process.isRunning {
        data.append(reader.availableData)
        if Date() > deadline { process.terminate(); return nil }
    }
    data.append(reader.readDataToEndOfFile())
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Xcode simulators

public struct SimulatorReport: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public var name: String
        public var udid: String
        public var runtime: String
        public var bytes: Int64
    }

    /// Simulators whose iOS version is no longer installed, so they can't be opened.
    public var unavailable: [Device]
    public var bytes: Int64 { unavailable.reduce(0) { $0 + $1.bytes } }
}

public enum Simulators {
    static let xcrun = "/usr/bin/xcrun"

    public static func report(home: URL, scanner: DiskScanner) -> SimulatorReport? {
        // Asking xcrun without Xcode installed would offer to install the developer tools, so check first.
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard Glob.isRealDirectory(devices),
              let json = runTool(xcrun, ["simctl", "list", "devices", "unavailable", "--json"]),
              let parsed = try? JSONDecoder().decode(SimctlList.self, from: Data(json.utf8)) else { return nil }
        var out: [SimulatorReport.Device] = []
        for (runtime, list) in parsed.devices {
            for d in list {
                let bytes = scanner.usage(of: devices.appendingPathComponent(d.udid)).bytes
                out.append(.init(name: d.name, udid: d.udid, runtime: readable(runtime), bytes: bytes))
            }
        }
        return SimulatorReport(unavailable: out.sorted { $0.bytes > $1.bytes })
    }

    /// Removes simulators whose iOS version is gone. Simulators that still work are kept.
    public static func deleteUnavailable() -> Bool {
        runTool(xcrun, ["simctl", "delete", "unavailable"], timeout: 300) != nil
    }

    private struct SimctlList: Decodable {
        struct Device: Decodable { var name: String; var udid: String }
        var devices: [String: [Device]]
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-2` → `iOS 17.2`
    static func readable(_ runtime: String) -> String {
        guard let last = runtime.split(separator: ".").last else { return runtime }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return runtime }
        return "\(os) \(parts.dropFirst().joined(separator: "."))"
    }
}

// MARK: - Docker

public struct DockerReport: Codable, Sendable {
    public struct Line: Codable, Sendable {
        public var type: String
        public var size: String
        public var reclaimable: String
    }

    public var lines: [Line]
    /// Space Docker says it can give back from images, containers and build cache. Volumes are never counted: they hold data.
    public var reclaimableBytes: Int64
}

public enum Docker {
    static let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]

    static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Nil when Docker isn't installed or isn't running.
    public static func report() -> DockerReport? {
        guard let docker = binary, let out = runTool(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30) else { return nil }
        var lines: [DockerReport.Line] = []
        var reclaimable: Int64 = 0
        for row in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String, let size = obj["Size"] as? String, let rec = obj["Reclaimable"] as? String else { continue }
            lines.append(.init(type: type, size: size, reclaimable: rec))
            if !type.lowercased().contains("volume") { reclaimable += parseSize(rec) }
        }
        return DockerReport(lines: lines, reclaimableBytes: reclaimable)
    }

    /// Asks Docker to remove stopped containers, images no container uses, and build cache. Volumes are left alone.
    public static func tidy() -> Bool {
        guard let docker = binary else { return false }
        let steps = [["container", "prune", "--force"], ["image", "prune", "--all", "--force"], ["builder", "prune", "--all", "--force"]]
        return steps.allSatisfy { runTool(docker, $0, timeout: 600) != nil }
    }

    /// `"1.2GB (35%)"` → bytes. Docker uses decimal units.
    static func parseSize(_ text: String) -> Int64 {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            return Int64((Double(s.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }
}

// MARK: - Time Machine copies on this Mac

public enum TimeMachine {
    /// Dates of the Time Machine copies macOS keeps on the startup disk while the backup drive is away.
    public static func localSnapshots() -> [Date] {
        guard let out = runTool("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: 30) else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return out.split(separator: "\n").compactMap { f.date(from: String($0).trimmingCharacters(in: .whitespaces)) }.sorted(by: >)
    }
}
