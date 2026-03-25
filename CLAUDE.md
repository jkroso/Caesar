# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Caesar is an AI agent platform written in Julia. Agents use a sandboxed Julia REPL (via JuliaInterpreter) as their primary tool instead of Bash. The REPL is persistent — variables and functions survive across evaluations — and shared with the user. All function calls in the interpreter are intercepted by a safety dispatch system (`safety.jl`) that checks filesystem paths, blocks `eval`/ENV mutation, and prompts the user for approval on unknown operations.

## Running

```bash
julia tui.jl        # TUI with chat + live REPL log pane (Tachikoma-based)
julia cli.jl        # Minimal CLI REPL
julia json_io.jl    # JSON-over-stdin/stdout bridge for the GUI sidecar
```

The GUI is a separate Tauri 2 app in `gui/` — see `gui/CLAUDE.md` for its own build commands and architecture.

## Running Tests

```bash
julia tests/test_repl.jl   # Safety system + REPL interpreter tests
julia tests/test_cli.jl    # CLI event loop + JSON parsing tests
```

Tests are standalone scripts using `Test` — no test runner. They stub the dependencies they need (CONFIG, event types) rather than loading main.jl.

## Module System

This project uses [Kip.jl](https://github.com/jkroso/Kip.jl) instead of Julia's standard `using`/`import`. The `@use` macro resolves paths relative to the current file:

```julia
@use "."...                        # import everything from current package
@use "./safety"...                 # import all exports from safety.jl
@use "./repl" interpret TRUSTED_MODULES  # import specific names
@use "github.com/jkroso/URI.jl/FSPath" home FSPath  # external dependency
```

The `...` suffix means "import all exports." Kip auto-downloads GitHub dependencies on first use. `FSPath` from URI.jl is used throughout instead of bare strings for file paths — it supports `*` for path joining (e.g., `HOME * "config.yaml"`).

## Architecture

### Core Loop (`main.jl`)

The ReAct agent loop in `process_message` / `_process_message`:
1. Builds a system prompt (personality + instructions + tool schemas + skill catalog + memory)
2. Sends message history to the LLM via `call_llm` (wraps `PromptingTools.aigenerate`)
3. Parses the JSON response and dispatches:
   - `{"eval": "code"}` → runs through `interpret()` in the agent's sandboxed module
   - `{"js": "code"}` → shorthand for browser JS execution
   - `{"tool": "name", "args": {...}}` → calls a registered tool function
   - `{"skill": "name"}` → activates a skill (injects its content into the system prompt)
   - `{"handoff": {"to_agent": "...", ...}}` → delegates to another agent
   - `{"final_answer": "text"}` → sends response to user, ends loop
4. Tool results are fed back as `UserMessage("Result: ...")` for the next LLM turn

### Event System

Agent ↔ interface communication uses typed events over `Channel`s:
- **Outbound** (agent → UI): `AgentMessage`, `ToolCallRequest`, `ToolResult`, `AgentDone`
- **Inbound** (UI → agent): `UserInput`, `ToolApproval` (`:allow`, `:deny`, `:always`)

The `PresenceRouter` handles approval routing between GUI and Telegram — when the GUI is inactive, approvals are forwarded to Telegram with inline keyboard buttons.

### Safety System (`safety.jl` + `repl.jl`)

`safety.jl` defines a `validate(f, args...)` dispatch table returning `Allow`, `Deny`, or `Ask`:
- Filesystem writes: checked against `CONFIG["allowed_dirs"]` and `DENIED_PATHS`
- `eval` / `Core.eval`: only `using`/`import` expressions allowed
- ENV mutation: always denied
- Process execution: checked against `CONFIG["allowed_commands"]` glob patterns
- Everything else: `Allow` by default

`repl.jl` steps through code expression-by-expression via `JuliaInterpreter`, intercepting every `:call` node to run through `validate()`. REPL-style soft scope is injected into loops so outer variables work like in the Julia REPL.

### Extensibility

- **Tools** (`tools/*.jl`): Each file exports `name`, `schema` (JSON string), `needs_confirm` (bool), and `fn(args)::String`. Loaded at startup by `load_tools!()`.
- **Skills** (`skills/*.md`): YAML frontmatter with `name` and `description`, body is the prompt content. Activated by `/name` or `{"skill": "name"}`. Agents can also have local skills in `agents/<id>/skills/`.
- **Commands** (`commands/*.jl`): Each file exports `name`, `description`, and `fn(args)::String`. Invoked via `/name` in the CLI/TUI. Not available to agents.
- **Agents** (`agents/<id>/`): Each agent has `soul.md` (personality), `instructions.md` (capabilities), optional `config.yaml` and `skills/` directory. Gets its own `Module` and `repl.log`.

### Memory

Two pluggable memory providers per agent (configured in `MEMORY_PROVIDERS`):
- **Ori** (`ori/`): Graph-aware markdown vault with BM25 + TF-IDF/Ollama semantic search, PageRank, vitality scoring, and automatic knowledge extraction from conversations. Notes are markdown files with `[[Wiki Links]]`.
- **Hindsight**: External REST API adapter (`memory/hindsight/`).

### Interfaces

- **TUI** (`tui.jl`): Tachikoma-based terminal UI with tabs (Chat, Help, Skills, Agents), markdown rendering, tab completion for `/commands` and `/skills`
- **CLI** (`cli.jl`): Simple stdin loop with `y/n/a(lways)` approval prompts
- **JSON I/O** (`json_io.jl`): Newline-delimited JSON protocol for the Tauri GUI sidecar. Lines prefixed with `PROSCA:` are protocol messages; other stdout is ignored
- **Gateways** (`gateway/`): Telegram bot adapter and Zoho Mail integration

### LLM Support

Multi-provider via PromptingTools.jl — schema auto-detected from model name prefix in `_detect_schema_for()`. Supported: Ollama (local), OpenAI, Anthropic, Google, Mistral, DeepSeek, xAI. Model switching at runtime via `/model`.

### State & Config

- `CONFIG` dict loaded from `~/Caesar/config.yaml` at startup
- SQLite database at `~/Caesar/memories/memories.db` — tables: `memories`, `projects`, `routines`, `routine_runs`, `conversations`
- `~/Caesar/` is the `HOME` constant — all agent data, logs, tools, skills live here

## Conventions

- LLM responses must be valid JSON with one of the recognized keys (`eval`, `tool`, `final_answer`, `skill`, `handoff`, `js`, `index_page`). Non-JSON responses are treated as direct text to the user.
- Tool/command modules use `parentmodule(@__MODULE__)` aliased as `prosca` to access the main module's exports.
- The `CONFIG` dict is the single source of truth for runtime settings and API keys.
