# ═══════════════════════════════════════════════════════════════════════
# Prosca JSON I/O — stdin/stdout bridge for the GUI (Tauri sidecar)
#
# Protocol: newline-delimited JSON on stdin/stdout.
# All output lines are prefixed with "PROSCA:" so the Rust sidecar
# can filter them from Julia noise.
# ═══════════════════════════════════════════════════════════════════════

@use "github.com/jkroso/LLM.jl" LLM
@use "github.com/jkroso/LLM.jl/providers/abstract_provider" Message SystemMessage UserMessage AIMessage Image Audio Document
@use "github.com/jkroso/LLM.jl/models" search
@use "github.com/jkroso/JSON.jl" parse_json write_json
@use "./gateway/telegram"...
@use "./scheduler"...
@use "."...
@use Base64...
@use SQLite
@use Dates...
@use UUIDs
@use YAML

const last_user_activity_at = Ref{DateTime}(now(Dates.UTC))

mutable struct GUIConversation
  history::Vector{Message}
  auto_allowed::Set{String}
  agent_id::String
end

const GUI_CONVERSATIONS = Dict{String, GUIConversation}()

function get_gui_conversation(id::String, agent_id::String="prosca")
  get!(GUI_CONVERSATIONS, id) do
    GUIConversation(Message[], Set{String}(), agent_id)
  end
end

# Map tool-call ID → per-message approvals channel (for direct GUI approvals without gateway)
const PENDING_GUI_APPROVALS = Dict{UInt64, Channel}()

"User-facing error — caught by the dispatch loop and sent to the frontend"
struct UserError <: Exception
  msg::String
end

# ── Output helpers ────────────────────────────────────────────────────

function emit(obj; conversation_id::Union{String,Nothing}=nothing)
  if conversation_id !== nothing
    obj["conversation_id"] = conversation_id
  end
  println("PROSCA:", write_json(obj))
  flush(stdout)
end

"Emit a response to an RPC request, attaching the request id"
function reply(msg, result::Dict)
  id = get(msg, "id", nothing)
  if id !== nothing
    result["id"] = id
  end
  emit(result)
end

# ── Drain agent events and emit as JSON ──────────────────────────────

function handle_events(outbox::Channel; conversation_id::Union{String,Nothing}=nothing, approvals::Channel)
  while true
    event = take!(outbox)
    if event isa StreamToken
      emit(Dict("type" => "stream_token", "text" => event.text); conversation_id)
    elseif event isa AgentMessage
      emit(Dict("type" => "agent_message", "text" => event.text); conversation_id)
    elseif event isa ToolCallRequest
      if !isempty(ROUTER.active_adapters)
        @async route_approval(ROUTER, event, approvals; conversation_id)
      else
        PENDING_GUI_APPROVALS[event.id] = approvals
        emit(Dict("type" => "tool_call_request", "id" => string(event.id), "name" => event.name, "args" => event.args); conversation_id)
      end
    elseif event isa ToolResult
      emit(Dict("type" => "tool_result", "name" => event.name, "args" => event.args, "result" => event.result); conversation_id)
    elseif event isa AgentDone
      d = Dict{String,Any}("type" => "agent_done")
      (event.input_tokens > 0 || event.output_tokens > 0) && (d["input_tokens"] = event.input_tokens; d["output_tokens"] = event.output_tokens)
      emit(d; conversation_id)
      break
    end
  end
end

# ── Command handlers ─────────────────────────────────────────────────

handle(::Val{:config_get}, msg) = Dict("type" => "config", "data" => CONFIG)

function handle(::Val{:config_set}, msg)
  key, value = string(msg["key"]), msg["value"]
  CONFIG[key] = value
  YAML.write_file(string(HOME * "config.yaml"), CONFIG)
  if key == "llm"
    for (_, agent) in AGENTS
      agent.llm = LLM(string(value), CONFIG)
    end
  end
  Dict("type" => "config", "data" => CONFIG)
end

function handle(::Val{:skills_list}, msg)
  skills = [Dict("name" => s.name, "description" => s.description, "file" => "") for s in values(SKILLS)]
  Dict("type" => "skills", "data" => skills)
end

function handle(::Val{:commands_list}, msg)
  cmds = [Dict("name" => c.name, "description" => c.description) for c in values(COMMANDS)]
  Dict("type" => "commands", "data" => cmds)
end

function handle(::Val{:slash_completions}, msg)
  items = vcat(
    [Dict("name" => c.name, "description" => c.description, "kind" => "command") for c in values(COMMANDS)],
    [Dict("name" => s.name, "description" => s.description, "kind" => "skill") for s in values(SKILLS)]
  )
  sort!(items; by=i->i["name"])
  Dict("type" => "slash_completions", "data" => items)
