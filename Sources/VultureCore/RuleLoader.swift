// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RuleProblem: Error, CustomStringConvertible, Equatable, Sendable {
    public let file: String
    public let ruleID: String?
    public let message: String

    public var description: String {
        if let ruleID { return "\(file): \(ruleID): \(message)" }
        return "\(file): \(message)"
    }
}

public enum RuleLoader {
    public static let maxTitleLength = 40
    public static let maxExplanationLength = 200

    /// The rules that ship with Vulture.
    public static func bundledRulesDirectory() -> URL? {
        // The command-line tool inside Vulture.app (Contents/Helpers) uses the app's copy in Contents/Resources.
        // Checked first because Bundle.module stops the program when it can't find its bundle.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let inApp = exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Vulture_VultureCore.bundle/Rules")
            if Glob.isRealDirectory(inApp) { return inApp }
        }
        return Bundle.module.url(forResource: "Rules", withExtension: nil)
    }

    /// Loads every `*.json` rule file in `directory`, throwing all problems found at once.
    public static func load(directory: URL) throws -> [Rule] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "schema.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rules: [Rule] = []
        var problems: [RuleProblem] = []
        for file in files {
            do {
                let decoded = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: file))
                if decoded.schemaVersion != RuleFile.currentSchemaVersion {
                    problems.append(RuleProblem(file: file.lastPathComponent, ruleID: nil,
                                                message: "schemaVersion \(decoded.schemaVersion) isn't supported (expected \(RuleFile.currentSchemaVersion))"))
                    continue
                }
                problems += decoded.rules.flatMap { validate($0, file: file.lastPathComponent) }
                rules += decoded.rules
            } catch let error as DecodingError {
                problems.append(RuleProblem(file: file.lastPathComponent, ruleID: nil, message: describe(error)))
            }
        }
        var seen: Set<String> = []
        for rule in rules where !seen.insert(rule.id).inserted {
            problems.append(RuleProblem(file: "-", ruleID: rule.id, message: "id is used by more than one rule"))
        }
        if !problems.isEmpty { throw RuleValidationError(problems: problems) }
        return rules
    }

    /// Static checks that every rule must pass before it's allowed to run.
    public static func validate(_ rule: Rule, file: String = "-", policy: SafetyPolicy = SafetyPolicy(home: URL(fileURLWithPath: "/"))) -> [RuleProblem] {
        var out: [String] = []
        if rule.id.range(of: #"^[a-z0-9]+(\.[a-z0-9]+(-[a-z0-9]+)*)+$"#, options: .regularExpression) == nil {
            out.append("id must look like `group.name`, lowercase with dots and dashes")
        }
        if rule.title.trimmingCharacters(in: .whitespaces).isEmpty || rule.title.count > maxTitleLength {
            out.append("title must be 1–\(maxTitleLength) characters")
        }
        if rule.explanation.trimmingCharacters(in: .whitespaces).isEmpty || rule.explanation.count > maxExplanationLength {
            out.append("explanation must be 1–\(maxExplanationLength) characters of plain language")
        }
        if rule.paths.isEmpty { out.append("paths is empty") }
        if rule.minAgeDays < 0 { out.append("minAgeDays can't be negative") }
        for pattern in rule.paths {
            out += checkPattern(pattern, policy: policy).map { "path `\(pattern)`: \($0)" }
        }
        return out.map { RuleProblem(file: file, ruleID: rule.id, message: $0) }
    }

    static func checkPattern(_ pattern: String, policy: SafetyPolicy) -> [String] {
        guard pattern.hasPrefix("~/") else { return ["must start with ~/ (only the home folder is supported)"] }
        let parts = pattern.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        if parts.contains(where: { $0.isEmpty }) { out.append("has an empty component") }
        if parts.contains(where: { $0 == ".." || $0 == "." }) { out.append("can't contain . or ..") }
        if parts.contains(where: { $0.contains("**") }) { out.append("** isn't supported") }
        if parts.count < 2 { out.append("must point inside a folder in the home folder, not at the folder itself") }
        if let first = parts.first, Glob.hasWildcard(first) { out.append("the first folder can't be a wildcard") }
        let literal = parts.prefix { !Glob.hasWildcard($0) }.joined(separator: "/")
        if !literal.isEmpty, policy.protectedPaths.contains(where: { literal == $0 || literal.hasPrefix($0 + "/") }) {
            out.append("points inside a protected folder")
        }
        return out
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx): return "missing `\(key.stringValue)` at \(path(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx): return "\(ctx.debugDescription) at \(path(ctx))"
        @unknown default: return "\(error)"
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}

public struct RuleValidationError: Error, CustomStringConvertible {
    public let problems: [RuleProblem]
    public var description: String { problems.map(\.description).joined(separator: "\n") }
}
