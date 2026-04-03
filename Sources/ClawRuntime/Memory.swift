// MIT License
//
// Copyright (c) 2026 KnotTheory.ai
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
import CryptoKit

// MARK: - Memory File

public struct MemoryFile: Equatable, Sendable {
    public let path: String
    public let name: String
    public let description: String
    public let type: String  // user, feedback, project, reference
    public let content: String

    public init(path: String, name: String, description: String, type: String, content: String) {
        self.path = path
        self.name = name
        self.description = description
        self.type = type
        self.content = content
    }
}

// MARK: - Memory Index Entry

public struct MemoryIndexEntry: Equatable, Sendable {
    public let title: String
    public let file: String
    public let hook: String

    public init(title: String, file: String, hook: String) {
        self.title = title
        self.file = file
        self.hook = hook
    }
}

// MARK: - Memory Store

public struct MemoryStore: Sendable {
    public let projectDir: String
    /// Raw content of MEMORY.md (the index file — always loaded into prompt)
    public let indexContent: String?
    public let indexEntries: [MemoryIndexEntry]
    /// Catalog of available memory files (metadata only — content loaded on-demand)
    public let availableFiles: [MemoryFileMeta]

    public init(projectDir: String, indexContent: String? = nil, indexEntries: [MemoryIndexEntry] = [], availableFiles: [MemoryFileMeta] = []) {
        self.projectDir = projectDir
        self.indexContent = indexContent
        self.indexEntries = indexEntries
        self.availableFiles = availableFiles
    }

    /// Discover memory store for a given project working directory.
    /// Searches ~/.claw/projects/<hash>/memory/.
    public static func discover(cwd: String, configHome: String? = nil) -> MemoryStore {
        let home = configHome ?? ConfigLoader.defaultConfigHome()
        let hash = projectHash(cwd)
        let clawDir = "\(home)/projects/\(hash)/memory"

        let fm = FileManager.default
        let projectDir: String
        if fm.fileExists(atPath: clawDir) {
            projectDir = clawDir
        } else {
            return MemoryStore(projectDir: clawDir)
        }

        // Load MEMORY.md index content (always injected into prompt)
        let indexPath = "\(projectDir)/MEMORY.md"
        let indexContent = try? String(contentsOfFile: indexPath, encoding: .utf8)
        let indexEntries = parseMemoryIndex(indexPath)

        // Scan available memory files (metadata only — no content loaded)
        var availableFiles: [MemoryFileMeta] = []
        if let contents = try? fm.contentsOfDirectory(atPath: projectDir) {
            for filename in contents.sorted() {
                guard filename.hasSuffix(".md"), filename != "MEMORY.md" else { continue }
                let filePath = "\(projectDir)/\(filename)"
                if let meta = parseMemoryFileMeta(filePath) {
                    availableFiles.append(meta)
                }
            }
        }

        return MemoryStore(projectDir: projectDir, indexContent: indexContent, indexEntries: indexEntries, availableFiles: availableFiles)
    }

    /// Maximum chars of MEMORY.md to inject into system prompt.
    /// Beyond this, the model should use read_file to access the full index.
    public static let maxIndexChars = 6_000

    /// Render memory for injection into system prompt.
    /// Only MEMORY.md content is injected into the system prompt. Individual files
    /// are read on-demand by the model via read_file tool.
    public func renderForPrompt() -> String? {
        guard indexContent != nil || !availableFiles.isEmpty else { return nil }

        var sections: [String] = []
        sections.append("# Memory")
        sections.append("""
        You have a persistent memory system at `\(projectDir)/`.

        IMPORTANT: Memory is ALREADY loaded below — you do NOT need to call any tool to "load memory." There is no `workspace_info` tool. When the user asks to load, check, or recall memory, simply refer to the MEMORY.md content shown below and summarize what you know.

        To access individual memory files for more detail, use the `read_file` tool with their full path. Only read memory files when they seem relevant to the current task.

        When the user asks you to remember something, save it using `write_file`. When they ask you to recall or check memory, refer to the index below or use `read_file` on specific files.
        """)

        if let content = indexContent {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.count <= Self.maxIndexChars {
                    sections.append("## MEMORY.md\n\n\(trimmed)")
                } else {
                    let truncated = String(trimmed.prefix(Self.maxIndexChars))
                    sections.append("## MEMORY.md\n\n\(truncated)\n\n_[MEMORY.md truncated at \(Self.maxIndexChars) chars — use `read_file` on `\(projectDir)/MEMORY.md` for the full index]_")
                }
            }
        }