end

handle(::Val{:model_search}, msg) = @async begin
  allowed = get(CONFIG, "providers", nothing)
  allowed_ids = allowed isa Vector ? union(string.(allowed), ["ollama"]) : String[]
  query = string(get(msg, "query", ""))
  results = if contains(query, '/')
    parts = split(query, '/'; limit=2)
    search(string(parts[1]), string(parts[2]); max_results=100, allowed_providers=allowed_ids)
  else
    search(query; max_results=100, allowed_providers=allowed_ids)
  end
  unique!(m -> "$(m.provider)/$(m.id)", results)
  data = map(results) do m
    p = m.pricing
    cost = (p[1].value == 0 && p[2].value == 0) ? nothing :
           Dict("input" => round(Float64(p[1].value), digits=2),
                "output" => round(Float64(p[2].value), digits=2))
    logo = try "data:image/svg+xml;base64," * base64encode(read(m.logo)) catch; nothing end
    Dict{String,Any}("id" => m.id, "name" => m.name, "provider" => m.provider,
                      "reasoning" => m.reasoning, "tool_call" => m.tool_call,
                      "context" => m.context, "cost" => cost, "logo" => logo,
                      "modalities" => Dict("input" => m.modalities.input, "output" => m.modalities.output))
  end
  Dict("type" => "model_search_results", "data" => data, "query" => query)
end


function handle(::Val{:reset}, msg)
  conv_id = let v = get(msg, "conversation_id", nothing); v === nothing ? nothing : string(v) end
  if conv_id !== nothing && haskey(GUI_CONVERSATIONS, conv_id)
    conv = GUI_CONVERSATIONS[conv_id]
    empty!(conv.history)
    empty!(conv.auto_allowed)
  else
    empty!(default_agent().history)
    empty!(AUTO_ALLOWED_TOOLS)
  end
  nothing
end

handle(::Val{:generate_title}, msg) = @async begin
  text = string(get(msg, "text", ""))
  messages = Message[
    SystemMessage("Generate a short chat title (3-6 words, no quotes, no punctuation) that summarizes the user's message. Reply with ONLY the title, nothing else."),
    UserMessage(text)
  ]
  title = strip(llm_generate(messages))
  Dict{String,Any}("type" => "title", "title" => title)
end

function handle(::Val{:restore_context}, msg)
  conv_id = let v = get(msg, "conversation_id", nothing); v === nothing ? nothing : string(v) end
  messages = get(msg, "messages", [])
  history = if conv_id !== nothing
    conv = get_gui_conversation(conv_id)
    empty!(conv.auto_allowed)
    conv.history
  else
    empty!(AUTO_ALLOWED_TOOLS)
    default_agent().history
  end
  empty!(history)
  for m in messages
    role = string(get(m, "role", ""))
    text = string(get(m, "text", ""))
    if role == "user"
      push!(history, UserMessage(text))
    elseif role == "agent"
      push!(history, AIMessage(text))
    end
  end
  # Keep only the last 20 entries (10 exchange pairs) like _process_message does
  if length(history) > 20
    splice!(history, 1:length(history)-20)
  end
  nothing
end

# ── Project CRUD ─────────────────────────────────────────────────────

function handle(::Val{:projects_list}, msg)
  rows = SQLite.DBInterface.execute(DB[], """
    SELECT p.*, (SELECT COUNT(*) FROM routines WHERE project_id=p.id) as routine_count
    FROM projects p ORDER BY is_default DESC, name ASC
  """) |> SQLite.rowtable
  data = [Dict(
    "id" => r.id, "name" => r.name, "path" => r.path,
    "is_default" => r.is_default == 1, "paused" => something(r.paused, 0) == 1,
    "model" => something(r.model, nothing),
    "idle_check_mins" => r.idle_check_mins, "tokens_used" => r.tokens_used,
    "cost_usd" => r.cost_usd, "last_checked_at" => something(r.last_checked_at, nothing),
    "created_at" => r.created_at, "routine_count" => r.routine_count
  ) for r in rows]
  Dict("type" => "projects", "data" => data)
end

function handle(::Val{:project_create}, msg)
  name = string(get(msg, "name", ""))
  path = string(get(msg, "path", ""))
  model = let v = get(msg, "model", nothing); v === nothing ? nothing : string(v) end
  idle_mins = get(msg, "idle_check_mins", 30)

  isempty(name) && throw(UserError("Project name required"))
  isempty(path) && throw(UserError("Project path required"))

  path = endswith(path, "/") ? path : path * "/"
  mkpath(path)

  if !isfile(joinpath(path, "Project.md"))
    write(joinpath(path, "Project.md"), "# $name\n\n## Goals\n\n- \n")
  end

  id = string(UUIDs.uuid4())
  SQLite.execute(DB[], """
    INSERT INTO projects (id, name, path, model, idle_check_mins, created_at)
    VALUES (?, ?, ?, ?, ?, datetime('now'))
  """, (id, name, path, model, idle_mins))

  # Create Telegram topic for new project if gateway is active
  adapter = primary_adapter(ROUTER)
  if adapter !== nothing && adapter isa TelegramAdapter
    try ensure_project_topic!(adapter, id, name) catch e
      @warn "Failed to create Telegram topic for new project" exception=e
    end
  end

  handle(Val(:projects_list), msg)
