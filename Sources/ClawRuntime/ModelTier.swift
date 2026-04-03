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

// ┌─────────────────────────────────────────────────────────────────────┐
// │  Tiered LLM Tool-Calling Architecture                              │
// │                                                                     │
// │  Tier 1: nativeTools      — Ollama native tool_calls JSON           │
// │  Tier 2: textBasedTools   — Mistral [TOOL_CALLS] text format        │
// │  Tier 3: reactPrompting   — ReAct Thought/Action/Observation        │
// │  Tier 4: noTools           — Plain chat, no tool calling            │
// │                                                                     │
// │  Auto-fallback: Tier 1 → Tier 3 → Tier 4 on HTTP 400               │
// └─────────────────────────────────────────────────────────────────────┘

// MARK: - Capability Tier

public enum ToolCapabilityTier: String, CaseIterable, Sendable {
    case nativeTools
    case textBasedTools
    case reactPrompting
    case noTools

    /// Whether to send the `tools[]` parameter in the Ollama API request.
    public var supportsToolsParameter: Bool {
        self == .nativeTools
    }

    /// Whether the LLM response text must be parsed for tool calls.
    public var requiresTextParsing: Bool {
        self == .textBasedTools || self == .reactPrompting
    }

    public var label: String {
        switch self {
        case .nativeTools:      return "Native Tool Calling"
        case .textBasedTools:   return "Text-Based Tools (Mistral)"
        case .reactPrompting:   return "ReAct Prompting"
        case .noTools:          return "Simple (No Tools)"
        }
    }
}

// MARK: - Model Classification

public struct ModelTierClassifier {

    // Tier 1 — models with Ollama-native tool_calls support
    private static let nativeToolModels: Set<String> = [
        "llama3.1", "llama3.2", "llama3.3",
        "llama-3.1", "llama-3.2", "llama-3.3",
        "llama4",
        "qwen2", "qwen2.5", "qwen3",
        "command-r",
        "firefunction",
        "hermes",
    ]

    // Tier 2 — models that use [TOOL_CALLS] text format
    private static let textBasedToolModels: Set<String> = [
        "mistral",
        "mixtral",
    ]

    // Tier 3 — models capable of following ReAct format (Thought/Action/Action Input)
    // These models are smart enough to follow structured instructions but lack native tool support
    private static let reactPromptingModels: Set<String> = [
        "gemma3",
        "phi4",
        "deepseek",
    ]

    // Tier 4 — models too small or limited for any tool calling
    private static let noToolModels: Set<String> = [
        "gemma", "gemma2",
        "phi", "phi3",
        "codellama",
        "yi",
        "vicuna",
        "orca",
        "neural-chat",
        "starling",
        "openchat",
        "zephyr",
    ]

    /// Classify a model into its tool-calling capability tier.
    /// Priority: Tier 2 (Mistral) → Tier 3 (ReAct) → Tier 1 (native) → Tier 4 (none) → default Tier 1.
    public static func classify(_ modelName: String) -> ToolCapabilityTier {
        let lower = modelName.lowercased()

        for keyword in textBasedToolModels {
            if lower.contains(keyword) { return .textBasedTools }
        }
        for keyword in reactPromptingModels {
            if lower.contains(keyword) { return .reactPrompting }
        }
        for keyword in nativeToolModels {
            if lower.contains(keyword) { return .nativeTools }
        }
        for keyword in noToolModels {
            if lower.contains(keyword) { return .noTools }
        }

        // Unknown model: default to nativeTools — orchestrator falls back if it fails
        return .nativeTools
    }

    /// Convenience: does this model support Ollama native tools?
    public static func supportsNativeTools(_ modelName: String) -> Bool {
        classify(modelName) == .nativeTools
    }
}

// MARK: - Tool Description Adapter

/// Lightweight representation of a tool for prompt injection (Tier 2 & 3).
/// Built from OllamaToolSpec at the API layer.
public struct ToolDescription: Sendable {
    public let name: String
    public let description: String
    public let parameters: [(name: String, type: String, required: Bool, description: String)]