        if !availableFiles.isEmpty {
            var fileList = ["## Available memory files (\(availableFiles.count))"]
            for meta in availableFiles {
                let desc = meta.description.isEmpty ? "" : " — \(meta.description)"
                fileList.append("- `\(meta.path)` [\(meta.type)] \(meta.name)\(desc)")
            }
            sections.append(fileList.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// Render a human-readable report for /memory command.
    public func renderReport() -> String {
        var lines: [String] = []
        lines.append("Memory Store")
        lines.append("  Directory: \(projectDir)")
        lines.append("  Available files: \(availableFiles.count)")

        if let content = indexContent {
            let lineCount = content.components(separatedBy: .newlines).count
            lines.append("  MEMORY.md: \(lineCount) lines (loaded into prompt)")
        } else {
            lines.append("  MEMORY.md: not found")
        }

        if !indexEntries.isEmpty {
            lines.append("\n  Index entries:")
            for entry in indexEntries {
                lines.append("    - \(entry.title) → \(entry.file)")
                if !entry.hook.isEmpty {
                    lines.append("      \(entry.hook)")
                }
            }
        }

        if !availableFiles.isEmpty {
            lines.append("\n  Memory files (read on-demand via read_file):")
            for meta in availableFiles {
                let desc = meta.description.isEmpty ? "" : " — \(meta.description)"
                lines.append("    [\(meta.type)] \(meta.name)\(desc)")
                lines.append("           \(meta.path)")
            }
        } else {
            lines.append("\n  No memory files found.")
            lines.append("  Create \(projectDir)/MEMORY.md to start.")
        }

        return lines.joined(separator: "\n")
    }

    /// Load a specific memory file's full content (for on-demand reading).
    public func loadFile(named filename: String) -> MemoryFile? {
        let path: String
        if filename.contains("/") {
            path = filename  // absolute path
        } else {
            path = "\(projectDir)/\(filename)"
        }
        return parseMemoryFile(path)
    }
}

// MARK: - Memory File Metadata (lightweight, no content)

public struct MemoryFileMeta: Equatable, Sendable {
    public let path: String
    public let name: String
    public let description: String
    public let type: String

    public init(path: String, name: String, description: String, type: String) {
        self.path = path
        self.name = name
        self.description = description
        self.type = type
    }
}

// MARK: - Project Hash

/// Stable hash of the project working directory path, used to namespace memory storage.
/// Produces a 16-char hex string from MD5.
public func projectHash(_ path: String) -> String {
    let data = Data(path.utf8)
    let digest = Insecure.MD5.hash(data: data)
    // Take first 8 bytes → 16 hex chars
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

// MARK: - MEMORY.md Parser

/// Parse MEMORY.md index file. Each entry is a markdown link line:
/// `- [Title](file.md) — one-line hook`
func parseMemoryIndex(_ path: String) -> [MemoryIndexEntry] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

    var entries: [MemoryIndexEntry] = []
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Match: - [Title](file.md) — hook
        guard trimmed.hasPrefix("- [") else { continue }
        guard let titleEnd = trimmed.range(of: "](") else { continue }
        let title = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<titleEnd.lowerBound])
        let afterTitle = String(trimmed[titleEnd.upperBound...])
        guard let fileEnd = afterTitle.range(of: ")") else { continue }
        let file = String(afterTitle[afterTitle.startIndex..<fileEnd.lowerBound])
        let hookPart = String(afterTitle[fileEnd.upperBound...])
        let hook = hookPart
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^[—–-]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        entries.append(MemoryIndexEntry(title: title, file: file, hook: hook))
    }
    return entries
}

// MARK: - Memory File Metadata Parser (frontmatter only, no body)

func parseMemoryFileMeta(_ path: String) -> MemoryFileMeta? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let filename = (path as NSString).lastPathComponent
    var name = (filename as NSString).deletingPathExtension
    var description = ""
    var type = "project"

    // Parse frontmatter only
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
                    name = stripYAMLValue(String(fmLine.dropFirst(5)))
                } else if fmLine.hasPrefix("description:") {
                    description = stripYAMLValue(String(fmLine.dropFirst(12)))
                } else if fmLine.hasPrefix("type:") {
                    type = stripYAMLValue(String(fmLine.dropFirst(5)))
                }
            }
        }
    }

    return MemoryFileMeta(path: path, name: name, description: description, type: type)
}

// MARK: - Full Memory File Parser (for on-demand loading)

func parseMemoryFile(_ path: String) -> MemoryFile? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let filename = (path as NSString).lastPathComponent
    var name = (filename as NSString).deletingPathExtension
    var description = ""
    var type = "project"
    var body = trimmed

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
                    name = stripYAMLValue(String(fmLine.dropFirst(5)))
                } else if fmLine.hasPrefix("description:") {
                    description = stripYAMLValue(String(fmLine.dropFirst(12)))
                } else if fmLine.hasPrefix("type:") {
                    type = stripYAMLValue(String(fmLine.dropFirst(5)))
                }
            }
            body = lines[(frontmatterEnd + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    return MemoryFile(path: path, name: name, description: description, type: type, content: body)
}

private func stripYAMLValue(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
       (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
    }
    return value
}
