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
import ClawRuntime

// MARK: - Model Configuration

public let defaultTextModel = "gemma3"
public let defaultVisionModel = "llava"

public func resolveModelAlias(_ model: String) -> String {
    switch model.lowercased() {
    case "gemma", "gemma3": return "gemma3"
    case "llama", "llama3": return "llama3.2"
    case "mistral": return "mistral"
    case "qwen", "qwen3": return "qwen3"
    case "phi", "phi4": return "phi4"
    case "llava": return "llava"
    case "moondream": return "moondream"
    case "minicpm": return "minicpm-v"
    case "llama-vision": return "llama3.2-vision"
    default: return model
    }
}

/// Known vision-capable model families
public func isVisionModel(_ model: String) -> Bool {
    let normalized = model.lowercased()
    return normalized.contains("llava") || normalized.contains("moondream")
        || normalized.contains("minicpm-v") || normalized.contains("llama3.2-vision")
        || normalized.contains("gemma3") // gemma3 supports multimodal
}

// MARK: - Ollama Model Info

public struct OllamaModelInfo: Sendable {
    public let name: String
    public let size: Int64
    public let modifiedAt: String
    public let family: String?

    public var displayName: String {
        name.replacingOccurrences(of: ":latest", with: "")
    }

    public var sizeGB: String {
        String(format: "%.1f GB", Double(size) / 1_073_741_824.0)
    }
}

// MARK: - Ollama Error

public enum OllamaError: Error, LocalizedError {
    case notRunning
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case noResponse
    case modelNotAvailable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama is not running. Start it with: ollama serve"
        case .invalidURL:
            return "Invalid Ollama URL"
        case .httpError(let code, let body):
            return "Ollama HTTP error \(code): \(String(body.prefix(200)))"
        case .noResponse:
            return "No response from Ollama"
        case .modelNotAvailable(let model):
            return "Model '\(model)' is not available. Pull it with: ollama pull \(model)"
        case .invalidResponse(let detail):
            return "Invalid response from Ollama: \(detail)"
        }
    }
}

// MARK: - Ollama Tool Definitions

public struct OllamaToolSpec: Codable {
    public let type: String
    public let function: OllamaToolFunction

    public init(name: String, description: String, parameters: [String: OllamaParamProp] = [:], required: [String] = []) {
        self.type = "function"
        self.function = OllamaToolFunction(
            name: name,
            description: description,
            parameters: OllamaToolParams(type: "object", properties: parameters, required: required)
        )
    }
}

public struct OllamaToolFunction: Codable {
    public let name: String
    public let description: String
    public let parameters: OllamaToolParams
}

public struct OllamaToolParams: Codable {
    public let type: String
    public let properties: [String: OllamaParamProp]
    public let required: [String]
}

public struct OllamaParamProp: Codable {
    public let type: String
    public let description: String
    public var `enum`: [String]?

    public init(type: String, description: String, `enum`: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
    }
}

// MARK: - Ollama Chat Message

struct OllamaChatMessage: Codable {
    let role: String
    var content: String
    var tool_calls: [OllamaToolCall]?
    var images: [String]?  // base64-encoded images for multimodal models
}

struct OllamaToolCall: Codable {
    let function: OllamaToolCallFunction
}

struct OllamaToolCallFunction: Codable {
    let name: String
    let arguments: [String: AnyCodable]?
}

// MARK: - AnyCodable helper for tool arguments

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let dbl = try? container.decode(Double.self) { value = dbl }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = try container.decode(String.self) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String { try container.encode(str) }
        else if let int = value as? Int { try container.encode(int) }
        else if let dbl = value as? Double { try container.encode(dbl) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else { try container.encode(String(describing: value)) }
    }
}

// MARK: - Ollama Chat Response

struct OllamaChatResponse: Codable {
    let model: String?
    let message: OllamaChatMessage?
    let done: Bool?
    let done_reason: String?
    let total_duration: Int64?
    let eval_count: Int?
    let prompt_eval_count: Int?
}

