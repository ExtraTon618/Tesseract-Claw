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
import ClawAPI

// MARK: - Constants

let version = "0.6.0"
let defaultDate: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}()

// MARK: - CLI Actions

/// When true, show ReAct reasoning (Thought/Action/Action Input) during streaming.
/// Off by default — only tool execution blocks and final answers are shown.
var detailMode = false

enum CliAction {
    case version
    case help
    case systemPrompt
    case listModels
    case prompt(text: String, model: String, permissionMode: PermissionMode, imagePath: String?)
    case repl(model: String, permissionMode: PermissionMode)
}

// MARK: - Argument Parsing

func parseArgs(_ args: [String]) -> CliAction {
    var model = defaultTextModel
    var permissionMode: PermissionMode = .workspaceWrite
    var imagePath: String? = nil
    var rest: [String] = []
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--version", "-V":
            return .version
        case "--help", "-h":
            return .help
        case "--model":
            if i + 1 < args.count {
                model = resolveModelAlias(args[i + 1])
                i += 2; continue
            }
        case "--system-prompt":
            return .systemPrompt
        case "--list-models", "--models":
            return .listModels
        case "--image":
            if i + 1 < args.count {
                imagePath = args[i + 1]
                i += 2; continue
            }
        case "--permission-mode":
            if i + 1 < args.count {
                switch args[i + 1] {
                case "read-only": permissionMode = .readOnly
                case "workspace-write": permissionMode = .workspaceWrite
                case "danger-full-access": permissionMode = .dangerFullAccess
                default: break
                }
                i += 2; continue
            }
        case "--detail", "--verbose":
            detailMode = true
            i += 1; continue
        case "-p", "--prompt":
            if i + 1 < args.count {
                return .prompt(text: args[i + 1], model: model, permissionMode: permissionMode, imagePath: imagePath)
            }
        default:
            rest.append(args[i])
        }
        i += 1
    }

    if !rest.isEmpty {
        return .prompt(text: rest.joined(separator: " "), model: model, permissionMode: permissionMode, imagePath: imagePath)
    }

    return .repl(model: model, permissionMode: permissionMode)
}

// MARK: - Terminal Prompter

struct TerminalPrompter: PermissionPrompter {
    /// Reference to spinner so we can stop it before prompting for input.
    /// Without this, the spinner's background timer overwrites the prompt.
    weak var spinner: Spinner?

    mutating func decide(_ request: PermissionRequest) -> PermissionPromptDecision {
        // Stop spinner animation so the permission prompt is visible and readLine() works
        spinner?.clear()

        // ── Permission box ──
        let toolLabel = request.toolName
        let modeLabel = request.requiredMode.asString
        let currentLabel = request.currentMode.asString

        print("")
        print("  \u{001B}[33m┌─ Permission Required ──────────────────────────────────┐\u{001B}[0m")
        print("  \u{001B}[33m│\u{001B}[0m  Tool:       \u{001B}[1m\(toolLabel)\u{001B}[0m")
        print("  \u{001B}[33m│\u{001B}[0m  Requires:   \(modeLabel)  (current: \(currentLabel))")

        // Show input preview (truncated, indented)
        let rawPreview = String(request.input.prefix(300))
        if !rawPreview.isEmpty {
            let lines = rawPreview.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
            for (i, line) in lines.prefix(4).enumerated() {
                let prefix = i == 0 ? "  Input:      " : "              "
                let truncated = (i == 3 || (i == lines.count - 1 && request.input.count > 300)) ? "..." : ""
                print("  \u{001B}[33m│\u{001B}[0m  \(prefix)\u{001B}[2m\(line)\(truncated)\u{001B}[0m")
            }
        }
        print("  \u{001B}[33m└───────────────────────────────────────────────────────┘\u{001B}[0m")

        print("  \u{001B}[1mAllow this tool? (yes/no)\u{001B}[0m ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "n"
        if answer == "y" || answer == "yes" {
            print("  \u{001B}[32m✓ Allowed\u{001B}[0m (cached for this session)\n")
            return .allow
        }
        print("  \u{001B}[31m✗ Denied\u{001B}[0m\n")
        return .deny(reason: "User denied tool '\(request.toolName)'")
    }
}

// MARK: - Build Runtime

// MARK: - Sub-Agent Runtime Bridge

/// Bridges a ConversationRuntime with RestrictedToolExecutor into the SubAgentRunnable protocol.
class SubAgentRunnableImpl: SubAgentRunnable {
    private let runtime: ConversationRuntime<OllamaClient, RestrictedToolExecutor>

