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

// MARK: - Message Role

public enum MessageRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - Content Block

public enum ContentBlock: Equatable, Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseId: String, toolName: String, output: String, isError: Bool)
    case image(base64Data: String, mediaType: String)

    private enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case text, id, name, input
        case toolUseId = "tool_use_id"
        case toolName = "tool_name"
        case output
        case isError = "is_error"
        case base64Data = "base64_data"
        case mediaType = "media_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type_)
        switch type_ {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(String.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let toolName = try container.decode(String.self, forKey: .toolName)
            let output = try container.decode(String.self, forKey: .output)
            let isError = try container.decode(Bool.self, forKey: .isError)
            self = .toolResult(toolUseId: toolUseId, toolName: toolName, output: output, isError: isError)
        case "image":
            let base64Data = try container.decode(String.self, forKey: .base64Data)
            let mediaType = try container.decode(String.self, forKey: .mediaType)
            self = .image(base64Data: base64Data, mediaType: mediaType)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type_, in: container, debugDescription: "Unsupported block type: \(type_)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type_)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type_)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let toolName, let output, let isError):
            try container.encode("tool_result", forKey: .type_)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(output, forKey: .output)
            try container.encode(isError, forKey: .isError)
        case .image(let base64Data, let mediaType):
            try container.encode("image", forKey: .type_)
            try container.encode(base64Data, forKey: .base64Data)
            try container.encode(mediaType, forKey: .mediaType)
        }
    }
}

// MARK: - Image Helpers

extension ConversationMessage {
    /// Create a user message with text and an image
    public static func userWithImage(text: String, imagePath: String) -> ConversationMessage? {
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else { return nil }
        let base64 = imageData.base64EncodedString()
        let ext = (imagePath as NSString).pathExtension.lowercased()
        let mediaType: String
        switch ext {
        case "png": mediaType = "image/png"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: mediaType = "image/jpeg"
        }
        return ConversationMessage(role: .user, blocks: [
            .image(base64Data: base64, mediaType: mediaType),
            .text(text)
        ])
    }
}

// MARK: - Token Usage

public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: UInt32
    public var outputTokens: UInt32
    public var cacheCreationInputTokens: UInt32
    public var cacheReadInputTokens: UInt32

    public init(
        inputTokens: UInt32 = 0,
        outputTokens: UInt32 = 0,
        cacheCreationInputTokens: UInt32 = 0,
        cacheReadInputTokens: UInt32 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public var totalTokens: UInt32 {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - Conversation Message

public struct ConversationMessage: Codable, Equatable, Sendable {
    public var role: MessageRole
    public var blocks: [ContentBlock]
    public var usage: TokenUsage?

    public init(role: MessageRole, blocks: [ContentBlock], usage: TokenUsage? = nil) {
        self.role = role
        self.blocks = blocks
        self.usage = usage
    }

    public static func userText(_ text: String) -> ConversationMessage {
        ConversationMessage(role: .user, blocks: [.text(text)])
    }

    public static func assistant(_ blocks: [ContentBlock]) -> ConversationMessage {
        ConversationMessage(role: .assistant, blocks: blocks)
    }

    public static func assistantWithUsage(_ blocks: [ContentBlock], usage: TokenUsage?) -> ConversationMessage {
        ConversationMessage(role: .assistant, blocks: blocks, usage: usage)
    }

    public static func toolResult(toolUseId: String, toolName: String, output: String, isError: Bool) -> ConversationMessage {
        ConversationMessage(
            role: .tool,
            blocks: [.toolResult(toolUseId: toolUseId, toolName: toolName, output: output, isError: isError)]
        )
    }
}

// MARK: - Session

public struct Session: Codable, Equatable, Sendable {
    public var version: UInt32
    public var messages: [ConversationMessage]

    public init(version: UInt32 = 1, messages: [ConversationMessage] = []) {
        self.version = version
        self.messages = messages
    }

    public func saveToPath(_ path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
    }

    public static func loadFromPath(_ path: String) throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Session.self, from: data)
    }
}
