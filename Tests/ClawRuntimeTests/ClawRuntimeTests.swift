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

import XCTest
@testable import ClawRuntime

// MARK: - Test API Client

struct ScriptedApiClient: ApiClient {
    var callCount = 0

    mutating func stream(_ request: ApiRequest) throws -> [AssistantEvent] {
        callCount += 1
        switch callCount {
        case 1:
            XCTAssert(request.messages.contains(where: { $0.role == .user }))
            return [
                .textDelta("Let me calculate that."),
                .toolUse(id: "tool-1", name: "add", input: "2,2"),
                .usage(TokenUsage(inputTokens: 20, outputTokens: 6, cacheCreationInputTokens: 1, cacheReadInputTokens: 2)),
                .messageStop
            ]
        case 2:
            XCTAssertEqual(request.messages.last?.role, .tool)
            return [
                .textDelta("The answer is 4."),
                .usage(TokenUsage(inputTokens: 24, outputTokens: 4, cacheCreationInputTokens: 1, cacheReadInputTokens: 3)),
                .messageStop
            ]
        default:
            throw RuntimeError("unexpected extra API call")
        }
    }
}

struct ScriptedApiClientNonMutating: ApiClient {
    var responses: [[AssistantEvent]]
    var callIndex = 0

    init(_ responses: [[AssistantEvent]]) {
        self.responses = responses
    }

    mutating func stream(_ request: ApiRequest) throws -> [AssistantEvent] {
        guard callIndex < responses.count else {
            throw RuntimeError("unexpected extra API call")
        }
        let result = responses[callIndex]
        callIndex += 1
        return result
    }
}

// MARK: - Session Tests

final class SessionTests: XCTestCase {
    func testPersistsAndRestoresSessionJSON() throws {
        var session = Session()
        session.messages.append(.userText("hello"))
        session.messages.append(.assistantWithUsage(
            [.text("thinking"), .toolUse(id: "tool-1", name: "bash", input: "echo hi")],
            usage: TokenUsage(inputTokens: 10, outputTokens: 4, cacheCreationInputTokens: 1, cacheReadInputTokens: 2)
        ))
        session.messages.append(.toolResult(toolUseId: "tool-1", toolName: "bash", output: "hi", isError: false))

        let path = NSTemporaryDirectory() + "test-session-\(ProcessInfo.processInfo.globallyUniqueString).json"
        try session.saveToPath(path)
        let restored = try Session.loadFromPath(path)
        try FileManager.default.removeItem(atPath: path)

        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.messages[2].role, .tool)
        XCTAssertEqual(restored.messages[1].usage?.totalTokens, 17)
    }
}

// MARK: - Usage Tests

final class UsageTests: XCTestCase {
    func testTracksCumulativeUsage() {
        let tracker = UsageTracker()
        tracker.record(TokenUsage(inputTokens: 10, outputTokens: 4, cacheCreationInputTokens: 2, cacheReadInputTokens: 1))
        tracker.record(TokenUsage(inputTokens: 20, outputTokens: 6, cacheCreationInputTokens: 3, cacheReadInputTokens: 2))

        XCTAssertEqual(tracker.turns, 2)
        XCTAssertEqual(tracker.currentTurnUsage.inputTokens, 20)
        XCTAssertEqual(tracker.cumulativeUsage.outputTokens, 10)
        XCTAssertEqual(tracker.cumulativeUsage.totalTokens, 48)
    }

    func testTokenUsageSummaryLines() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000, cacheCreationInputTokens: 100_000, cacheReadInputTokens: 200_000)
        let lines = usage.summaryLines(label: "usage")
        XCTAssert(lines[0].contains("total_tokens=\(usage.totalTokens)"))
        XCTAssert(lines[0].contains("input=1000000"))
        XCTAssert(lines[0].contains("output=500000"))
    }

    func testReconstructsUsageFromSession() {
        let session = Session(version: 1, messages: [
            ConversationMessage(role: .assistant, blocks: [.text("done")], usage: TokenUsage(inputTokens: 5, outputTokens: 2, cacheCreationInputTokens: 1))
        ])
        let tracker = UsageTracker.fromSession(session)
        XCTAssertEqual(tracker.turns, 1)
        XCTAssertEqual(tracker.cumulativeUsage.totalTokens, 8)
    }
}

// MARK: - Permission Tests

