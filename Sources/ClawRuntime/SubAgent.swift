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

// MARK: - Sub-Agent Types

/// Predefined sub-agent types with different tool access levels.
public enum SubAgentType: String, Sendable {
    case explore         // Read-only exploration — no writes, no bash
    case plan            // Architecture planning — read-only + todo
    case verification    // Testing/verification — read + bash (no writes)
    case generalPurpose  // General tasks — most tools except agent/bash/repl

    public var label: String {
        switch self {
        case .explore:        return "Explore"
        case .plan:           return "Plan"
        case .verification:   return "Verification"
        case .generalPurpose: return "General"
        }
    }

    public static func from(_ name: String) -> SubAgentType {
        switch name.lowercased().replacingOccurrences(of: "-", with: "") {
        case "explore":                    return .explore
        case "plan":                       return .plan
        case "verification", "verify":     return .verification
        case "generalpurpose", "general":  return .generalPurpose
        default:                           return .generalPurpose
        }
    }

    /// Tools allowed for this sub-agent type. Agent tool is NEVER included (no recursion).
    public var allowedTools: Set<String> {
        switch self {
        case .explore:
            return ["read_file", "read_pdf", "glob_search", "grep_search",
                    "web_fetch", "web_search", "tool_search", "structured_output"]
        case .plan:
            return ["read_file", "read_pdf", "glob_search", "grep_search",
                    "web_fetch", "web_search", "tool_search", "todo",
                    "structured_output", "send_message"]
        case .verification:
            return ["bash", "read_file", "read_pdf", "glob_search", "grep_search",
                    "web_fetch", "web_search", "tool_search", "todo",
                    "structured_output", "send_message"]
        case .generalPurpose:
            return ["read_file", "read_pdf", "write_file", "edit_file",
                    "glob_search", "grep_search", "web_fetch", "web_search",
                    "todo", "notebook", "tool_search", "send_message",
                    "structured_output", "sleep"]
        }
    }

    /// Instruction appended to the sub-agent's system prompt.
    public var systemInstruction: String {
        switch self {
        case .explore:
            return "You are a background sub-agent specialized in code exploration. Search files, read code, and report findings. Do not modify any files."
        case .plan:
            return "You are a background sub-agent specialized in architecture planning. Explore the codebase, identify patterns, and design implementation approaches. Do not modify files."
        case .verification:
            return "You are a background sub-agent specialized in testing and verification. Run tests, check build output, and verify correctness. You may use bash but should not modify source files."
        case .generalPurpose:
            return "You are a background sub-agent handling a delegated task. Work only on the assigned task using the tools available to you. Do not ask the user questions."
        }
    }
}

// MARK: - Agent Manifest (Persisted State)

/// Persistent metadata for a spawned sub-agent, stored as JSON.
public struct AgentManifest: Codable, Sendable {
    public let agentId: String
    public let name: String
    public let description: String
    public let subagentType: String
    public var status: String            // "running", "completed", "failed"
    public let outputFile: String        // path to .claw-agents/{id}.md
    public let manifestFile: String      // path to .claw-agents/{id}.json
    public let createdAt: String
    public var completedAt: String?
    public var error: String?