end

function handle(::Val{:project_update}, msg)
  id = string(get(msg, "id", ""))
  isempty(id) && return nothing

  sets = String[]
  vals = Any[]
  for (key, col) in [(:name, "name"), (:model, "model"), (:idle_check_mins, "idle_check_mins"), (:paused, "paused")]
    v = get(msg, key, nothing)
    if v !== nothing
      push!(sets, "$col=?")
      val = if key == :model && v == ""
        nothing
      elseif key == :paused
        v == true || v == 1 ? 1 : 0
      else
        v
      end
      push!(vals, val)
    end
  end
  isempty(sets) && return nothing
  push!(vals, id)
  SQLite.execute(DB[], "UPDATE projects SET $(join(sets, ", ")) WHERE id=?", vals)
  handle(Val(:projects_list), msg)
end

function handle(::Val{:project_delete}, msg)
  id = string(get(msg, "id", ""))
  rows = SQLite.DBInterface.execute(DB[], "SELECT is_default FROM projects WHERE id=?", (id,)) |> SQLite.rowtable
  length(rows) > 0 && rows[1].is_default == 1 && throw(UserError("Cannot delete the default project"))
  SQLite.execute(DB[], "DELETE FROM routine_runs WHERE project_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM routines WHERE project_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM projects WHERE id=?", (id,))
  handle(Val(:projects_list), msg)
end

# ── Routine CRUD ─────────────────────────────────────────────────────

function handle(::Val{:routines_list}, msg)
  project_id = let v = get(msg, "project_id", nothing); v === nothing ? nothing : string(v) end
  query = if project_id !== nothing
    SQLite.DBInterface.execute(DB[], """
      SELECT r.*, p.name as project_name FROM routines r
      JOIN projects p ON r.project_id = p.id
      WHERE r.project_id=? ORDER BY r.created_at
    """, (project_id,))
  else
    SQLite.DBInterface.execute(DB[], """
      SELECT r.*, p.name as project_name FROM routines r
      JOIN projects p ON r.project_id = p.id
      ORDER BY p.is_default DESC, p.name, r.created_at
    """)
  end
  rows = query |> SQLite.rowtable
  data = [Dict(
    "id" => r.id, "project_id" => r.project_id, "project_name" => r.project_name,
    "name" => r.name, "prompt" => r.prompt, "model" => something(r.model, nothing),
    "schedule_natural" => something(r.schedule_natural, nothing),
    "schedule_cron" => something(r.schedule_cron, nothing),
    "enabled" => r.enabled == 1, "tokens_used" => r.tokens_used,
    "cost_usd" => r.cost_usd, "last_run_at" => something(r.last_run_at, nothing),
    "next_run_at" => something(r.next_run_at, nothing),
    "created_at" => r.created_at
  ) for r in rows]
  Dict("type" => "routines", "data" => data)
end

function handle(::Val{:routine_create}, msg)
  project_id = string(get(msg, "project_id", ""))
  prompt = string(get(msg, "prompt", ""))
  schedule_natural = string(get(msg, "schedule_natural", ""))
  model = let v = get(msg, "model", nothing); v === nothing ? nothing : string(v) end

  isempty(project_id) && throw(UserError("Project required"))
  isempty(prompt) && throw(UserError("Routine prompt required"))

  # Generate name + parse schedule in a single LLM call
  gen_prompt = """Given this routine prompt, generate a short name (2-5 words) for it."""
  if !isempty(schedule_natural)
    gen_prompt *= """

Also convert this schedule to a standard 5-field cron expression.

Reply in this exact format (two lines):
NAME: <short name>
CRON: <cron expression>

Examples:
- "every morning at 8am" → CRON: 0 8 * * *
- "every 2 hours" → CRON: 0 */2 * * *
- "weekday mornings at 9" → CRON: 0 9 * * 1-5

Schedule: $schedule_natural"""
  else
    gen_prompt *= """

Reply in this exact format (one line):
NAME: <short name>"""
  end
  gen_prompt *= "\n\nPrompt: $prompt"

  gen_msgs = [SystemMessage("You generate short names for tasks and convert schedules to cron. Reply only in the requested format."),
              UserMessage(gen_prompt)]
  result = try
    llm_generate(gen_msgs)
  catch e
    throw(UserError("Failed to generate routine: $(sprint(showerror, e))"))
  end

  # Parse response
  name = prompt[1:min(40, length(prompt))]  # fallback
  schedule_cron = nothing
  next_run = nothing
  for line in split(strip(result), '\n')
    line = strip(line)
    if startswith(line, "NAME:")
      name = strip(line[6:end])
    elseif startswith(line, "CRON:")
      schedule_cron = strip(line[6:end])
    end
  end

  if schedule_cron !== nothing
    try
      next_run = string(next_cron_time_utc(schedule_cron, now(Dates.UTC)))
    catch e
      throw(UserError("Invalid cron expression '$schedule_cron': $(sprint(showerror, e))"))
    end
  end

  id = string(UUIDs.uuid4())
  SQLite.execute(DB[], """
    INSERT INTO routines (id, project_id, name, prompt, model, schedule_natural, schedule_cron, next_run_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
  """, (id, project_id, name, prompt, model, schedule_natural, schedule_cron, next_run))

  handle(Val(:routines_list), msg)