final class PermissionTests: XCTestCase {
    func testAllowsToolsWhenActiveModeMetRequirement() {
        let policy = PermissionPolicy(activeMode: .workspaceWrite)
            .withToolRequirement("read_file", mode: .readOnly)
            .withToolRequirement("write_file", mode: .workspaceWrite)

        var prompter: (any PermissionPrompter)? = nil
        XCTAssertEqual(policy.authorize(toolName: "read_file", input: "{}", prompter: &prompter), .allow)
        XCTAssertEqual(policy.authorize(toolName: "write_file", input: "{}", prompter: &prompter), .allow)
    }

    func testDeniesReadOnlyEscalations() {
        let policy = PermissionPolicy(activeMode: .readOnly)
            .withToolRequirement("write_file", mode: .workspaceWrite)

        var prompter: (any PermissionPrompter)? = nil
        let outcome = policy.authorize(toolName: "write_file", input: "{}", prompter: &prompter)
        if case .deny(let reason) = outcome {
            XCTAssert(reason.contains("requires workspace-write permission"))
        } else {
            XCTFail("Expected deny")
        }
    }
}

// MARK: - Conversation Tests

final class ConversationTests: XCTestCase {
    struct AllowPrompter: PermissionPrompter {
        mutating func decide(_ request: PermissionRequest) -> PermissionPromptDecision { .allow }
    }

    func testRunsToolLoopEndToEnd() throws {
        var apiClient = ScriptedApiClient()
        var toolExecutor = StaticToolExecutor().withRegistered("add") { input in
            let total = input.split(separator: ",").compactMap { Int($0) }.reduce(0, +)
            return String(total)
        }

        let policy = PermissionPolicy(activeMode: .workspaceWrite)
        let cwd = FileManager.default.currentDirectoryPath
        let systemPrompt = SystemPromptBuilder()
            .withProjectContext(ProjectContext(cwd: cwd, currentDate: "2026-03-31"))
            .withOS(name: "macOS", version: "15.0")
            .build()

        let runtime = ConversationRuntime(
            session: Session(),
            apiClient: apiClient,
            toolExecutor: toolExecutor,
            permissionPolicy: policy,
            systemPrompt: systemPrompt
        )

        var prompter: (any PermissionPrompter)? = AllowPrompter()
        let summary = try runtime.runTurn("what is 2 + 2?", prompter: &prompter)

        XCTAssertEqual(summary.iterations, 2)
        XCTAssertEqual(summary.assistantMessages.count, 2)
        XCTAssertEqual(summary.toolResults.count, 1)
        XCTAssertEqual(runtime.currentSession.messages.count, 4)
        XCTAssertEqual(summary.usage.outputTokens, 10)
    }

    func testDeniedToolResultsWhenPromptRejects() throws {
        struct RejectPrompter: PermissionPrompter {
            mutating func decide(_ request: PermissionRequest) -> PermissionPromptDecision {
                .deny(reason: "not now")
            }
        }

        var apiClient = ScriptedApiClientNonMutating([
            [.toolUse(id: "tool-1", name: "blocked", input: "secret"), .messageStop],
            [.textDelta("I could not use the tool."), .messageStop]
        ])

        let runtime = ConversationRuntime(
            session: Session(),
            apiClient: apiClient,
            toolExecutor: StaticToolExecutor(),
            permissionPolicy: PermissionPolicy(activeMode: .workspaceWrite),
            systemPrompt: ["system"]
        )

        var prompter: (any PermissionPrompter)? = RejectPrompter()
        let summary = try runtime.runTurn("use the tool", prompter: &prompter)

        XCTAssertEqual(summary.toolResults.count, 1)
        if case .toolResult(_, _, let output, let isError) = summary.toolResults[0].blocks[0] {
            XCTAssertTrue(isError)
            XCTAssertEqual(output, "not now")
        } else {
            XCTFail("Expected tool result block")
        }
    }
}

// MARK: - Compaction Tests

final class CompactionTests: XCTestCase {
    func testLeavesSmallSessionsUnchanged() {
        let session = Session(version: 1, messages: [.userText("hello")])
        let result = compactSession(session, config: CompactionConfig())
        XCTAssertEqual(result.removedMessageCount, 0)
        XCTAssertEqual(result.compactedSession, session)
        XCTAssertTrue(result.summary.isEmpty)
    }

