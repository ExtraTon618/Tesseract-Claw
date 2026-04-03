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

// MARK: - Hook Event

public enum HookEvent: String, Sendable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
}

// MARK: - Hook Config

public struct HookConfig: Equatable, Sendable {
    public let preToolUse: [String]
    public let postToolUse: [String]

    public init(preToolUse: [String] = [], postToolUse: [String] = []) {
        self.preToolUse = preToolUse
        self.postToolUse = postToolUse
    }
}

// MARK: - Hook Run Result

public struct HookRunResult: Equatable, Sendable {
    public let denied: Bool
    public let messages: [String]

    public static func allow(_ messages: [String] = []) -> HookRunResult {
        HookRunResult(denied: false, messages: messages)
    }

    public var isDenied: Bool { denied }
}

// MARK: - Hook Runner

public struct HookRunner: Sendable {
    private let config: HookConfig

    public init(config: HookConfig = HookConfig()) {
        self.config = config
    }

    public func runPreToolUse(toolName: String, toolInput: String) -> HookRunResult {
        runCommands(
            event: .preToolUse,
            commands: config.preToolUse,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: nil,
            isError: false
        )
    }

    public func runPostToolUse(toolName: String, toolInput: String, toolOutput: String, isError: Bool) -> HookRunResult {
        runCommands(
            event: .postToolUse,
            commands: config.postToolUse,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            isError: isError
        )
    }

    private func runCommands(event: HookEvent, commands: [String], toolName: String, toolInput: String, toolOutput: String?, isError: Bool) -> HookRunResult {
        guard !commands.isEmpty else {
            return .allow()
        }

        let payloadDict: [String: Any] = [
            "hook_event_name": event.rawValue,
            "tool_name": toolName,
            "tool_input": toolInput,
            "tool_output": toolOutput as Any,
            "tool_result_is_error": isError
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: payloadDict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var messages: [String] = []

        for command in commands {
            let outcome = Self.runCommand(
                command,
                event: event,
                toolName: toolName,
                toolInput: toolInput,
                toolOutput: toolOutput,
                isError: isError,
                payload: payload
            )

            switch outcome {
            case .allow(let message):
                if let msg = message { messages.append(msg) }
            case .deny(let message):
                let msg = message ?? "\(event.rawValue) hook denied tool `\(toolName)`"
                messages.append(msg)
                return HookRunResult(denied: true, messages: messages)
            case .warn(let message):
                messages.append(message)
            }
        }

        return .allow(messages)
    }

    private static func runCommand(_ command: String, event: HookEvent, toolName: String, toolInput: String, toolOutput: String?, isError: Bool, payload: String) -> HookCommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]

        var env = ProcessInfo.processInfo.environment
        env["HOOK_EVENT"] = event.rawValue
        env["HOOK_TOOL_NAME"] = toolName
        env["HOOK_TOOL_INPUT"] = toolInput
        env["HOOK_TOOL_IS_ERROR"] = isError ? "1" : "0"
        if let toolOutput = toolOutput {
            env["HOOK_TOOL_OUTPUT"] = toolOutput
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            if let payloadData = payload.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(payloadData)
            }
            stdinPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message: String? = stdout.isEmpty ? nil : stdout
            let exitCode = process.terminationStatus

            switch exitCode {
            case 0:
                return .allow(message: message)
            case 2:
                return .deny(message: message)
            default:
                let detail = message ?? (stderr.isEmpty ? nil : stderr) ?? ""
                let warning = "Hook `\(command)` exited with status \(exitCode); allowing tool execution to continue\(detail.isEmpty ? "" : ": \(detail)")"
                return .warn(message: warning)
            }
        } catch {
            return .warn(message: "\(event.rawValue) hook `\(command)` failed to start for `\(toolName)`: \(error)")
        }
    }
}

private enum HookCommandOutcome {
    case allow(message: String?)
    case deny(message: String?)
    case warn(message: String)
}