// MARK: - Ollama API Client

public class OllamaClient: ApiClient {
    private let baseURL: String
    private let model: String
    private let contextLength: Int
    private let temperature: Double
    private let chatTimeout: TimeInterval
    private var toolSpecs: [OllamaToolSpec]

    public init(
        model: String = defaultTextModel,
        baseURL: String = "http://127.0.0.1:11434",
        contextLength: Int = 8192,
        temperature: Double = 0.7,
        chatTimeout: TimeInterval = 120
    ) {
        self.model = model
        self.baseURL = baseURL
        self.contextLength = contextLength
        self.temperature = temperature
        self.chatTimeout = chatTimeout
        self.toolSpecs = []
    }

    /// Set tool definitions for the next chat call
    public func setTools(_ specs: [OllamaToolSpec]) {
        self.toolSpecs = specs
    }

    // MARK: - Health Check

    public func healthCheck() -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var isHealthy = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isHealthy = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return isHealthy
    }

    // MARK: - List Models

    public func listModels() throws -> [OllamaModelInfo] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, _) = try syncRequest(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw OllamaError.invalidResponse("failed to parse model list")
        }

        return models.map { m in
            OllamaModelInfo(
                name: m["name"] as? String ?? "unknown",
                size: m["size"] as? Int64 ?? 0,
                modifiedAt: m["modified_at"] as? String ?? "",
                family: (m["details"] as? [String: Any])?["family"] as? String
            )
        }
    }

    // MARK: - ApiClient Protocol

    /// Token callback for streaming text to terminal during generation.
    /// Set this before calling stream() to get incremental token output.
    public var onToken: ((String) -> Void)?

    /// When true, suppress live token streaming for Tier 2/3 (ReAct/Mistral) models.
    /// The raw Thought/Action/Action Input text is noise — only show tool blocks + final answer.
    /// Set to false to show ReAct reasoning (--detail mode).
    public var suppressReActStreaming: Bool = true

    public func stream(_ request: ApiRequest) throws -> [AssistantEvent] {
        let tier = ModelTierClassifier.classify(model)
        return try streamWithTier(request, tier: tier)
    }

    // ┌─────────────────────────────────────────────────────────────────────────────┐
    // │  Tiered Streaming Dispatch & Auto-Fallback Engine                           │
    // │  Copyright (c) 2026 KnotTheory.ai Inc. All rights reserved.                │
    // │                                                                             │
    // │  This tiered dispatch system — including Tier 1 native tool-call relay,     │
    // │  Tier 2 Mistral text-format injection, Tier 3 ReAct prompt injection,       │
    // │  auto-fallback cascade (Tier 1 → 3 → 4 on HTTP 400), and tier-aware        │
    // │  streaming/parsing — is original work by KnotTheory.ai Inc.                 │
    // │                                                                             │
    // │  Designed for local-only inference via Ollama. No API tokens required.       │
    // │  No cloud dependency. No per-request charges.                               │
    // └─────────────────────────────────────────────────────────────────────────────┘
    private func streamWithTier(_ request: ApiRequest, tier: ToolCapabilityTier) throws -> [AssistantEvent] {
        guard healthCheck() else {
            throw RuntimeError("Ollama is not running. Start it with: ollama serve")
        }

        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw RuntimeError("Invalid Ollama URL")
        }

        // For Tier 2 & 3, inject tool descriptions into the system prompt
        let effectiveRequest: ApiRequest
        switch tier {
        case .textBasedTools:
            effectiveRequest = injectMistralToolPrompt(request)
        case .reactPrompting:
            effectiveRequest = injectReActToolPrompt(request)
        default:
            effectiveRequest = request
        }

        let ollamaMessages = convertMessages(effectiveRequest)

        // Build request body
        // For Tier 2/3 (text-parsed tool calls), suppress live token streaming unless detail mode
        // is on — the raw ReAct/Mistral formatting is noise for the user.
        let useStreaming = onToken != nil && (tier == .nativeTools || tier == .noTools || suppressReActStreaming == false)
        var body: [String: Any] = [
            "model": model,
            "stream": useStreaming,
            "options": [
                "num_ctx": contextLength,
                "temperature": temperature
            ] as [String: Any],
            "messages": ollamaMessages.map { msgToDict($0) }
        ]

        // Only send tools[] for Tier 1 (native tool calling)
        if tier.supportsToolsParameter && !toolSpecs.isEmpty {
            let toolDicts = try toolSpecs.map { spec -> [String: Any] in
                let data = try JSONEncoder().encode(spec)
                guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ["type": "function", "function": ["name": spec.function.name, "description": spec.function.description] as [String: Any]] as [String: Any]
                }
                return dict
            }
            body["tools"] = toolDicts
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = chatTimeout

        if useStreaming {
            return try streamingRequestTiered(urlRequest, tier: tier)
        }

        let (responseData, httpResponse) = try syncRequest(urlRequest)

        if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "unknown"

            // Auto-fallback: HTTP 400 "does not support tools" → Tier 3 → Tier 4
            if http.statusCode == 400 && responseBody.lowercased().contains("does not support") {
                switch tier {
                case .nativeTools:
                    return try streamWithTier(request, tier: .reactPrompting)
                case .reactPrompting, .textBasedTools:
                    return try streamWithTier(request, tier: .noTools)
                case .noTools:
                    break // no further fallback
                }
            }

            if responseBody.contains("model") && responseBody.contains("not found") {
                throw RuntimeError("Model '\(model)' not found. Pull it with: ollama pull \(model)")
            }
            throw RuntimeError("Ollama error (HTTP \(http.statusCode)): \(String(responseBody.prefix(200)))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RuntimeError("Failed to parse Ollama response")
        }

        return parseOllamaResponseTiered(json, tier: tier)
    }

    /// Streaming request with tier-aware response parsing.
    private func streamingRequestTiered(_ urlRequest: URLRequest, tier: ToolCapabilityTier) throws -> [AssistantEvent] {
        let delegate = StreamingDelegate(onToken: onToken)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        task.resume()
        delegate.semaphore.wait()
        session.invalidateAndCancel()

        if let error = delegate.error {
            throw RuntimeError("Ollama stream error: \(error.localizedDescription)")
        }

        var events: [AssistantEvent] = []
        let text = delegate.accumulatedText

        // Native tool calls from Ollama (Tier 1 only)
        var hasNativeToolCalls = false
        for tc in delegate.toolCalls {
            if let fn = tc["function"] as? [String: Any],
               let name = fn["name"] as? String {
                hasNativeToolCalls = true
                let args = fn["arguments"] ?? [:]
                let argsString: String
                if let argsData = try? JSONSerialization.data(withJSONObject: args) {
                    argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                } else {
                    argsString = "{}"
                }
                let id = "tool-\(UUID().uuidString.prefix(8))"
                events.append(.toolUse(id: id, name: name, input: argsString))
            }
        }

        // Parse text based on tier
        if !text.isEmpty && !hasNativeToolCalls {
            switch tier {
            case .nativeTools:
                // Tier 1: text is just the response (tools came via native tool_calls)
                events.append(.textDelta(text))

            case .textBasedTools:
                // Tier 2: parse [TOOL_CALLS] format from text
                let parsed = TierResponseParser.parseMistralToolCalls(text)
                if !parsed.isEmpty {
                    for call in parsed {
                        let id = "tool-\(UUID().uuidString.prefix(8))"
                        events.append(.toolUse(id: id, name: call.toolName, input: call.arguments))
                    }
                } else {
                    events.append(.textDelta(text))
                }

            case .reactPrompting:
                // Tier 3: parse Thought/Action/Action Input format
                let (toolCalls, finalAnswer) = TierResponseParser.parseReAct(text)
                for call in toolCalls {
                    let id = "tool-\(UUID().uuidString.prefix(8))"
                    events.append(.toolUse(id: id, name: call.toolName, input: call.arguments))
                }
                if let answer = finalAnswer, toolCalls.isEmpty {
                    events.append(.textDelta(answer))
                } else if toolCalls.isEmpty {
                    events.append(.textDelta(text))
                }

            case .noTools:
                // Tier 4: plain text, no tool parsing
                events.append(.textDelta(text))
            }
        }

        events.append(.usage(TokenUsage(
            inputTokens: UInt32(delegate.promptTokens),
            outputTokens: UInt32(delegate.evalTokens)
        )))
        events.append(.messageStop)
        return events
    }

    private func convertMessages(_ request: ApiRequest) -> [OllamaChatMessage] {
        var ollamaMessages: [OllamaChatMessage] = []
        let systemText = request.systemPrompt.joined(separator: "\n\n")
        if !systemText.isEmpty {
            ollamaMessages.append(OllamaChatMessage(role: "system", content: systemText))
        }
        for message in request.messages {
            let ollamaRole: String
            switch message.role {
            case .system: ollamaRole = "system"
            case .user: ollamaRole = "user"
            case .assistant: ollamaRole = "assistant"
            case .tool: ollamaRole = "tool"
            }
            var textParts: [String] = []
            var images: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let text): textParts.append(text)
                case .toolUse(_, let name, let input): textParts.append("[tool_use: \(name)(\(input))]")
                case .toolResult(_, let toolName, let output, let isError):
                    textParts.append(isError ? "Error from \(toolName): \(output)" : output)
                case .image(let base64Data, _): images.append(base64Data)
                }
            }
            var msg = OllamaChatMessage(role: ollamaRole, content: textParts.joined(separator: "\n"))
            if !images.isEmpty { msg.images = images }
            ollamaMessages.append(msg)
        }
        return ollamaMessages
    }

    // MARK: - Stream Chat (token-by-token callback)

    public func streamChat(_ request: ApiRequest, onToken: @escaping (String) -> Void) throws -> [AssistantEvent] {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw RuntimeError("Invalid Ollama URL")
        }

        var ollamaMessages: [OllamaChatMessage] = []
        let systemText = request.systemPrompt.joined(separator: "\n\n")
        if !systemText.isEmpty {
            ollamaMessages.append(OllamaChatMessage(role: "system", content: systemText))
        }

        for message in request.messages {
            let role: String
            switch message.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            var textParts: [String] = []
            var images: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let t): textParts.append(t)
                case .toolUse(_, let n, let i): textParts.append("[tool_use: \(n)(\(i))]")
                case .toolResult(_, let tn, let o, let e): textParts.append(e ? "Error from \(tn): \(o)" : o)
                case .image(let b64, _): images.append(b64)
                }
            }
            var msg = OllamaChatMessage(role: role, content: textParts.joined(separator: "\n"))
            if !images.isEmpty { msg.images = images }
            ollamaMessages.append(msg)
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "options": ["num_ctx": contextLength, "temperature": temperature] as [String: Any],
            "messages": ollamaMessages.map { msgToDict($0) }
        ]
        let tier = ModelTierClassifier.classify(model)
        if tier.supportsToolsParameter && !toolSpecs.isEmpty {
            let toolDicts = try toolSpecs.map { spec -> [String: Any] in
                let data = try JSONEncoder().encode(spec)
                guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ["type": "function", "function": ["name": spec.function.name] as [String: Any]] as [String: Any]
                }
                return dict
            }
            body["tools"] = toolDicts
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = chatTimeout

        // Streaming: read NDJSON lines
        let semaphore = DispatchSemaphore(value: 0)
        var accumulatedText = ""
        var toolCalls: [[String: Any]] = []
        var promptTokens: Int = 0
        var evalTokens: Int = 0
        var responseError: Error?

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error = error { responseError = error; return }
            guard let data = data else { return }

            let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
            for line in lines {
                guard !line.isEmpty,
                      let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                if let msg = json["message"] as? [String: Any] {
                    if let content = msg["content"] as? String, !content.isEmpty {
                        accumulatedText += content
                        onToken(content)
                    }
                    if let tc = msg["tool_calls"] as? [[String: Any]] {
                        toolCalls.append(contentsOf: tc)
                    }
                }
                if json["done"] as? Bool == true {
                    promptTokens = json["prompt_eval_count"] as? Int ?? 0
                    evalTokens = json["eval_count"] as? Int ?? 0
                }
            }
        }
        task.resume()
        semaphore.wait()

        if let error = responseError { throw RuntimeError("Ollama stream error: \(error.localizedDescription)") }

        var events: [AssistantEvent] = []
        if !accumulatedText.isEmpty {
            events.append(.textDelta(accumulatedText))
        }
        for tc in toolCalls {
            if let fn = tc["function"] as? [String: Any],
               let name = fn["name"] as? String {
                let args = fn["arguments"] ?? [:]
                let argsString: String
                if let argsData = try? JSONSerialization.data(withJSONObject: args) {
                    argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                } else {
                    argsString = "{}"
                }
                let id = "tool-\(UUID().uuidString.prefix(8))"
                events.append(.toolUse(id: id, name: name, input: argsString))
            }
        }
        events.append(.usage(TokenUsage(inputTokens: UInt32(promptTokens), outputTokens: UInt32(evalTokens))))
        events.append(.messageStop)
        return events
    }

    // MARK: - Tiered Response Parsing

    private func parseOllamaResponseTiered(_ json: [String: Any], tier: ToolCapabilityTier) -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        var hasNativeToolCalls = false

        if let message = json["message"] as? [String: Any] {
            // Native tool calls (Tier 1 only)
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                hasNativeToolCalls = true
                for tc in toolCalls {
                    if let fn = tc["function"] as? [String: Any],
                       let name = fn["name"] as? String {
                        let args = fn["arguments"] ?? [:]
                        let argsString: String
                        if let argsData = try? JSONSerialization.data(withJSONObject: args) {
                            argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                        } else {
                            argsString = "{}"
                        }
                        let id = "tool-\(UUID().uuidString.prefix(8))"
                        events.append(.toolUse(id: id, name: name, input: argsString))
                    }
                }
            }

            // Text content — tier-aware parsing
            if let content = message["content"] as? String, !content.isEmpty, !hasNativeToolCalls {
                switch tier {
                case .nativeTools:
                    events.append(.textDelta(content))

                case .textBasedTools:
                    let parsed = TierResponseParser.parseMistralToolCalls(content)
                    if !parsed.isEmpty {
                        for call in parsed {
                            let id = "tool-\(UUID().uuidString.prefix(8))"
                            events.append(.toolUse(id: id, name: call.toolName, input: call.arguments))
                        }
                    } else {
                        events.append(.textDelta(content))
                    }

                case .reactPrompting:
                    let (toolCalls, finalAnswer) = TierResponseParser.parseReAct(content)
                    for call in toolCalls {
                        let id = "tool-\(UUID().uuidString.prefix(8))"
                        events.append(.toolUse(id: id, name: call.toolName, input: call.arguments))
                    }
                    if let answer = finalAnswer, toolCalls.isEmpty {
                        events.append(.textDelta(answer))
                    } else if toolCalls.isEmpty {
                        events.append(.textDelta(content))
                    }

                case .noTools:
                    events.append(.textDelta(content))
                }
            }
        }

        let promptTokens = json["prompt_eval_count"] as? Int ?? 0
        let evalTokens = json["eval_count"] as? Int ?? 0
        events.append(.usage(TokenUsage(
            inputTokens: UInt32(promptTokens),
            outputTokens: UInt32(evalTokens)
        )))

        events.append(.messageStop)
        return events
    }

    // MARK: - Tier Prompt Injection

    /// Convert OllamaToolSpec array to ToolDescription for prompt builders.
    private func toolDescriptions() -> [ToolDescription] {
        toolSpecs.map { spec in
            let params = spec.function.parameters.properties.map { (key, prop) in
                let required = spec.function.parameters.required.contains(key)
                return (name: key, type: prop.type, required: required, description: prop.description)
            }
            return ToolDescription(name: spec.function.name, description: spec.function.description, parameters: params)
        }
    }

    private func injectMistralToolPrompt(_ request: ApiRequest) -> ApiRequest {
        let basePrompt = request.systemPrompt.joined(separator: "\n\n")
        let mistralPrompt = TierPromptBuilder.buildMistralSystemPrompt(base: basePrompt, tools: toolDescriptions())
        return ApiRequest(systemPrompt: [mistralPrompt], messages: request.messages)
    }

    private func injectReActToolPrompt(_ request: ApiRequest) -> ApiRequest {
        let basePrompt = request.systemPrompt.joined(separator: "\n\n")
        let reactPrompt = TierPromptBuilder.buildReActSystemPrompt(base: basePrompt, tools: toolDescriptions())
        return ApiRequest(systemPrompt: [reactPrompt], messages: request.messages)
    }

    // MARK: - Helpers

    private func msgToDict(_ msg: OllamaChatMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": msg.role,
            "content": msg.content
        ]
        if let images = msg.images, !images.isEmpty {
            dict["images"] = images
        }
        return dict
    }

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse?) {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var urlResponse: URLResponse?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            urlResponse = response
            responseError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            if (error as NSError).code == NSURLErrorCannotConnectToHost || (error as NSError).code == NSURLErrorTimedOut {
                throw RuntimeError("Cannot connect to Ollama at \(baseURL). Is it running? Start with: ollama serve")
            }
            throw RuntimeError("Request failed: \(error.localizedDescription)")
        }
        guard let data = responseData else {
            throw RuntimeError("No response data")
        }
        return (data, urlResponse)
    }
}

