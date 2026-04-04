# Tesseract-Claw

A Swift CLI coding agent powered by local LLMs via [Ollama](https://ollama.com). No API keys, no cloud, no per-request charges — everything runs on your machine.

Built by [KnotTheory.ai Inc.](https://knottheory.ai).

> **Prerequisites:** [Ollama](https://ollama.com) (free, open-source local LLM runtime) and **macOS 13+** with **Swift 5.9+**. Install Ollama with `brew install ollama`, then pull a model: `ollama pull gemma3`.

## Features

- **Local-first** — runs entirely on your machine via Ollama. Zero API keys, zero cloud dependencies.
- **4-tier LLM architecture** — automatically adapts tool calling to your model's capabilities:
  - **Tier 1 (Native Tools):** llama3.x, qwen, command-r, hermes — Ollama native tool calling
  - **Tier 2 (Text-Based Tools):** mistral, mixtral — `[TOOL_CALLS]` text format parsing
  - **Tier 3 (ReAct Prompting):** gemma3, phi4, deepseek — Thought/Action/Action Input format
  - **Tier 4 (No Tools):** gemma2, phi3, codellama — plain chat mode
- **Auto-fallback** — if a model doesn't support native tools, Tesseract-Claw automatically falls back to ReAct prompting or plain chat
- **Vision support** — pass images to multimodal models (gemma3, llava, moondream, llama3.2-vision)
- **11 built-in tools** — file operations, shell commands, web fetching, search, sub-agents, notebooks, and more
- **Sub-agent system** — spawn isolated agents for complex tasks (explore, plan, verify, general-purpose)
- **Security hardened** — path traversal protection, bash risk assessment for dangerous commands, workspace boundary enforcement
- **Session management** — save/load conversations, auto-compaction when context gets large
- **REPL + one-shot modes** — interactive session or single-prompt execution
- **Hooks system** — pre/post tool-use shell hooks for custom workflows
- **Persistent memory** — remembers context across sessions via `~/.claw/memory/`
- **PDF reading** — native PDFKit support, reads PDF files directly
- **Clipboard & screenshot** — paste text/images, capture screen for vision analysis

## Requirements

- **macOS 13+** (Ventura or later)
- **Swift 5.9+**
- **[Ollama](https://ollama.com)** installed and running

## Quick Start

```bash
# 1. Install Ollama and pull a model
brew install ollama
ollama serve &
ollama pull gemma3

# 2. Build Tesseract-Claw
git clone https://github.com/KnotTheory-ai-Inc/Tesseract-Claw.git
cd Tesseract-Claw
swift build -c release

# 3. Run
.build/release/tesseract-claw
```

Or copy the binary somewhere on your PATH:

```bash
cp .build/release/tesseract-claw /usr/local/bin/
```

## Usage

### REPL Mode (interactive)

```bash
tesseract-claw
```

### One-Shot Mode

```bash
tesseract-claw -p "explain what this project does"
```

### Vision Mode

```bash
tesseract-claw --image screenshot.png -p "describe what you see"
```

### Specify a Model

```bash
tesseract-claw --model llama3.2 -p "refactor this function"
```

### List Installed Models

```bash
tesseract-claw --models
```

## REPL Commands

| Command | Description |
|---------|-------------|
| `/quit`, `/exit` | Exit the REPL |
| `/models` | List available Ollama models |
| `/model <name>` | Switch to a different model |
| `/image <path> [prompt]` | Send an image to a vision model |
| `/usage` | Show token usage for the session |
| `/compact` | Manually compact the session context |
| `/clear` | Clear conversation history |
| `/save [name]` | Save the current session |
| `/load [name]` | Load a saved session |
| `/config` | Show current configuration |
| `/memory` | Show persistent memory |
| `/skills` | List available skills |
| `/help` | Show help |

## Tools

Tesseract-Claw provides 11 tools to the LLM:

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents (also handles PDFs and auto-redirects URLs) |
| `write_file` | Create or overwrite files |
| `edit_file` | Make targeted edits to existing files |
| `glob_search` | Find files by pattern |
| `grep_search` | Search file contents with regex |
| `bash` | Execute shell commands (with risk assessment) |
| `web_fetch` | Fetch and extract content from URLs |
| `web_search` | Search the web via DuckDuckGo |
| `todo` | Session-scoped task list (add/update/delete/list) |
| `agent` | Spawn sub-agents for isolated complex tasks |
| `notebook` | Read and edit Jupyter notebooks |

## Configuration

Tesseract-Claw looks for configuration in:

- **`CLAW.md`** — project-level instructions (discovered up the directory tree, like `.gitignore`)
- **`~/.claw/settings.json`** — global settings and hooks
- **`~/.claw/memory/`** — persistent memory across sessions
- **`~/.claw/sessions/`** — saved conversation sessions

### Hooks

Configure pre/post tool-use hooks in `~/.claw/settings.json`:

```json
{
  "hooks": {
    "preToolUse": [
      {
        "matcher": "bash",
        "command": "echo 'About to run bash'"
      }
    ],
    "postToolUse": [
      {
        "matcher": "*",
        "command": "echo 'Tool finished'"
      }
    ]
  }
}
```

## Building with Xcode

If you prefer Xcode over SPM:

```bash
# Requires XcodeGen (brew install xcodegen)
xcodegen generate
xcodebuild -project TesseractClaw.xcodeproj -scheme TesseractClaw -configuration Release build
```

The release binary is output to `Build/Products/Release/tesseract-claw`.

## Architecture

```
Sources/
├── TesseractClaw/main.swift         — CLI entry point, REPL loop, argument parsing
├── ClawAPI/APIClient.swift          — Ollama HTTP client, vision support, tiered dispatch
└── ClawRuntime/                     — Core runtime library
    ├── Conversation.swift           — Agentic loop, turn execution, auto-compaction
    ├── Session.swift                — Message history, persistence, serialization
    ├── ModelTier.swift              — 4-tier classifier, prompt builders, response parsers
    ├── ToolRegistry.swift           — Tool definitions and execution dispatch
    ├── Permissions.swift            — Permission modes, interactive prompting, session caching
    ├── FileOps.swift                — read/write/edit/glob/grep implementations
    ├── BashExecutor.swift           — Shell execution with timeout and cd persistence
    ├── SubAgent.swift               — Sub-agent spawning and lifecycle
    ├── WebFetch.swift               — URL fetching and web search
    ├── Prompt.swift                 — System prompt builder, CLAW.md discovery, git context
    ├── Config.swift                 — Settings and hooks loader
    ├── Hooks.swift                  — Pre/post tool-use hook runner
    ├── Memory.swift                 — Persistent memory system
    ├── Skills.swift                 — Reusable skill management
    ├── Compact.swift                — Session compaction with summary preservation
    ├── Usage.swift                  — Token usage tracking
    ├── Spinner.swift                — Terminal spinner and status display
    ├── PdfReader.swift              — Native PDF reading via PDFKit
    ├── TodoManager.swift            — Session-scoped task list
    ├── NotebookEditor.swift         — Jupyter .ipynb support
    ├── ClipboardOps.swift           — Clipboard and screenshot support
    └── MarkdownRenderer.swift       — Terminal markdown rendering
```

## Running Tests

```bash
swift test
```

45 tests covering tier classification, ReAct/Mistral parsing, bash cd persistence, tool execution, and more.

## Supported Models

Any model available through Ollama works. Tesseract-Claw automatically classifies models into the appropriate tier. Some popular choices:

| Model | Tier | Tool Support | Vision |
|-------|------|-------------|--------|
| gemma3 | 3 (ReAct) | Yes | Yes |
| llama3.2 | 1 (Native) | Yes | Yes (vision variant) |
| qwen2.5 | 1 (Native) | Yes | No |
| mistral | 2 (Text) | Yes | No |
| deepseek-coder | 3 (ReAct) | Yes | No |
| command-r | 1 (Native) | Yes | No |
| codellama | 4 (None) | No | No |

## License

MIT License. See [LICENSE](LICENSE) for details.

### Attribution

The **4-tier LLM tool-calling architecture** — including the ReAct prompt engineering pattern, Mistral text-based tool-call parsing, tiered model classification, auto-fallback cascade, and all associated prompt builders and response parsers (in `ModelTier.swift` and `APIClient.swift`) — is original work by **KnotTheory.ai Inc.**

Tesseract-Claw is designed to work exclusively with **local LLMs via Ollama**. No API tokens, no cloud services, no per-request usage charges.

Copyright (c) 2026 KnotTheory.ai Inc.