    public init(agentId: String, name: String, description: String, subagentType: String,
                outputFile: String, manifestFile: String) {
        self.agentId = agentId
        self.name = name
        self.description = description
        self.subagentType = subagentType
        self.status = "running"
        self.outputFile = outputFile
        self.manifestFile = manifestFile
        self.createdAt = ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - Agent Store Directory

/// Returns the directory for storing agent manifests and output.
public func agentStoreDir() -> String {
    if let envDir = ProcessInfo.processInfo.environment["CLAW_AGENT_STORE"] {
        return envDir
    }
    let cwd = FileManager.default.currentDirectoryPath
    return "\(cwd)/.claw-agents"
}

// MARK: - Restricted Tool Executor

/// Wraps a LiveToolExecutor and enforces a tool whitelist.
/// Prevents sub-agents from calling dangerous or recursive tools.
public struct RestrictedToolExecutor: ToolExecutor {
    private var inner: LiveToolExecutor
    private let allowedTools: Set<String>

    public init(inner: LiveToolExecutor, allowedTools: Set<String>) {
        self.inner = inner
        self.allowedTools = allowedTools
    }

    public mutating func execute(toolName: String, input: String) throws -> String {
        guard allowedTools.contains(toolName) else {
            throw ToolError("tool '\(toolName)' is not available for this sub-agent. Available: \(allowedTools.sorted().joined(separator: ", "))")
        }
        return try inner.execute(toolName: toolName, input: input)
    }
}

// MARK: - Sub-Agent Input/Output

public struct SubAgentInput: Sendable {
    public let prompt: String
    public let description: String
    public let subagentType: SubAgentType
    public let maxIterations: Int

    public init(prompt: String, description: String = "", subagentType: SubAgentType = .generalPurpose, maxIterations: Int = 32) {
        self.prompt = prompt
        self.description = description
        self.subagentType = subagentType
        self.maxIterations = maxIterations
    }
}

/// Returned immediately to the parent when an agent is spawned.
public struct SubAgentSpawnResult: Sendable {
    public let manifest: AgentManifest
    public let summary: String  // human-readable summary for the parent LLM
}

// MARK: - Sub-Agent Spawning

/// Factory closure type for creating sub-agent runtimes.
/// The CLI layer provides this to bridge the API client into the runtime module.
public typealias SubAgentRuntimeFactory = (SubAgentType, [String]) -> SubAgentRunnable?

/// Protocol for a runnable sub-agent (hides generic ConversationRuntime types).
public protocol SubAgentRunnable {
    func runTurn(_ input: String) throws -> SubAgentTurnResult
}

public struct SubAgentTurnResult: Sendable {
    public let text: String
    public let toolsUsed: [String]
    public let iterations: Int

    public init(text: String, toolsUsed: [String], iterations: Int) {
        self.text = text
        self.toolsUsed = toolsUsed
        self.iterations = iterations
    }
}

/// Spawn a sub-agent in a background thread. Returns immediately with manifest paths.
/// The sub-agent runs asynchronously and persists results to `.claw-agents/`.
public func spawnSubAgent(
    input: SubAgentInput,
    runtimeFactory: @escaping SubAgentRuntimeFactory
) -> SubAgentSpawnResult {
    let agentId = generateAgentId()
    let slug = slugify(input.description.isEmpty ? String(input.prompt.prefix(40)) : input.description)
    let storeDir = agentStoreDir()

    // Ensure store directory exists
    try? FileManager.default.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

    let outputFile = "\(storeDir)/\(agentId).md"
    let manifestFile = "\(storeDir)/\(agentId).json"

    let manifest = AgentManifest(
        agentId: agentId,
        name: slug,
        description: input.description,
        subagentType: input.subagentType.label,
        outputFile: outputFile,
        manifestFile: manifestFile
    )

    // Write initial manifest and output
    writeManifest(manifest)
    writeOutput(outputFile, content: "# Sub-Agent: \(input.description)\n\nType: \(input.subagentType.label)\nStatus: running\n\n---\n\n**Task:**\n\(input.prompt)\n\n---\n\n")

    // Spawn background thread
    let capturedInput = input
    let capturedManifest = manifest
    DispatchQueue.global(qos: .userInitiated).async {
        runSubAgentJob(input: capturedInput, manifest: capturedManifest, runtimeFactory: runtimeFactory)
    }

    let summary = """
    Sub-agent spawned (background):
      ID: \(agentId)
      Type: \(input.subagentType.label)
      Task: \(input.description.isEmpty ? String(input.prompt.prefix(80)) : input.description)
      Output: \(outputFile)
      Manifest: \(manifestFile)

    The agent is running in the background. Check status with: read_file \(manifestFile)
    Read results with: read_file \(outputFile)
    """

    return SubAgentSpawnResult(manifest: manifest, summary: summary)
}

// MARK: - Background Agent Execution

private func runSubAgentJob(
    input: SubAgentInput,
    manifest: AgentManifest,
    runtimeFactory: SubAgentRuntimeFactory
) {
    guard let runtime = runtimeFactory(input.subagentType, Array(input.subagentType.allowedTools)) else {
        persistTerminalState(manifest: manifest, status: "failed", error: "Failed to create sub-agent runtime")
        return
    }

    do {
        let result = try runtime.runTurn(input.prompt)
        let output = """

        **Result:**
        \(result.text)

        ---
        Tools used: \(result.toolsUsed.joined(separator: ", "))
        Turns: \(result.iterations)
        """
        appendOutput(manifest.outputFile, content: output)
        persistTerminalState(manifest: manifest, status: "completed")
    } catch {
        let errorMsg = "Sub-agent error: \(error.localizedDescription)"
        appendOutput(manifest.outputFile, content: "\n\n**Error:** \(errorMsg)\n")
        persistTerminalState(manifest: manifest, status: "failed", error: errorMsg)
    }
}

// MARK: - File Persistence Helpers

private func writeManifest(_ manifest: AgentManifest) {
    guard let data = try? JSONEncoder().encode(manifest),
          let json = String(data: data, encoding: .utf8) else { return }
    try? json.write(toFile: manifest.manifestFile, atomically: true, encoding: .utf8)
}

private func persistTerminalState(manifest: AgentManifest, status: String, error: String? = nil) {
    var updated = manifest
    updated.status = status
    updated.completedAt = ISO8601DateFormatter().string(from: Date())
    updated.error = error
    writeManifest(updated)
}

private func writeOutput(_ path: String, content: String) {
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func appendOutput(_ path: String, content: String) {
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = content.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }
}

// MARK: - Utility

private func generateAgentId() -> String {
    let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    return String(nanos, radix: 16)
}

private func slugify(_ text: String) -> String {
    let slug = text.lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return String(slug.prefix(40))
}
