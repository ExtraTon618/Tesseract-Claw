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

// MARK: - Tool Spec

public struct ToolSpec: Equatable, Sendable {
    public let name: String
    public let description: String
    public let requiredPermission: PermissionMode

    public init(name: String, description: String, requiredPermission: PermissionMode) {
        self.name = name
        self.description = description
        self.requiredPermission = requiredPermission
    }
}

// MARK: - MVP Tool Specs

public func mvpToolSpecs() -> [ToolSpec] {
    [
        ToolSpec(name: "read_file", description: "Reads a file from the local filesystem.", requiredPermission: .readOnly),
        ToolSpec(name: "write_file", description: "Writes a file to the local filesystem.", requiredPermission: .workspaceWrite),
        ToolSpec(name: "edit_file", description: "Performs exact string replacements in files.", requiredPermission: .workspaceWrite),
        ToolSpec(name: "glob_search", description: "Fast file pattern matching tool.", requiredPermission: .readOnly),
        ToolSpec(name: "grep_search", description: "Search tool built on regex.", requiredPermission: .readOnly),
        ToolSpec(name: "bash", description: "Executes a bash command and returns its output.", requiredPermission: .dangerFullAccess),
        ToolSpec(name: "web_fetch", description: "Fetches content from a URL.", requiredPermission: .readOnly),
        ToolSpec(name: "web_search", description: "Performs a web search and returns results.", requiredPermission: .readOnly),
        ToolSpec(name: "todo", description: "Manages a to-do list for the session.", requiredPermission: .readOnly),
        ToolSpec(name: "agent", description: "Launches a sub-agent for complex tasks.", requiredPermission: .dangerFullAccess),
        ToolSpec(name: "notebook", description: "Reads and edits Jupyter notebook cells.", requiredPermission: .workspaceWrite),
        ToolSpec(name: "repl", description: "Execute code in a REPL-like subprocess (Python, JavaScript, Bash).", requiredPermission: .dangerFullAccess),
        ToolSpec(name: "sleep", description: "Pauses execution for a specified duration in milliseconds.", requiredPermission: .readOnly),
        ToolSpec(name: "tool_search", description: "Search available tools by name or keyword for capability discovery.", requiredPermission: .readOnly),
        ToolSpec(name: "send_message", description: "Send a formatted message to the user with optional file attachments.", requiredPermission: .readOnly),
        ToolSpec(name: "structured_output", description: "Return structured output (JSON) in the requested format.", requiredPermission: .readOnly),
        ToolSpec(name: "config", description: "Get or set Claw Code settings from config files.", requiredPermission: .workspaceWrite),
        ToolSpec(name: "read_pdf", description: "Reads text from a PDF file, page by page.", requiredPermission: .readOnly),
    ]
}

// MARK: - Tool Registry

public struct ToolRegistry: Sendable {
    private let specs: [ToolSpec]

    public init() {
        self.specs = mvpToolSpecs()
    }

    public var entries: [ToolSpec] { specs }

    public func permissionPolicy() -> PermissionPolicy {
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        for spec in specs {
            policy.setToolRequirement(spec.name, mode: spec.requiredPermission)
        }
        return policy
    }
}

// MARK: - Live Tool Executor

public struct LiveToolExecutor: ToolExecutor {
    private let cwd: String
    private let todoManager: TodoManager
    /// Factory for creating sub-agent runtimes. Set by the CLI layer to bridge
    /// the API client into the runtime module.
    public var subAgentFactory: SubAgentRuntimeFactory?

    public init(cwd: String? = nil) {
        let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
        self.cwd = resolvedCwd
        self.todoManager = TodoManager(cwd: resolvedCwd)
    }

