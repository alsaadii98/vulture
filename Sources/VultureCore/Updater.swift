// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Security

/// A newer Vulture, as described by `update.json` on the latest GitHub release.
public struct UpdateInfo: Codable, Sendable, Equatable {
    public var version: String
    public var url: URL
    public var sha256: String
    public var size: Int64
    public var minimumSystemVersion: String
    public var notesURL: URL?

    public init(version: String, url: URL, sha256: String, size: Int64, minimumSystemVersion: String, notesURL: URL? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
        self.notesURL = notesURL
    }
}

/// Keeps Vulture up to date without reinstalling it.
///
/// It only downloads a small JSON file from GitHub, and sends nothing about the Mac. A new copy is used only when
/// its code signature is valid and was made with the same release key as the copy that's running, so a changed
/// download, or one built by someone else, is refused. Same key also means macOS keeps Full Disk Access.
public enum Updater {
    public static let feed = URL(string: "https://github.com/alsaadii98/vulture/releases/latest/download/update.json")!
    public static let bundleID = "io.github.alsaadii98.Vulture"

    /// Other signing identities a future release may switch to (for example a Developer ID), as code requirements.
    /// A release adds the new one here before any update is signed with it.
    public static let alsoAccepted: [String] = []

    public enum Problem: Error, CustomStringConvertible, Equatable {
        case notInstalled
        case notUpdatable
        case badFeed
        case needsNewerMacOS(String)
        case download(String)
        case damaged
        case wrongApp
        case untrusted(String)
        case cantReplace(String)

        public var description: String {
            switch self {
            case .notInstalled: "This copy of Vulture isn't inside Vulture.app, so it can't update itself."
            case .notUpdatable: "This is a development build of Vulture. Only released copies update themselves."
            case .badFeed: "Couldn't read the update information from GitHub."
            case .needsNewerMacOS(let v): "The new version needs macOS \(v) or later."
            case .download(let why): "The download didn't finish: \(why)"
            case .damaged: "The download was damaged (it doesn't match its checksum), so it wasn't used."
            case .wrongApp: "The download isn't the expected version of Vulture, so it wasn't used."
            case .untrusted(let why): "The download isn't signed by Vulture's release key, so it wasn't used. (\(why))"
            case .cantReplace(let why): "Vulture couldn't replace itself: \(why) You can download the new version from GitHub instead."
            }
        }
    }

    // MARK: - Where and what is installed

    /// The Vulture.app containing `executable`: Contents/MacOS/Vulture or Contents/Helpers/vulture.
    public static func app(containing executable: URL) -> URL? {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }

    public static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    static func identifier(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    /// `0.10.0` > `0.9.2`; anything after a `-` (like `-dev`) is ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Checking

    /// The newer version on offer, or nil when `current` is up to date.
    public static func check(current: String, feed: URL = feed) async throws -> UpdateInfo? {
        let data: Data
        do { data = try await fetch(feed) } catch { throw Problem.download(error.localizedDescription) }
        guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data), info.url.scheme == "https" || info.url.isFileURL
        else { throw Problem.badFeed }
        guard isNewer(info.version, than: current) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if isNewer(info.minimumSystemVersion, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") {
            throw Problem.needsNewerMacOS(info.minimumSystemVersion)
        }
        return info
    }

    // MARK: - Installing

    /// Downloads, checks and swaps in the new version. The running copy keeps running until it's restarted.
    public static func install(_ info: UpdateInfo, replacing app: URL) async throws {
        let requirement = try trustedRequirement(for: app)
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw Problem.cantReplace("your account can't change \(app.deletingLastPathComponent().path).")
        }
        // A folder on the same disk as the app, so the final swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }

        let data: Data
        do { data = try await fetch(info.url) } catch { throw Problem.download(error.localizedDescription) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Int64(data.count) == info.size, digest == info.sha256.lowercased() else { throw Problem.damaged }
        let zip = work.appendingPathComponent("update.zip")
        try data.write(to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        do { try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) } catch { throw Problem.damaged }
        let apps = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }) ?? []
        guard apps.count == 1, let new = apps.first else { throw Problem.wrongApp }
        try verify(new, version: info.version, requirement: requirement)

        // Downloads made by Vulture aren't quarantined, but make sure: the update was checked above.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", new.path])
        do {
            _ = try fm.replaceItemAt(app, withItemAt: new, backupItemName: nil, options: [])
        } catch {
            throw Problem.cantReplace(error.localizedDescription)
        }
    }

    /// Checks a downloaded app before it's used.
    static func verify(_ new: URL, version: String, requirement: String) throws {
        guard identifier(of: new) == bundleID, Updater.version(of: new) == version else { throw Problem.wrongApp }
        let requirements = [requirement] + alsoAccepted
        var lastError = "no matching signature"
        for text in requirements {
            guard let why = signatureProblem(of: new, against: text) else { return }
            lastError = why
        }
        throw Problem.untrusted(lastError)
    }

    /// The code requirement a new version must meet: the running copy's own, which names its signing certificate.
    /// Ad hoc and development builds name only their exact code, so they can't update.
    static func trustedRequirement(for app: URL) throws -> String {
        #if DEBUG
        if let forTests = ProcessInfo.processInfo.environment["VULTURE_UPDATE_REQUIREMENT"] { return forTests }
        #endif
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { throw Problem.notUpdatable }
        let string = text as String
        guard string.contains("certificate"), !string.contains("cdhash") else { throw Problem.notUpdatable }
        return string
    }

    /// nil when `app` is validly signed and meets the requirement, otherwise why not.
    static func signatureProblem(of app: URL, against requirementText: String) -> String? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return "not signed" }
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return "bad requirement"
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        if status == errSecSuccess { return nil }
        return error?.takeRetainedValue().localizedDescription ?? (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
    }

    /// Opens `app` once the process `pid` has quit. Used to restart into the new version.
    public static func relaunch(_ app: URL, after pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Values are passed as arguments, never put into the script text.
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh", String(pid), app.path]
        try process.run()
    }

    // MARK: - Helpers

    static func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Vulture", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Problem.download("GitHub answered \(http.statusCode)")
        }
        return data
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Problem.damaged }
    }
}
