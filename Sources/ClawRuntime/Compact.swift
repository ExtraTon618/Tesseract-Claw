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

// MARK: - Compaction Config

public struct CompactionConfig: Equatable, Sendable {
    public var preserveRecentMessages: Int
    public var maxEstimatedTokens: Int

    public init(preserveRecentMessages: Int = 4, maxEstimatedTokens: Int = 10_000) {
        self.preserveRecentMessages = preserveRecentMessages
        self.maxEstimatedTokens = maxEstimatedTokens
    }
}

// MARK: - Compaction Result

public struct CompactionResult: Equatable, Sendable {
    public let summary: String
    public let formattedSummary: String
    public let compactedSession: Session
    public let removedMessageCount: Int
}

private let compactContinuationPreamble = "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n"
private let compactRecentMessagesNote = "Recent messages are preserved verbatim."
private let compactDirectResumeInstruction = "Continue the conversation from where it left off without asking the user any further questions. Resume directly — do not acknowledge the summary, do not recap what was happening, and do not preface with continuation text."

// MARK: - Public API

public func estimateSessionTokens(_ session: Session) -> Int {
    session.messages.reduce(0) { $0 + estimateMessageTokens($1) }
}

public func shouldCompact(_ session: Session, config: CompactionConfig) -> Bool {
    let start = compactedSummaryPrefixLen(session)
    let compactable = Array(session.messages[start...])
    return compactable.count > config.preserveRecentMessages
        && compactable.reduce(0, { $0 + estimateMessageTokens($1) }) >= config.maxEstimatedTokens
}