    public init(name: String, description: String, parameters: [(name: String, type: String, required: Bool, description: String)] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Tier Prompt Builders

public struct TierPromptBuilder {

    // MARK: Tier 3 — ReAct Format

    /// Build a system prompt that instructs the model to use ReAct format
    /// (Thought → Action → Action Input → Observation → Final Answer).
    public static func buildReActSystemPrompt(base: String, tools: [ToolDescription]) -> String {
        let toolDescriptions = tools.map { tool -> String in
            var lines = ["\(tool.name): \(tool.description)"]
            for param in tool.parameters {
                let req = param.required ? ", required" : ""
                lines.append("  - \(param.name) (\(param.type)\(req)): \(param.description)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let toolNames = tools.map(\.name).joined(separator: ", ")

        return """
        \(base)

        You have access to these tools:

        \(toolDescriptions)

        You MUST use this EXACT format for every response:

        Thought: think about what to do
        Action: tool_name
        Action Input: {"param1": "value1", "param2": "value2"}

        After each tool call, you will receive an Observation with the result. Then continue:

        Thought: analyze the result and decide next step
        Action: next_tool_name
        Action Input: {"param1": "value1"}

        When done, finish with:
        Thought: I now know the final answer
        Final Answer: your complete answer

        CRITICAL RULES:
        1. ALWAYS start with "Thought:" — plan what tools you need BEFORE acting
        2. After each "Thought:" you MUST have "Action:" on the next line (unless you know the final answer)
        3. After "Action:" you MUST have "Action Input:" with a JSON object on the next line — e.g. {"command": "ls"} or {"query": "search term"}
        4. Available tool names are: \(toolNames)
        5. Output ONLY ONE Action + Action Input per response. Wait for the Observation before the next step.
        6. For complex tasks, break them into multiple steps. Example: to create a file from web content, first use web_search, then web_fetch the URL, then write_file with the content. Do each step one at a time.
        7. When you have enough information, write "Thought: I now know the final answer" then "Final Answer:"
        8. If no tool is needed, go straight to "Thought: I can answer this directly" then "Final Answer:"
        9. NEVER skip steps — if you need information from the web, ALWAYS fetch it first before writing files
        """
    }

    // MARK: Tier 2 — Mistral [TOOL_CALLS] Format

    /// Build a system prompt that instructs the model to use Mistral's [TOOL_CALLS] format.
    public static func buildMistralSystemPrompt(base: String, tools: [ToolDescription]) -> String {
        let toolDescriptions = tools.map { tool -> String in
            var lines = ["\(tool.name) — \(tool.description)"]
            for param in tool.parameters {
                lines.append("   - \(param.name): \(param.description)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        // Build a dynamic example from the first tool if available
        let example: String
        if let first = tools.first {
            let exampleArgs = first.parameters.isEmpty
                ? "{}"
                : "{\(first.parameters.map { "\"\($0.name)\": \"example\"" }.joined(separator: ", "))}"
            example = "[TOOL_CALLS] [{\"name\": \"\(first.name)\", \"arguments\": \(exampleArgs)}]"
        } else {
            example = "[TOOL_CALLS] [{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}]"
        }

        return """
        \(base)

        ## Available Tools

        \(toolDescriptions)

        ## How to Call Tools

        When you need to use a tool, output EXACTLY this format:
        \(example)

        You may call multiple tools at once by including multiple objects in the array.
        If no tool is needed, respond normally without [TOOL_CALLS].
        """
    }

    // MARK: Tier 4 — No Tools (Context Injection)

    /// Build a system prompt for models that cannot call tools.
    /// Pre-executed tool results are injected as additional context.
    public static func buildNoToolsSystemPrompt(base: String, preExecutedContext: String? = nil) -> String {
        guard let context = preExecutedContext,
              !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }

        return """
        \(base)

        === ADDITIONAL CONTEXT ===
        \(context)
        === END ADDITIONAL CONTEXT ===
        """
    }
}

// MARK: - Parsed Tool Call

public struct ParsedToolCall: Equatable, Sendable {
    public let toolName: String
    /// JSON string of arguments (e.g. `{"path": "/tmp"}`)
    public let arguments: String
    public let thought: String?

    public init(toolName: String, arguments: String, thought: String? = nil) {
        self.toolName = toolName
        self.arguments = arguments
        self.thought = thought
    }
}

// MARK: - Tier Response Parser

public struct TierResponseParser {

    // MARK: ReAct Parsing (Tier 3)

    /// Parse a ReAct-formatted response into tool calls and/or a final answer.
    public static func parseReAct(_ text: String) -> (toolCalls: [ParsedToolCall], finalAnswer: String?) {
        var toolCalls: [ParsedToolCall] = []
        var finalAnswer: String? = nil
        var currentThought: String? = nil
        var currentAction: String? = nil
        var collectingFinalAnswer = false
        var finalAnswerLines: [String] = []

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Collecting multi-line final answer
            if collectingFinalAnswer {
                finalAnswerLines.append(line)
                continue
            }

            // Final Answer: ...
            if lower.hasPrefix("final answer:") {
                let answer = String(trimmed.dropFirst("final answer:".count)).trimmingCharacters(in: .whitespaces)
                finalAnswerLines.append(answer)
                collectingFinalAnswer = true
                continue
            }

            // Thought: ...
            if lower.hasPrefix("thought:") {
                currentThought = String(trimmed.dropFirst("thought:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Action: ...
            if lower.hasPrefix("action:") {
                currentAction = String(trimmed.dropFirst("action:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Action Input: ...
            if lower.hasPrefix("action input:") {
                let jsonStr = String(trimmed.dropFirst("action input:".count)).trimmingCharacters(in: .whitespaces)
                if let action = currentAction, !action.isEmpty {
                    let argsJson = normalizeArgumentsJSON(jsonStr, toolName: action)
                    toolCalls.append(ParsedToolCall(
                        toolName: action,
                        arguments: argsJson,
                        thought: currentThought
                    ))
                }
                currentAction = nil
                currentThought = nil
                continue
            }

            // Observation: ... (skip — this is tool output injected by the runtime)
            if lower.hasPrefix("observation:") {
                continue
            }
        }

        let collectedAnswer = finalAnswerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !collectedAnswer.isEmpty {
            finalAnswer = collectedAnswer
        }

        return (toolCalls, finalAnswer)
    }

    // MARK: Mistral Parsing (Tier 2)

    /// Parse a Mistral [TOOL_CALLS] formatted response.
    /// Uses 3 fallback strategies for robustness.
    public static func parseMistralToolCalls(_ text: String) -> [ParsedToolCall] {
        // Strategy 1: Look for [TOOL_CALLS] marker
        if let markerRange = text.range(of: "[TOOL_CALLS]", options: .caseInsensitive) {
            let afterMarker = String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let calls = extractToolCallsFromJSONArray(afterMarker) {
                return calls
            }
        }

        // Strategy 2: Regex for JSON array with "name" and "arguments"
        let arrayPattern = #"\[\s*\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}\s*\]"#
        if let regex = try? NSRegularExpression(pattern: arrayPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 3 {
            let nameRange = Range(match.range(at: 1), in: text)!
            let argsRange = Range(match.range(at: 2), in: text)!
            return [ParsedToolCall(
                toolName: String(text[nameRange]),
                arguments: String(text[argsRange])
            )]
        }

        // Strategy 3: Inline JSON object without array brackets
        let inlinePattern = #"\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*\{([^}]*)\}\s*\}"#
        if let regex = try? NSRegularExpression(pattern: inlinePattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 3 {
            let nameRange = Range(match.range(at: 1), in: text)!
            let argsRange = Range(match.range(at: 2), in: text)!
            return [ParsedToolCall(
                toolName: String(text[nameRange]),
                arguments: "{\(text[argsRange])}"
            )]
        }

        return []
    }

    // MARK: Detection

    /// Quick check: does this text look like it contains tool calls?
    public static func containsToolCalls(_ text: String) -> Bool {
        let lower = text.lowercased()

        // ReAct format
        if lower.contains("action:") && lower.contains("action input:") { return true }

        // Mistral format
        if lower.contains("[tool_calls]") { return true }

        // JSON tool call pattern
        if lower.contains("\"name\"") && lower.contains("\"arguments\"") { return true }

        // Function-call syntax: word(key=value)
        if let regex = try? NSRegularExpression(pattern: #"\b\w+\(\s*\w+\s*="#),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }

        return false
    }

    /// Extract a final answer from text that may contain tool-call formatting.
    public static func extractFinalAnswer(_ text: String) -> String? {
        let lower = text.lowercased()

        // Look for explicit "Final Answer:" marker
        if let range = lower.range(of: "final answer:") {
            let answer = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        }

        // If no tool calls detected, the entire text is the answer
        if !containsToolCalls(text) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Normalize a JSON arguments string — ensure it's valid JSON.
    /// For bare text (e.g. "ls" instead of {"command": "ls"}), wraps into
    /// the tool's primary parameter based on `currentToolName`.
    static func normalizeArgumentsJSON(_ raw: String, toolName: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }

        // Already valid JSON object/array?
        if let data = trimmed.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) {
            return trimmed
        }

        // Bare text — wrap into the tool's primary parameter.
        // Map of tool → primary string parameter name.
        let primaryParam: [String: String] = [
            "bash": "command",
            "read_file": "file_path",
            "write_file": "file_path",
            "edit_file": "file_path",
            "glob_search": "pattern",
            "grep_search": "pattern",
            "web_fetch": "url",
            "web_search": "query",
            "agent": "prompt",
            "repl": "code",
            "read_pdf": "file_path",
        ]

        if let tool = toolName?.lowercased(), let paramName = primaryParam[tool] {
            // Escape the bare text for JSON string value
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "{\"\(paramName)\": \"\(escaped)\"}"
        }

        // Unknown tool — return raw text as-is (executor fallbacks handle it)
        return trimmed
    }

    /// Extract tool calls from a JSON array string like `[{"name": "...", "arguments": {...}}]`.
    private static func extractToolCallsFromJSONArray(_ text: String) -> [ParsedToolCall]? {
        // Find balanced [] brackets
        guard let startIdx = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var endIdx: String.Index? = nil
        for idx in text.indices[startIdx...] {
            if text[idx] == "[" { depth += 1 }
            if text[idx] == "]" {
                depth -= 1
                if depth == 0 {
                    endIdx = text.index(after: idx)
                    break
                }
            }
        }
        guard let end = endIdx else { return nil }

        let jsonStr = String(text[startIdx..<end])
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var calls: [ParsedToolCall] = []
        for dict in array {
            guard let name = dict["name"] as? String else { continue }
            let args: String
            if let argsObj = dict["arguments"] {
                if let argsData = try? JSONSerialization.data(withJSONObject: argsObj) {
                    args = String(data: argsData, encoding: .utf8) ?? "{}"
                } else {
                    args = "{}"
                }
            } else {
                args = "{}"
            }
            calls.append(ParsedToolCall(toolName: name, arguments: args))
        }

        return calls.isEmpty ? nil : calls
    }
}
