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

// MARK: - Permission Mode

public enum PermissionMode: Int, Comparable, Equatable, Sendable {
    case readOnly = 0
    case workspaceWrite = 1
    case dangerFullAccess = 2
    case prompt = 3
    case allow = 4

    public static func < (lhs: PermissionMode, rhs: PermissionMode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var asString: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .dangerFullAccess: return "danger-full-access"
        case .prompt: return "prompt"
        case .allow: return "allow"
        }
    }
}

// MARK: - Permission Request

public struct PermissionRequest: Equatable, Sendable {
    public let toolName: String
    public let input: String
    public let currentMode: PermissionMode
    public let requiredMode: PermissionMode

    public init(toolName: String, input: String, currentMode: PermissionMode, requiredMode: PermissionMode) {
        self.toolName = toolName
        self.input = input
        self.currentMode = currentMode
        self.requiredMode = requiredMode
    }
}

// MARK: - Permission Prompt Decision

public enum PermissionPromptDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
}

// MARK: - Permission Prompter Protocol

public protocol PermissionPrompter {
    mutating func decide(_ request: PermissionRequest) -> PermissionPromptDecision
}

// MARK: - Permission Outcome

public enum PermissionOutcome: Equatable, Sendable {
    case allow
    case deny(reason: String)
}

// MARK: - Permission Policy

public class PermissionPolicy {
    private let activeMode: PermissionMode
    private var toolRequirements: [String: PermissionMode]
    /// Cache of user decisions within this session: tool name → allow/deny
    private var sessionCache: [String: PermissionOutcome] = [:]

    public init(activeMode: PermissionMode) {
        self.activeMode = activeMode
        self.toolRequirements = [:]
    }

    public func setToolRequirement(_ toolName: String, mode: PermissionMode) {
        toolRequirements[toolName] = mode
    }

    public func withToolRequirement(_ toolName: String, mode: PermissionMode) -> PermissionPolicy {
        let copy = PermissionPolicy(activeMode: activeMode)
        copy.toolRequirements = self.toolRequirements
        copy.sessionCache = self.sessionCache
        copy.toolRequirements[toolName] = mode
        return copy
    }

    public func getActiveMode() -> PermissionMode { activeMode }

    public func requiredMode(for toolName: String) -> PermissionMode {
        toolRequirements[toolName] ?? .dangerFullAccess
    }

    /// Clear cached decisions (e.g. on /clear or session reset)
    public func clearCache() {
        sessionCache.removeAll()
    }

    /// Cache an allow decision for a tool (e.g. after bash risk assessment approval)
    public func cacheAllow(_ toolName: String) {
        sessionCache[toolName] = .allow
    }

    public func authorize(toolName: String, input: String, prompter: inout (any PermissionPrompter)?) -> PermissionOutcome {
        let currentMode = getActiveMode()
        let requiredMode = requiredMode(for: toolName)

        if currentMode == .allow || currentMode >= requiredMode {
            return .allow
        }

        // Check session cache — if user already approved/denied this tool, reuse decision
        if let cached = sessionCache[toolName] {
            return cached
        }

        let request = PermissionRequest(
            toolName: toolName,
            input: input,
            currentMode: currentMode,
            requiredMode: requiredMode
        )

        if currentMode == .prompt || (currentMode == .workspaceWrite && requiredMode == .dangerFullAccess) {
            guard var p = prompter else {
                return .deny(reason: "tool '\(toolName)' requires approval to escalate from \(currentMode.asString) to \(requiredMode.asString)")
            }
            let decision = p.decide(request)
            switch decision {
            case .allow:
                sessionCache[toolName] = .allow
                return .allow
            case .deny(let reason):
                let outcome = PermissionOutcome.deny(reason: reason)
                sessionCache[toolName] = outcome
                return outcome
            }
        }

        return .deny(reason: "tool '\(toolName)' requires \(requiredMode.asString) permission; current mode is \(currentMode.asString)")
    }
}
