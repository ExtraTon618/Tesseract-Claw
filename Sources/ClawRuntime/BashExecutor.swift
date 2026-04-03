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

// MARK: - Bash Command Input

public struct BashCommandInput: Sendable {
    public let command: String
    public let timeout: UInt64?
    public let description: String?
    public let runInBackground: Bool

    public init(command: String, timeout: UInt64? = nil, description: String? = nil, runInBackground: Bool = false) {
        self.command = command
        self.timeout = timeout
        self.description = description
        self.runInBackground = runInBackground
    }
}

// MARK: - Bash Command Output

public struct BashCommandOutput: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let interrupted: Bool
    public let exitCode: Int32

    public init(stdout: String, stderr: String, interrupted: Bool, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.interrupted = interrupted
        self.exitCode = exitCode
    }
}

// MARK: - Dangerous Command Detection

/// Sentinel used to extract the shell's final working directory after command execution.
private let cwdSentinel = "__TESSERACT_CWD__"

/// Patterns that indicate potentially destructive or privilege-escalating commands.
/// These require explicit dangerFullAccess permission and user confirmation.
private let dangerousPatterns: [(pattern: String, description: String)] = [
    ("rm\\s+(-[a-zA-Z]*f|-[a-zA-Z]*r|--force|--recursive)", "recursive/forced file deletion"),
    ("rm\\s+-rf\\s+/", "destructive root deletion"),
    ("chmod\\s+(000|777|\\+s)", "dangerous permission change"),
    ("chown\\s+", "ownership change"),
    ("sudo\\s+", "privilege escalation"),
    ("mkfs", "filesystem format"),
    ("dd\\s+", "raw disk write"),
    ("> /dev/", "writing to device file"),
    (":(){ :|:& };:", "fork bomb"),
    ("\\|\\s*sh\\b", "piped shell execution"),
    ("\\|\\s*bash\\b", "piped bash execution"),
    ("curl.*\\|\\s*(sh|bash)", "remote code execution"),
    ("wget.*\\|\\s*(sh|bash)", "remote code execution"),
    ("eval\\s+", "dynamic code evaluation"),
    ("git\\s+push.*--force", "force push (destructive)"),
    ("git\\s+reset\\s+--hard", "hard reset (destroys changes)"),
    ("git\\s+clean\\s+-[a-zA-Z]*f", "git clean (deletes untracked files)"),
    ("\\bkill\\s+-9", "forced process kill"),
    ("\\bkillall\\b", "kill all matching processes"),
    ("\\bshutdown\\b", "system shutdown"),
    ("\\breboot\\b", "system reboot"),
    ("launchctl\\s+unload", "service unload"),
    ("defaults\\s+delete", "defaults deletion"),
    ("networksetup", "network configuration change"),
    ("csrutil\\s+disable", "SIP disable"),
]

/// Assess a bash command for dangerous patterns. Returns a list of risk descriptions.
public func assessBashRisk(_ command: String) -> [String] {
    var risks: [String] = []
    for (pattern, description) in dangerousPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
            risks.append(description)
        }
    }
    return risks
}

// MARK: - Execute Bash

public func executeBash(_ input: BashCommandInput) throws -> BashCommandOutput {
    let cwd = FileManager.default.currentDirectoryPath

    if input.runInBackground {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", input.command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return BashCommandOutput(stdout: "", stderr: "", interrupted: false, exitCode: 0)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Wrap command to capture final working directory for cd persistence
    let wrappedCommand = "\(input.command)\n__claw_rc=$?; printf '\\n\(cwdSentinel)%s' \"$PWD\"; exit $__claw_rc"
    process.arguments = ["-lc", wrappedCommand]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    var interrupted = false
    if let timeoutMs = input.timeout {
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

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr: String
    if interrupted {
        stderr = "Command exceeded timeout of \(input.timeout ?? 0) ms"
    } else {
        stderr = String(data: stderrData, encoding: .utf8) ?? ""
    }

    // Extract and apply the shell's final working directory
    if let sentinelRange = stdout.range(of: "\n\(cwdSentinel)", options: .backwards) {
        let afterSentinel = stdout[sentinelRange.upperBound...]
        let newCwd = afterSentinel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip sentinel from visible output
        stdout = String(stdout[..<sentinelRange.lowerBound])
        // Update process CWD so subsequent bash calls use the new directory
        if !newCwd.isEmpty && newCwd != cwd {
            FileManager.default.changeCurrentDirectoryPath(newCwd)
        }
    }

    return BashCommandOutput(
        stdout: stdout,
        stderr: stderr,
        interrupted: interrupted,
        exitCode: process.terminationStatus
    )
}
