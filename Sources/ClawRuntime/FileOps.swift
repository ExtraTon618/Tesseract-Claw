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

// MARK: - Path Security

/// Canonicalize a path, resolving symlinks and `..` components, to prevent directory traversal attacks.
/// For existing files, fully resolves the path. For new files (write), resolves the parent directory.
func normalizePath(_ path: String, mustExist: Bool = true) throws -> String {
    let url: URL
    if (path as NSString).isAbsolutePath {
        url = URL(fileURLWithPath: path)
    } else {
        let cwd = FileManager.default.currentDirectoryPath
        url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
    }

    if mustExist {
        // Resolve symlinks and canonicalize — catches ../../../etc/passwd
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw ToolError("file does not exist: \(path)")
        }
        return resolved.path
    } else {
        // For writes: canonicalize the parent directory, keep the filename
        let parent = url.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath()
        // Create parent dirs if needed (writeFile does this)
        return resolvedParent.appendingPathComponent(url.lastPathComponent).path
    }
}

/// Validate that a resolved path is within the workspace (cwd or its descendants).
/// Prevents escaping the project directory via symlinks or path traversal.
func validateWorkspaceBoundary(_ resolvedPath: String, cwd: String? = nil) throws {
    let workspace = cwd ?? FileManager.default.currentDirectoryPath
    let resolvedWorkspace = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path

    // Allow paths within the workspace, home directory, or /tmp
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let allowedPrefixes = [resolvedWorkspace, home, "/tmp", "/var/folders"]

    let isAllowed = allowedPrefixes.contains { prefix in
        resolvedPath.hasPrefix(prefix)
    }

    guard isAllowed else {
        throw ToolError("path '\(resolvedPath)' is outside allowed directories (workspace, home, /tmp). Refusing to access for security.")
    }
}

// MARK: - Read File

public struct ReadFileOutput: Codable, Equatable, Sendable {
    public let filePath: String
    public let content: String
    public let numLines: Int
    public let startLine: Int
    public let totalLines: Int
}

public func readFile(path: String, offset: Int = 0, limit: Int = 2000) throws -> ReadFileOutput {
    let safePath = try normalizePath(path, mustExist: true)
    try validateWorkspaceBoundary(safePath)
    let content = try String(contentsOfFile: safePath, encoding: .utf8)
    let allLines = content.components(separatedBy: "\n")
    let totalLines = allLines.count
    let startLine = min(offset, totalLines)
    let endLine = min(startLine + limit, totalLines)
    let selectedLines = Array(allLines[startLine..<endLine])
    let numberedContent = selectedLines.enumerated().map { (i, line) in
        "\(startLine + i + 1)\t\(line)"
    }.joined(separator: "\n")

    return ReadFileOutput(
        filePath: path,
        content: numberedContent,
        numLines: selectedLines.count,
        startLine: startLine + 1,
        totalLines: totalLines
    )
}

// MARK: - Write File

public struct WriteFileOutput: Codable, Equatable, Sendable {
    public let filePath: String
    public let content: String
}

