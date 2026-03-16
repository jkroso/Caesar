# Multi-Agent System Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Prosca from a single-agent system into a multi-agent system with per-agent personalities, instructions, skills, memory isolation, conversation handoff, and a restructured GUI.

**Architecture:** Agents are lightweight structs loaded from `~/Prosca/agents/<name>/` folders. Each agent has isolated RAG memory but shared conversation visibility. The ReAct loop (`_run_agent`) takes an `Agent` parameter instead of using globals. Conversations gain an `agent_id` and are persisted in SQLite. The GUI sidebar groups conversations under agents.

**Tech Stack:** Julia (backend), React 19 + TypeScript (frontend), SQLite, Tailwind CSS

**Spec:** `docs/specs/2026-03-15-multi-agent-system-design.md`

---

## File Structure

**New files:**
- `agents.jl` — Agent struct, loading, creation, deletion, migration

**Modified files (backend):**
- `main.jl` — Memory functions gain `agent_id`, `build_system_prompt` takes agent, `_run_agent` takes agent + handles handoff, skills merged per-agent
- `json_io.jl` — Agent/conversation CRUD handlers, `GUIConversation` gains `agent_id`, `user_message` dispatches by agent, handoff event emission

**Modified files (frontend):**
- `gui/src/types/conversation.ts` — Add `agentId`, handoff fields
- `gui/src/types/sidecar.ts` — Add agent-related event types
- `gui/src/contexts/ConversationContext.tsx` — Conversations grouped by agent, backend-driven CRUD
- `gui/src/components/layout/Sidebar.tsx` — Agent-grouped conversation tree
- `gui/src/App.tsx` — Add Agents page to routing

**New files (frontend):**
- `gui/src/contexts/AgentContext.tsx` — Agent list state, CRUD
- `gui/src/pages/AgentsPage.tsx` — Agent management page

---

## Chunk 1: Backend Agent System

### Task 1: Agent struct, loading, and migration

**Files:**
- Create: `agents.jl`
- Modify: `main.jl:14-16` (add include), `main.jl:35-36` (keep PERSONALITY/INSTRUCTIONS as fallbacks)

- [ ] **Step 1: Create `agents.jl` with Agent struct and loading**

