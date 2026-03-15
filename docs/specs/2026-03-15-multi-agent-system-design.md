# Multi-Agent System Design (Sub-project 1: Agent System)

**Date:** 2026-03-15
**Status:** Approved
**Scope:** Agent data model, folder structure, conversations, memory isolation, GUI. Does NOT cover REPL runtime, MCP replacement, or multi-agent project pipelines (separate sub-projects).

## Overview

Transform Prosca from a single-agent system into a multi-agent system where each agent has its own personality, instructions, and skills. Agents are lightweight configuration — folders on disk loaded into structs. Each agent gets isolated memories but conversations are visible across agents. Agents can hand off conversations to other agents.

## Key Decisions

- **Agents are data, not processes** — an `Agent` struct holds personality/instructions/skills loaded from disk. No separate processes or modules.
- **Agent folders live at `~/Prosca/agents/<name>/`** — each with `soul.md`, `instructions.md`, and optional `skills/` directory.
- **Auto-migration** — on first run, existing root `soul.md`/`instructions.md` are copied into `agents/prosca/`. Root files left in place for CLI/TUI backward compat.
- **Guided creation** — user provides name + description, LLM generates starter `soul.md` and `instructions.md`.
- **Local skills override globals** — if an agent has a skill with the same name as a global skill, the agent's version wins.
- **Memory isolation** — each agent's RAG memory index is isolated. Cross-agent chat history is readable but memories don't leak.
- **Conversation handoff** — agents can hand off to another agent, spawning a linked conversation with context summary.
- **Sequential handoff** — handoffs are sequential (the original conversation finishes before the new one starts) due to the single `AGENT_LOCK`. This is intentional — concurrent agent execution is deferred to sub-project 2 (REPL runtime).
- **Default agent protected** — the `prosca` agent cannot be deleted.

## Agent Data Model

```julia
struct Agent
    id::String           # folder name, e.g. "prosca"
    personality::String  # contents of soul.md
    instructions::String # contents of instructions.md
    skills::Dict{String, Skill}  # local skills (override globals by name)
    path::String         # absolute path to agent folder
end
```

Note: `id` doubles as display name. If display names diverge from folder names in the future, add a `name` field then.

### Folder Structure

```
~/Prosca/agents/
├── prosca/
│   ├── soul.md
│   ├── instructions.md
│   └── skills/
│       └── commit.md
├── researcher/
│   ├── soul.md
│   ├── instructions.md
│   └── skills/
└── ops/
    ├── soul.md
    └── instructions.md
```

### Loading

On startup, scan `~/Prosca/agents/` and load each subfolder into an `Agent` struct. Store in a `Dict{String, Agent}` keyed by agent ID (folder name).

The global `SKILLS` dict remains. When building a system prompt for an agent, merge the agent's local skills on top of globals — local wins on name collision.

### Creation

`create_agent(name, description)`:
1. Create `agents/<name>/` directory
2. Call the LLM with the description to generate starter `soul.md` and `instructions.md`
   - Uses the global `CONFIG["llm"]` model
   - On LLM failure: emit error event and return early (same pattern as `handle_routine_create`)
   - Fallback: if LLM fails, create files with a basic template (`# <name>\n\n<description>`)
3. Create `agents/<name>/skills/` directory
4. Load and return the new `Agent` struct
5. Add to the in-memory agents dict

### Deletion

`delete_agent(id)`:
1. Guard: reject deletion of `prosca` (the default agent), emit error
2. Remove from in-memory agents dict
3. Delete the folder from disk
4. Orphaned conversations and memories remain in SQLite (agent_id still set, just no matching agent)

### Migration

On first run, if `agents/` directory doesn't exist but root `soul.md` and `instructions.md` do:
1. Create `agents/prosca/`
2. Copy root `soul.md` → `agents/prosca/soul.md`
3. Copy root `instructions.md` → `agents/prosca/instructions.md`
4. Copy root `skills/` → `agents/prosca/skills/` (if exists)
5. Leave root files in place (CLI/TUI backward compat)

## Conversations

### SQLite `conversations` Table