public func writeFile(path: String, content: String) throws -> WriteFileOutput {
    let safePath = try normalizePath(path, mustExist: false)
    try validateWorkspaceBoundary(safePath)
    let directory = (safePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try content.write(toFile: safePath, atomically: true, encoding: .utf8)
    return WriteFileOutput(filePath: safePath, content: content)
}

// MARK: - Edit File

public struct EditFileOutput: Equatable, Sendable {
    public let filePath: String
    public let oldString: String
    public let newString: String
    public let originalFile: String
    public let replaceAll: Bool
}

public func editFile(path: String, oldString: String, newString: String, replaceAll: Bool = false) throws -> EditFileOutput {
    let safePath = try normalizePath(path, mustExist: true)
    try validateWorkspaceBoundary(safePath)
    let original = try String(contentsOfFile: safePath, encoding: .utf8)

    let occurrences = original.components(separatedBy: oldString).count - 1
    guard occurrences > 0 else {
        throw ToolError("old_string not found in file")
    }
    if !replaceAll && occurrences > 1 {
        throw ToolError("old_string is not unique in the file (\(occurrences) occurrences). Provide a larger string with more surrounding context to make it unique, or use replaceAll.")
    }

    let updated: String
    if replaceAll {
        updated = original.replacingOccurrences(of: oldString, with: newString)
    } else {
        if let range = original.range(of: oldString) {
            updated = original.replacingCharacters(in: range, with: newString)
        } else {
            throw ToolError("old_string not found in file")
        }
    }

    try updated.write(toFile: safePath, atomically: true, encoding: .utf8)

    return EditFileOutput(
        filePath: safePath,
        oldString: oldString,
        newString: newString,
        originalFile: original,
        replaceAll: replaceAll
    )
}

// MARK: - Glob Search

public struct GlobSearchOutput: Equatable, Sendable {
    public let durationMs: UInt64
    public let numFiles: Int
    public let filenames: [String]
    public let truncated: Bool
}

public func globSearch(pattern: String, path: String? = nil, limit: Int = 250) -> GlobSearchOutput {
    let start = DispatchTime.now()
    let searchPath = path ?? FileManager.default.currentDirectoryPath

    var results: [String] = []
    let fm = FileManager.default

    if let enumerator = fm.enumerator(atPath: searchPath) {
        while let file = enumerator.nextObject() as? String {
            if matchesGlobPattern(file, pattern: pattern) {
                results.append(file)
                if results.count >= limit {
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    return GlobSearchOutput(durationMs: elapsed / 1_000_000, numFiles: results.count, filenames: results, truncated: true)
                }
            }
        }
    }

    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return GlobSearchOutput(durationMs: elapsed / 1_000_000, numFiles: results.count, filenames: results, truncated: false)
}

// MARK: - Grep Search

public struct GrepSearchOutput: Equatable, Sendable {
    public let pattern: String
    public let matchCount: Int
    public let results: [String]
    public let truncated: Bool
}

public func grepSearch(pattern: String, path: String? = nil, glob globPattern: String? = nil, limit: Int = 250) -> GrepSearchOutput {
    let searchPath = path ?? FileManager.default.currentDirectoryPath
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return GrepSearchOutput(pattern: pattern, matchCount: 0, results: [], truncated: false)
    }

    var results: [String] = []
    let fm = FileManager.default

    if let enumerator = fm.enumerator(atPath: searchPath) {
        while let file = enumerator.nextObject() as? String {
            if let globPattern = globPattern, !matchesGlobPattern(file, pattern: globPattern) {
                continue
            }
            let fullPath = (searchPath as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (lineNum, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    results.append("\(file):\(lineNum + 1): \(line)")
                    if results.count >= limit {
                        return GrepSearchOutput(pattern: pattern, matchCount: results.count, results: results, truncated: true)
                    }
                }
            }
        }
    }

    return GrepSearchOutput(pattern: pattern, matchCount: results.count, results: results, truncated: false)
}

// MARK: - Glob Pattern Matching

private func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
    // Convert glob pattern to regex
    var regex = "^"
    var i = pattern.startIndex
    while i < pattern.endIndex {
        let c = pattern[i]
        switch c {
        case "*":
            let next = pattern.index(after: i)
            if next < pattern.endIndex && pattern[next] == "*" {
                regex += ".*"
                i = pattern.index(after: next)
                if i < pattern.endIndex && pattern[i] == "/" {
                    i = pattern.index(after: i)
                }
                continue
            } else {
                regex += "[^/]*"
            }
        case "?":
            regex += "[^/]"
        case ".":
            regex += "\\."
        case "{":
            regex += "("
        case "}":
            regex += ")"
        case ",":
            regex += "|"
        default:
            regex += String(c)
        }
        i = pattern.index(after: i)
    }
    regex += "$"

    return (try? NSRegularExpression(pattern: regex))
        .map { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil } ?? false
}
