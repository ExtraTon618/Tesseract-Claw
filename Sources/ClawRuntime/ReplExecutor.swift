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

// MARK: - REPL Output

public struct ReplOutput: Equatable, Sendable {
    public let language: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let durationMs: UInt64
}

// MARK: - Execute REPL

public func executeRepl(code: String, language: String, timeoutMs: UInt64? = nil) throws -> ReplOutput {
    let (program, args) = try resolveReplRuntime(language: language)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = args + [code]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let start = DispatchTime.now()
    try process.run()

    var interrupted = false
    if let timeoutMs = timeoutMs {
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutMs))
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            interrupted = true
        }
    } else {
        process.waitUntilExit()
    }

    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr: String
    if interrupted {
        stderr = "Command exceeded timeout of \(timeoutMs ?? 0) ms"
    } else {
        stderr = String(data: stderrData, encoding: .utf8) ?? ""
    }

    return ReplOutput(
        language: language,
        stdout: stdout,
        stderr: stderr,
        exitCode: process.terminationStatus,
        durationMs: elapsed / 1_000_000
    )
}

// MARK: - Runtime Resolution

private func resolveReplRuntime(language: String) throws -> (String, [String]) {
    switch language.trimmingCharacters(in: .whitespaces).lowercased() {
    case "python", "py":
        if let path = detectCommand(["python3", "python"]) {
            return (path, ["-c"])
        }
        throw ToolError("python runtime not found")

    case "javascript", "js", "node":
        if let path = detectCommand(["node"]) {
            return (path, ["-e"])
        }
        throw ToolError("node runtime not found")

    case "sh", "shell", "bash":
        if let path = detectCommand(["bash", "sh"]) {
            return (path, ["-lc"])
        }
        throw ToolError("shell runtime not found")

    default:
        throw ToolError("unsupported REPL language: \(language)")
    }
}

private func detectCommand(_ candidates: [String]) -> String? {
    for cmd in candidates {
        // Check common paths
        let paths = ["/usr/bin/\(cmd)", "/usr/local/bin/\(cmd)", "/opt/homebrew/bin/\(cmd)"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: use `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty { return path }
            }
        } catch {}
    }
    return nil
}
