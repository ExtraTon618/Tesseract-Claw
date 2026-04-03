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

// MARK: - Errors

public struct ToolError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
}

extension ToolError: CustomStringConvertible {
    public var description: String { message }
}

public struct RuntimeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
}

extension RuntimeError: CustomStringConvertible {
    public var description: String { message }
}

// MARK: - API Types

public struct ApiRequest: Equatable, Sendable {
    public let systemPrompt: [String]
    public let messages: [ConversationMessage]

    public init(systemPrompt: [String], messages: [ConversationMessage]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

public enum AssistantEvent: Equatable, Sendable {
    case textDelta(String)
    case toolUse(id: String, name: String, input: String)
    case usage(TokenUsage)
    case messageStop
}

// MARK: - Protocols

public protocol ApiClient {
    mutating func stream(_ request: ApiRequest) throws -> [AssistantEvent]
}

public protocol ToolExecutor {
    mutating func execute(toolName: String, input: String) throws -> String
}

// MARK: - Turn Summary

public struct TurnSummary: Equatable, Sendable {
    public let assistantMessages: [ConversationMessage]
    public let toolResults: [ConversationMessage]
    public let iterations: Int
    public let usage: TokenUsage

    public init(assistantMessages: [ConversationMessage], toolResults: [ConversationMessage], iterations: Int, usage: TokenUsage) {
        self.assistantMessages = assistantMessages
        self.toolResults = toolResults
        self.iterations = iterations
        self.usage = usage
    }
}

// MARK: - Conversation Runtime

public class ConversationRuntime<C: ApiClient, T: ToolExecutor> {
    private var session: Session
    private var apiClient: C
    private var toolExecutor: T
    private let permissionPolicy: PermissionPolicy
    private let systemPrompt: [String]
    private let maxIterations: Int
    private let usageTracker: UsageTracker
    private let hookRunner: HookRunner
    private let compactionConfig: CompactionConfig

    public init(
        session: Session,
        apiClient: C,
        toolExecutor: T,
        permissionPolicy: PermissionPolicy,
        systemPrompt: [String],
        maxIterations: Int = Int.max,
        hookConfig: HookConfig = HookConfig(),
        compactionConfig: CompactionConfig = CompactionConfig(preserveRecentMessages: 6, maxEstimatedTokens: 6_000)
    ) {
        self.session = session
        self.apiClient = apiClient
        self.toolExecutor = toolExecutor
        self.permissionPolicy = permissionPolicy
        self.systemPrompt = systemPrompt
        self.maxIterations = maxIterations
        self.usageTracker = UsageTracker.fromSession(session)
        self.hookRunner = HookRunner(config: hookConfig)
        self.compactionConfig = compactionConfig
    }

    public func runTurn(_ userInput: String, prompter: inout (any PermissionPrompter)?, onStatus: StatusCallback? = nil) throws -> TurnSummary {
        session.messages.append(.userText(userInput))

        // Auto-compact if context is growing too large
        if shouldCompact(session, config: compactionConfig) {
            let result = compactSession(session, config: compactionConfig)
            if result.removedMessageCount > 0 {
                session = result.compactedSession
            }
        }

        var assistantMessages: [ConversationMessage] = []
        var toolResults: [ConversationMessage] = []
        var iterations = 0

        onStatus?(.thinking)

        while true {
            iterations += 1
            if iterations > maxIterations {
                throw RuntimeError("conversation loop exceeded the maximum number of iterations")
            }

            let request = ApiRequest(systemPrompt: systemPrompt, messages: session.messages)
            let events = try apiClient.stream(request)
            let (assistantMessage, eventUsage) = try buildAssistantMessage(events)

            if let usage = eventUsage {
                usageTracker.record(usage)
            }

            let pendingToolUses: [(String, String, String)] = assistantMessage.blocks.compactMap { block in
                if case .toolUse(let id, let name, let input) = block {
                    return (id, name, input)
                }
                return nil
            }

            session.messages.append(assistantMessage)
            assistantMessages.append(assistantMessage)

            if pendingToolUses.isEmpty {
                break
            }

            for (toolUseId, toolName, input) in pendingToolUses {
                onStatus?(.toolStart(name: toolName, input: input))

                // Bash risk assessment: if bash command contains dangerous patterns,
                // escalate to require user confirmation even in dangerFullAccess mode
                if toolName == "bash" || toolName == "repl" {
                    let json = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
                    let command = json?["command"] as? String ?? json?["code"] as? String ?? input
                    let risks = assessBashRisk(command)
                    if !risks.isEmpty {
                        // Force prompt the user about dangerous commands
                        let riskDesc = risks.joined(separator: ", ")
                        let request = PermissionRequest(
                            toolName: toolName,
                            input: "⚠️ DANGEROUS: \(riskDesc)\nCommand: \(command)",
                            currentMode: permissionPolicy.getActiveMode(),
                            requiredMode: .dangerFullAccess
                        )
                        if var p = prompter {
                            let decision = p.decide(request)
                            if case .deny(let reason) = decision {
                                let resultMessage = ConversationMessage.toolResult(
                                    toolUseId: toolUseId, toolName: toolName,
                                    output: "Blocked: \(reason) [risks: \(riskDesc)]", isError: true)
                                session.messages.append(resultMessage)
                                toolResults.append(resultMessage)
                                onStatus?(.toolFinish(name: toolName, isError: true))
                                continue
                            }
                            // Cache allow so authorize() below doesn't double-prompt
                            permissionPolicy.cacheAllow(toolName)
                        }
                    }
                }

                let outcome = permissionPolicy.authorize(toolName: toolName, input: input, prompter: &prompter)

                let resultMessage: ConversationMessage
                switch outcome {
                case .allow:
                    let preHookResult = hookRunner.runPreToolUse(toolName: toolName, toolInput: input)
                    if preHookResult.isDenied {
                        let denyMessage = "PreToolUse hook denied tool `\(toolName)`"
                        resultMessage = .toolResult(
                            toolUseId: toolUseId,
                            toolName: toolName,
                            output: formatHookMessage(preHookResult, fallback: denyMessage),
                            isError: true
                        )
                        onStatus?(.toolFinish(name: toolName, isError: true))
                    } else {
                        var output: String
                        var isError: Bool
                        do {
                            output = try toolExecutor.execute(toolName: toolName, input: input)
                            isError = false
                        } catch let toolError as ToolError {
                            output = toolError.message
                            isError = true
                        } catch {
                            output = error.localizedDescription
                            isError = true
                        }
                        output = mergeHookFeedback(preHookResult.messages, output: output, denied: false)

                        let postHookResult = hookRunner.runPostToolUse(toolName: toolName, toolInput: input, toolOutput: output, isError: isError)
                        if postHookResult.isDenied {
                            isError = true
                        }
                        output = mergeHookFeedback(postHookResult.messages, output: output, denied: postHookResult.isDenied)

                        resultMessage = .toolResult(toolUseId: toolUseId, toolName: toolName, output: output, isError: isError)
                        onStatus?(.toolOutput(name: toolName, input: input, output: output, isError: isError))
                        onStatus?(.toolFinish(name: toolName, isError: isError))
                    }

                case .deny(let reason):
                    resultMessage = .toolResult(toolUseId: toolUseId, toolName: toolName, output: reason, isError: true)
                    onStatus?(.toolOutput(name: toolName, input: input, output: reason, isError: true))
                    onStatus?(.toolFinish(name: toolName, isError: true))
                }

                session.messages.append(resultMessage)
                toolResults.append(resultMessage)
            }

            // About to loop back for another LLM call after tool results
            onStatus?(.thinking)
        }

        onStatus?(.done)

        return TurnSummary(
            assistantMessages: assistantMessages,
            toolResults: toolResults,
            iterations: iterations,
            usage: usageTracker.cumulativeUsage
        )
    }

    public var currentSession: Session { session }
    public var currentUsage: UsageTracker { usageTracker }
    public func intoSession() -> Session { session }

    /// Append a message directly to the session (e.g. for image messages)
    public func appendMessage(_ message: ConversationMessage) {
        session.messages.append(message)
    }

    /// Replace the session (e.g. for /clear or /load)
    public func replaceSession(_ newSession: Session) {
        session = newSession
    }

    public func estimatedTokens() -> Int {
        estimateSessionTokens(session)
    }
}

// MARK: - Static Tool Executor

public struct StaticToolExecutor: ToolExecutor {
    private var handlers: [String: (String) throws -> String]

    public init() {
        self.handlers = [:]
    }

    public mutating func register(_ toolName: String, handler: @escaping (String) throws -> String) {
        handlers[toolName] = handler
    }

    public func withRegistered(_ toolName: String, handler: @escaping (String) throws -> String) -> StaticToolExecutor {
        var copy = self
        copy.handlers[toolName] = handler
        return copy
    }

    public mutating func execute(toolName: String, input: String) throws -> String {
        guard let handler = handlers[toolName] else {
            throw ToolError("unknown tool: \(toolName)")
        }
        return try handler(input)
    }
}

// MARK: - Helpers

private func buildAssistantMessage(_ events: [AssistantEvent]) throws -> (ConversationMessage, TokenUsage?) {
    var text = ""
    var blocks: [ContentBlock] = []
    var finished = false
    var usage: TokenUsage?

    for event in events {
        switch event {
        case .textDelta(let delta):
            text += delta
        case .toolUse(let id, let name, let input):
            flushTextBlock(&text, &blocks)
            blocks.append(.toolUse(id: id, name: name, input: input))
        case .usage(let value):
            usage = value
        case .messageStop:
            finished = true
        }
    }

    flushTextBlock(&text, &blocks)

    guard finished else {
        throw RuntimeError("assistant stream ended without a message stop event")
    }
    if blocks.isEmpty {
        // LLM returned empty response (common after tool errors with gemma3).
        // Synthesize a fallback so the conversation can continue.
        blocks.append(.text("[No response from model — try rephrasing or continue.]"))
    }

    return (.assistantWithUsage(blocks, usage: usage), usage)
}

private func flushTextBlock(_ text: inout String, _ blocks: inout [ContentBlock]) {
    if !text.isEmpty {
        blocks.append(.text(text))
        text = ""
    }
}

private func formatHookMessage(_ result: HookRunResult, fallback: String) -> String {
    result.messages.isEmpty ? fallback : result.messages.joined(separator: "\n")
}

private func mergeHookFeedback(_ messages: [String], output: String, denied: Bool) -> String {
    guard !messages.isEmpty else { return output }

    var sections: [String] = []
    if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sections.append(output)
    }
    let label = denied ? "Hook feedback (denied)" : "Hook feedback"
    sections.append("\(label):\n\(messages.joined(separator: "\n"))")
    return sections.joined(separator: "\n\n")
}