    public mutating func execute(toolName: String, input: String) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]

        switch toolName {
        case "read_file":
            let filePath = json?["file_path"] as? String ?? input
            // Auto-detect directories — redirect to glob_search
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
                let result = globSearch(pattern: "*", path: filePath)
                if result.filenames.isEmpty { return "Directory '\(filePath)' is empty." }
                return "Directory listing of \(filePath):\n\(result.filenames.joined(separator: "\n"))"
            }
            // Auto-detect URLs — redirect to web_fetch
            if filePath.hasPrefix("http://") || filePath.hasPrefix("https://") {
                let output = try webFetch(url: filePath, maxChars: 20_000)
                var result = "HTTP \(output.statusCode) — \(output.url)\n\n\(output.content)"
                if output.truncated { result += "\n[truncated]" }
                return result
            }
            let ext = (filePath as NSString).pathExtension.lowercased()
            // Auto-detect PDF files
            if ext == "pdf" {
                let pages = json?["pages"] as? String
                let result = try readPdf(path: filePath, pages: pages)
                return result.content
            }
            // Detect image files — return metadata (binary can't be displayed as text)
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg"]
            if imageExts.contains(ext) {
                let safePath = try normalizePath(filePath)
                try validateWorkspaceBoundary(safePath)
                let attrs = try FileManager.default.attributesOfItem(atPath: safePath)
                let size = attrs[.size] as? UInt64 ?? 0
                return "[Image file: \(filePath) (\(size) bytes)]\nThis is a binary image file. Use /image \(filePath) to analyze it with a vision model."
            }
            let offset = json?["offset"] as? Int ?? 0
            let limit = json?["limit"] as? Int ?? 2000
            let result = try readFile(path: filePath, offset: offset, limit: limit)
            return result.content

        case "write_file":
            let filePath = json?["file_path"] as? String ?? ""
            let content = json?["content"] as? String ?? ""
            let _ = try writeFile(path: filePath, content: content)
            return "File written successfully to \(filePath)"

        case "edit_file":
            let filePath = json?["file_path"] as? String ?? ""
            let oldString = json?["old_string"] as? String ?? ""
            let newString = json?["new_string"] as? String ?? ""
            let replaceAll = json?["replace_all"] as? Bool ?? false
            let _ = try editFile(path: filePath, oldString: oldString, newString: newString, replaceAll: replaceAll)
            return "Edit applied to \(filePath)"

        case "glob_search":
            let pattern = json?["pattern"] as? String ?? input
            let path = json?["path"] as? String
            let result = globSearch(pattern: pattern, path: path)
            if result.filenames.isEmpty { return "No files matched pattern '\(pattern)'" }
            return result.filenames.joined(separator: "\n")

        case "grep_search":
            let pattern = json?["pattern"] as? String ?? input
            let path = json?["path"] as? String
            let glob = json?["glob"] as? String
            let result = grepSearch(pattern: pattern, path: path, glob: glob)
            if result.results.isEmpty { return "No matches for pattern '\(pattern)'" }
            return result.results.joined(separator: "\n")

        case "bash":
            let command = json?["command"] as? String ?? input
            let timeout = json?["timeout"] as? UInt64
            let description = json?["description"] as? String
            let bashInput = BashCommandInput(command: command, timeout: timeout, description: description)
            let output = try executeBash(bashInput)
            var result = output.stdout
            if !output.stderr.isEmpty {
                result += "\nSTDERR:\n\(output.stderr)"
            }
            if output.exitCode != 0 {
                result += "\n[exit code: \(output.exitCode)]"
            }
            return result

        case "web_fetch":
            let url = json?["url"] as? String ?? input
            let maxChars = json?["max_chars"] as? Int ?? 20_000
            let output = try webFetch(url: url, maxChars: maxChars)
            var result = "HTTP \(output.statusCode) — \(output.url)\n\n\(output.content)"
            if output.truncated { result += "\n[truncated]" }
            return result

        case "web_search":
            let query = json?["query"] as? String ?? input
            let limit = json?["limit"] as? Int ?? 8
            let output = try webSearch(query: query, limit: limit)
            if output.results.isEmpty { return "No results for: \(query)" }
            return output.results.enumerated().map { (i, r) in
                "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
            }.joined(separator: "\n\n")

        case "todo":
            let action = json?["action"] as? String ?? "list"
            return try todoManager.execute(action: action, json: json)

        case "agent":
            let prompt = json?["prompt"] as? String ?? input
            let description = json?["description"] as? String ?? ""
            let typeName = json?["subagent_type"] as? String ?? "general-purpose"
            let agentType = SubAgentType.from(typeName)

            guard let factory = subAgentFactory else {
                return "[Sub-agent unavailable: runtime factory not configured]\nUse bash tool for complex multi-step tasks."
            }

            let agentInput = SubAgentInput(
                prompt: prompt,
                description: description,
                subagentType: agentType
            )
            let result = spawnSubAgent(input: agentInput, runtimeFactory: factory)
            return result.summary

        case "notebook":
            let action = json?["action"] as? String ?? "read"
            let path = json?["path"] as? String ?? ""
            guard !path.isEmpty else { throw ToolError("notebook requires a 'path'") }

            switch action {
            case "read":
                let cellIndex = json?["cell_index"] as? Int
                let output = try notebookRead(path: path, cellIndex: cellIndex)
                if output.cells.isEmpty { return "Notebook has no cells." }
                return output.cells.map { cell in
                    var result = "--- Cell \(cell.index) [\(cell.cellType)] ---\n\(cell.source)"
                    if !cell.outputPreview.isEmpty {
                        result += "\n--- Output ---\n\(cell.outputPreview)"
                    }
                    return result
                }.joined(separator: "\n\n")

            case "edit":
                let cellIndex = json?["cell_index"] as? Int ?? 0
                let newSource = json?["new_source"] as? String ?? ""
                let cellType = json?["cell_type"] as? String
                return try notebookEdit(path: path, cellIndex: cellIndex, newSource: newSource, cellType: cellType)

            case "insert":
                let atIndex = json?["cell_index"] as? Int ?? 0
                let source = json?["new_source"] as? String ?? ""
                let cellType = json?["cell_type"] as? String ?? "code"
                return try notebookInsertCell(path: path, atIndex: atIndex, source: source, cellType: cellType)

            default:
                throw ToolError("Unknown notebook action '\(action)'. Use: read, edit, insert")
            }

        case "repl":
            let code = json?["code"] as? String ?? ""
            let language = json?["language"] as? String ?? "python"
            let timeoutMs = json?["timeout_ms"] as? UInt64
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("code must not be empty")
            }
            let output = try executeRepl(code: code, language: language, timeoutMs: timeoutMs)
            var result = output.stdout
            if !output.stderr.isEmpty {
                result += "\nSTDERR:\n\(output.stderr)"
            }
            result += "\n[exit code: \(output.exitCode), language: \(output.language), duration: \(output.durationMs)ms]"
            return result

        case "sleep":
            let durationMs = json?["duration_ms"] as? Int ?? 0
            return executeSleep(durationMs: durationMs)

        case "tool_search":
            let query = json?["query"] as? String ?? input
            let maxResults = json?["max_results"] as? Int ?? 5
            return executeToolSearch(query: query, maxResults: maxResults, specs: mvpToolSpecs())

        case "send_message":
            let message = json?["message"] as? String ?? input
            let attachments = json?["attachments"] as? [String]
            return executeSendUserMessage(message: message, attachments: attachments)

        case "structured_output":
            return executeStructuredOutput(input: input)

        case "config":
            let setting = json?["setting"] as? String
            let value = json?["value"]
            return executeConfigTool(setting: setting, value: value, cwd: cwd)

        case "read_pdf":
            let filePath = json?["file_path"] as? String ?? input
            let pages = json?["pages"] as? String
            let result = try readPdf(path: filePath, pages: pages)
            return result.content

        default:
            throw ToolError("unknown tool: \(toolName)")
        }
    }
}
