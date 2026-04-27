# Caesar: An Agent Platform with a Julia REPL

Caesar is an AI agent platform built in Julia that uses a Julia REPL as its primary tool. Instead of shelling out to Bash, agents evaluate Julia expressions step-by-step, keeping variables in scope across interactions.

<img src="./GUI Screenshot.png" alt="GUI screenshot" style=""/>

https://github.com/user-attachments/assets/3a969d11-ba84-42d9-bf75-f85bac0c48f6

Using Julia instead of Bash for tool calls means smaller contexts, fewer tokens, and code that's easier to validate statically. The interpreter runs every expression through a safety system that checks filesystem paths, blocks `eval`/`ENV` mutation, and prompts for approval on unknown operations.

## Features

| Feature | Description |
|---------|-------------|
| Julia REPL | Sandboxed interpreter with safety validation and REPL-style soft scope |
| Multi-agent | Create agents with distinct personalities, instructions, and skills. Agents can hand off tasks to each other |
| Pluggable memory | Ori (graph-aware markdown vault) or Hindsight (REST API with auto-extraction) — per-agent |
| Tools | git_branch_and_pr, web_search, email — extensible via `~/Caesar/tools/` |
| Skills | Markdown-defined prompts activated by `/name` — extensible via `~/Caesar/skills/` |
| Commands | CLI commands via `/name` — model switching, plugin management |
| Interfaces | TUI (`tui.jl`) with chat + live REPL log pane, CLI (`cli.jl`), Telegram gateway |
| LLM support | Ollama, OpenAI, Anthropic, Google, Mistral, DeepSeek, xAI via PromptingTools.jl |

## Getting Started

1. Install [Kip](https://github.com/jkroso/Kip.jl)
2. Clone this repo
3. Run `julia tui.jl` for the TUI or `julia cli.jl` for the CLI
4. Configuration lives in `~/Caesar/config.yaml` (created on first run)

## Creating an Agent

```julia
agent = Agent("Pliny", "You are a concise research assistant.", "Summarize papers. Cite sources.")
```

Only `id`, `personality`, and `instructions` are required — the rest have defaults:

| Keyword | Default |
|---------|---------|
| `skills` | `Dict{String, Skill}()` |
| `path` | `HOME * "agents" * id` |
| `repl_module` | `Module(Symbol("agent_$id"))` |
| `repl_log` | opens `agents/<id>/repl.log` |
| `config` | `Dict{String, Any}()` |

Then talk to it:

```julia
promise = message(agent, "Summarize the latest paper on transformer architectures")
# do other work...
reply = need(promise)
```

Agents on disk (`agents/<id>/` with `soul.md` and `instructions.md`) are loaded automatically on startup by `load_agents!()`. `create_agent!("name", "description")` scaffolds the directory and uses the LLM to generate the personality and instructions.
