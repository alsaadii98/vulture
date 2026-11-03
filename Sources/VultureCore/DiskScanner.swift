// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a folder (or file) adds up to.
public struct DiskUsage: Codable, Hashable, Sendable {
    /// Space actually allocated on disk, so sparse files count for what they use, not their nominal length.
    public var bytes: Int64 = 0
    public var files: Int = 0
    /// The newest modification (or date added) of anything inside.
    public var newest: Date?
    /// Folders that couldn't be read, usually for lack of Full Disk Access.
    public var unreadable: Int = 0

    public init() {}

    mutating func add(_ other: DiskUsage) {
        bytes += other.bytes
        files += other.files
        unreadable += other.unreadable
        if let n = other.newest { note(n) }
    }

    mutating func note(_ date: Date) {
        if newest.map({ date > $0 }) ?? true { newest = date }
    }
}

public struct DiskEntry: Codable, Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var usage: DiskUsage
}

/// Measures folders with `getattrlistbulk`, which returns names, types, dates and sizes for a whole
/// directory in a few system calls instead of one `stat` per file.
///
/// - Doesn't follow symbolic links and doesn't cross into other volumes.
/// - Files with several hard links are counted once.
/// - APFS clones are counted at full size; the disk may actually share their blocks.
public final class DiskScanner: @unchecked Sendable {
    /// Folders this many levels below the starting point are measured in parallel.
    public var parallelDepth = 3

    private let lock = NSLock()
    private var seenInodes: Set<UInt64> = []
    private let skippedFolders: Set<UInt64>

    /// - Parameter skipping: folders never entered; each counts as unreadable. Used for places where opening
    ///   a folder would make macOS show a privacy prompt and wait for an answer.
    public init(skipping: [URL] = []) {
        skippedFolders = Set(skipping.compactMap { url in
            var st = stat()
            return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
        })
    }

    /// Measures `url` and everything inside it.
    public func usage(of url: URL) -> DiskUsage {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return DiskUsage() }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { var u = DiskUsage(); u.unreadable = 1; return u }
            defer { close(fd) }
            return walk(fd, device: st.st_dev, depth: 0)
        case S_IFREG:
            var u = DiskUsage()
            if st.st_nlink <= 1 || firstSighting(UInt64(st.st_ino)) {
                u.bytes = Int64(st.st_blocks) * 512
                u.files = 1
            }
            u.note(Date(timespec: st.st_mtimespec))
            return u
        default:
            return DiskUsage()
        }
    }

    /// Measures each item directly inside `url`, largest first. Items named in `skipping` aren't measured.
    public func children(of url: URL, skipping names: Set<String> = []) -> [DiskEntry] {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return [] }
        let device = st.st_dev
        var listing = DirectoryListing()
        read(fd, into: &listing)
        listing.files.removeAll { names.contains($0.name) }
        listing.directories.removeAll { names.contains($0) }

        var result = listing.files.map { DiskEntry(name: $0.name, isDirectory: false, usage: $0.usage) }
        let dirs = listing.directories
        let measured = measureInParallel(dirs, in: fd, device: device, depth: 1)
        result += zip(dirs, measured).map { DiskEntry(name: $0, isDirectory: true, usage: $1) }
        return result.sorted { $0.usage.bytes > $1.usage.bytes }
    }

    // MARK: - Walking

    private func walk(_ fd: Int32, device: dev_t, depth: Int) -> DiskUsage {
        var listing = DirectoryListing()
        read(fd, into: &listing)
        var total = DiskUsage()
        for file in listing.files { total.add(file.usage) }
        total.unreadable += listing.unreadable
        let dirs = listing.directories
        if depth < parallelDepth && dirs.count > 1 {
            for u in measureInParallel(dirs, in: fd, device: device, depth: depth + 1) { total.add(u) }
        } else {
            for name in dirs { total.add(walkChild(named: name, in: fd, device: device, depth: depth + 1)) }
        }
        return total
    }

    private func measureInParallel(_ names: [String], in parent: Int32, device: dev_t, depth: Int) -> [DiskUsage] {
        let slots = Slots(count: names.count)
        defer { slots.free() }
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            slots.base[i] = self.walkChild(named: names[i], in: parent, device: device, depth: depth)
        }
        return Array(slots.base)
    }

    /// Each parallel task writes only its own index, so sharing the buffer is safe.
    private struct Slots: @unchecked Sendable {
        let base: UnsafeMutableBufferPointer<DiskUsage>
        init(count: Int) {
            base = .allocate(capacity: count)
            base.initialize(repeating: DiskUsage())
        }
        func free() {
            base.deinitialize()
            base.deallocate()
        }
    }

    private func walkChild(named name: String, in parent: Int32, device: dev_t, depth: Int) -> DiskUsage {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { var u = DiskUsage(); u.unreadable = 1; return u }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == device else { return DiskUsage() }
        return walk(fd, device: device, depth: depth)
    }

    private func firstSighting(_ inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenInodes.insert(inode).inserted
    }

    // MARK: - getattrlistbulk

    private struct DirectoryListing {
        var files: [(name: String, usage: DiskUsage)] = []
        var directories: [String] = []
        var unreadable = 0
    }

    // Attribute bits from <sys/attr.h>. They're packed into the buffer in increasing bit order.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnAddedTime: UInt32 = 0x1000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let packInvalidAttrs: UInt64 = 0x0000_0008
    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2

    private func read(_ fd: Int32, into listing: inout DirectoryListing) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnDevID | Self.cmnObjType | Self.cmnModTime | Self.cmnFileID | Self.cmnAddedTime
        request.fileattr = Self.fileLinkCount | Self.fileAllocSize

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, Self.packInvalidAttrs)
            if count < 0 { listing.unreadable += 1; return }
            if count == 0 { return }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                parse(entry, into: &listing)
                entry += length
            }
        }
    }

    private func parse(_ entry: UnsafeMutableRawPointer, into listing: inout DirectoryListing) {
        // length, then the attribute_set_t of returned attributes (5 × UInt32)
        var cursor = entry + 4 + 20
        let nameRef = cursor
        let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
        let name = String(cString: (nameRef + nameOffset).assumingMemoryBound(to: CChar.self))
        cursor += 8
        cursor += 4 // device id; volume changes are caught when a folder is opened
        let type = cursor.loadUnaligned(as: UInt32.self); cursor += 4
        let modified = Date(timespec: cursor.loadUnaligned(as: timespec.self)); cursor += MemoryLayout<timespec>.size
        let fileID = cursor.loadUnaligned(as: UInt64.self); cursor += 8
        let added = cursor.loadUnaligned(as: timespec.self); cursor += MemoryLayout<timespec>.size
        let links = cursor.loadUnaligned(as: UInt32.self); cursor += 4
        let allocated = cursor.loadUnaligned(as: Int64.self)

        switch type {
        case Self.vDir:
            if skippedFolders.contains(fileID) { listing.unreadable += 1 } else { listing.directories.append(name) }
        case Self.vReg:
            var u = DiskUsage()
            if links <= 1 || firstSighting(fileID) {
                u.bytes = allocated
                u.files = 1
            }
            u.note(modified)
            if added.tv_sec > 0 { u.note(Date(timespec: added)) }
            listing.files.append((name, u))
        default:
            break // links, sockets, devices take no space worth reporting
        }
    }
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}