    func testCompactsOlderMessagesIntoSystemSummary() {
        let session = Session(version: 1, messages: [
            .userText(String(repeating: "one ", count: 200)),
            .assistant([.text(String(repeating: "two ", count: 200))]),
            .toolResult(toolUseId: "1", toolName: "bash", output: String(repeating: "ok ", count: 200), isError: false),
            ConversationMessage(role: .assistant, blocks: [.text("recent")])
        ])

        let config = CompactionConfig(preserveRecentMessages: 2, maxEstimatedTokens: 1)
        let result = compactSession(session, config: config)

        XCTAssertEqual(result.removedMessageCount, 2)
        XCTAssertEqual(result.compactedSession.messages[0].role, .system)
        if case .text(let text) = result.compactedSession.messages[0].blocks[0] {
            XCTAssertTrue(text.contains("Summary:"))
        }
        XCTAssertTrue(result.formattedSummary.contains("Scope:"))
    }

    func testFormatsCompactSummary() {
        let summary = "<analysis>scratch</analysis>\n<summary>Kept work</summary>"
        XCTAssertEqual(formatCompactSummary(summary), "Summary:\nKept work")
    }
}

// MARK: - File Ops Tests

final class FileOpsTests: XCTestCase {
    func testReadFileWithLineNumbers() throws {
        let path = NSTemporaryDirectory() + "test-read-\(UUID().uuidString).txt"
        try "line one\nline two\nline three\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let output = try readFile(path: path)
        XCTAssertEqual(output.totalLines, 4) // trailing newline adds empty line
        XCTAssertTrue(output.content.contains("1\tline one"))
        XCTAssertTrue(output.content.contains("2\tline two"))
    }

    func testEditFileReplacesString() throws {
        let path = NSTemporaryDirectory() + "test-edit-\(UUID().uuidString).txt"
        try "hello world".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try editFile(path: path, oldString: "world", newString: "swift")
        XCTAssertEqual(result.oldString, "world")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, "hello swift")
    }
}

// MARK: - Bash Tests

final class BashTests: XCTestCase {
    func testExecutesSimpleCommand() throws {
        let output = try executeBash(BashCommandInput(command: "printf 'hello'", timeout: 1000))
        XCTAssertEqual(output.stdout, "hello")
        XCTAssertFalse(output.interrupted)
    }
}

// MARK: - Prompt Builder Tests

final class PromptBuilderTests: XCTestCase {
    func testBuildIncludesAllSections() {
        let prompt = SystemPromptBuilder()
            .withOS(name: "macOS", version: "15.0")
            .withProjectContext(ProjectContext(cwd: "/tmp/project", currentDate: "2026-04-01"))
            .build()

        let rendered = prompt.joined(separator: "\n\n")
        XCTAssertTrue(rendered.contains("# System"))
        XCTAssertTrue(rendered.contains("# Project context"))
        XCTAssertTrue(rendered.contains("macOS"))
        XCTAssertTrue(rendered.contains("2026-04-01"))
    }
}

// MARK: - Todo Manager Tests

final class TodoManagerTests: XCTestCase {
    func testAddAndListTodos() throws {
        let manager = TodoManager()
        let addResult = try manager.execute(action: "add", json: ["title": "Fix bug", "description": "In login flow"])
        XCTAssertTrue(addResult.contains("todo-1"))
        XCTAssertTrue(addResult.contains("Fix bug"))

        let listResult = try manager.execute(action: "list", json: nil)
        XCTAssertTrue(listResult.contains("[ ] todo-1: Fix bug"))
        XCTAssertTrue(listResult.contains("In login flow"))
    }

    func testUpdateTodoStatus() throws {
        let manager = TodoManager()
        _ = try manager.execute(action: "add", json: ["title": "Task 1"])
        let updateResult = try manager.execute(action: "update", json: ["id": "todo-1", "status": "in_progress"])
        XCTAssertTrue(updateResult.contains("[~]"))

        let completeResult = try manager.execute(action: "update", json: ["id": "todo-1", "status": "completed"])
        XCTAssertTrue(completeResult.contains("[x]"))
    }

    func testDeleteTodo() throws {
        let manager = TodoManager()
        _ = try manager.execute(action: "add", json: ["title": "Temporary"])
        let deleteResult = try manager.execute(action: "delete", json: ["id": "todo-1"])
        XCTAssertTrue(deleteResult.contains("Deleted"))

        let listResult = try manager.execute(action: "list", json: nil)
        XCTAssertEqual(listResult, "No tasks.")
    }

    func testInvalidActionThrows() {
        let manager = TodoManager()
        XCTAssertThrowsError(try manager.execute(action: "bogus", json: nil))
    }
}