Conversations are currently frontend-only (in-memory). To support agent assignment, handoff links, and backend queries ("which conversations belong to this agent?"), add a `conversations` table:

```sql
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL DEFAULT 'prosca',
    title TEXT NOT NULL DEFAULT 'New chat',
    handed_off_to TEXT,      -- conversation id if handed off
    handed_off_from TEXT,    -- conversation id if received handoff
    created_at TEXT,
    updated_at TEXT
);
```

The frontend `Conversation` type gains matching fields:

```typescript
interface Conversation {
    id: string;
    title: string;
    createdAt: number;
    updatedAt: number;
    messages: ChatMessage[];  // still in-memory / localStorage
    busy?: boolean;
    agentId: string;
    handedOffTo?: string;
    handedOffFrom?: string;
}
```

Conversation CRUD goes through the backend protocol (like projects/routines), with messages still managed on the frontend.

### Memory Isolation

**SQLite `memories` table** — add `agent_id` column:
```sql
ALTER TABLE memories ADD COLUMN agent_id TEXT DEFAULT 'prosca'
```

All existing memories are attributed to the `prosca` agent.

**MEMORY_INDEXES key change:**

```julia
# Before:
const MEMORY_INDEXES = Dict{Union{String,Nothing}, ChunkIndex}()

# After:
const MEMORY_INDEXES = Dict{Tuple{String, Union{String,Nothing}}, ChunkIndex}()
# Key is (agent_id, conversation_id)
```

**Updated function signatures:**

```julia
function rebuild_memory_index(; agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
    # SQL: WHERE agent_id = ? AND conversation_id = ?  (or IS NULL)
    # Index key: MEMORY_INDEXES[(agent_id, conversation_id)] = ...
end

function log_memory(text::String; role::String="Agent", metadata=Dict(),
                    agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
    # INSERT includes agent_id column
    # Rebuilds index for (agent_id, conversation_id)
end

function search_memories(query::String; limit::Int=5,
                         agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)::String
    # Looks up MEMORY_INDEXES[(agent_id, conversation_id)]
end
```

### GUIConversation Changes

```julia
mutable struct GUIConversation
    history::Vector{PromptingTools.AbstractMessage}
    auto_allowed::Set{String}
    outbox::Channel
    inbox::Channel
    agent_id::String
end
```

`get_gui_conversation` gains an `agent_id` parameter:

```julia
function get_gui_conversation(id::String, agent_id::String="prosca")
    get!(GUI_CONVERSATIONS, id) do
        GUIConversation(PromptingTools.AbstractMessage[], Set{String}(), Channel(32), Channel(32), agent_id)
    end
end
```

The `agent_id` is set at conversation creation time (from the `user_message` protocol field) and does not change. If a conversation is created from a handoff, it gets the target agent's ID.

### Cross-Agent Chat Visibility

Chat history is not filtered by agent. The `restore_context` mechanism works across agents — it operates on conversation history, which is agent-agnostic. Only the RAG memory index is isolated per agent.

In practice, cross-agent visibility is used during handoff: the receiving agent gets a context summary from the originating conversation. Direct restoration of another agent's conversation into your context is possible but not exposed as a UI action.

### Handoff

When an agent decides to hand off, it returns:
```json
{"handoff": {"to_agent": "researcher", "reason": "This requires deep research", "context": "summary of key points"}}
```

**Prompt injection:** `build_system_prompt` includes a list of available agents with their descriptions (first line of `soul.md`) so the agent knows what's available:
```
Available agents for handoff (use {"handoff": {...}} to delegate):
- researcher: Expert at deep research and analysis
- ops: Operations and infrastructure specialist
```

