// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Newer cleaning rules, published separately from the app and signed by the project's maintainers.
///
/// A pack is JSON: `{ "payload": base64, "signature": base64, "keyID": hex }`. The payload is the JSON of `Contents`;
/// the signature is Ed25519 over the payload's exact bytes. A pack is only used when one of the app's trusted keys
/// verifies it and every rule passes the same checks as the rules that ship with the app.
public enum RuleUpdates {
    /// Public keys (raw, base64) allowed to sign rule packs. Empty until the project publishes its first key,
    /// so until then only the rules built into the app are used.
    public static let trustedKeys: [String] = []

    /// Version of the rules inside the app. A pack must be newer to be used.
    public static let bundledVersion = "2026.11.03"

    public struct Contents: Codable, Sendable {
        public var schemaVersion: Int
        /// `YYYY.MM.DD` or `YYYY.MM.DD.N`.
        public var version: String
        public var files: [String: RuleFile]
    }

    struct Envelope: Codable {
        var payload: String
        var signature: String
        var keyID: String
    }

    public enum Problem: Error, CustomStringConvertible, Equatable {
        case notAPack, noTrustedKeys, untrustedKey(String), badSignature, notNewer(String), invalidRules(String)

        public var description: String {
            switch self {
            case .notAPack: "That file isn't a Vulture rule pack."
            case .noTrustedKeys: "This build of Vulture doesn't trust any rule-pack keys yet, so only its built-in rules are used."
            case .untrustedKey(let id): "The pack is signed with a key this Vulture doesn't trust (\(id))."
            case .badSignature: "The pack's signature doesn't match its contents. It may have been changed."
            case .notNewer(let v): "Version \(v) isn't newer than the rules already in use."
            case .invalidRules(let why): "The pack's rules didn't pass Vulture's checks: \(why)"
            }
        }
    }

    public static func keyID(_ key: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func publicKeys(_ base64: [String]) -> [Curve25519.Signing.PublicKey] {
        base64.compactMap { Data(base64Encoded: $0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } }
    }

    // MARK: - Reading

    /// Checks the signature and every rule, and returns the rules. Throws a `Problem` explaining any refusal.
    public static func verify(_ data: Data, trusted: [String] = trustedKeys) throws -> (version: String, rules: [Rule]) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature) else { throw Problem.notAPack }
        let keys = publicKeys(trusted)
        guard !keys.isEmpty else { throw Problem.noTrustedKeys }
        guard let key = keys.first(where: { keyID($0) == envelope.keyID }) else { throw Problem.untrustedKey(envelope.keyID) }
        guard key.isValidSignature(signature, for: payload) else { throw Problem.badSignature }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: payload),
              contents.schemaVersion == RuleFile.currentSchemaVersion else { throw Problem.notAPack }

        var rules: [Rule] = []
        var problems: [RuleProblem] = []
        for (name, file) in contents.files.sorted(by: { $0.key < $1.key }) {
            problems += file.rules.flatMap { RuleLoader.validate($0, file: name) }
            rules += file.rules
        }
        if Set(rules.map(\.id)).count != rules.count { problems.append(RuleProblem(file: "-", ruleID: nil, message: "two rules share an id")) }
        if let first = problems.first { throw Problem.invalidRules(first.description) }
        return (contents.version, rules)
    }

    /// `2026.11.10` > `2026.11.03.2` > `2026.11.03`
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Installing

    public static func installedPack(home: URL) -> URL {
        VultureData.folder(home: home).appendingPathComponent("Rules/current.vulturerules")
    }

    /// Verifies a pack and keeps it for future scans. Returns its version.
    @discardableResult
    public static func install(_ data: Data, home: URL, trusted: [String] = trustedKeys) throws -> String {
        let (version, _) = try verify(data, trusted: trusted)
        let current = activeVersion(home: home, trusted: trusted)
        guard isNewer(version, than: current) else { throw Problem.notNewer(version) }
        let url = installedPack(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return version
    }

    /// The rules to use: an installed pack if it still verifies and is newer than the built-in rules, else the built-in rules.
    public static func activeRules(home: URL, bundled: [Rule], trusted: [String] = trustedKeys) -> (version: String, rules: [Rule]) {
        if let data = try? Data(contentsOf: installedPack(home: home)),
           let pack = try? verify(data, trusted: trusted), isNewer(pack.version, than: bundledVersion) {
            return pack
        }
        return (bundledVersion, bundled)
    }

    static func activeVersion(home: URL, trusted: [String]) -> String {
        if let data = try? Data(contentsOf: installedPack(home: home)), let pack = try? verify(data, trusted: trusted),
           isNewer(pack.version, than: bundledVersion) {
            return pack.version
        }
        return bundledVersion
    }

    // MARK: - For maintainers

    /// Makes a new signing key. Keep the private key secret and offline; publish the public key in `trustedKeys`.
    public static func makeKey() -> (privateKey: String, publicKey: String, keyID: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString(), keyID(key.publicKey))
    }

    /// Signs the rule files in `directory` into a pack.
    public static func pack(directory: URL, version: String, privateKey: String) throws -> Data {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Problem.notAPack }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        _ = try RuleLoader.load(directory: directory) // refuse to sign rules that don't pass the checks
        var files: [String: RuleFile] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            files[url.lastPathComponent] = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: url))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Contents(schemaVersion: RuleFile.currentSchemaVersion, version: version, files: files))
        let envelope = Envelope(payload: payload.base64EncodedString(), signature: try key.signature(for: payload).base64EncodedString(),
                                keyID: keyID(key.publicKey))
        return try encoder.encode(envelope)
    }
}
