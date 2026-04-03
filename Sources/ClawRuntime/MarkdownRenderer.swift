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

// MARK: - Terminal Markdown Renderer

/// Renders markdown text with ANSI terminal formatting.
/// Supports streaming (push token-by-token) and batch (render full text) modes.
public class TerminalMarkdownRenderer {
    private var pending = ""
    private let output: UnsafeMutablePointer<FILE>

    public init(output: UnsafeMutablePointer<FILE> = stdout) {
        self.output = output
    }

    // MARK: - Streaming Mode

    /// Push a token for incremental rendering. Buffers until safe boundaries
    /// (completed lines outside code fences) then renders and flushes.
    public func push(_ token: String) {
        pending += token

        // Find safe boundary to render up to
        if let boundary = findSafeBoundary(pending) {
            let toRender = String(pending.prefix(boundary))
            pending = String(pending.dropFirst(boundary))
            let rendered = renderLines(toRender)
            fputs(rendered, output)
            fflush(output)
        }
    }

    /// Flush any remaining buffered content.
    public func flush() {
        if !pending.isEmpty {
            let rendered = renderLines(pending)
            fputs(rendered, output)
            fflush(output)
            pending = ""
        }
    }

    // MARK: - Batch Mode

    /// Render a complete markdown string for terminal display.
    public func render(_ text: String) -> String {
        return renderLines(text)
    }

    // MARK: - Safe Boundary Detection

    /// Find a safe position to split streaming content.
    /// Safe boundaries are after complete lines when not inside a code fence.
    private func findSafeBoundary(_ text: String) -> Int? {
        var inFence = false
        var lastSafe: Int? = nil

        let lines = text.components(separatedBy: "\n")
        var offset = 0

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = !inFence
            }

            offset += line.utf8.count
            if i < lines.count - 1 {
                offset += 1 // newline char
            }