The current agent is excluded from this list (can't hand off to yourself).

**Validation:** If `to_agent` doesn't exist, the ReAct loop feeds back an error message: "Unknown agent 'xyz'. Available agents: researcher, ops" and the agent can retry.

**Execution flow:**
1. `_run_agent` detects `handoff` in the parsed JSON response
2. Validates `to_agent` exists in the agents dict
3. Creates a new conversation in SQLite with `agent_id = to_agent`, `handed_off_from = current_conv_id`
4. Updates the current conversation: `handed_off_to = new_conv_id`
5. Emits `agent_message` with handoff metadata to the GUI
6. Puts `AgentDone` on the outbox (current conversation ends)
7. The new conversation is **not** auto-started — it appears in the sidebar under the target agent, and the user can open it to begin. This avoids `AGENT_LOCK` contention and gives the user control.

## Agent Integration with run_agent

`_run_agent` currently uses global `PERSONALITY` and `INSTRUCTIONS` constants. Changes:

- `run_agent` / `_run_agent` gain an `agent::Agent` parameter
- `build_system_prompt` takes `agent.personality` and `agent.instructions` instead of globals
- `build_system_prompt` includes the available agents list for handoff (excluding current agent)
- Skill resolution: merge `agent.skills` over global `SKILLS` — `merged = merge(SKILLS, agent.skills)` (local wins)
- `log_memory`, `search_memories`, `rebuild_memory_index` all pass `agent.id`
- The handoff JSON response is handled in the ReAct loop alongside `tool`, `final_answer`, and `skill`

## GUI Changes

### Sidebar

The sidebar chat section is restructured from a flat conversation list to an agent-grouped layout:

```
Agents
├── prosca                    [+]
│   ├── Debug auth issue
│   └── Review PR #42
├── researcher                [+]
│   └── Market analysis
└── ops                       [+]
```

- Agents are sorted: `prosca` always first, then alphabetical
- Each agent name row shows the agent name + a `[+]` button to create a new conversation
- Conversations are indented under their agent
- Clicking a conversation opens it (same as today)
- Active conversation is highlighted

### Agents Page

A new page accessible from the sidebar nav (alongside Projects, Skills, Settings) for managing agents:
- List all agents with name
- Create: form with name + description → backend generates soul.md/instructions.md
- Edit: text areas for soul.md and instructions.md content (saves to disk, reloads agent struct)
- Delete: with confirmation (disabled for `prosca`)

### Handoff UI

- When a conversation is handed off, the chat shows a message: "Handed off to [agent] → [conversation title]" with a clickable link
- The receiving conversation shows "Continued from [agent] → [conversation title]" at the top
- Both links navigate to the linked conversation

### Protocol Changes

**New messages:**

```
GUI → Backend:
  {"type": "agents_list"}
  {"type": "agent_create", "name": "...", "description": "..."}
  {"type": "agent_delete", "id": "..."}
  {"type": "agent_update", "id": "...", "soul": "...", "instructions": "..."}

Backend → GUI:
  {"type": "agents", "data": [{"id": "prosca"}, ...]}
  // All CRUD operations respond with an updated agents list (same pattern as projects/routines)
```

**Conversation protocol (new):**

```
GUI → Backend:
  {"type": "conversations_list"}
  {"type": "conversation_create", "agent_id": "prosca"}
  {"type": "conversation_delete", "id": "..."}
  {"type": "conversation_update_title", "id": "...", "title": "..."}

Backend → GUI:
  {"type": "conversations", "data": [{"id": "...", "agent_id": "prosca", "title": "...", ...}]}
```

**Modified messages:**

```
GUI → Backend:
  {"type": "user_message", "text": "...", "conversation_id": "...", "agent_id": "..."}
  // agent_id added so backend knows which agent to dispatch

Backend → GUI:
  // All existing events unchanged — they already carry conversation_id
  // Handoff emits agent_message with handoff metadata:
  {"type": "agent_message", "text": "...", "conversation_id": "...",
   "handoff": {"to_agent": "researcher", "new_conversation_id": "..."}}
```

## What This Does NOT Cover

- REPL runtime (sub-project 2) — agents still use the existing MCP/Kaimon setup for now
- Multi-agent project pipelines (sub-project 4) — agents can be assigned to projects later
- Per-agent REPL isolation (sub-project 2)
- Code verification (sub-project 2)
- Concurrent agent execution (deferred — current `AGENT_LOCK` serializes all agents)