// MARK: - Streaming Delegate

/// URLSession delegate that processes Ollama NDJSON streaming responses incrementally.
/// Each line of data triggers token callback immediately — no buffering the full response.
private class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    let onToken: ((String) -> Void)?
    var accumulatedText = ""
    var toolCalls: [[String: Any]] = []
    var promptTokens: Int = 0
    var evalTokens: Int = 0
    var error: Error?
    private var buffer = Data()

    init(onToken: ((String) -> Void)?) {
        self.onToken = onToken
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Process complete NDJSON lines
        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let msg = json["message"] as? [String: Any] {
                if let content = msg["content"] as? String, !content.isEmpty {
                    accumulatedText += content
                    onToken?(content)
                }
                if let tc = msg["tool_calls"] as? [[String: Any]] {
                    toolCalls.append(contentsOf: tc)
                }
            }
            if json["done"] as? Bool == true {
                promptTokens = json["prompt_eval_count"] as? Int ?? 0
                evalTokens = json["eval_count"] as? Int ?? 0
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Process any remaining data in buffer
        if !buffer.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
            if let msg = json["message"] as? [String: Any] {
                if let content = msg["content"] as? String, !content.isEmpty {
                    accumulatedText += content
                    onToken?(content)
                }
                if let tc = msg["tool_calls"] as? [[String: Any]] {
                    toolCalls.append(contentsOf: tc)
                }
            }
            if json["done"] as? Bool == true {
                promptTokens = json["prompt_eval_count"] as? Int ?? 0
                evalTokens = json["eval_count"] as? Int ?? 0
            }
        }
        self.error = error
        semaphore.signal()
    }
}