```julia
# agents.jl — Multi-agent system: struct, loading, creation, migration

@use "github.com/jkroso/URI.jl/FSPath" FSPath

struct Agent
    id::String
    personality::String
    instructions::String
    skills::Dict{String, Skill}
    path::FSPath
end

const AGENTS = Dict{String, Agent}()

"""Load skills from an agent's skills/ directory."""
function load_agent_skills(agent_path::FSPath)::Dict{String, Skill}
    skills = Dict{String, Skill}()
    skills_dir = agent_path * "skills"
    isdir(skills_dir) || return skills
    for file in skills_dir.children
        file.extension == "md" || continue
        skill = parse_skill(string(file))
        skill === nothing && continue
        skills[skill.name] = skill
    end
    skills
end

const AGENTS_DIR = HOME*"agents"

"""Load a single agent from its directory."""
function load_agent(agent_dir::FSPath)::Union{Agent, Nothing}
    id = agent_dir.name
    soul_path = agent_dir*"soul.md"
    instr_path = agent_dir*"instructions.md"
    isfile(soul_path) && isfile(instr_path) || return nothing
    Agent(
        id,
        read(soul_path, String),
        read(instr_path, String),
        load_agent_skills(agent_dir),
        agent_dir
    )
end

"""Scan ~/Prosca/agents/ and load all agents."""
function load_agents!()
    empty!(AGENTS)
    isdir(AGENTS_DIR) || return
    for entry in AGENTS_DIR.children
        isdir(entry) || continue
        agent = load_agent(entry)
        agent === nothing && continue
        AGENTS[agent.id] = agent
        @info "Loaded agent: $(agent.id) ($(length(agent.skills)) local skills)"
    end
end

"""Migrate root soul.md/instructions.md to agents/prosca/ on first run."""
function migrate_to_agents!()
    isdir(AGENTS_DIR) && return  # already migrated

    root_soul = HOME * "soul.md"
    root_instr = HOME * "instructions.md"
    (isfile(root_soul) && isfile(root_instr)) || return

    prosca_dir = mkpath(AGENTS_DIR * "prosca")

    cp(root_soul, prosca_dir * "soul.md")
    cp(root_instr, prosca_dir * "instructions.md")

    # Copy skills if they exist
    root_skills = HOME * "skills"
    if isdir(root_skills)
        prosca_skills = mkpath(prosca_dir * "skills")
        for file in root_skills.children
            file.extension == "md" || continue
            cp(file, prosca_skills * file.name)
        end
    end

    @info "Migrated root soul.md/instructions.md to agents/prosca/"
end

"""Create a new agent with LLM-generated soul and instructions."""
function create_agent!(name::String, description::String)::Union{Agent, Nothing}
    agent_dir = AGENTS_DIR * name
    isdir(agent_dir) && return nothing  # already exists

    mkpath(agent_dir)
    mkpath(agent_dir * "skills")

    # Generate soul.md and instructions.md via LLM
    soul_content, instr_content = try
        gen_msgs = [
            PromptingTools.SystemMessage("""You are creating a new AI agent persona. Generate two markdown files based on the description.

Reply in this exact format:
===SOUL===
<soul.md content: personality, tone, values — 3-5 short paragraphs>
===INSTRUCTIONS===
<instructions.md content: capabilities, constraints, how to approach tasks — bullet points>"""),
            PromptingTools.UserMessage("Agent name: $name\nDescription: $description")
        ]
        result = call_llm(gen_msgs).content
        soul_match = match(r"===SOUL===\s*\n(.*?)===INSTRUCTIONS===\s*\n(.*)"s, result)
        if soul_match !== nothing
            strip(String(soul_match.captures[1])), strip(String(soul_match.captures[2]))
        else
            "# $name\n\n$description", "# Instructions\n\n- $description"
        end
    catch e
        @warn "LLM generation failed for agent $name, using template" exception=e
        "# $name\n\n$description", "# Instructions\n\n- $description"
    end

    write(agent_dir * "soul.md", soul_content)
    write(agent_dir * "instructions.md", instr_content)

    agent = load_agent(agent_dir)
    agent !== nothing && (AGENTS[name] = agent)
    agent
end

"""Delete an agent (prosca cannot be deleted)."""
function delete_agent!(id::String)::Bool
    id == "prosca" && return false
    haskey(AGENTS, id) || return false
    agent = AGENTS[id]
    delete!(AGENTS, id)
    rm(agent.path; recursive=true, force=true)
    true
end

"""Update an agent's soul.md and/or instructions.md, reload from disk."""
function update_agent!(id::String; soul::Union{String,Nothing}=nothing, instructions::Union{String,Nothing}=nothing)::Bool
    haskey(AGENTS, id) || return false
    agent = AGENTS[id]
    soul !== nothing && write(agent.path * "soul.md", soul)
    instructions !== nothing && write(agent.path * "instructions.md", instructions)
    # Reload
    updated = load_agent(agent.path)
    updated !== nothing && (AGENTS[id] = updated)
    true
end

"""Get the default agent."""
function default_agent()::Agent
    get(AGENTS, "prosca", first(values(AGENTS)))
end

"""Merge agent-local skills over global skills. Local wins on name collision."""
function merged_skills(agent::Agent)::Dict{String, Skill}
    merged = copy(SKILLS)
    merge!(merged, agent.skills)
    merged
end
```

- [ ] **Step 2: Add include and initialization to `main.jl`**

After the existing `include("validate_ex.jl")` (line 16), add:
```julia
include("agents.jl")
```

After `load_skills!()` (line 362) and before the MCP section, add:
```julia
# ============= AGENTS =============
migrate_to_agents!()
load_agents!()
```

Keep the existing `PERSONALITY` and `INSTRUCTIONS` constants (line 35-36) — they're still used by CLI/TUI.