end

function handle(::Val{:routine_update}, msg)
  id = string(get(msg, "id", ""))
  isempty(id) && return

  sets = String[]
  vals = Any[]
  for (key, col) in [(:name, "name"), (:prompt, "prompt"), (:model, "model"), (:enabled, "enabled")]
    v = get(msg, key, nothing)
    if v !== nothing
      push!(sets, "$col=?")
      push!(vals, key == :enabled ? (v ? 1 : 0) : (key == :model && v == "" ? nothing : v))
    end
  end

  schedule_natural = get(msg, "schedule_natural", nothing)
  if schedule_natural !== nothing
    sn = string(schedule_natural)
    push!(sets, "schedule_natural=?")
    push!(vals, sn)
    if !isempty(sn)
      parse_msgs = [SystemMessage("You convert schedules to cron. Reply with only the cron expression."),
                    UserMessage("Convert to cron: $sn")]
      cron_str = strip(llm_generate(parse_msgs))
      push!(sets, "schedule_cron=?")
      push!(vals, cron_str)
      next_run = string(next_cron_time_utc(cron_str, now(Dates.UTC)))
      push!(sets, "next_run_at=?")
      push!(vals, next_run)
    end
  end

  isempty(sets) && return
  push!(vals, id)
  SQLite.execute(DB[], "UPDATE routines SET $(join(sets, ", ")) WHERE id=?", vals)
  handle(Val(:routines_list), msg)
end

function handle(::Val{:routine_delete}, msg)
  id = string(get(msg, "id", ""))
  SQLite.execute(DB[], "DELETE FROM routine_runs WHERE routine_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM routines WHERE id=?", (id,))
  handle(Val(:routines_list), msg)
end

function handle(::Val{:routine_runs_list}, msg)
  project_id = let v = get(msg, "project_id", nothing); v === nothing ? nothing : string(v) end
  unseen_only = get(msg, "unseen_only", false)

  conditions = String[]
  params = Any[]
  project_id !== nothing && (push!(conditions, "project_id=?"); push!(params, project_id))
  unseen_only && (push!(conditions, "notable=1 AND seen=0"))

  where = isempty(conditions) ? "" : "WHERE " * join(conditions, " AND ")
  rows = SQLite.DBInterface.execute(DB[],
    "SELECT * FROM routine_runs $where ORDER BY started_at DESC LIMIT 100", params) |> SQLite.rowtable

  data = [Dict(
    "id" => r.id, "routine_id" => something(r.routine_id, nothing),
    "project_id" => r.project_id, "started_at" => r.started_at,
    "finished_at" => r.finished_at, "result" => r.result,
    "tokens_used" => r.tokens_used, "cost_usd" => r.cost_usd,
    "notable" => r.notable == 1, "seen" => r.seen == 1
  ) for r in rows]
  Dict("type" => "routine_runs", "data" => data)
end

function handle(::Val{:routine_runs_mark_seen}, msg)
  ids = get(msg, "ids", [])
  for id in ids
    SQLite.execute(DB[], "UPDATE routine_runs SET seen=1 WHERE id=?", (id,))
  end
  count = unseen_notable_count(DB[])
  Dict("type" => "unseen_count", "count" => count)
end

# ── Agent CRUD ───────────────────────────────────────────────────────

function handle(::Val{:agents_list}, msg)
  data = [Dict("id" => a.id) for a in values(AGENTS)]
  sort!(data; by=d -> d["id"] == "prosca" ? "" : d["id"])
  Dict("type" => "agents", "data" => data)
end

