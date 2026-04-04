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
- **Xcode 15+** or the Xcode Command Line Tools (`xcode-select --install`)
- **Swift 5.9+** (ships with Xcode 15+)
- **[Ollama](https://ollama.com)** installed and running

## Quick Start

### Option A: Download the pre-built binary

Download the latest release from the [Releases page](https://github.com/KnotTheory-ai-Inc/Tesseract-Claw/releases). The binary is codesigned with an Apple Developer ID, so it should run without Gatekeeper issues.

```bash
# Extract and install
tar xzf tesseract-claw-v0.6.0-macos-universal.tar.gz
cp tesseract-claw-v0.6.0-macos/tesseract-claw /usr/local/bin/

# Verify
tesseract-claw --version
```

> **Note (macOS Gatekeeper):** The release binary is codesigned, but if macOS still blocks it (e.g. the quarantine attribute wasn't cleared), run:
> ```bash
> xattr -cr /usr/local/bin/tesseract-claw
> ```

### Option B: Build from source

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

## Building

### Option 1: Swift Package Manager (recommended)

The simplest way to build — no extra tools needed.

```bash
# Debug build (faster compilation, includes debug symbols)
swift build

# Release build (optimized, smaller binary)
swift build -c release
```

The binary is output to:
- Debug: `.build/debug/tesseract-claw`
- Release: `.build/release/tesseract-claw`

### Option 2: Xcode GUI

If you prefer working in Xcode:

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open TesseractClaw.xcodeproj
```

Then select the `TesseractClaw` scheme and hit **Cmd+B** to build, or **Cmd+R** to build and run.

### Option 3: Xcode Command Line

```bash
# Generate project + build in one step
xcodegen generate && xcodebuild -project TesseractClaw.xcodeproj -scheme TesseractClaw -configuration Release build
```

The binary is output to `Build/Products/Release/tesseract-claw`.

### Installing the Binary

After building, copy the binary to a directory on your `PATH`:

```bash
# From SPM build
cp .build/release/tesseract-claw /usr/local/bin/

# From Xcode build
cp Build/Products/Release/tesseract-claw /usr/local/bin/
```

Verify it works:

```bash
tesseract-claw --version
```

### Setting Up Ollama

Tesseract-Claw requires [Ollama](https://ollama.com) to be running with at least one model installed.

```bash
# Install Ollama
brew install ollama

# Start the Ollama server (runs on http://127.0.0.1:11434)
ollama serve

# Pull a model — gemma3 is the recommended default (supports text + vision)
ollama pull gemma3
```

Other recommended models to try:

```bash
ollama pull llama3.2        # Tier 1 — native tool calling
ollama pull mistral         # Tier 2 — text-based tool calling
ollama pull deepseek-coder  # Tier 3 — ReAct prompting, good for code
ollama pull qwen2.5         # Tier 1 — native tool calling
```

Tesseract-Claw auto-detects which tier each model belongs to and adapts its tool-calling strategy accordingly. See [Supported Models](#supported-models) for the full list.

### Troubleshooting

**`swift build` fails with "no such module"**
Make sure you have Xcode 15+ or the Command Line Tools installed:
```bash
xcode-select --install
swift --version   # should show 5.9+
```

**"Ollama is not running" error**
Start the Ollama server in a separate terminal:
```bash
ollama serve
```

**"Model not found" error**
Pull the model first:
```bash
ollama pull gemma3
```

**Build succeeds but binary crashes on launch**
Make sure Ollama is reachable at `http://127.0.0.1:11434`. You can verify with:
```bash
curl http://127.0.0.1:11434
# Should return: Ollama is running
```

**XcodeGen not found**
```bash
brew install xcodegen
```

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