- [ ] **Step 3: Verify it loads**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'include("main.jl"); println("Agents: ", join(keys(AGENTS), ", "))'`
Expected: `Agents: prosca` (after migration creates agents/prosca/)

- [ ] **Step 4: Commit**

```bash
git add agents.jl main.jl
git commit -m "feat: add Agent struct, loading, creation, migration"
```

### Task 2: Memory isolation (agent_id on memories)

**Files:**
- Modify: `main.jl:41-55` (add agent_id column to memories schema)
- Modify: `main.jl:184-267` (update MEMORY_INDEXES, rebuild_memory_index, log_memory, search_memories, prune_memories)

- [ ] **Step 1: Add `agent_id` column to memories table**

In `main.jl`, after the existing `conversation_id` migration (line 54), add:
```julia
# Migrate: add agent_id column if missing
try SQLite.execute(DB, "ALTER TABLE memories ADD COLUMN agent_id TEXT DEFAULT 'prosca'") catch end
SQLite.execute(DB, "CREATE INDEX IF NOT EXISTS idx_agent_id ON memories(agent_id);")
```

- [ ] **Step 2: Update MEMORY_INDEXES key type**

Change line 184 from:
```julia
const MEMORY_INDEXES = Dict{Union{String,Nothing}, ChunkIndex}()
```
To:
```julia
const MEMORY_INDEXES = Dict{Tuple{String, Union{String,Nothing}}, ChunkIndex}()
```

- [ ] **Step 3: Update `rebuild_memory_index` to filter by agent_id**

Replace the function (lines 186-208) with:
```julia
function rebuild_memory_index(; agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  query, params = if conversation_id !== nothing
    "SELECT id, content FROM memories WHERE agent_id = ? AND conversation_id = ? ORDER BY timestamp DESC", (agent_id, conversation_id)
  else
    "SELECT id, content FROM memories WHERE agent_id = ? AND conversation_id IS NULL ORDER BY timestamp DESC", (agent_id,)
  end
  rows = map(SQLite.DBInterface.execute(DB, query, params)) do row
    (id=row.id, content=row.content)
  end

  key = (agent_id, conversation_id)
  if isempty(rows)
    @info "No memories yet for agent=$agent_id conversation=$(something(conversation_id, "global"))"
    MEMORY_INDEXES[key] = build_index(["(empty memory)"]; chunker_kwargs=(; sources=["mem-0"]))
    return
  end

  docs = [r.content for r in rows]
  sources = ["mem-$(r.id)" for r in rows]
  MEMORY_INDEXES[key] = build_index(docs; chunker_kwargs=(; sources))
  @info "RAG index rebuilt with $(length(docs)) memories for agent=$agent_id conversation=$(something(conversation_id, "global"))"
end
```

- [ ] **Step 4: Update `log_memory` to include agent_id**

Replace the function (lines 210-219) with:
```julia
function log_memory(text::String; role::String="Agent", metadata=Dict(),
                    agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  emb = get_embedding(text)
  stmt = SQLite.Stmt(DB, """
    INSERT INTO memories (timestamp, role, content, embedding, metadata, agent_id, conversation_id)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  """)
  SQLite.execute(stmt, (Dates.now(Dates.UTC), role, text, emb === nothing ? "" : JSON3.write(emb), JSON3.write(metadata), agent_id, conversation_id))
  rebuild_memory_index(; agent_id, conversation_id)
end
```

- [ ] **Step 5: Update `search_memories` to use agent_id**

Replace the function (lines 221-236) with:
```julia
function search_memories(query::String; limit::Int=5,
                         agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)::String
  key = (agent_id, conversation_id)
  index = get(MEMORY_INDEXES, key, nothing)
  if index === nothing || isempty(index.chunks)
    return "(no memories yet)"
  end
  try
    result = retrieve(index, query; top_k=limit)
    ctx = result.context
    isempty(ctx) && return "(no relevant memories)"
    "=== Relevant past memories ===\n" * join(ctx, "\n\n")
  catch e
    @warn "Memory search failed: $e"
    "(memory search unavailable)"
  end
end
```

- [ ] **Step 6: Update `prune_memories` to filter by agent_id**

Add `agent_id::String="prosca"` parameter to `prune_memories` (line 238). Update its SQL queries to include `AND agent_id = ?` in the WHERE clause, and pass `agent_id` to `rebuild_memory_index` and `log_memory` calls within the function.

- [ ] **Step 7: Update startup memory index build**

Change line 267 from:
```julia
rebuild_memory_index()
```
To:
```julia
# Build indexes for all agents on startup
for agent_id in keys(AGENTS)
    rebuild_memory_index(; agent_id)
end
```

- [ ] **Step 8: Verify it loads**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'include("main.jl"); println("Memory indexes: ", length(MEMORY_INDEXES))'`
Expected: `Memory indexes: 1` (prosca agent, global conversation)

- [ ] **Step 9: Commit**

```bash
git add main.jl
git commit -m "feat: add agent_id to memory system for per-agent isolation"
```

### Task 3: Agent-aware `build_system_prompt` and `_run_agent`

**Files:**
- Modify: `main.jl:374-460` (build_system_prompt gains agent parameter)
- Modify: `main.jl:520-727` (run_agent/_run_agent gain agent parameter, handle handoff)

- [ ] **Step 1: Update `build_system_prompt` to take an Agent**

Change the signature (line 374) from:
```julia
function build_system_prompt(;active_skill::Union{Skill, Nothing}=nothing)::String
```
To:
```julia
function build_system_prompt(agent::Agent; active_skill::Union{Skill, Nothing}=nothing)::String
```

Replace `PERSONALITY` with `agent.personality` and `INSTRUCTIONS` with `agent.instructions` in the string interpolation (line 445-446).

Replace the skill list building (lines 375-383) to use merged skills:
```julia
  all_skills = merged_skills(agent)
  skill_list = if isempty(all_skills)
    ""
  else
    catalog = join(["- /$(s.name): $(s.description)" for s in values(all_skills)], "\n")
    """
    Available skills (use {"skill": "name"} to activate, or user types /name):
    $catalog
    """
  end
```

Add handoff agent listing after the skill list:
```julia
  # Available agents for handoff
  other_agents = [a for a in values(AGENTS) if a.id != agent.id]
  handoff_section = if isempty(other_agents)
    ""
  else
    agent_lines = join(["- $(a.id): $(split(a.personality, '\n')[1])" for a in other_agents], "\n")
    """

    ## Handoff
    You can delegate to another agent if the task is better suited for them:
    $agent_lines

    To hand off: {"handoff": {"to_agent": "agent_id", "reason": "why", "context": "summary"}}
    """
  end
```

Include `handoff_section` in the final string template.

- [ ] **Step 2: Update `run_agent` and `_run_agent` signatures**

Change `run_agent` (line 520) to:
```julia
function run_agent(user_input::String, outbox::Channel, inbox::Channel, agent::Agent;
                   session_history=SESSION_HISTORY, auto_allowed=AUTO_ALLOWED_TOOLS,
                   conversation_id::Union{String,Nothing}=nothing)
```

Change `_run_agent` (line 532) similarly, adding `agent::Agent` parameter.

- [ ] **Step 3: Pass agent_id to memory operations in `_run_agent`**

Update all calls within `_run_agent`:
- `log_memory("User: ..."; role="User", agent_id=agent.id, conversation_id)` (line 535)
- `search_memories(user_input; agent_id=agent.id, conversation_id)` (line 549)
- `build_system_prompt(agent; active_skill)` (line 550)
- `log_memory("Agent: ..."; agent_id=agent.id, conversation_id)` (lines 609, 615)
- `log_memory("Tool: ..."; agent_id=agent.id, conversation_id)` (line 710)

- [ ] **Step 4: Update skill resolution in `_run_agent` to use merged skills**

Change the skill lookup (lines 619-633) from `haskey(SKILLS, sn)` to use merged skills:
```julia
    if haskey(parsed, :skill)
      sn = string(parsed.skill)
      all_skills = merged_skills(agent)
      if haskey(all_skills, sn)
        active_skill = all_skills[sn]
        @info "LLM activated skill: $sn"
        messages[1] = PromptingTools.SystemMessage(build_system_prompt(agent; active_skill))
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Skill '$sn' activated. Proceed with the task using this skill's guidance."))
        continue
      else
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Unknown skill '$sn'. Available: $(join(keys(all_skills), ", "))"))
        continue
      end
    end
```

- [ ] **Step 5: Add handoff handling in the ReAct loop**

After the `skill` handling block (around line 634) and before the `tool` handling, add:
```julia
    if haskey(parsed, :handoff)
      to_agent_id = string(get(parsed.handoff, :to_agent, ""))
      reason = string(get(parsed.handoff, :reason, ""))
      context_summary = string(get(parsed.handoff, :context, ""))

      if !haskey(AGENTS, to_agent_id)
        push!(messages, PromptingTools.AIMessage(response_text))
        available = join([a.id for a in values(AGENTS) if a.id != agent.id], ", ")
        push!(messages, PromptingTools.UserMessage("Unknown agent '$to_agent_id'. Available agents: $available"))
        continue
      end

      # Create handoff conversation in SQLite
      new_conv_id = string(UUIDs.uuid4())
      SQLite.execute(DB, """
        INSERT INTO conversations (id, agent_id, title, handed_off_from, created_at, updated_at)
        VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
      """, (new_conv_id, to_agent_id, "Handoff: $reason", conversation_id))

      # Update current conversation
      if conversation_id !== nothing
        SQLite.execute(DB, "UPDATE conversations SET handed_off_to=?, updated_at=datetime('now') WHERE id=?",
                       (new_conv_id, conversation_id))
      end

      # Emit handoff message
      put!(outbox, AgentMessage("Handing off to **$to_agent_id**: $reason"))
      # The GUI will receive this via handle_events and can show the link
      # We emit a special notification so the GUI knows about the new conversation
      log_memory("Handoff to $to_agent_id: $reason\nContext: $context_summary"; agent_id=agent.id, conversation_id)
      break
    end
```

- [ ] **Step 6: Verify it loads**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'include("main.jl"); a = default_agent(); println(build_system_prompt(a)[1:100])'`
Expected: First 100 chars of the system prompt using the prosca agent's personality.

- [ ] **Step 7: Commit**

```bash
git add main.jl
git commit -m "feat: agent-aware build_system_prompt, _run_agent, and handoff handling"
```

### Task 4: Conversations table and agent/conversation CRUD in json_io.jl

**Files:**
- Modify: `json_io.jl` — Add conversations table, agent CRUD handlers, update GUIConversation, update user_message dispatch

- [ ] **Step 1: Add conversations table to SQLite schema**

In `main.jl`, after the `routine_runs` table creation (around line 109), add:
```julia
SQLite.execute(DB, """
  CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL DEFAULT 'prosca',
    title TEXT NOT NULL DEFAULT 'New chat',
    handed_off_to TEXT,
    handed_off_from TEXT,
    created_at TEXT,
    updated_at TEXT
  );
""")
```

- [ ] **Step 2: Update `GUIConversation` struct in json_io.jl**

Change the struct (lines 17-22) to:
```julia
mutable struct GUIConversation
  history::Vector{PromptingTools.AbstractMessage}
  auto_allowed::Set{String}
  outbox::Channel
  inbox::Channel
  agent_id::String
end
```

Update `get_gui_conversation` (lines 26-30) to:
```julia
function get_gui_conversation(id::String, agent_id::String="prosca")
  get!(GUI_CONVERSATIONS, id) do
    GUIConversation(PromptingTools.AbstractMessage[], Set{String}(), Channel(32), Channel(32), agent_id)
  end
end
```

- [ ] **Step 3: Add agent CRUD handlers**

Add these functions after the existing command handlers section:

```julia
# ── Agent CRUD ───────────────────────────────────────────────────────

function handle_agents_list()
  data = [Dict("id" => a.id) for a in values(AGENTS)]
  # Sort: prosca first, then alphabetical
  sort!(data; by=d -> d["id"] == "prosca" ? "" : d["id"])
  emit(Dict("type" => "agents", "data" => data))
end

function handle_agent_create(msg)
  name = string(get(msg, :name, ""))
  description = string(get(msg, :description, ""))
  isempty(name) && (emit(Dict("type" => "error", "text" => "Agent name required")); return)

  # Validate name (filesystem-safe)
  if !all(c -> isletter(c) || isdigit(c) || c in ('-', '_'), name)
    emit(Dict("type" => "error", "text" => "Agent name must be alphanumeric (hyphens/underscores allowed)")); return
  end

  haskey(AGENTS, name) && (emit(Dict("type" => "error", "text" => "Agent '$name' already exists")); return)

  agent = create_agent!(name, description)
  if agent === nothing
    emit(Dict("type" => "error", "text" => "Failed to create agent '$name'"))
    return
  end
  handle_agents_list()
end

function handle_agent_update(msg)
  id = string(get(msg, :id, ""))
  isempty(id) && return
  soul = let v = get(msg, :soul, nothing); v === nothing ? nothing : string(v) end
  instructions = let v = get(msg, :instructions, nothing); v === nothing ? nothing : string(v) end
  update_agent!(id; soul, instructions)
  handle_agents_list()
end

function handle_agent_delete(msg)
  id = string(get(msg, :id, ""))
  if id == "prosca"
    emit(Dict("type" => "error", "text" => "Cannot delete the default agent")); return
  end
  if !delete_agent!(id)
    emit(Dict("type" => "error", "text" => "Agent '$id' not found")); return
  end
  handle_agents_list()
end
```

- [ ] **Step 4: Add conversation CRUD handlers**

```julia
# ── Conversation CRUD ────────────────────────────────────────────────

function handle_conversations_list()
  rows = SQLite.DBInterface.execute(DB, """
    SELECT * FROM conversations ORDER BY updated_at DESC
  """) |> SQLite.rowtable
  data = [Dict(
    "id" => r.id, "agent_id" => r.agent_id, "title" => r.title,
    "handed_off_to" => something(r.handed_off_to, nothing),
    "handed_off_from" => something(r.handed_off_from, nothing),
    "created_at" => r.created_at, "updated_at" => r.updated_at
  ) for r in rows]
  emit(Dict("type" => "conversations", "data" => data))
end

function handle_conversation_create(msg)
  agent_id = string(get(msg, :agent_id, "prosca"))
  haskey(AGENTS, agent_id) || (emit(Dict("type" => "error", "text" => "Unknown agent '$agent_id'")); return)

  id = string(UUIDs.uuid4())
  SQLite.execute(DB, """
    INSERT INTO conversations (id, agent_id, title, created_at, updated_at)
    VALUES (?, ?, 'New chat', datetime('now'), datetime('now'))
  """, (id, agent_id))
  handle_conversations_list()
end

function handle_conversation_delete(msg)
  id = string(get(msg, :id, ""))
  SQLite.execute(DB, "DELETE FROM conversations WHERE id=?", (id,))
  handle_conversations_list()
end

function handle_conversation_update_title(msg)
  id = string(get(msg, :id, ""))
  title = string(get(msg, :title, ""))
  SQLite.execute(DB, "UPDATE conversations SET title=?, updated_at=datetime('now') WHERE id=?", (title, id))
  handle_conversations_list()
end
```

- [ ] **Step 5: Update `user_message` handler to use agent_id**

In the main loop, update the `user_message` handler (around line 730-744) to extract `agent_id` and pass it through:

```julia
    if msg_type == "user_message"
      text = string(get(msg, :text, ""))
      agent_id = string(get(msg, :agent_id, "prosca"))
      last_user_activity_at[] = now(Dates.UTC)
      agent = get(AGENTS, agent_id, default_agent())
      conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id, agent_id)
      @async begin
        lock(AGENT_LOCK)
        try
          run_agent(text, conv.outbox, conv.inbox, agent;
                    session_history=conv.history, auto_allowed=conv.auto_allowed,
                    conversation_id=conv_id)
        finally
          unlock(AGENT_LOCK)
        end
      end
      @async handle_events(conv.outbox; conversation_id=conv_id)
```

- [ ] **Step 6: Add message type handlers to the main loop**

In the main loop's `elseif` chain (around line 808), add:

```julia
    elseif msg_type == "agents_list"
      handle_agents_list()
    elseif msg_type == "agent_create"
      @async handle_agent_create(msg)
    elseif msg_type == "agent_update"
      handle_agent_update(msg)
    elseif msg_type == "agent_delete"
      handle_agent_delete(msg)
    elseif msg_type == "conversations_list"
      handle_conversations_list()
    elseif msg_type == "conversation_create"
      handle_conversation_create(msg)
    elseif msg_type == "conversation_delete"
      handle_conversation_delete(msg)
    elseif msg_type == "conversation_update_title"
      handle_conversation_update_title(msg)
```

- [ ] **Step 7: Update Telegram inbound handler to pass agent**

The gateway's `_inbound_handler` in `json_io.jl` (around line 778) calls `run_agent` without an agent parameter. Update it to resolve the agent from the conversation's `agent_id`:

```julia
    agent = get(AGENTS, conv.agent_id, default_agent())
    run_agent(text, conv.outbox, conv.inbox, agent;
              session_history=conv.history, auto_allowed=conv.auto_allowed,
              conversation_id=conv_id)
```

Also update `handle_conversation_delete` to clean up `GUI_CONVERSATIONS`:
```julia
function handle_conversation_delete(msg)
  id = string(get(msg, :id, ""))
  SQLite.execute(DB, "DELETE FROM conversations WHERE id=?", (id,))
  delete!(GUI_CONVERSATIONS, id)  # clean up in-memory state
  handle_conversations_list()
end
```

- [ ] **Step 8: Emit initial agents list after ready signal**

After the existing `emit(Dict("type" => "ready"))` line, add:
```julia
handle_agents_list()
handle_conversations_list()
```

- [ ] **Step 9: Verify it loads**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'try; include("json_io.jl"); catch e; println(sprint(showerror, e)); end' 2>&1 | head -10`
Expected: `PROSCA:{"type":"agents",...}` in the output (no syntax errors)

- [ ] **Step 10: Commit**

```bash
git add main.jl json_io.jl
git commit -m "feat: conversation persistence, agent/conversation CRUD handlers"
```

---

## Chunk 2: Frontend — Agent Context, Sidebar, and Agents Page

### Task 5: Frontend types and AgentContext

**Files:**
- Modify: `gui/src/types/conversation.ts`
- Modify: `gui/src/types/sidecar.ts`
- Create: `gui/src/contexts/AgentContext.tsx`

- [ ] **Step 1: Update Conversation type**

In `gui/src/types/conversation.ts`, replace the interface:
```typescript
import type { ChatMessage } from "./message";

export interface Conversation {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
  busy?: boolean;
  agentId: string;
  handedOffTo?: string;
  handedOffFrom?: string;
}
```

- [ ] **Step 2: Add agent types to sidecar.ts**

In `gui/src/types/sidecar.ts`, add to the `SidecarEvent` union:
```typescript
| { type: "agents"; data: AgentInfo[] }
| { type: "conversations"; data: ConversationInfo[] }
```

And add the interfaces:
```typescript
export interface AgentInfo {
  id: string;
}

export interface ConversationInfo {
  id: string;
  agent_id: string;
  title: string;
  handed_off_to?: string | null;
  handed_off_from?: string | null;
  created_at: string;
  updated_at: string;
}
```

- [ ] **Step 3: Create AgentContext**

Create `gui/src/contexts/AgentContext.tsx`:
```typescript
import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from "react";
import { useSidecar } from "./SidecarContext";
import type { AgentInfo } from "@/types/sidecar";

interface AgentContextValue {
  agents: AgentInfo[];
  createAgent: (name: string, description: string) => void;
  deleteAgent: (id: string) => void;
  updateAgent: (id: string, soul: string, instructions: string) => void;
  refreshAgents: () => void;
}

const AgentContext = createContext<AgentContextValue | null>(null);

export function AgentProvider({ children }: { children: ReactNode }) {
  const { send, onEvent } = useSidecar();
  const [agents, setAgents] = useState<AgentInfo[]>([]);

  useEffect(() => {
    return onEvent((event) => {
      if (event.type === "agents") {
        setAgents(event.data);
      }
    });
  }, [onEvent]);

  useEffect(() => {
    send({ type: "agents_list" });
  }, [send]);

  const createAgent = useCallback((name: string, description: string) => {
    send({ type: "agent_create", name, description });
  }, [send]);

  const deleteAgent = useCallback((id: string) => {
    send({ type: "agent_delete", id });
  }, [send]);

  const updateAgent = useCallback((id: string, soul: string, instructions: string) => {
    send({ type: "agent_update", id, soul, instructions });
  }, [send]);

  const refreshAgents = useCallback(() => {
    send({ type: "agents_list" });
  }, [send]);

  return (
    <AgentContext.Provider value={{ agents, createAgent, deleteAgent, updateAgent, refreshAgents }}>
      {children}
    </AgentContext.Provider>
  );
}

export function useAgents() {
  const ctx = useContext(AgentContext);
  if (!ctx) throw new Error("useAgents must be used within AgentProvider");
  return ctx;
}
```

- [ ] **Step 4: Update ConversationContext to be backend-driven**

Rewrite `gui/src/contexts/ConversationContext.tsx` to:
- Listen for `"conversations"` events from the backend
- Map `ConversationInfo` from backend into `Conversation` objects (messages stay in local state)
- `createConversation` sends `conversation_create` to backend
- `deleteConversation` sends `conversation_delete` to backend
- `renameConversation` sends `conversation_update_title` to backend
- Keep `messages`, `busy`, `appendMessage`, `saveMessages` as local state (keyed by conversation id)

- [ ] **Step 5: Add AgentProvider to App.tsx provider tree**

In `gui/src/App.tsx`, wrap with `AgentProvider` in the provider tree (after `SidecarProvider`, before `ConversationProvider`).

Add `"agents"` to the `Page` type union and add the nav item.

- [ ] **Step 6: Type check**

Run: `cd /Users/jake/Prosca/gui && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 7: Commit**

```bash
git add src/types/ src/contexts/AgentContext.tsx src/contexts/ConversationContext.tsx src/App.tsx
git commit -m "feat(gui): add AgentContext, backend-driven conversations, agent types"
```

### Task 6: Sidebar restructure — agent-grouped conversations

**Files:**
- Modify: `gui/src/components/layout/Sidebar.tsx`

- [ ] **Step 1: Restructure sidebar conversations section**

Replace the flat "Chat" section with an agent-grouped tree. Import `useAgents`. Group `conversations` by `agentId`. For each agent, show the agent name + `[+]` button, then indented conversations underneath. `prosca` sorts first, then alphabetical.

The `handleNewChat` function now takes an `agentId` parameter and calls `createConversation` with it.

Also update the `Page` type in `Sidebar.tsx` (line 7) to include `"agents"` and add the Agents nav item (with a `Bot` or `Users` icon from lucide-react).

- [ ] **Step 2: Verify visually**

Start the app with `npm run tauri dev`, navigate to the sidebar. Should see agents with conversations grouped underneath.

- [ ] **Step 3: Commit**

```bash
git add src/components/layout/Sidebar.tsx
git commit -m "feat(gui): restructure sidebar with agent-grouped conversations"
```

### Task 7: Agents management page

**Files:**
- Create: `gui/src/pages/AgentsPage.tsx`

- [ ] **Step 1: Create AgentsPage**

A page following the same pattern as ProjectsPage/SettingsPage:
- List all agents
- "Create Agent" button opens a form (name + description)
- Each agent card shows the id, with Edit and Delete buttons
- Edit opens text areas for soul.md and instructions.md
- Delete disabled for `prosca`, shows confirmation for others
- Uses `useAgents()` hook for CRUD

- [ ] **Step 2: Wire into App.tsx routing**

Add the `AgentsPage` to the page routing in `App.tsx`.

- [ ] **Step 3: Type check and verify**

Run: `cd /Users/jake/Prosca/gui && npx tsc --noEmit`
Start app, navigate to Agents page, create/edit/delete agents.

- [ ] **Step 4: Commit**

```bash
git add src/pages/AgentsPage.tsx src/App.tsx
git commit -m "feat(gui): add Agents management page"
```

### Task 8: Send agent_id with user messages

**Files:**
- Modify: `gui/src/contexts/ChatContext.tsx`

- [ ] **Step 1: Update sendMessage to include agent_id**

The `sendMessage` function needs to look up the active conversation's `agentId` and include it in the `user_message` sent to the backend:
```typescript
send({
  type: "user_message",
  text,
  conversation_id: activeId,
  agent_id: activeConversation?.agentId ?? "prosca",
});
```

- [ ] **Step 2: Type check**

Run: `cd /Users/jake/Prosca/gui && npx tsc --noEmit`

- [ ] **Step 3: Commit**

```bash
git add src/contexts/ChatContext.tsx
git commit -m "feat(gui): send agent_id with user messages"
```