handle(::Val{:agent_create}, msg) = @async begin
  name = string(get(msg, "name", ""))
  description = string(get(msg, "description", ""))
  isempty(name) && throw(UserError("Agent name required"))
  all(c -> isletter(c) || isdigit(c) || c in ('-', '_'), name) || throw(UserError("Agent name must be alphanumeric (hyphens/underscores allowed)"))
  haskey(AGENTS, name) && throw(UserError("Agent '$name' already exists"))
  agent = create_agent!(name, description)
  agent === nothing && throw(UserError("Failed to create agent '$name'"))
  handle(Val(:agents_list), Dict())
end

function handle(::Val{:agent_update}, msg)
  id = string(get(msg, "id", ""))
  isempty(id) && return nothing
  soul = let v = get(msg, "soul", nothing); v === nothing ? nothing : string(v) end
  instructions = let v = get(msg, "instructions", nothing); v === nothing ? nothing : string(v) end
  update_agent!(id; soul, instructions)
  handle(Val(:agents_list), Dict())
end

function handle(::Val{:agent_delete}, msg)
  id = string(get(msg, "id", ""))
  id == "prosca" && throw(UserError("Cannot delete the default agent"))
  delete_agent!(id) || throw(UserError("Agent '$id' not found"))
  handle(Val(:agents_list), Dict())
end

# ── Conversation CRUD ────────────────────────────────────────────────

function handle(::Val{:conversations_list}, msg)
  rows = SQLite.DBInterface.execute(DB[], """
    SELECT * FROM conversations ORDER BY updated_at DESC
  """) |> SQLite.rowtable
  data = [Dict(
    "id" => r.id, "agent_id" => r.agent_id, "title" => r.title,
    "handed_off_to" => something(r.handed_off_to, nothing),
    "handed_off_from" => something(r.handed_off_from, nothing),
    "created_at" => r.created_at, "updated_at" => r.updated_at,
    "messages" => let m = something(r.messages, "[]"); try parse_json(m) catch; [] end end
  ) for r in rows]
  Dict("type" => "conversations", "data" => data)
end

function handle(::Val{:conversation_save_messages}, msg)
  id = string(get(msg, "conversation_id", ""))
  messages = get(msg, "messages", [])
  SQLite.execute(DB[], "UPDATE conversations SET messages=?, updated_at=datetime('now') WHERE id=?",
                 (write_json(messages), id))
  nothing
end

function handle(::Val{:conversation_create}, msg)
  agent_id = string(get(msg, "agent_id", "prosca"))
  haskey(AGENTS, agent_id) || throw(UserError("Unknown agent '$agent_id'"))
  id = string(UUIDs.uuid4())
  SQLite.execute(DB[], """
    INSERT INTO conversations (id, agent_id, title, created_at, updated_at)
    VALUES (?, ?, 'New chat', datetime('now'), datetime('now'))
  """, (id, agent_id))
  handle(Val(:conversations_list), Dict())
end

function handle(::Val{:conversation_delete}, msg)
  id = string(get(msg, "conversation_id", ""))
  SQLite.execute(DB[], "DELETE FROM conversations WHERE id=?", (id,))
  delete!(GUI_CONVERSATIONS, id)
  handle(Val(:conversations_list), Dict())
end

function handle(::Val{:conversation_update_title}, msg)
  id = string(get(msg, "conversation_id", ""))
  title = string(get(msg, "title", ""))
  SQLite.execute(DB[], "UPDATE conversations SET title=?, updated_at=datetime('now') WHERE id=?", (title, id))
  handle(Val(:conversations_list), Dict())
end

# ── Message handlers (inline) ────────────────────────────────────────

function handle(::Val{:user_message}, msg)
  text = string(get(msg, "text", ""))
  agent_id = string(get(msg, "agent_id", "prosca"))
  conv_id = let v = get(msg, "conversation_id", nothing); v === nothing ? nothing : string(v) end
  last_user_activity_at[] = now(Dates.UTC)
  # Intercept /commands (skills go through to the agent which handles them in process_message)
  if startswith(text, "/") && !startswith(text, "//")
    parts = split(text, limit=2)
    cmd_name = parts[1][2:end]
    if haskey(COMMANDS, cmd_name)
      cmd_args = length(parts) > 1 ? strip(String(parts[2])) : ""
      result = try COMMANDS[cmd_name].fn(cmd_args) catch e "Command error: $(sprint(showerror, e))" end
      return Dict("type" => "command_result", "name" => cmd_name, "result" => string(result))
    end
    # Not a command — fall through to agent (may be a skill like /browser)
  end
  agent = get(AGENTS, agent_id, default_agent())
  conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id, agent_id)
  # Parse file attachments
  images = Image[]
  audio_files = Audio[]
  docs = Document[]
  for att in get(msg, "attachments", [])
    mime = string(get(att, "mime", ""))
    data = base64decode(string(get(att, "data", "")))
    if startswith(mime, "image/")
      push!(images, ImageData(data, mime))
    elseif startswith(mime, "audio/")
      fmt = split(mime, '/')[2]
      push!(audio_files, Audio(data, fmt))
    else
      push!(docs, Document(data, mime))
    end
  end
  outbox = Channel(32)
  approvals = Channel(32)
  put!(agent.inbox, Envelope(text; outbox, approvals, auto_allowed=conv.auto_allowed,
                             conversation_id=conv_id, images, audio=audio_files, documents=docs))
  @async handle_events(outbox; conversation_id=conv_id, approvals)
