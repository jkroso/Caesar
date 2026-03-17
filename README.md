# Prosca: An Agent with a Julia REPL

Prosca is an AI agent built in Julia that uses a persistent Julia REPL as its primary tool. Instead of shelling out to Bash, it evaluates Julia expressions step-by-step, keeping variables in scope across interactions.

<img src="./tui_screenshot.png" alt="tui screenshot" style=""/>

The REPL is shared — you can work in it alongside Prosca. Define a function, then ask Prosca to write tests for it by name. No copy-pasting needed since Prosca can introspect the same module scope you're working in.

Using Julia instead of Bash for tool calls means smaller contexts, fewer tokens, and code that's easier to validate statically. The interpreter runs every expression through a safety system that checks filesystem paths, blocks `eval`/`ENV` mutation, and prompts for approval on unknown operations.

## Features

| Feature | Description |
|---------|-------------|
| Julia REPL | Sandboxed interpreter with safety validation and REPL-style soft scope |
| Multi-agent | Create agents with distinct personalities, instructions, and skills. Agents can hand off tasks to each other |
| Persistent memory | RAG-backed memory with per-agent and per-conversation scoping |
| Tools | git_branch_and_pr, prune_memories, web_search — extensible via `~/Prosca/tools/` |
| Skills | Markdown-defined prompts activated by `/name` — extensible via `~/Prosca/skills/` |
| Commands | CLI commands via `;name` — model switching, plugin management |
| Interfaces | TUI (`tui.jl`) with chat + live REPL log pane, CLI (`cli.jl`), Telegram gateway |
| LLM support | Ollama, OpenAI, Anthropic, Google, Mistral, DeepSeek, xAI via PromptingTools.jl |

## Getting Started

1. Install [Kip](https://github.com/jkroso/Kip.jl)
2. Clone this repo
3. Run `julia tui.jl` for the TUI or `julia cli.jl` for the CLI
4. Configuration lives in `~/Prosca/config.yaml` (created on first run)