// MARK: - Tool Spec Conversion

extension OllamaClient {
    /// Build Ollama tool specs from the MVP tool registry
    public static func toolSpecsFromRegistry() -> [OllamaToolSpec] {
        [
            OllamaToolSpec(
                name: "read_file",
                description: "Read a file from the filesystem. Returns the file content with line numbers.",
                parameters: [
                    "file_path": OllamaParamProp(type: "string", description: "Absolute path to the file to read"),
                    "offset": OllamaParamProp(type: "integer", description: "Line number to start reading from (0-based)"),
                    "limit": OllamaParamProp(type: "integer", description: "Number of lines to read")
                ],
                required: ["file_path"]
            ),
            OllamaToolSpec(
                name: "write_file",
                description: "Write content to a file, creating directories as needed.",
                parameters: [
                    "file_path": OllamaParamProp(type: "string", description: "Absolute path to write to"),
                    "content": OllamaParamProp(type: "string", description: "Content to write")
                ],
                required: ["file_path", "content"]
            ),
            OllamaToolSpec(
                name: "edit_file",
                description: "Replace a string in a file with a new string.",
                parameters: [
                    "file_path": OllamaParamProp(type: "string", description: "Absolute path to the file"),
                    "old_string": OllamaParamProp(type: "string", description: "The exact string to find and replace"),
                    "new_string": OllamaParamProp(type: "string", description: "The replacement string"),
                    "replace_all": OllamaParamProp(type: "boolean", description: "Replace all occurrences (default false)")
                ],
                required: ["file_path", "old_string", "new_string"]
            ),
            OllamaToolSpec(
                name: "bash",
                description: "Execute a bash command and return stdout/stderr.",
                parameters: [
                    "command": OllamaParamProp(type: "string", description: "The shell command to run"),
                    "timeout": OllamaParamProp(type: "integer", description: "Timeout in milliseconds"),
                    "description": OllamaParamProp(type: "string", description: "What this command does")
                ],
                required: ["command"]
            ),
            OllamaToolSpec(
                name: "glob_search",
                description: "Search for files matching a glob pattern.",
                parameters: [
                    "pattern": OllamaParamProp(type: "string", description: "Glob pattern like **/*.swift"),
                    "path": OllamaParamProp(type: "string", description: "Directory to search in")
                ],
                required: ["pattern"]
            ),
            OllamaToolSpec(
                name: "grep_search",
                description: "Search file contents with a regex pattern.",
                parameters: [
                    "pattern": OllamaParamProp(type: "string", description: "Regex pattern to search for"),
                    "path": OllamaParamProp(type: "string", description: "File or directory to search"),
                    "glob": OllamaParamProp(type: "string", description: "Glob filter for files, e.g. *.swift")
                ],
                required: ["pattern"]
            ),
            OllamaToolSpec(
                name: "web_fetch",
                description: "Fetch content from a URL. Returns the page text with HTML tags stripped.",
                parameters: [
                    "url": OllamaParamProp(type: "string", description: "The URL to fetch"),
                    "max_chars": OllamaParamProp(type: "integer", description: "Maximum characters to return (default 20000)")
                ],
                required: ["url"]
            ),
            OllamaToolSpec(
                name: "web_search",
                description: "Search the web and return a list of results with titles, URLs, and snippets.",
                parameters: [
                    "query": OllamaParamProp(type: "string", description: "The search query"),
                    "limit": OllamaParamProp(type: "integer", description: "Maximum number of results (default 8)")
                ],
                required: ["query"]
            ),
            OllamaToolSpec(
                name: "todo",
                description: "Manage a to-do list for tracking progress on multi-step tasks.",
                parameters: [
                    "action": OllamaParamProp(type: "string", description: "Action to perform", enum: ["add", "update", "delete", "list"]),
                    "title": OllamaParamProp(type: "string", description: "Task title (for add/update)"),
                    "id": OllamaParamProp(type: "string", description: "Task ID (for update/delete)"),
                    "status": OllamaParamProp(type: "string", description: "New status (for update)", enum: ["pending", "in_progress", "completed"]),
                    "description": OllamaParamProp(type: "string", description: "Task description (for add)")
                ],
                required: ["action"]
            ),
            OllamaToolSpec(
                name: "agent",
                description: "Launch a sub-agent in the background to handle a complex task. Returns immediately with output file paths.",
                parameters: [
                    "prompt": OllamaParamProp(type: "string", description: "The task for the sub-agent to perform"),
                    "description": OllamaParamProp(type: "string", description: "Short description of the task (3-5 words)"),
                    "subagent_type": OllamaParamProp(type: "string", description: "Agent type", enum: ["explore", "plan", "verification", "general-purpose"])
                ],
                required: ["prompt"]
            ),
            OllamaToolSpec(
                name: "notebook",
                description: "Read and edit Jupyter notebook (.ipynb) cells.",
                parameters: [
                    "action": OllamaParamProp(type: "string", description: "Action to perform", enum: ["read", "edit", "insert"]),
                    "path": OllamaParamProp(type: "string", description: "Path to the .ipynb file"),
                    "cell_index": OllamaParamProp(type: "integer", description: "Cell index (0-based)"),
                    "new_source": OllamaParamProp(type: "string", description: "New cell source content (for edit/insert)"),
                    "cell_type": OllamaParamProp(type: "string", description: "Cell type (for edit/insert)", enum: ["code", "markdown", "raw"])
                ],
                required: ["action", "path"]
            ),
            OllamaToolSpec(
                name: "repl",
                description: "Execute code in a REPL-like subprocess. Supported languages: python, javascript, bash.",
                parameters: [
                    "code": OllamaParamProp(type: "string", description: "The code to execute"),
                    "language": OllamaParamProp(type: "string", description: "The language runtime to use", enum: ["python", "javascript", "bash"]),
                    "timeout_ms": OllamaParamProp(type: "integer", description: "Optional timeout in milliseconds")
                ],
                required: ["code", "language"]
            ),
            OllamaToolSpec(
                name: "sleep",
                description: "Pause execution for a specified duration without blocking shell processes.",
                parameters: [
                    "duration_ms": OllamaParamProp(type: "integer", description: "Duration to sleep in milliseconds")
                ],
                required: ["duration_ms"]
            ),
            OllamaToolSpec(
                name: "tool_search",
                description: "Search available tools by name or keyword to discover capabilities.",
                parameters: [
                    "query": OllamaParamProp(type: "string", description: "Search query — tool name or keywords"),
                    "max_results": OllamaParamProp(type: "integer", description: "Maximum number of results (default 5)")
                ],
                required: ["query"]
            ),
            OllamaToolSpec(
                name: "send_message",
                description: "Send a formatted message to the user with optional file attachments.",
                parameters: [
                    "message": OllamaParamProp(type: "string", description: "The message to send to the user"),
                    "attachments": OllamaParamProp(type: "array", description: "Optional list of file paths to attach")
                ],
                required: ["message"]
            ),
            OllamaToolSpec(
                name: "structured_output",
                description: "Return structured output (JSON) in the requested format. Place the structured data as the tool input.",
                parameters: [
                    "data": OllamaParamProp(type: "object", description: "The structured data to return")
                ],
                required: ["data"]
            ),
            OllamaToolSpec(
                name: "config",
                description: "Get or set Claw Code settings. Omit value to read, provide value to write.",
                parameters: [
                    "setting": OllamaParamProp(type: "string", description: "Setting name (dot-separated path, e.g. 'hooks.preToolUse')"),
                    "value": OllamaParamProp(type: "string", description: "New value to set (omit to read current value)")
                ],
                required: []
            ),
            OllamaToolSpec(
                name: "read_pdf",
                description: "Read text from a PDF file, page by page. Caps at 20 pages per request.",
                parameters: [
                    "file_path": OllamaParamProp(type: "string", description: "Absolute path to the PDF file"),
                    "pages": OllamaParamProp(type: "string", description: "Page range to read, e.g. '1-5', '3', or omit for first 20 pages")
                ],
                required: ["file_path"]
            ),
        ]
    }
}