end

function handle(::Val{:tool_approval}, msg)
  id = parse(UInt64, string(get(msg, "id", "0")))
  decision_str = string(get(msg, "decision", "deny"))
  decision = if decision_str == "allow"
    :allow
  elseif decision_str == "always"
    :always
  else
    :deny
  end
  if !isempty(ROUTER.active_adapters)
    resolve_approval(ROUTER, id, decision, :gui)
  elseif haskey(PENDING_GUI_APPROVALS, id)
    put!(PENDING_GUI_APPROVALS[id], ToolApproval(id, decision))
    delete!(PENDING_GUI_APPROVALS, id)
  end
  nothing
end

function handle(::Val{:command}, msg)
  cmd_name = string(get(msg, "name", ""))
  cmd_args = string(get(msg, "args", ""))
  haskey(COMMANDS, cmd_name) || throw(UserError("Unknown command: $cmd_name"))
  result = try
    COMMANDS[cmd_name].fn(cmd_args)
  catch e
    "Command error: $(sprint(showerror, e))"
  end
  Dict("type" => "command_result", "name" => cmd_name, "result" => string(result))
end

# Fallback for unknown message types
handle(::Val, msg) = throw(UserError("Unknown message type: $(get(msg, "type", ""))"))

# ── Scheduler ─────────────────────────────────────────────────────────

function scheduler_tick!()
  try
    _scheduler_tick!()
  catch e
    @error "Scheduler tick error" exception=(e, catch_backtrace())
  end
end

function _scheduler_tick!()
  now_utc = now(Dates.UTC)

  # 1. Run due routines
  due = SQLite.DBInterface.execute(DB[], """
    SELECT r.*, p.path as project_path, p.model as project_model
    FROM routines r JOIN projects p ON r.project_id = p.id
    WHERE r.enabled=1 AND p.paused=0 AND r.next_run_at IS NOT NULL AND r.next_run_at <= ?
  """, (string(now_utc),)) |> SQLite.rowtable

  for routine in due
    _run_routine(routine, now_utc)
  end

  # 2. Idle project check-ins
  idle_secs = Dates.value(now_utc - last_user_activity_at[]) / 1000
  projects = SQLite.DBInterface.execute(DB[], "SELECT * FROM projects WHERE paused=0") |> SQLite.rowtable

  for proj in projects
    idle_mins = something(proj.idle_check_mins, 30)
    if idle_secs >= idle_mins * 60
      last_checked = proj.last_checked_at
      if last_checked === missing || last_checked === nothing ||
         Dates.value(now_utc - DateTime(string(last_checked))) / 1000 >= idle_mins * 60
        _run_project_checkin(proj, now_utc)
      end
    end
  end
end

function _run_routine(routine, now_utc::DateTime)
  model = resolve_model(DB[], routine.model, string(routine.project_id), CONFIG["llm"])
  project_md_path = joinpath(string(routine.project_path), "Project.md")
  context = isfile(project_md_path) ? read(project_md_path, String) : ""

  prompt = """You are running a scheduled routine for a project.

Project context (from Project.md):
$context

Routine task: $(routine.prompt)

Execute this task. At the end, on a new line, write either NOTABLE:true or NOTABLE:false to indicate whether the result is actionable or noteworthy for the user."""

  messages = [SystemMessage(PERSONALITY * "\n" * INSTRUCTIONS),
              UserMessage(prompt)]

  started_at = string(now(Dates.UTC))
  content = try
    llm_generate(messages; model)
  catch e
    @error "Routine execution failed" routine_id=routine.id exception=e
    "Error: $(sprint(showerror, e))"
  end
  notable = occursin("NOTABLE:true", content) ? 1 : 0
  clean_result = replace(content, r"\nNOTABLE:(true|false)\s*$" => "")

  total_tokens = 0
  cost = 0.0
  finished_at = string(now(Dates.UTC))

  # Store run
  SQLite.execute(DB[], """
    INSERT INTO routine_runs (routine_id, project_id, started_at, finished_at, result, tokens_used, cost_usd, notable)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  """, (routine.id, routine.project_id, started_at, finished_at, clean_result, total_tokens, cost, notable))

  # Update routine counters
  SQLite.execute(DB[], """
    UPDATE routines SET last_run_at=?, tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (finished_at, total_tokens, cost, routine.id))

  # Compute next run
  if routine.schedule_cron !== missing && routine.schedule_cron !== nothing
    next_at = next_cron_time_utc(string(routine.schedule_cron), now_utc)
    SQLite.execute(DB[], "UPDATE routines SET next_run_at=? WHERE id=?",
                   (string(next_at), routine.id))
  end

  # Update project counters
  SQLite.execute(DB[], """
    UPDATE projects SET tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (total_tokens, cost, routine.project_id))

  # Emit notification if notable
  if notable == 1
    route_notification(ROUTER, clean_result;
        project_id=routine.project_id,
        routine_id=routine.id,
        extra_gui_emit=() -> begin
          count = unseen_notable_count(DB[])
          emit(Dict("type" => "unseen_count", "count" => count))
        end)
  end