    init(runtime: ConversationRuntime<OllamaClient, RestrictedToolExecutor>) {
        self.runtime = runtime
    }

    func runTurn(_ input: String) throws -> SubAgentTurnResult {
        var prompter: (any PermissionPrompter)? = nil  // sub-agents don't prompt
        let summary = try runtime.runTurn(input, prompter: &prompter)

        // Extract final text
        var text = ""
        for message in summary.assistantMessages.reversed() {
            for block in message.blocks {
                if case .text(let t) = block { text = t; break }
            }
            if !text.isEmpty { break }
        }

        // Collect tool names
        var toolNames = Set<String>()
        for message in summary.toolResults {
            for block in message.blocks {
                if case .toolResult(_, let name, _, _) = block { toolNames.insert(name) }
            }
        }

        return SubAgentTurnResult(text: text, toolsUsed: Array(toolNames.sorted()), iterations: summary.iterations)
    }
}

func buildRuntime(model: String, permissionMode: PermissionMode, mdRenderer: TerminalMarkdownRenderer? = nil, spinner: Spinner? = nil) -> (ConversationRuntime<OllamaClient, LiveToolExecutor>, OllamaClient) {
    let cwd = FileManager.default.currentDirectoryPath
    let config = ConfigLoader(cwd: cwd).load()
    // Use config model if no explicit model provided
    let effectiveModel = model == defaultTextModel ? (config.featureConfig.model ?? model) : model
    let systemPrompt = loadSystemPrompt(cwd: cwd, currentDate: defaultDate, osName: "macOS", osVersion: ProcessInfo.processInfo.operatingSystemVersionString, modelName: effectiveModel)
    let client = OllamaClient(model: effectiveModel)
    client.setTools(OllamaClient.toolSpecsFromRegistry())
    client.suppressReActStreaming = !detailMode

    // Enable streaming: tokens flow to terminal as they're generated.
    if let renderer = mdRenderer {
        client.onToken = { token in
            spinner?.clear()
            renderer.push(token)
        }
    }

    var toolExecutor = LiveToolExecutor(cwd: cwd)

    // Wire sub-agent factory: creates an isolated runtime with restricted tools
    let capturedModel = effectiveModel
    toolExecutor.subAgentFactory = { (agentType: SubAgentType, _: [String]) -> SubAgentRunnable? in
        let agentCwd = FileManager.default.currentDirectoryPath
        let agentClient = OllamaClient(model: capturedModel)
        // Sub-agents don't stream to terminal
        let restrictedExecutor = RestrictedToolExecutor(
            inner: LiveToolExecutor(cwd: agentCwd),
            allowedTools: agentType.allowedTools
        )
        var basePrompt = loadSystemPrompt(cwd: agentCwd, currentDate: defaultDate, osName: "macOS",
                                          osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                          modelName: capturedModel)
        basePrompt.append(agentType.systemInstruction)

        let agentPolicy = PermissionPolicy(activeMode: .dangerFullAccess)
        for spec in ToolRegistry().entries {
            agentPolicy.setToolRequirement(spec.name, mode: spec.requiredPermission)
        }

        let agentRuntime = ConversationRuntime(
            session: Session(),
            apiClient: agentClient,
            toolExecutor: restrictedExecutor,
            permissionPolicy: agentPolicy,
            systemPrompt: basePrompt,
            maxIterations: 32
        )
        return SubAgentRunnableImpl(runtime: agentRuntime)
    }

    let registry = ToolRegistry()
    var policy: PermissionPolicy
    let effectivePermission = config.featureConfig.permissionMode ?? permissionMode
    if effectivePermission == .dangerFullAccess {
        policy = registry.permissionPolicy()
    } else {
        policy = PermissionPolicy(activeMode: effectivePermission)
        for spec in registry.entries {
            policy.setToolRequirement(spec.name, mode: spec.requiredPermission)
        }
    }

    let hookConfig = config.featureConfig.hooks

    let runtime = ConversationRuntime(
        session: Session(),
        apiClient: client,
        toolExecutor: toolExecutor,
        permissionPolicy: policy,
        systemPrompt: systemPrompt,
        hookConfig: hookConfig
    )

    return (runtime, client)
}

// MARK: - Run One Turn

func makeStatusHandler(_ spinner: Spinner) -> StatusCallback {
    var firstText = true
    return { event in
        switch event {
        case .thinking:
            spinner.tickThinking()
        case .toolStart(let name, let input):
            let label = formatToolStatus(name: name, input: input)
            spinner.tick(label)
        case .toolOutput(let name, let input, let output, let isError):
            // Clear spinner, then render tool block
            spinner.clear()
            let block = renderToolBlock(name: name, input: input, output: output, isError: isError)
            fputs("\(block)\n", stderr)
            fflush(stderr)
        case .toolFinish:
            // Output already rendered by toolOutput — nothing more to show
            break
        case .textDelta:
            // Clear spinner on first text token so streaming output isn't clobbered
            if firstText {
                spinner.clear()
                firstText = false
            }
        case .done:
            spinner.clear()
            firstText = true
        }
    }
}

func runOneTurn(prompt: String, model: String, permissionMode: PermissionMode, imagePath: String?) {
    let mdRenderer = TerminalMarkdownRenderer()
    let spinner = Spinner()
    let (runtime, _) = buildRuntime(model: model, permissionMode: permissionMode, mdRenderer: mdRenderer, spinner: spinner)
    let onStatus = makeStatusHandler(spinner)

    // If image provided, inject it as the first user message with image
    if let imagePath = imagePath {
        guard let imageMsg = ConversationMessage.userWithImage(text: prompt, imagePath: imagePath) else {
            fputs("Error: Could not read image at \(imagePath)\n", stderr)
            exit(1)
        }
        var prompter: (any PermissionPrompter)? = TerminalPrompter(spinner: spinner)
        do {
            runtime.appendMessage(imageMsg)
            let visionPrompt = "[Image attached: \(imagePath)]\n\(prompt)"
            let summary = try runtime.runTurn(visionPrompt, prompter: &prompter, onStatus: onStatus)
            mdRenderer.flush()
            printAssistantResponse(summary, streamed: true)
        } catch {
            spinner.fail("Request failed")
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
        return
    }

    var prompter: (any PermissionPrompter)? = TerminalPrompter(spinner: spinner)
    do {
        let summary = try runtime.runTurn(prompt, prompter: &prompter, onStatus: onStatus)
        mdRenderer.flush()
        printAssistantResponse(summary, streamed: true)
    } catch {
        spinner.fail("Request failed")
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func printAssistantResponse(_ summary: TurnSummary, streamed: Bool = false) {
    // If tokens were already streamed to terminal, just print the trailing newline
    if !streamed {
        let renderer = TerminalMarkdownRenderer()
        for message in summary.assistantMessages {
            for block in message.blocks {
                if case .text(let text) = block {
                    print(renderer.render(text))
                }
            }
        }
    }
    print() // blank line after response
    let usageLines = summary.usage.summaryLines(label: "Usage")
    for line in usageLines {
        fputs("\(line)\n", stderr)
    }
}

// MARK: - Session Paths

func sessionDirectory() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.claw/sessions"
}

func sessionPath(name: String) -> String {
    let dir = sessionDirectory()
    return "\(dir)/\(name).json"
}

// MARK: - REPL

func runRepl(model: String, permissionMode: PermissionMode) {
    var currentModel = model
    let mdRenderer = TerminalMarkdownRenderer()
    let spinner = Spinner()
    var (runtime, client) = buildRuntime(model: currentModel, permissionMode: permissionMode, mdRenderer: mdRenderer, spinner: spinner)

    // Check Ollama health concurrently while printing the banner
    var ollamaHealthy = true
    let healthGroup = DispatchGroup()
    healthGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        ollamaHealthy = client.healthCheck()
        healthGroup.leave()
    }

    print("Tesseract-Claw v\(version) — KnotTheory.ai Inc.")
    print("Local model: \(currentModel) — powered by Ollama, no API keys needed.")
    print("Type your message, /help for commands, or /quit to exit.\n")

    healthGroup.wait()
    if !ollamaHealthy {
        fputs("⚠  Ollama is not running at http://127.0.0.1:11434\n", stderr)
        fputs("   Start it with: ollama serve\n\n", stderr)
    }

    var prompter: (any PermissionPrompter)? = TerminalPrompter(spinner: spinner)
    let onStatus = makeStatusHandler(spinner)

    let cwd = FileManager.default.currentDirectoryPath
    let history = PromptHistory(cwd: cwd)

    while true {
        guard let line = history.readline(prompt: "> ") else { break }
        let input = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if input.isEmpty { continue }
        if input == "/quit" || input == "/exit" || input == "quit" || input == "exit" || input == "q" { break }

        if input == "/models" {
            listModels()
            continue
        }

        if input == "/usage" {
            let usage = runtime.currentUsage
            let lines = usage.cumulativeUsage.summaryLines(label: "Session usage")
            for l in lines { print(l) }
            continue
        }

        if input == "/compact" {
            let estimated = runtime.estimatedTokens()
            print("Estimated tokens: \(estimated)")
            let session = runtime.currentSession
            let config = CompactionConfig(preserveRecentMessages: 6, maxEstimatedTokens: 6_000)
            if shouldCompact(session, config: config) {
                let result = compactSession(session, config: config)
                runtime.replaceSession(result.compactedSession)
                print("Compacted: removed \(result.removedMessageCount) messages")
                print("New estimated tokens: \(runtime.estimatedTokens())")
            } else {
                print("No compaction needed.")
            }
            continue
        }

        if input == "/history" {
            if let contents = try? String(contentsOfFile: history.historyPath, encoding: .utf8) {
                let lines = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
                let recent = lines.suffix(20)
                print("Recent prompts (\(lines.count) total, showing last \(recent.count)):")
                for (i, line) in recent.enumerated() {
                    print("  \(lines.count - recent.count + i + 1). \(line)")
                }
            } else {
                print("No history yet for this folder.")
            }
            continue
        }

        if input == "/memory" {
            let cwd = FileManager.default.currentDirectoryPath
            let store = MemoryStore.discover(cwd: cwd)
            print(store.renderReport())
            continue
        }

        if input == "/skills" {
            let cwd = FileManager.default.currentDirectoryPath
            let store = SkillStore.discover(cwd: cwd)
            print(store.renderReport())
            continue
        }

        if input == "/clear" {
            runtime.replaceSession(Session())
            print("Session cleared.")
            continue
        }

        if input.hasPrefix("/save") {
            let parts = input.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name = parts.isEmpty ? "session-\(Int(Date().timeIntervalSince1970))" : parts
            let path = sessionPath(name: name)
            do {
                try FileManager.default.createDirectory(atPath: sessionDirectory(), withIntermediateDirectories: true)
                try runtime.currentSession.saveToPath(path)
                print("Session saved to \(path)")
            } catch {
                print("Error saving session: \(error)")
            }
            continue
        }

        if input.hasPrefix("/load") {
            let parts = input.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if parts.isEmpty {
                // List available sessions
                let dir = sessionDirectory()
                if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    let sessions = files.filter { $0.hasSuffix(".json") }.sorted()
                    if sessions.isEmpty {
                        print("No saved sessions found in \(dir)")
                    } else {
                        print("Saved sessions:")
                        for f in sessions {
                            print("  \((f as NSString).deletingPathExtension)")
                        }
                        print("\nUsage: /load <name>")
                    }
                } else {
                    print("No saved sessions found.")
                }
            } else {
                let path = sessionPath(name: parts)
                do {
                    let loaded = try Session.loadFromPath(path)
                    runtime.replaceSession(loaded)
                    print("Session loaded from \(path) (\(loaded.messages.count) messages)")
                } catch {
                    print("Error loading session: \(error)")
                }
            }
            continue
        }

        if input.hasPrefix("/model") {
            let parts = input.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if parts.isEmpty {
                print("Current model: \(currentModel)")
                print("Usage: /model <name>  (e.g. /model llama3)")
            } else {
                let newModel = resolveModelAlias(parts)
                currentModel = newModel
                // Rebuild runtime with new model, preserving session
                let savedSession = runtime.currentSession
                (runtime, client) = buildRuntime(model: currentModel, permissionMode: permissionMode, mdRenderer: mdRenderer, spinner: spinner)
                runtime.replaceSession(savedSession)
                let vision = isVisionModel(currentModel) ? " 👁" : ""
                print("Switched to model: \(currentModel)\(vision)")
            }
            continue
        }

        if input == "/config" {
            let cwd = FileManager.default.currentDirectoryPath
            let config = ConfigLoader(cwd: cwd).load()
            print("Configuration:")
            print("  Working directory: \(cwd)")
            print("  Model: \(currentModel)")
            print("  Permission mode: \(permissionMode.asString)")
            if !config.loadedEntries.isEmpty {
                print("  Config files loaded:")
                for entry in config.loadedEntries {
                    print("    [\(entry.source)] \(entry.path)")
                }
            } else {
                print("  No config files found.")
            }
            if !config.featureConfig.hooks.preToolUse.isEmpty {
                print("  Pre-tool hooks: \(config.featureConfig.hooks.preToolUse.count)")
            }
            if !config.featureConfig.hooks.postToolUse.isEmpty {
                print("  Post-tool hooks: \(config.featureConfig.hooks.postToolUse.count)")
            }
            continue
        }

        if input == "/paste" || input.hasPrefix("/paste ") {
            let pastePrompt = input.hasPrefix("/paste ") ? String(input.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
            do {
                let content = try readClipboard()
                switch content {
                case .text(let text):
                    let fullPrompt = pastePrompt.isEmpty ? text : "\(pastePrompt)\n\nClipboard content:\n\(text)"
                    let _ = try runtime.runTurn(fullPrompt, prompter: &prompter, onStatus: onStatus)
                    mdRenderer.flush()
                    print()
                    print()
                case .image(let base64, let mediaType):
                    let imageMsg = ConversationMessage(role: .user, blocks: [
                        .image(base64Data: base64, mediaType: mediaType),
                        .text(pastePrompt.isEmpty ? "Describe this image from the clipboard." : pastePrompt)
                    ])
                    runtime.appendMessage(imageMsg)
                    print("  [Clipboard image attached]")
                    let visionPrompt = pastePrompt.isEmpty ? "Describe the clipboard image." : pastePrompt
                    let _ = try runtime.runTurn(visionPrompt, prompter: &prompter, onStatus: onStatus)
                    mdRenderer.flush()
                    print()
                    print()
                case .empty:
                    print("Clipboard is empty.")
                }
            } catch {
                fputs("Error reading clipboard: \(error)\n", stderr)
            }
            continue
        }

        if input == "/screenshot" || input.hasPrefix("/screenshot ") {
            let screenshotPrompt = input.hasPrefix("/screenshot ") ? String(input.dropFirst(12)).trimmingCharacters(in: .whitespaces) : "Describe this screenshot."
            do {
                print("  Select a screen region to capture...")
                let path = try captureScreenshot()
                guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    print("Could not read screenshot: \(path)")
                    continue
                }
                defer { try? FileManager.default.removeItem(atPath: path) }
                let base64 = imageData.base64EncodedString()
                let imageMsg = ConversationMessage(role: .user, blocks: [
                    .image(base64Data: base64, mediaType: "image/png"),
                    .text(screenshotPrompt)
                ])
                runtime.appendMessage(imageMsg)
                print("  [Screenshot attached]")
                let _ = try runtime.runTurn(screenshotPrompt, prompter: &prompter, onStatus: onStatus)
                mdRenderer.flush()
                print()
                print()
            } catch {
                fputs("Error capturing screenshot: \(error)\n", stderr)
            }
            continue
        }

        if input == "/help" {
            print("""
            Commands:
              /quit, /exit        — Exit the REPL (also: quit, exit, q)
              /models             — List installed Ollama models
              /model <name>       — Switch model mid-session
              /image <path> [msg] — Send an image with optional prompt (vision models)
              /paste [prompt]     — Paste clipboard content (text or image) with optional prompt
              /screenshot [prompt] — Capture screen region and send to vision model
              /usage              — Show token usage
              /compact            — Compact session to reduce tokens
              /clear              — Clear session history
              /save [name]        — Save session to disk
              /load [name]        — Load a saved session (no name = list sessions)
              /config             — Show current configuration
              /memory             — Show loaded memory files
              /skills             — List available skills
              /<skill> [args]     — Run a skill by name
              /help               — Show this help
            """)
            continue
        }

        // Skill invocation: /skillname
        if input.hasPrefix("/") && !input.hasPrefix("/image") && !input.hasPrefix("/paste") && !input.hasPrefix("/screenshot") {
            let skillName = String(input.dropFirst()).components(separatedBy: " ").first ?? ""
            let skillArgs = input.dropFirst().dropFirst(skillName.count).trimmingCharacters(in: .whitespaces)
            let cwd = FileManager.default.currentDirectoryPath
            let store = SkillStore.discover(cwd: cwd)
            if let skill = store.resolve(skillName) {
                let fullPrompt = skillArgs.isEmpty ? skill.prompt : "\(skill.prompt)\n\nArgs: \(skillArgs)"
                print("  [Skill: \(skill.name)] \(skill.description)")
                do {
                    _ = try runtime.runTurn(fullPrompt, prompter: &prompter, onStatus: onStatus)
                    mdRenderer.flush()
                    print() // newline after streamed output
                    print()
                } catch {
                    spinner.fail("Request failed")
                    fputs("Error: \(error)\n", stderr)
                }
                continue
            }
            // Unknown command — print error
            print("Unknown command: \(input). Type /help for available commands.")
            continue
        }

        if input.hasPrefix("/image ") {
            let parts = input.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            let components = parts.components(separatedBy: " ")
            let imagePath = components[0]
            let imagePrompt = components.count > 1 ? components.dropFirst().joined(separator: " ") : "Describe this image."

            guard FileManager.default.fileExists(atPath: imagePath) else {
                print("File not found: \(imagePath)")
                continue
            }

            guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
                print("Could not read image: \(imagePath)")
                continue
            }

            let base64 = imageData.base64EncodedString()
            let ext = (imagePath as NSString).pathExtension.lowercased()
            let mediaType = ext == "png" ? "image/png" : "image/jpeg"

            // Create message with image
            let imageMsg = ConversationMessage(role: .user, blocks: [
                .image(base64Data: base64, mediaType: mediaType),
                .text(imagePrompt)
            ])

            // Manually add and run
            runtime.appendMessage(imageMsg)
            print("  [Image attached: \((imagePath as NSString).lastPathComponent)]")

            do {
                _ = try runtime.runTurn(imagePrompt, prompter: &prompter, onStatus: onStatus)
                mdRenderer.flush()
                print() // newline after streamed output
                print()
            } catch {
                spinner.fail("Request failed")
                fputs("Error: \(error)\n", stderr)
            }
            continue
        }

        // Regular message — run turn with live status
        do {
            let summary = try runtime.runTurn(input, prompter: &prompter, onStatus: onStatus)
            mdRenderer.flush()
            print() // newline after streamed output
            // Show tool activity summary
            if !summary.toolResults.isEmpty {
                let toolNames = summary.toolResults.compactMap { msg -> String? in
                    for block in msg.blocks {
                        if case .toolResult(_, let name, _, _) = block { return name }
                    }
                    return nil
                }
                if !toolNames.isEmpty {
                    fputs("  [tools: \(toolNames.joined(separator: ", ")) | turns: \(summary.iterations)]\n", stderr)
                }
            }
            print()
        } catch {
            spinner.fail("Request failed")
            fputs("Error: \(error)\n", stderr)
        }
    }

