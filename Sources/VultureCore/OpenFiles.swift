// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin

/// The files that processes have open right now, so a clean-up never pulls a file out from under an app.
/// Only this user's processes are visible without admin rights, which is what matters for files in the home folder.
public struct OpenFiles: Sendable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }

    /// Reads every open file of every process this user can see.
    public static func snapshot() -> OpenFiles {
        var paths: [String] = []
        let me = getpid()
        for pid in allPIDs() where pid != me {
            paths += openPaths(of: pid)
        }
        return OpenFiles(paths: paths)
    }

    /// The first open file at or inside `path`, if any.
    public func firstOpen(inside path: String) -> String? {
        paths.first { $0 == path || $0.hasPrefix(path + "/") }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    private static func openPaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }
}