end

function _run_project_checkin(project, now_utc::DateTime)
  model = project.model !== missing && project.model !== nothing ? string(project.model) : CONFIG["llm"]
  project_md_path = joinpath(string(project.path), "Project.md")
  if !isfile(project_md_path)
    @warn "Project.md not found" path=project_md_path
    return
  end
  context = read(project_md_path, String)

  prompt = """You are reviewing a project to see if there's anything you can do to move it forward.

Project: $(project.name)
Path: $(project.path)

Project.md contents:
$context

Review this project and determine if there's anything you can do to help move it forward. If nothing needs doing, say so briefly. At the end, on a new line, write either NOTABLE:true or NOTABLE:false."""

  messages = [SystemMessage(PERSONALITY * "\n" * INSTRUCTIONS),
              UserMessage(prompt)]

  started_at = string(now(Dates.UTC))
  content = try
    llm_generate(messages; model)
  catch e
    @error "Project check-in failed" project_id=project.id exception=e
    return
  end
  notable = occursin("NOTABLE:true", content) ? 1 : 0
  clean_result = replace(content, r"\nNOTABLE:(true|false)\s*$" => "")
  total_tokens = 0
  cost = 0.0
  finished_at = string(now(Dates.UTC))

  # Store as routine_run with NULL routine_id
  SQLite.execute(DB[], """
    INSERT INTO routine_runs (routine_id, project_id, started_at, finished_at, result, tokens_used, cost_usd, notable)
    VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)
  """, (project.id, started_at, finished_at, clean_result, total_tokens, cost, notable))

  # Update project
  SQLite.execute(DB[], """
    UPDATE projects SET last_checked_at=?, tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (finished_at, total_tokens, cost, project.id))

  if notable == 1
    route_notification(ROUTER, clean_result;
        project_id=project.id,
        extra_gui_emit=() -> begin
          count = unseen_notable_count(DB[])
          emit(Dict("type" => "unseen_count", "count" => count))
        end)
  end
end

# ── Main loop ────────────────────────────────────────────────────────

# Start scheduler timer (ticks every 60 seconds)
const SCHEDULER_TIMER = Timer(t -> scheduler_tick!(), 60; interval=60)

# ── Gateway setup ───────────────────────────────────────────────────

const ROUTER = PresenceRouter(;
  idle_threshold_mins=get(get(CONFIG, "gateway", Dict()), "idle_threshold_mins", 15)
)

# Wire the router's GUI emit function to our emit()
ROUTER.gui_io = (d; conversation_id=nothing) -> emit(d; conversation_id)

# Wire GUI activity check — uses last_user_activity_at directly
# (the GUI is the sidecar's only client, so backend activity == GUI activity)
ROUTER.check_gui_active = () -> begin
  idle_secs = Dates.value(now(Dates.UTC) - last_user_activity_at[]) / 1000
  idle_secs < ROUTER.idle_threshold_mins * 60
end

# Conversation queuing for Telegram topics (one conversation at a time per topic)
const TELEGRAM_ACTIVE_CONVERSATIONS = Dict{String, Bool}()
const TELEGRAM_MESSAGE_QUEUE = Dict{String, Vector{InboundEnvelope}}()

# Set up inbound handler for Telegram messages → agent dispatch
ROUTER._inbound_handler = (env::InboundEnvelope) -> begin
  text = env.text
  topic = env.topic_id
  conv_id = "tg-$(topic)"

  # Queue if a conversation is already running for this topic
  if get(TELEGRAM_ACTIVE_CONVERSATIONS, topic, false)
    queue = get!(TELEGRAM_MESSAGE_QUEUE, topic) do; InboundEnvelope[] end
    push!(queue, env)
    adapter = primary_adapter(ROUTER)
    if adapter !== nothing
      try send_message(adapter, OutboundEnvelope{channel_symbol(adapter)}(
        "Message queued — I'll get to it when the current task finishes.", topic))
      catch end
    end
    return
  end

  TELEGRAM_ACTIVE_CONVERSATIONS[topic] = true
  conv = get_gui_conversation(conv_id)
  outbox = Channel(32)
  approvals = Channel(32)
  agent = get(AGENTS, conv.agent_id, default_agent())
  put!(agent.inbox, Envelope(text; outbox, approvals, auto_allowed=conv.auto_allowed, conversation_id=conv_id))
  # Drain agent events and send back to Telegram
  @async begin
    adapter = primary_adapter(ROUTER)
    adapter === nothing && return
    while true
      event = take!(outbox)
      if event isa AgentMessage
        try
          out = OutboundEnvelope{:telegram}(event.text, env.topic_id)
          send_message(adapter, out)
        catch e
          @warn "Failed to send agent response to Telegram" exception=e
        end
      elseif event isa ToolCallRequest
        @async route_approval(ROUTER, event, approvals; conversation_id=conv_id)
      elseif event isa ToolResult
        # Tool results not sent to Telegram (too noisy)
      elseif event isa AgentDone
        break
      end
    end
    # Process queued messages for this topic
    TELEGRAM_ACTIVE_CONVERSATIONS[topic] = false
    queue = get(TELEGRAM_MESSAGE_QUEUE, topic, nothing)
    if queue !== nothing && !isempty(queue)
      next_env = popfirst!(queue)
      ROUTER._inbound_handler(next_env)
    end
  end
end

# Initialize Telegram adapter if configured
let gw_config = get(CONFIG, "gateway", nothing)
  if gw_config !== nothing
    tg_config = get(gw_config, "telegram", nothing)
    if tg_config !== nothing
      bot_token = string(get(tg_config, "bot_token", ""))
      chat_id = get(tg_config, "chat_id", 0)
      owner_id = get(tg_config, "owner_id", 0)
      if !isempty(bot_token) && chat_id != 0 && owner_id != 0
        adapter = TelegramAdapter(; bot_token, chat_id=Int64(chat_id), owner_id=Int64(owner_id), db=DB[])
        register_adapter!(ROUTER, adapter)
        try
          start!(adapter, ROUTER)
          @info "Telegram gateway active"
        catch e
          @warn "Failed to start Telegram adapter" exception=e
        end
      end
    end
  end
end

# Timer to check pending approval migrations (every 60s)
const APPROVAL_CHECK_TIMER = Timer(t -> begin
  try check_pending_approvals!(ROUTER) catch e
    @warn "Approval check error" exception=e
  end
end, 60; interval=60)

# Emit initial unseen count
emit(Dict("type" => "unseen_count", "count" => unseen_notable_count(DB[])))

# Signal ready
emit(Dict("type" => "ready"))
emit(handle(Val(:agents_list), Dict()))
emit(handle(Val(:conversations_list), Dict()))

while !eof(stdin)
  line = readline()
  isempty(line) && continue

  msg = try
    parse_json(line)
  catch e
    @warn "Failed to parse input JSON" line exception=e
    emit(Dict("type" => "error", "text" => "Invalid JSON: $(sprint(showerror, e))"))
    continue
  end

  msg_type = Symbol(get(msg, "type", ""))
  try
    t0 = time()
    result = handle(Val(msg_type), msg)
    t1 = time()
    if result isa Task
      @async try
        r = fetch(result)
        t2 = time()
        n = r isa Dict ? length(get(r, "data", [])) : 0
        @warn "RPC timing" msg_type handle_ms=round((t1-t0)*1000) fetch_ms=round((t2-t1)*1000) results=n
        r isa Dict && reply(msg, r)
      catch e
        e = e isa TaskFailedException ? e.task.result : e
        reply(msg, if e isa UserError
          Dict("type" => "error", "text" => e.msg)
        else
          @error "Error handling message" msg_type exception=(e, catch_backtrace())
          Dict("type" => "error", "text" => "Error: $(sprint(showerror, e))")
        end)
      end
    elseif result isa Dict
      @warn "RPC timing" msg_type handle_ms=round((t1-t0)*1000)
      reply(msg, result)
    end
  catch e
    reply(msg, if e isa UserError
      Dict("type" => "error", "text" => e.msg)
    else
      @error "Error handling message" msg_type exception=(e, catch_backtrace())
      Dict("type" => "error", "text" => "Error: $(sprint(showerror, e))")
    end)
  end
end
