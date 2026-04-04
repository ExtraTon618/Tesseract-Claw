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

// MARK: - Spinner Verbs

/// Whimsical verbs displayed while the LLM is thinking. Randomly selected each thinking phase.
public let spinnerVerbs: [String] = [
    "Thinking", "Reasoning", "Analyzing", "Processing",
    "Evaluating", "Considering", "Examining", "Reviewing",
    "Interpreting", "Synthesizing", "Computing", "Resolving",
    "Exploring", "Investigating", "Scanning", "Planning",
    "Parsing", "Searching", "Compiling", "Drafting",
    "Decoding", "Checking", "Organizing", "Preparing",
    "Inspecting", "Gathering", "Structuring", "Formulating",
    "Tracing", "Piecing together", "Working out", "Figuring out",
]

/// Verbs displayed when a turn completes.
public let turnCompletionVerbs: [String] = [
    "Finished", "Completed", "Done", "Ready",
    "Resolved", "Delivered", "Wrapped up", "Concluded",
    "Finalized", "Submitted", "Produced", "Accomplished",
]

/// Pick a random spinner verb with "..." suffix.
public func randomSpinnerVerb() -> String {
    spinnerVerbs.randomElement()! + "..."
}

/// Pick a random turn completion verb.
public func randomCompletionVerb() -> String {
    turnCompletionVerbs.randomElement()!
}

// MARK: - Terminal Spinner

/// Animated braille spinner for terminal status display.
/// Uses a background GCD timer to animate frames while the main thread blocks on API calls.
public class Spinner {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex = 0
    private var currentMessage: String = ""
    private var isSpinning = false
    private let output: UnsafeMutablePointer<FILE>
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "spinner.timer", qos: .userInteractive)
    /// Tracks elapsed frames to rotate the thinking verb periodically.
    private var thinkingFrameCount = 0
    /// How many frames (~80ms each) before rotating the verb. ~4 seconds.
    private static let verbRotateInterval = 50

    public init(output: UnsafeMutablePointer<FILE> = stderr) {
        self.output = output
    }

    deinit {
        stopTimer()
    }

    /// Start spinning with a message. The spinner animates automatically in the background.
    public func tick(_ message: String) {
        lock.lock()
        currentMessage = message
        isRotatingVerb = false
        if !isSpinning {
            isSpinning = true
            frameIndex = 0
            lock.unlock()
            startTimer()
        } else {
            lock.unlock()
        }
        // Render immediately so there's no delay
        renderFrame()
    }

    /// Start spinning with a random whimsical verb that rotates every few seconds.
    public func tickThinking() {
        lock.lock()
        currentMessage = randomSpinnerVerb()
        isRotatingVerb = true
        thinkingFrameCount = 0
        if !isSpinning {
            isSpinning = true
            frameIndex = 0
            lock.unlock()
            startTimer()
        } else {
            lock.unlock()
        }
        renderFrame()
    }

    private var isRotatingVerb = false

    /// Finish with green checkmark. Stops animation.
    public func finish(_ message: String) {
        stopTimer()
        lock.lock()
        isSpinning = false
        lock.unlock()
        fputs("\r\u{1B}[2K\u{1B}[32m✔\u{1B}[0m \(message)\n", output)
        fflush(output)
    }

    /// Finish with red X. Stops animation.
    public func fail(_ message: String) {
        stopTimer()
        lock.lock()
        isSpinning = false
        lock.unlock()
        fputs("\r\u{1B}[2K\u{1B}[31m✘\u{1B}[0m \(message)\n", output)
        fflush(output)
    }

    /// Clear the current spinner line without finishing. Stops animation.
    public func clear() {
        stopTimer()
        lock.lock()
        isSpinning = false
        lock.unlock()
        fputs("\r\u{1B}[2K", output)
        fflush(output)
    }

    // MARK: - Private

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(80))
        source.setEventHandler { [weak self] in
            self?.renderFrame()
        }
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func renderFrame() {
        lock.lock()
        let frame = Spinner.frames[frameIndex % Spinner.frames.count]
        frameIndex += 1
        // Rotate the thinking verb periodically
        if isRotatingVerb {
            thinkingFrameCount += 1
            if thinkingFrameCount % Spinner.verbRotateInterval == 0 {
                currentMessage = randomSpinnerVerb()
            }
        }
        let message = currentMessage
        lock.unlock()

        fputs("\r\u{1B}[2K\u{1B}[34m\(frame)\u{1B}[0m \(message)", output)
        fflush(output)
    }
}

// MARK: - Status Event

/// Events emitted during a conversation turn for live status display.
public enum StatusEvent {
    case thinking
    case toolStart(name: String, input: String)
    case toolOutput(name: String, input: String, output: String, isError: Bool)
    case toolFinish(name: String, isError: Bool)
    case textDelta(String)
    case done
}

// MARK: - Tool Output Formatting

/// Maximum number of output lines to show inline before truncating.
private let toolOutputMaxLines = 6
/// Tools that should show more output lines (file listings, search results, agent output).
private let verboseOutputTools: Set<String> = ["glob_search", "grep_search", "todo", "agent", "web_fetch", "web_search", "structured_output"]
private let verboseOutputMaxLines = 50

