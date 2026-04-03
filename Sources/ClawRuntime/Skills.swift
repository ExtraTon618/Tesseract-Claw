// MIT License
//
// Copyright (c) 2026 KnotTheory.ai Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

// MARK: - Skill Origin

public enum SkillOrigin: String, Equatable, Sendable {
    case projectClaw = "project .claw/skills"
    case userClaw = "~/.claw/skills"

    public var displayName: String { rawValue }
}

// MARK: - Skill Definition

public struct SkillDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let prompt: String
    public let path: String
    public let origin: SkillOrigin

    public init(name: String, description: String, prompt: String, path: String, origin: SkillOrigin) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.path = path
        self.origin = origin
    }
}

// MARK: - Skill Store

public struct SkillStore: Sendable {
    public let skills: [SkillDefinition]
    public let roots: [SkillRoot]

    public init(skills: [SkillDefinition] = [], roots: [SkillRoot] = []) {
        self.skills = skills
        self.roots = roots
    }

    /// Discover skills from project and user directories.
    /// Project skills shadow user skills with the same name.
    public static func discover(cwd: String, configHome: String? = nil) -> SkillStore {
        let home = configHome ?? ConfigLoader.defaultConfigHome()
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path

        // Build search roots in priority order (first match wins for shadowing)
        var roots: [SkillRoot] = []

        // Walk ancestors for project-level skills
        var cursor: String? = cwd
        while let dir = cursor {
            let projectSkills = "\(dir)/.claw/skills"
            if FileManager.default.fileExists(atPath: projectSkills) {
                roots.append(SkillRoot(path: projectSkills, origin: .projectClaw))
            }
            let parent = (dir as NSString).deletingLastPathComponent
            cursor = parent == dir ? nil : parent
        }

        // User-level skills
        let userSkills = "\(home)/skills"
        if FileManager.default.fileExists(atPath: userSkills) {
            roots.append(SkillRoot(path: userSkills, origin: .userClaw))
        }
        // Also check ~/.claw/skills directly if configHome is non-standard
        let defaultUserSkills = "\(userHome)/.claw/skills"
        if defaultUserSkills != userSkills && FileManager.default.fileExists(atPath: defaultUserSkills) {
            roots.append(SkillRoot(path: defaultUserSkills, origin: .userClaw))
        }

        // Deduplicate roots by path
        var seenPaths = Set<String>()
        roots = roots.filter { seenPaths.insert($0.path).inserted }

        // Load skills, respecting shadowing (first occurrence wins)
        var skills: [SkillDefinition] = []
        var seenNames = Set<String>()

        for root in roots {
            let discovered = loadSkillsFromRoot(root)
            for skill in discovered {
                let key = skill.name.lowercased()
                if seenNames.contains(key) { continue }
                seenNames.insert(key)
                skills.append(skill)
            }
        }

        return SkillStore(skills: skills, roots: roots)
    }

    /// Find a skill by name (case-insensitive).
    public func resolve(_ name: String) -> SkillDefinition? {
        let normalized = name
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^[/$]", with: "", options: .regularExpression)
            .lowercased()
        return skills.first { $0.name.lowercased() == normalized }
    }

    /// Render a human-readable report for /skills command.
    public func renderReport() -> String {
        var lines: [String] = []
        lines.append("Skills")

        if skills.isEmpty {
            lines.append("  No skills found.")
            lines.append("  Create a skill directory with SKILL.md:")
            lines.append("    .claw/skills/my-skill/SKILL.md")
            lines.append("    ~/.claw/skills/my-skill/SKILL.md")
            return lines.joined(separator: "\n")
        }

        lines.append("  \(skills.count) available skill(s)\n")

        // Group by origin
        let grouped = Dictionary(grouping: skills, by: { $0.origin })
        for origin in [SkillOrigin.projectClaw, .userClaw] {
            guard let group = grouped[origin], !group.isEmpty else { continue }
            lines.append("  [\(origin.displayName)]")
            for skill in group {
                let desc = skill.description.isEmpty ? "" : " — \(skill.description)"
                lines.append("    /\(skill.name)\(desc)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Render skill descriptions for system prompt injection.
    public func renderForPrompt() -> String? {
        guard !skills.isEmpty else { return nil }

        var lines = ["# Available Skills"]
        lines.append("The following skills are available. Use /skillname to invoke.\n")
        for skill in skills {
            let desc = skill.description.isEmpty ? "No description" : skill.description
            lines.append("- `/\(skill.name)` — \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Skill Root

public struct SkillRoot: Equatable, Sendable {
    public let path: String
    public let origin: SkillOrigin

    public init(path: String, origin: SkillOrigin) {
        self.path = path
        self.origin = origin
    }
}

// MARK: - Skill Loader

/// Load all skills from a single root directory.
/// Each subdirectory containing SKILL.md is a skill.
/// Also supports flat .md files as legacy skills.
func loadSkillsFromRoot(_ root: SkillRoot) -> [SkillDefinition] {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }

    var skills: [SkillDefinition] = []

    for entry in contents.sorted() {
        let entryPath = "\(root.path)/\(entry)"
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: entryPath, isDirectory: &isDir) {
            if isDir.boolValue {
                // Directory-based skill: look for SKILL.md
                let skillMdPath = "\(entryPath)/SKILL.md"
                if let skill = parseSkillFile(skillMdPath, dirName: entry, origin: root.origin) {
                    skills.append(skill)
                }
            } else if entry.hasSuffix(".md") {
                // Legacy flat .md skill file
                let name = (entry as NSString).deletingPathExtension
                if let skill = parseSkillFile(entryPath, dirName: name, origin: root.origin) {
                    skills.append(skill)
                }
            }
        }
    }

    return skills
}

/// Parse a SKILL.md file with optional YAML frontmatter.
func parseSkillFile(_ path: String, dirName: String, origin: SkillOrigin) -> SkillDefinition? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var name = dirName
    var description = ""
    var prompt = trimmed

    // Parse frontmatter
    if trimmed.hasPrefix("---") {
        let lines = trimmed.components(separatedBy: .newlines)
        var frontmatterEnd = -1
        for (i, line) in lines.enumerated() where i > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = i
                break
            }
        }
        if frontmatterEnd > 0 {
            for i in 1..<frontmatterEnd {
                let fmLine = lines[i].trimmingCharacters(in: .whitespaces)
                if fmLine.hasPrefix("name:") {
                    name = stripSkillYAMLValue(String(fmLine.dropFirst(5)))
                } else if fmLine.hasPrefix("description:") {
                    description = stripSkillYAMLValue(String(fmLine.dropFirst(12)))
                }
            }
            prompt = lines[(frontmatterEnd + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    return SkillDefinition(name: name, description: description, prompt: prompt, path: path, origin: origin)
}

private func stripSkillYAMLValue(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
       (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
    }
    return value
}