public func formatCompactSummary(_ summary: String) -> String {
    let withoutAnalysis = stripTagBlock(summary, tag: "analysis")
    let formatted: String
    if let content = extractTagBlock(withoutAnalysis, tag: "summary") {
        formatted = withoutAnalysis.replacingOccurrences(
            of: "<summary>\(content)</summary>",
            with: "Summary:\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    } else {
        formatted = withoutAnalysis
    }
    return collapseBlankLines(formatted).trimmingCharacters(in: .whitespacesAndNewlines)
}

public func getCompactContinuationMessage(summary: String, suppressFollowUpQuestions: Bool, recentMessagesPreserved: Bool) -> String {
    var base = "\(compactContinuationPreamble)\(formatCompactSummary(summary))"
    if recentMessagesPreserved {
        base += "\n\n\(compactRecentMessagesNote)"
    }
    if suppressFollowUpQuestions {
        base += "\n\(compactDirectResumeInstruction)"
    }
    return base
}

public func compactSession(_ session: Session, config: CompactionConfig) -> CompactionResult {
    guard shouldCompact(session, config: config) else {
        return CompactionResult(
            summary: "",
            formattedSummary: "",
            compactedSession: session,
            removedMessageCount: 0
        )
    }

    let existingSummary = session.messages.first.flatMap(extractExistingCompactedSummary)
    let compactedPrefixLen = existingSummary != nil ? 1 : 0
    let keepFrom = max(0, session.messages.count - config.preserveRecentMessages)
    let removed = Array(session.messages[compactedPrefixLen..<keepFrom])
    let preserved = Array(session.messages[keepFrom...])
    let summary = mergeCompactSummaries(existing: existingSummary, new: summarizeMessages(removed))
    let formattedSummary = formatCompactSummary(summary)
    let continuation = getCompactContinuationMessage(summary: summary, suppressFollowUpQuestions: true, recentMessagesPreserved: !preserved.isEmpty)

    var compactedMessages = [ConversationMessage(
        role: .system,
        blocks: [.text(continuation)]
    )]
    compactedMessages.append(contentsOf: preserved)

    return CompactionResult(
        summary: summary,
        formattedSummary: formattedSummary,
        compactedSession: Session(version: session.version, messages: compactedMessages),
        removedMessageCount: removed.count
    )
}

// MARK: - Internal Helpers

private func compactedSummaryPrefixLen(_ session: Session) -> Int {
    session.messages.first.flatMap(extractExistingCompactedSummary) != nil ? 1 : 0
}

func estimateMessageTokens(_ message: ConversationMessage) -> Int {
    message.blocks.reduce(0) { total, block in
        switch block {
        case .text(let text):
            return total + text.count / 4 + 1
        case .toolUse(_, let name, let input):
            return total + (name.count + input.count) / 4 + 1
        case .toolResult(_, let toolName, let output, _):
            return total + (toolName.count + output.count) / 4 + 1
        case .image:
            return total + 256 // estimate for image token cost
        }
    }
}

private func summarizeMessages(_ messages: [ConversationMessage]) -> String {
    let userMessages = messages.filter { $0.role == .user }.count
    let assistantMessages = messages.filter { $0.role == .assistant }.count
    let toolMessages = messages.filter { $0.role == .tool }.count

    var toolNames = Set<String>()
    for message in messages {
        for block in message.blocks {
            switch block {
            case .toolUse(_, let name, _): toolNames.insert(name)
            case .toolResult(_, let toolName, _, _): toolNames.insert(toolName)
            case .text, .image: break
            }
        }
    }

    var lines = [
        "<summary>",
        "Conversation summary:",
        "- Scope: \(messages.count) earlier messages compacted (user=\(userMessages), assistant=\(assistantMessages), tool=\(toolMessages))."
    ]

    if !toolNames.isEmpty {
        lines.append("- Tools mentioned: \(toolNames.sorted().joined(separator: ", ")).")
    }

    let recentUserRequests = collectRecentRoleSummaries(messages, role: .user, limit: 3)
    if !recentUserRequests.isEmpty {
        lines.append("- Recent user requests:")
        lines.append(contentsOf: recentUserRequests.map { "  - \($0)" })
    }

    let pendingWork = inferPendingWork(messages)
    if !pendingWork.isEmpty {
        lines.append("- Pending work:")
        lines.append(contentsOf: pendingWork.map { "  - \($0)" })
    }

    let keyFiles = collectKeyFiles(messages)
    if !keyFiles.isEmpty {
        lines.append("- Key files referenced: \(keyFiles.joined(separator: ", ")).")
    }

    if let currentWork = inferCurrentWork(messages) {
        lines.append("- Current work: \(currentWork)")
    }

    lines.append("- Key timeline:")
    for message in messages {
        let role: String
        switch message.role {
        case .system: role = "system"
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .tool: role = "tool"
        }
        let content = message.blocks.map { summarizeBlock($0) }.joined(separator: " | ")
        lines.append("  - \(role): \(content)")
    }
    lines.append("</summary>")
    return lines.joined(separator: "\n")
}

private func mergeCompactSummaries(existing: String?, new: String) -> String {
    guard let existing = existing else { return new }

    let previousHighlights = extractSummaryHighlights(existing)
    let newFormatted = formatCompactSummary(new)
    let newHighlights = extractSummaryHighlights(newFormatted)
    let newTimeline = extractSummaryTimeline(newFormatted)

    var lines = ["<summary>", "Conversation summary:"]
    if !previousHighlights.isEmpty {
        lines.append("- Previously compacted context:")
        lines.append(contentsOf: previousHighlights.map { "  \($0)" })
    }
    if !newHighlights.isEmpty {
        lines.append("- Newly compacted context:")
        lines.append(contentsOf: newHighlights.map { "  \($0)" })
    }
    if !newTimeline.isEmpty {
        lines.append("- Key timeline:")
        lines.append(contentsOf: newTimeline.map { "  \($0)" })
    }
    lines.append("</summary>")
    return lines.joined(separator: "\n")
}

private func summarizeBlock(_ block: ContentBlock) -> String {
    let raw: String
    switch block {
    case .text(let text): raw = text
    case .toolUse(_, let name, let input): raw = "tool_use \(name)(\(input))"
    case .toolResult(_, let toolName, let output, let isError):
        raw = "tool_result \(toolName): \(isError ? "error " : "")\(output)"
    case .image(_, let mediaType): raw = "[image: \(mediaType)]"
    }
    return truncateSummary(raw, maxChars: 160)
}

private func collectRecentRoleSummaries(_ messages: [ConversationMessage], role: MessageRole, limit: Int) -> [String] {
    Array(messages
        .filter { $0.role == role }
        .reversed()
        .compactMap { firstTextBlock($0) }
        .prefix(limit)
        .map { truncateSummary($0, maxChars: 160) }
        .reversed())
}

private func inferPendingWork(_ messages: [ConversationMessage]) -> [String] {
    Array(messages
        .reversed()
        .compactMap { firstTextBlock($0) }
        .filter { text in
            let lowered = text.lowercased()
            return lowered.contains("todo") || lowered.contains("next") || lowered.contains("pending") || lowered.contains("follow up") || lowered.contains("remaining")
        }
        .prefix(3)
        .map { truncateSummary($0, maxChars: 160) }
        .reversed())
}

private func collectKeyFiles(_ messages: [ConversationMessage]) -> [String] {
    var files = Set<String>()
    for message in messages {
        for block in message.blocks {
            let content: String
            switch block {
            case .text(let text): content = text
            case .toolUse(_, _, let input): content = input
            case .toolResult(_, _, let output, _): content = output
            case .image: content = ""
            }
            for candidate in extractFileCandidates(content) {
                files.insert(candidate)
            }
        }
    }
    return Array(files.sorted().prefix(8))
}

private func inferCurrentWork(_ messages: [ConversationMessage]) -> String? {
    messages.reversed()
        .compactMap { firstTextBlock($0) }
        .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        .map { truncateSummary($0, maxChars: 200) }
}

private func firstTextBlock(_ message: ConversationMessage) -> String? {
    for block in message.blocks {
        if case .text(let text) = block, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
    }
    return nil
}

private func extractFileCandidates(_ content: String) -> [String] {
    let interestingExtensions: Set<String> = ["swift", "rs", "ts", "tsx", "js", "json", "md"]
    return content.split(separator: " ").compactMap { token in
        let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:)('\"`"))
        guard candidate.contains("/"),
              let ext = candidate.split(separator: ".").last,
              interestingExtensions.contains(ext.lowercased()) else { return nil }
        return candidate
    }
}

private func truncateSummary(_ content: String, maxChars: Int) -> String {
    guard content.count > maxChars else { return content }
    return String(content.prefix(maxChars)) + "…"
}

private func extractTagBlock(_ content: String, tag: String) -> String? {
    let startTag = "<\(tag)>"
    let endTag = "</\(tag)>"
    guard let startRange = content.range(of: startTag),
          let endRange = content.range(of: endTag, range: startRange.upperBound..<content.endIndex) else { return nil }
    return String(content[startRange.upperBound..<endRange.lowerBound])
}

private func stripTagBlock(_ content: String, tag: String) -> String {
    let startTag = "<\(tag)>"
    let endTag = "</\(tag)>"
    guard let startRange = content.range(of: startTag),
          let endRange = content.range(of: endTag) else { return content }
    var result = String(content[..<startRange.lowerBound])
    result += String(content[endRange.upperBound...])
    return result
}

func collapseBlankLines(_ content: String) -> String {
    var result = ""
    var previousBlank = false
    for line in content.components(separatedBy: "\n") {
        let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if isBlank && previousBlank { continue }
        result += line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        result += "\n"
        previousBlank = isBlank
    }
    return result
}

private func extractExistingCompactedSummary(_ message: ConversationMessage) -> String? {
    guard message.role == .system else { return nil }
    guard let text = firstTextBlock(message) else { return nil }
    guard let summary = text.hasPrefix(compactContinuationPreamble) ? String(text.dropFirst(compactContinuationPreamble.count)) : nil else { return nil }
    let trimmed: String
    if let range = summary.range(of: "\n\n\(compactRecentMessagesNote)") {
        trimmed = String(summary[..<range.lowerBound])
    } else if let range = summary.range(of: "\n\(compactDirectResumeInstruction)") {
        trimmed = String(summary[..<range.lowerBound])
    } else {
        trimmed = summary
    }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func extractSummaryHighlights(_ summary: String) -> [String] {
    var lines: [String] = []
    var inTimeline = false
    for line in formatCompactSummary(summary).components(separatedBy: "\n") {
        let trimmed = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if trimmed.isEmpty || trimmed == "Summary:" || trimmed == "Conversation summary:" { continue }
        if trimmed == "- Key timeline:" { inTimeline = true; continue }
        if inTimeline { continue }
        lines.append(trimmed)
    }
    return lines
}

private func extractSummaryTimeline(_ summary: String) -> [String] {
    var lines: [String] = []
    var inTimeline = false
    for line in formatCompactSummary(summary).components(separatedBy: "\n") {
        let trimmed = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if trimmed == "- Key timeline:" { inTimeline = true; continue }
        if !inTimeline { continue }
        if trimmed.isEmpty { break }
        lines.append(trimmed)
    }
    return lines
}