            if !inFence && i < lines.count - 1 {
                lastSafe = offset
            }
        }

        return lastSafe
    }

    // MARK: - Rendering

    private func renderLines(_ text: String) -> String {
        var result = ""
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent = ""
        let lines = text.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence toggle
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCodeBlock {
                    // End code block
                    result += renderCodeBlock(codeContent, language: codeLanguage)
                    inCodeBlock = false
                    codeContent = ""
                    codeLanguage = ""
                } else {
                    // Start code block
                    inCodeBlock = true
                    let fenceLen = trimmed.hasPrefix("```") ? 3 : 3
                    codeLanguage = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                if !codeContent.isEmpty { codeContent += "\n" }
                codeContent += line
                continue
            }

            // Regular markdown line
            result += renderMarkdownLine(line)
            if i < lines.count - 1 {
                result += "\n"
            }
        }

        // Unclosed code block — render what we have
        if inCodeBlock && !codeContent.isEmpty {
            result += renderCodeBlock(codeContent, language: codeLanguage)
        }

        return result
    }

    private func renderMarkdownLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Headers
        if trimmed.hasPrefix("#### ") {
            return "\(ansi(.bold))\(ansi(.fg(.white)))\(String(trimmed.dropFirst(5)))\(ansi(.reset))"
        }
        if trimmed.hasPrefix("### ") {
            return "\(ansi(.bold))\(ansi(.fg(.blue)))\(String(trimmed.dropFirst(4)))\(ansi(.reset))"
        }
        if trimmed.hasPrefix("## ") {
            return "\(ansi(.bold))\(ansi(.fg(.white)))\(String(trimmed.dropFirst(3)))\(ansi(.reset))"
        }
        if trimmed.hasPrefix("# ") {
            return "\(ansi(.bold))\(ansi(.fg(.cyan)))\(String(trimmed.dropFirst(2)))\(ansi(.reset))"
        }

        // Block quotes
        if trimmed.hasPrefix("> ") {
            let quoteText = String(trimmed.dropFirst(2))
            return "\(ansi(.fg(.darkGray)))│ \(renderInlineMarkdown(quoteText))\(ansi(.reset))"
        }

        // Horizontal rule
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return "\(ansi(.fg(.darkGray)))────────────────────────────────\(ansi(.reset))"
        }

        // Unordered list items
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            let content = String(trimmed.dropFirst(2))
            return "\(indent)  • \(renderInlineMarkdown(content))"
        }

        // Ordered list items
        if let match = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
            let content = String(trimmed[match.upperBound...])
            let number = String(trimmed[trimmed.startIndex..<trimmed.index(before: match.upperBound)])
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            return "\(indent) \(number) \(renderInlineMarkdown(content))"
        }

        return renderInlineMarkdown(line)
    }

    /// Render inline markdown: bold, italic, inline code, links
    private func renderInlineMarkdown(_ text: String) -> String {
        var result = text

        // Inline code: `code` → green
        result = replacePattern(result, pattern: #"`([^`]+)`"#) { match in
            "\(ansi(.fg(.green)))\(match)\(ansi(.reset))"
        }

        // Bold: **text** → bold yellow
        result = replacePattern(result, pattern: #"\*\*([^*]+)\*\*"#) { match in
            "\(ansi(.bold))\(ansi(.fg(.yellow)))\(match)\(ansi(.reset))"
        }

        // Italic: *text* → magenta (but not ** which is bold)
        result = replacePattern(result, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { match in
            "\(ansi(.fg(.magenta)))\(match)\(ansi(.reset))"
        }

        // Links: [text](url) → blue underlined text
        result = replacePattern(result, pattern: #"\[([^\]]+)\]\([^)]+\)"#) { match in
            "\(ansi(.fg(.blue)))\(ansi(.underline))\(match)\(ansi(.reset))"
        }

        return result
    }

    // MARK: - Code Block Rendering

    private func renderCodeBlock(_ code: String, language: String) -> String {
        let lang = language.isEmpty ? "" : " \(language)"
        let darkBg = "\u{1B}[48;5;236m"
        var result = "\(ansi(.fg(.darkGray)))╭─\(lang)\(ansi(.reset))\n"

        let lines = code.components(separatedBy: "\n")
        for line in lines {
            result += "\(darkBg) \(line) \(ansi(.reset))\n"
        }
        result += "\(ansi(.fg(.darkGray)))╰─\(ansi(.reset))"
        return result
    }

    // MARK: - ANSI Helpers

    private enum AnsiCode {
        case reset
        case bold
        case underline
        case fg(AnsiColor)
    }

    private enum AnsiColor {
        case cyan, yellow, magenta, green, blue, white, darkGray
    }

    private func ansi(_ code: AnsiCode) -> String {
        switch code {
        case .reset: return "\u{1B}[0m"
        case .bold: return "\u{1B}[1m"
        case .underline: return "\u{1B}[4m"
        case .fg(let color):
            switch color {
            case .cyan: return "\u{1B}[36m"
            case .yellow: return "\u{1B}[33m"
            case .magenta: return "\u{1B}[35m"
            case .green: return "\u{1B}[32m"
            case .blue: return "\u{1B}[34m"
            case .white: return "\u{1B}[97m"
            case .darkGray: return "\u{1B}[90m"
            }
        }
    }

    // MARK: - Regex Helper

    /// Replace regex pattern matches, passing the captured group (not full match) to the transform.
    private func replacePattern(_ text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var lastEnd = text.startIndex

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            let fullRange = Range(match.range, in: text)!
            // Append text before match
            result += text[lastEnd..<fullRange.lowerBound]

            // Get the captured group (group 1) — the content without markers
            if match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) {
                let captured = String(text[captureRange])
                result += transform(captured)
            } else {
                result += String(text[fullRange])
            }
            lastEnd = fullRange.upperBound
        }
        result += text[lastEnd...]
        return result
    }
}