// MARK: - Notebook Editor Tests

final class NotebookEditorTests: XCTestCase {
    private func createTestNotebook() throws -> String {
        let path = NSTemporaryDirectory() + "test-notebook-\(UUID().uuidString).ipynb"
        let notebook: [String: Any] = [
            "nbformat": 4,
            "nbformat_minor": 2,
            "metadata": [:] as [String: Any],
            "cells": [
                [
                    "cell_type": "code",
                    "source": ["print('hello')\n"],
                    "metadata": [:] as [String: Any],
                    "outputs": [
                        ["output_type": "stream", "text": ["hello\n"]]
                    ] as [[String: Any]],
                    "execution_count": 1
                ] as [String: Any],
                [
                    "cell_type": "markdown",
                    "source": ["# Title\n", "Some text\n"],
                    "metadata": [:] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: notebook, options: .prettyPrinted)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testReadNotebook() throws {
        let path = try createTestNotebook()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let output = try notebookRead(path: path)
        XCTAssertEqual(output.cellCount, 2)
        XCTAssertEqual(output.cells.count, 2)
        XCTAssertEqual(output.cells[0].cellType, "code")
        XCTAssertTrue(output.cells[0].source.contains("print('hello')"))
        XCTAssertEqual(output.cells[1].cellType, "markdown")
    }

    func testReadSingleCell() throws {
        let path = try createTestNotebook()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let output = try notebookRead(path: path, cellIndex: 1)
        XCTAssertEqual(output.cells.count, 1)
        XCTAssertEqual(output.cells[0].index, 1)
        XCTAssertTrue(output.cells[0].source.contains("# Title"))
    }

    func testEditCell() throws {
        let path = try createTestNotebook()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try notebookEdit(path: path, cellIndex: 0, newSource: "print('updated')")
        XCTAssertTrue(result.contains("Updated cell 0"))

        let readBack = try notebookRead(path: path, cellIndex: 0)
        XCTAssertTrue(readBack.cells[0].source.contains("print('updated')"))
    }

    func testInsertCell() throws {
        let path = try createTestNotebook()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try notebookInsertCell(path: path, atIndex: 1, source: "# New Cell", cellType: "markdown")
        XCTAssertTrue(result.contains("Inserted markdown cell at index 1"))

        let readBack = try notebookRead(path: path)
        XCTAssertEqual(readBack.cellCount, 3)
        XCTAssertEqual(readBack.cells[1].cellType, "markdown")
        XCTAssertTrue(readBack.cells[1].source.contains("# New Cell"))
    }
}

// MARK: - Web Fetch Tests (offline — test HTML stripping)

final class WebFetchHelpersTests: XCTestCase {
    func testWebSearchOutputStructure() {
        let result = WebSearchOutput(query: "test", results: [
            WebSearchResult(title: "Result 1", url: "https://example.com", snippet: "A snippet")
        ])
        XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(result.results[0].title, "Result 1")
    }

    func testWebFetchOutputStructure() {
        let output = WebFetchOutput(url: "https://example.com", statusCode: 200, content: "Hello", truncated: false)
        XCTAssertEqual(output.statusCode, 200)
        XCTAssertFalse(output.truncated)
    }
}

// MARK: - Tool Registry Tests

final class ToolRegistryTests: XCTestCase {
    func testRegistryContainsAllTools() {
        let registry = ToolRegistry()
        let names = registry.entries.map { $0.name }
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        XCTAssertTrue(names.contains("edit_file"))
        XCTAssertTrue(names.contains("bash"))
        XCTAssertTrue(names.contains("glob_search"))
        XCTAssertTrue(names.contains("grep_search"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("todo"))
        XCTAssertTrue(names.contains("agent"))
        XCTAssertTrue(names.contains("notebook"))
        XCTAssertTrue(names.contains("repl"))
        XCTAssertTrue(names.contains("sleep"))
        XCTAssertTrue(names.contains("tool_search"))
        XCTAssertTrue(names.contains("send_message"))
        XCTAssertTrue(names.contains("structured_output"))
        XCTAssertTrue(names.contains("config"))
        XCTAssertTrue(names.contains("read_pdf"))
        XCTAssertEqual(names.count, 18)
    }

    func testPermissionPolicyAssignsCorrectModes() {
        let registry = ToolRegistry()
        let policy = registry.permissionPolicy()
        XCTAssertEqual(policy.requiredMode(for: "read_file"), .readOnly)
        XCTAssertEqual(policy.requiredMode(for: "write_file"), .workspaceWrite)
        XCTAssertEqual(policy.requiredMode(for: "bash"), .dangerFullAccess)
        XCTAssertEqual(policy.requiredMode(for: "web_fetch"), .readOnly)
        XCTAssertEqual(policy.requiredMode(for: "agent"), .dangerFullAccess)
        XCTAssertEqual(policy.requiredMode(for: "todo"), .readOnly)
    }
}

// MARK: - Auto-Compaction Tests

final class AutoCompactionTests: XCTestCase {
    func testAutoCompactionTriggersInRuntime() throws {
        // Create a session that's large enough to trigger compaction
        var apiClient = ScriptedApiClientNonMutating([
            [.textDelta("response"), .usage(TokenUsage(inputTokens: 10, outputTokens: 5)), .messageStop]
        ])

        var largeSession = Session()
        // Add enough messages to trigger compaction
        for i in 0..<20 {
            largeSession.messages.append(.userText(String(repeating: "message \(i) ", count: 100)))
            largeSession.messages.append(.assistant([.text(String(repeating: "reply \(i) ", count: 100))]))
        }

        let runtime = ConversationRuntime(
            session: largeSession,
            apiClient: apiClient,
            toolExecutor: StaticToolExecutor(),
            permissionPolicy: PermissionPolicy(activeMode: .dangerFullAccess),
            systemPrompt: ["system"],
            compactionConfig: CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 100)
        )

        var prompter: (any PermissionPrompter)? = nil
        let summary = try runtime.runTurn("new message", prompter: &prompter)

        // Session should be compacted — first message should be a system summary
        let session = runtime.currentSession
        XCTAssertTrue(session.messages.count < 42) // 40 original + 2 new > would be 42 without compaction
        XCTAssertEqual(session.messages[0].role, .system)
    }
}

// MARK: - Live Tool Executor Tests

final class LiveToolExecutorTests: XCTestCase {
    func testTodoThroughExecutor() throws {
        var executor = LiveToolExecutor(cwd: NSTemporaryDirectory())
        let addResult = try executor.execute(toolName: "todo", input: #"{"action":"add","title":"Test task"}"#)
        XCTAssertTrue(addResult.contains("Created task"))

        let listResult = try executor.execute(toolName: "todo", input: #"{"action":"list"}"#)
        XCTAssertTrue(listResult.contains("Test task"))
    }

    func testNotebookThroughExecutor() throws {
        // Create a minimal notebook
        let path = NSTemporaryDirectory() + "exec-test-\(UUID().uuidString).ipynb"
        let nb: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 2,
            "metadata": [:] as [String: Any],
            "cells": [["cell_type": "code", "source": ["x = 1\n"], "metadata": [:] as [String: Any], "outputs": [] as [Any]] as [String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        var executor = LiveToolExecutor(cwd: NSTemporaryDirectory())
        let readResult = try executor.execute(toolName: "notebook", input: "{\"action\":\"read\",\"path\":\"\(path)\"}")
        XCTAssertTrue(readResult.contains("x = 1"))
    }

    func testUnknownToolThrows() {
        var executor = LiveToolExecutor(cwd: NSTemporaryDirectory())
        XCTAssertThrowsError(try executor.execute(toolName: "nonexistent", input: "{}"))
    }
}

// MARK: - Model Tier Classification Tests

final class ModelTierTests: XCTestCase {
    func testClassifiesNativeToolModels() {
        XCTAssertEqual(ModelTierClassifier.classify("llama3.2"), .nativeTools)
        XCTAssertEqual(ModelTierClassifier.classify("qwen3"), .nativeTools)
        XCTAssertEqual(ModelTierClassifier.classify("command-r-plus"), .nativeTools)
        XCTAssertEqual(ModelTierClassifier.classify("hermes-2"), .nativeTools)
    }

    func testClassifiesTextBasedToolModels() {
        XCTAssertEqual(ModelTierClassifier.classify("mistral"), .textBasedTools)
        XCTAssertEqual(ModelTierClassifier.classify("mixtral-8x7b"), .textBasedTools)
    }

    func testClassifiesReActModels() {
        XCTAssertEqual(ModelTierClassifier.classify("gemma3"), .reactPrompting)
        XCTAssertEqual(ModelTierClassifier.classify("phi4"), .reactPrompting)
        XCTAssertEqual(ModelTierClassifier.classify("deepseek-coder"), .reactPrompting)
    }

    func testClassifiesNoToolModels() {
        XCTAssertEqual(ModelTierClassifier.classify("codellama"), .noTools)
        XCTAssertEqual(ModelTierClassifier.classify("gemma2"), .noTools)
        XCTAssertEqual(ModelTierClassifier.classify("vicuna"), .noTools)
    }

    func testUnknownModelDefaultsToNative() {
        XCTAssertEqual(ModelTierClassifier.classify("some-new-model"), .nativeTools)
    }

    func testTierProperties() {
        XCTAssertTrue(ToolCapabilityTier.nativeTools.supportsToolsParameter)
        XCTAssertFalse(ToolCapabilityTier.textBasedTools.supportsToolsParameter)
        XCTAssertFalse(ToolCapabilityTier.noTools.supportsToolsParameter)

        XCTAssertTrue(ToolCapabilityTier.textBasedTools.requiresTextParsing)
        XCTAssertTrue(ToolCapabilityTier.reactPrompting.requiresTextParsing)
        XCTAssertFalse(ToolCapabilityTier.nativeTools.requiresTextParsing)
        XCTAssertFalse(ToolCapabilityTier.noTools.requiresTextParsing)
    }
}

// MARK: - ReAct Parser Tests

final class ReActParserTests: XCTestCase {
    func testParsesReActToolCall() {
        let text = """
        Thought: I need to read the file
        Action: read_file
        Action Input: {"file_path": "/tmp/test.txt"}
        """
        let (calls, finalAnswer) = TierResponseParser.parseReAct(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "read_file")
        XCTAssertTrue(calls[0].arguments.contains("/tmp/test.txt"))
        XCTAssertNil(finalAnswer)
    }

    func testParsesReActFinalAnswer() {
        let text = """
        Thought: I can answer this directly
        Final Answer: The file contains hello world.
        """
        let (calls, finalAnswer) = TierResponseParser.parseReAct(text)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(finalAnswer, "The file contains hello world.")
    }

    func testParsesMultipleToolCalls() {
        let text = """
        Thought: I need to read two files
        Action: read_file
        Action Input: {"file_path": "/tmp/a.txt"}
        Observation: contents of a
        Thought: Now read b
        Action: read_file
        Action Input: {"file_path": "/tmp/b.txt"}
        """
        let (calls, _) = TierResponseParser.parseReAct(text)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].toolName, "read_file")
        XCTAssertEqual(calls[1].toolName, "read_file")
    }
}

// MARK: - Mistral Parser Tests

final class MistralParserTests: XCTestCase {
    func testParsesToolCallsMarker() {
        let text = """
        [TOOL_CALLS] [{"name": "bash", "arguments": {"command": "ls"}}]
        """
        let calls = TierResponseParser.parseMistralToolCalls(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "bash")
        XCTAssertTrue(calls[0].arguments.contains("ls"))
    }

    func testParsesInlineJSON() {
        let text = """
        I'll list the files: {"name": "bash", "arguments": {"command": "pwd"}}
        """
        let calls = TierResponseParser.parseMistralToolCalls(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].toolName, "bash")
    }

    func testReturnsEmptyForPlainText() {
        let text = "Here is a list of files in the current directory."
        let calls = TierResponseParser.parseMistralToolCalls(text)
        XCTAssertTrue(calls.isEmpty)
    }

    func testContainsToolCallsDetection() {
        XCTAssertTrue(TierResponseParser.containsToolCalls("Action: bash\nAction Input: {}"))
        XCTAssertTrue(TierResponseParser.containsToolCalls("[TOOL_CALLS] [{}]"))
        XCTAssertFalse(TierResponseParser.containsToolCalls("Hello, how can I help?"))
    }
}

// MARK: - Bash cd Persistence Tests

final class BashCdTests: XCTestCase {
    func testCdPersistsBetweenCalls() throws {
        let originalCwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }

        // First call: cd to /tmp
        let result1 = try executeBash(BashCommandInput(command: "cd /tmp"))
        XCTAssertEqual(result1.exitCode, 0)

        // CWD should now be /tmp (or /private/tmp on macOS)
        let newCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(newCwd == "/tmp" || newCwd == "/private/tmp",
                       "CWD should be /tmp but was \(newCwd)")

        // Second call: pwd should report the new directory
        let result2 = try executeBash(BashCommandInput(command: "pwd"))
        XCTAssertTrue(result2.stdout.contains("tmp"),
                       "pwd should report /tmp but got: \(result2.stdout)")
    }
}