/// Format a tool call header: `⏺ Bash(command)` or `⏺ Read(path)`
public func formatToolHeader(name: String, input: String) -> String {
    let parsed = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]

    switch name {
    case "bash":
        let cmd = parsed?["command"] as? String ?? input
        return "Bash(\(cmd))"
    case "repl":
        let lang = parsed?["language"] as? String ?? "python"
        let code = parsed?["code"] as? String ?? input
        let short = code.count > 80 ? String(code.prefix(77)) + "..." : code
        return "REPL(\(lang): \(short))"
    case "read_file":
        let path = parsed?["file_path"] as? String ?? input
        return "Read(\(path))"
    case "write_file":
        let path = parsed?["file_path"] as? String ?? ""
        return "Write(\(path))"
    case "edit_file":
        let path = parsed?["file_path"] as? String ?? ""
        return "Edit(\(path))"
    case "glob_search":
        let pattern = parsed?["pattern"] as? String ?? input
        return "Glob(\(pattern))"
    case "grep_search":
        let pattern = parsed?["pattern"] as? String ?? input
        return "Grep(\(pattern))"
    case "web_fetch":
        let url = parsed?["url"] as? String ?? input
        return "WebFetch(\(url))"
    case "web_search":
        let query = parsed?["query"] as? String ?? input
        return "WebSearch(\(query))"
    case "agent":
        let desc = parsed?["description"] as? String ?? parsed?["prompt"] as? String ?? "sub-task"
        return "Agent(\(desc))"
    case "todo":
        let action = parsed?["action"] as? String ?? "list"
        return "Todo(\(action))"
    case "notebook":
        let action = parsed?["action"] as? String ?? "read"
        let path = parsed?["path"] as? String ?? ""
        return "Notebook(\(action) \(path))"
    default:
        return "\(name)(\(input.prefix(60)))"
    }
}

/// Render a tool call block with truncated output.
/// ```
/// ⏺ Bash(swift build -c release 2>&1)
///   ⎿  [0/1] Planning build
///      Building for production...
///      … +14 lines
/// ```
public func renderToolBlock(name: String, input: String, output: String, isError: Bool) -> String {
    let header = formatToolHeader(name: name, input: input)
    let icon = isError ? "\u{1B}[31m⏺\u{1B}[0m" : "\u{1B}[34m⏺\u{1B}[0m"  // red or blue dot

    let maxLines = verboseOutputTools.contains(name) ? verboseOutputMaxLines : toolOutputMaxLines

    let lines = output.components(separatedBy: "\n")
    let trimmedLines = lines.map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }

    var parts: [String] = []
    parts.append("\(icon) \(header)")

    if trimmedLines.isEmpty || (trimmedLines.count == 1 && trimmedLines[0].isEmpty) {
        parts.append("  \u{1B}[2m⎿\u{1B}[0m  (no output)")
    } else if trimmedLines.count <= maxLines {
        // Show all lines
        for (i, line) in trimmedLines.enumerated() {
            let prefix = i == 0 ? "  \u{1B}[2m⎿\u{1B}[0m  " : "     "
            parts.append("\(prefix)\(line)")
        }
    } else {
        // Show first few lines + truncation notice
        let showCount = maxLines - 1
        for (i, line) in trimmedLines.prefix(showCount).enumerated() {
            let prefix = i == 0 ? "  \u{1B}[2m⎿\u{1B}[0m  " : "     "
            parts.append("\(prefix)\(line)")
        }
        let remaining = trimmedLines.count - showCount
        parts.append("     \u{1B}[2m… +\(remaining) lines\u{1B}[0m")
    }

    return parts.joined(separator: "\n")
}

/// Callback type for receiving status events during a turn.
public typealias StatusCallback = (StatusEvent) -> Void

// MARK: - Tool Display Formatting

/// Format a tool call for display.
public func formatToolStatus(name: String, input: String) -> String {
    // Parse input JSON for key details
    let parsed = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]

    switch name {
    case "read_file":
        let path = parsed?["file_path"] as? String ?? input
        return "📄 Reading \(shortenPath(path))"
    case "write_file":
        let path = parsed?["file_path"] as? String ?? ""
        return "✏️  Writing \(shortenPath(path))"
    case "edit_file":
        let path = parsed?["file_path"] as? String ?? ""
        return "📝 Editing \(shortenPath(path))"
    case "bash":
        let cmd = parsed?["command"] as? String ?? input
        let short = cmd.count > 60 ? String(cmd.prefix(57)) + "..." : cmd
        return "$ \(short)"
    case "glob_search":
        let pattern = parsed?["pattern"] as? String ?? input
        return "🔎 Glob \(pattern)"
    case "grep_search":
        let pattern = parsed?["pattern"] as? String ?? input
        return "🔎 Grep \(pattern)"
    case "web_fetch":
        let url = parsed?["url"] as? String ?? input
        return "🌐 Fetching \(url)"
    case "web_search":
        let query = parsed?["query"] as? String ?? input
        return "🔍 Searching: \(query)"
    case "agent":
        let desc = parsed?["description"] as? String ?? "sub-task"
        return "🤖 Agent: \(desc)"
    case "todo":
        let action = parsed?["action"] as? String ?? "list"
        return "📋 Todo: \(action)"
    case "notebook":
        let action = parsed?["action"] as? String ?? "read"
        let path = parsed?["path"] as? String ?? ""
        return "📓 Notebook \(action) \(shortenPath(path))"
    default:
        return "🔧 \(name)"
    }
}

private func shortenPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    if components.count <= 3 { return path }
    return "…/" + components.suffix(3).joined(separator: "/")
}