    // Save prompt history for this folder
    history.save()

    // Final usage
    let usage = runtime.currentUsage
    if usage.turns > 0 {
        let lines = usage.cumulativeUsage.summaryLines(label: "Session total")
        for l in lines { print(l) }
    }
}

// MARK: - List Models

func listModels() {
    let client = OllamaClient()
    guard client.healthCheck() else {
        print("Ollama is not running. Start it with: ollama serve")
        return
    }

    do {
        let models = try client.listModels()
        if models.isEmpty {
            print("No models installed. Pull one with: ollama pull gemma3")
            return
        }
        print("Installed models:")
        for model in models {
            let vision = isVisionModel(model.name) ? " 👁 vision" : ""
            let family = model.family.map { " (\($0))" } ?? ""
            print("  \(model.displayName)\t\(model.sizeGB)\(family)\(vision)")
        }
    } catch {
        print("Error listing models: \(error)")
    }
}

// MARK: - Print Helpers

func printVersion() {
    print("tesseract-claw \(version) — KnotTheory.ai Inc.")
    print("Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Backend: Ollama (local)")
}

func printHelp() {
    print("""
    Tesseract-Claw — AI coding agent CLI (local models via Ollama)

    USAGE:
      tesseract-claw [OPTIONS] [PROMPT]
      tesseract-claw -p "your prompt"
      tesseract-claw --image photo.jpg -p "describe this"
      tesseract-claw                          # starts REPL

    OPTIONS:
      --model <MODEL>               Local model (default: gemma3)
      --image <PATH>                Attach an image (for vision models)
      --permission-mode <MODE>      read-only, workspace-write (default), danger-full-access
      --detail                     Show LLM reasoning (Thought/Action) during tool execution
      -p, --prompt <TEXT>           Run a single prompt and exit
      --list-models, --models       List installed Ollama models
      --system-prompt               Print the system prompt and exit
      --version, -V                 Print version
      --help, -h                    Show this help

    MODELS (text):
      gemma3, llama3, mistral, qwen3, phi4

    MODELS (vision):
      llava, moondream, minicpm-v, llama3.2-vision, gemma3

    TOOLS:
      read_file, write_file, edit_file, bash, glob_search, grep_search,
      web_fetch, web_search, todo, agent, notebook, repl, sleep,
      tool_search, send_message, structured_output, config

    REPL COMMANDS:
      /quit, /exit                  Exit (also: quit, exit, q)
      /models                       List installed models
      /model <name>                 Switch model mid-session
      /image <path> [prompt]        Send image to vision model
      /paste [prompt]               Paste clipboard content (text or image)
      /screenshot [prompt]          Capture screen region and send to vision model
      /usage                        Show token usage
      /compact                      Compact session to reduce tokens
      /clear                        Clear session history
      /save [name]                  Save session to disk
      /load [name]                  Load a saved session
      /config                       Show current configuration
      /history                      Show recent prompt history (per folder)
      /memory                       Show loaded memory files
      /skills                       List available skills
      /<skill> [args]               Run a skill by name
      /help                         Show help

    REQUIREMENTS:
      Ollama must be running: ollama serve
      Pull a model first:     ollama pull gemma3
    """)
}

func printSystemPrompt() {
    let cwd = FileManager.default.currentDirectoryPath
    let prompt = loadSystemPrompt(cwd: cwd, currentDate: defaultDate, osName: "macOS", osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    print(prompt.joined(separator: "\n\n"))
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let action = parseArgs(args)

switch action {
case .version:
    printVersion()
case .help:
    printHelp()
case .systemPrompt:
    printSystemPrompt()
case .listModels:
    listModels()
case .prompt(let text, let model, let permissionMode, let imagePath):
    runOneTurn(prompt: text, model: model, permissionMode: permissionMode, imagePath: imagePath)
case .repl(let model, let permissionMode):
    runRepl(model: model, permissionMode: permissionMode)
}
