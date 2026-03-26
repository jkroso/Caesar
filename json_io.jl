# ═══════════════════════════════════════════════════════════════════════
# Prosca JSON I/O — stdin/stdout bridge for the GUI (Tauri sidecar)
#
# Protocol: newline-delimited JSON on stdin/stdout.
# All output lines are prefixed with "PROSCA:" so the Rust sidecar
# can filter them from Julia noise.
# ═══════════════════════════════════════════════════════════════════════

@use "./main"...
@use "./scheduler"...
@use "./gateway/telegram"...
@use Dates...
@use HTTP
@use JSON3
@use SQLite
@use YAML
@use UUIDs

const last_user_activity_at = Ref{DateTime}(now(Dates.UTC))

mutable struct GUIConversation
  history::Vector{AbstractMessage}
  auto_allowed::Set{String}
  agent_id::String
end

const GUI_CONVERSATIONS = Dict{String, GUIConversation}()

function get_gui_conversation(id::String, agent_id::String="prosca")
  get!(GUI_CONVERSATIONS, id) do
    GUIConversation(AbstractMessage[], Set{String}(), agent_id)
  end
end

# Map tool-call ID → per-message approvals channel (for direct GUI approvals without gateway)
const PENDING_GUI_APPROVALS = Dict{UInt64, Channel}()

# ── Output helpers ────────────────────────────────────────────────────

function emit(obj; conversation_id::Union{String,Nothing}=nothing)
  if conversation_id !== nothing
    obj["conversation_id"] = conversation_id
  end
  println("PROSCA:", JSON3.write(obj))
  flush(stdout)
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
      emit(Dict("type" => "tool_result", "name" => event.name, "result" => event.result); conversation_id)
    elseif event isa AgentDone
      emit(Dict("type" => "agent_done"); conversation_id)
      break
    end
  end
end

# ── Command handlers ─────────────────────────────────────────────────

function handle_config_get()
  emit(Dict("type" => "config", "data" => CONFIG))
end

function handle_config_set(key::String, value)
  CONFIG[key] = value
  YAML.write_file(string(HOME * "config.yaml"), CONFIG)
  emit(Dict("type" => "config", "data" => CONFIG))
end

function handle_skills_list()
  skills = [Dict("name" => s.name, "description" => s.description, "file" => "") for s in values(SKILLS)]
  emit(Dict("type" => "skills", "data" => skills))
end


const _models_cache = Ref{Union{Vector{Dict{String,String}}, Nothing}}(nothing)
const _models_cache_time = Ref{Float64}(0.0)
const _MODELS_CACHE_TTL = 300.0  # 5 minutes

function _get_api_key(env_var::Union{String,Nothing}, config_key::Union{String,Nothing})
  if config_key !== nothing && haskey(CONFIG, config_key)
    return string(CONFIG[config_key])
  end
  if env_var !== nothing && haskey(ENV, env_var)
    return ENV[env_var]
  end
  nothing
end

function _fetch_xai_models(api_key::String)
  models = Dict{String,String}[]
  try
    resp = HTTP.get("https://api.x.ai/v1/models";
      headers=["Authorization" => "Bearer $api_key"],
      connect_timeout=5, readtimeout=10)
    parsed = JSON3.read(String(resp.body))
    for m in get(parsed, :data, [])
      id = string(get(m, :id, ""))
      if !isempty(id)
        push!(models, Dict("id" => id, "name" => id, "provider" => "xai"))
      end
    end
  catch e
    @warn "Could not fetch xAI models" exception=e
  end
  models
end

function _fetch_anthropic_models(api_key::String)
  models = Dict{String,String}[]
  try
    resp = HTTP.get("https://api.anthropic.com/v1/models";
      headers=["x-api-key" => api_key, "anthropic-version" => "2023-06-01"],
      connect_timeout=5, readtimeout=10)
    parsed = JSON3.read(String(resp.body))
    for m in get(parsed, :data, [])
      id = string(get(m, :id, ""))
      display_name = string(get(m, :display_name, id))
      if !isempty(id)
        push!(models, Dict("id" => id, "name" => display_name, "provider" => "anthropic"))
      end
    end
  catch e
    @warn "Could not fetch Anthropic models" exception=e
  end
  models
end

function _fetch_gemini_models(api_key::String)
  models = Dict{String,String}[]
  try
    resp = HTTP.get("https://generativelanguage.googleapis.com/v1beta/models?key=$api_key";
      connect_timeout=5, readtimeout=10)
    parsed = JSON3.read(String(resp.body))
    for m in get(parsed, :models, [])
      # API returns "models/gemini-2.5-pro" — strip the prefix
      full_name = string(get(m, :name, ""))
      id = replace(full_name, r"^models/" => "")
      display_name = string(get(m, :displayName, id))
      # Only include generateContent-capable models
      methods = get(m, :supportedGenerationMethods, [])
      if !isempty(id) && any(x -> string(x) == "generateContent", methods)
        push!(models, Dict("id" => id, "name" => display_name, "provider" => "gemini"))
      end
    end
  catch e
    @warn "Could not fetch Gemini models" exception=e
  end
  models
end

function handle_models_list()
  now = time()
  if _models_cache[] !== nothing && (now - _models_cache_time[]) < _MODELS_CACHE_TTL
    emit(Dict("type" => "models", "data" => _models_cache[]))
    return
  end

  models = Dict{String,String}[]

  # Fetch xAI models
  xai_key = _get_api_key("XAI_API_KEY", "xai_key")
  if xai_key !== nothing
    append!(models, _fetch_xai_models(xai_key))
  end

  # Fetch Anthropic models
  anthropic_key = _get_api_key("ANTHROPIC_API_KEY", "anthropic_key")
  if anthropic_key !== nothing
    append!(models, _fetch_anthropic_models(anthropic_key))
  end

  # Fetch Gemini models
  google_key = _get_api_key("GOOGLE_API_KEY", "google_key")
  if google_key !== nothing
    append!(models, _fetch_gemini_models(google_key))
  end

  # Query Ollama for local models
  try
    resp = HTTP.get("http://localhost:11434/api/tags"; connect_timeout=3, readtimeout=5)
    parsed = JSON3.read(String(resp.body))
    for m in get(parsed, :models, [])
      name = string(get(m, :name, ""))
      if !isempty(name)
        push!(models, Dict("id" => name, "name" => name, "provider" => "ollama"))
      end
    end
  catch e
    @warn "Could not reach Ollama" exception=e
  end

  # Enrich with pricing from models.dev api.json
  for m in models
    prices = get_pricing(m["id"])
    m["cost_input"] = prices[1]
    m["cost_output"] = prices[2]
  end

  _models_cache[] = models
  _models_cache_time[] = now
  emit(Dict("type" => "models", "data" => models))
end

function handle_reset(conv_id::Union{String,Nothing}=nothing)
  if conv_id !== nothing && haskey(GUI_CONVERSATIONS, conv_id)
    conv = GUI_CONVERSATIONS[conv_id]
    empty!(conv.history)
    empty!(conv.auto_allowed)
  else
    empty!(SESSION_HISTORY)
    empty!(AUTO_ALLOWED_TOOLS)
  end
end

function handle_generate_title(text::String; conversation_id::Union{String,Nothing}=nothing)
  messages = AbstractMessage[
    SystemMessage("Generate a short chat title (3-6 words, no quotes, no punctuation) that summarizes the user's message. Reply with ONLY the title, nothing else."),
    UserMessage(text)
  ]
  title = strip(llm_generate(messages))
  emit(Dict("type" => "title", "title" => title); conversation_id)
end

function handle_restore_context(messages; conv_id::Union{String,Nothing}=nothing)
  history = if conv_id !== nothing
    conv = get_gui_conversation(conv_id)
    empty!(conv.auto_allowed)
    conv.history
  else
    empty!(AUTO_ALLOWED_TOOLS)
    SESSION_HISTORY
  end
  empty!(history)
  for msg in messages
    role = string(get(msg, :role, ""))
    text = string(get(msg, :text, ""))
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
end

# ── Project CRUD ─────────────────────────────────────────────────────

function handle_projects_list()
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
  emit(Dict("type" => "projects", "data" => data))
end

function handle_project_create(msg)
  name = string(get(msg, :name, ""))
  path = string(get(msg, :path, ""))
  model = let v = get(msg, :model, nothing); v === nothing ? nothing : string(v) end
  idle_mins = get(msg, :idle_check_mins, 30)

  isempty(name) && (emit(Dict("type" => "error", "text" => "Project name required")); return)
  isempty(path) && (emit(Dict("type" => "error", "text" => "Project path required")); return)

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

  handle_projects_list()
end

function handle_project_update(msg)
  id = string(get(msg, :id, ""))
  isempty(id) && return

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
  isempty(sets) && return
  push!(vals, id)
  SQLite.execute(DB[], "UPDATE projects SET $(join(sets, ", ")) WHERE id=?", vals)
  handle_projects_list()
end

function handle_project_delete(msg)
  id = string(get(msg, :id, ""))
  rows = SQLite.DBInterface.execute(DB[], "SELECT is_default FROM projects WHERE id=?", (id,)) |> SQLite.rowtable
  if length(rows) > 0 && rows[1].is_default == 1
    emit(Dict("type" => "error", "text" => "Cannot delete the default project"))
    return
  end
  SQLite.execute(DB[], "DELETE FROM routine_runs WHERE project_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM routines WHERE project_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM projects WHERE id=?", (id,))
  handle_projects_list()
end

# ── Routine CRUD ─────────────────────────────────────────────────────

function handle_routines_list(msg)
  project_id = let v = get(msg, :project_id, nothing); v === nothing ? nothing : string(v) end
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
  emit(Dict("type" => "routines", "data" => data))
end

function handle_routine_create(msg)
  project_id = string(get(msg, :project_id, ""))
  prompt = string(get(msg, :prompt, ""))
  schedule_natural = string(get(msg, :schedule_natural, ""))
  model = let v = get(msg, :model, nothing); v === nothing ? nothing : string(v) end

  isempty(project_id) && (emit(Dict("type" => "error", "text" => "Project required")); return)
  isempty(prompt) && (emit(Dict("type" => "error", "text" => "Routine prompt required")); return)

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
    emit(Dict("type" => "error", "text" => "Failed to generate routine: $(sprint(showerror, e))"))
    return
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
      emit(Dict("type" => "error", "text" => "Invalid cron expression '$schedule_cron': $(sprint(showerror, e))"))
      return
    end
  end

  id = string(UUIDs.uuid4())
  SQLite.execute(DB[], """
    INSERT INTO routines (id, project_id, name, prompt, model, schedule_natural, schedule_cron, next_run_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
  """, (id, project_id, name, prompt, model, schedule_natural, schedule_cron, next_run))

  handle_routines_list(msg)
end

function handle_routine_update(msg)
  id = string(get(msg, :id, ""))
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

  schedule_natural = get(msg, :schedule_natural, nothing)
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
  handle_routines_list(msg)
end

function handle_routine_delete(msg)
  id = string(get(msg, :id, ""))
  SQLite.execute(DB[], "DELETE FROM routine_runs WHERE routine_id=?", (id,))
  SQLite.execute(DB[], "DELETE FROM routines WHERE id=?", (id,))
  handle_routines_list(msg)
end

function handle_routine_runs_list(msg)
  project_id = let v = get(msg, :project_id, nothing); v === nothing ? nothing : string(v) end
  unseen_only = get(msg, :unseen_only, false)

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
  emit(Dict("type" => "routine_runs", "data" => data))
end

function handle_routine_runs_mark_seen(msg)
  ids = get(msg, :ids, [])
  for id in ids
    SQLite.execute(DB[], "UPDATE routine_runs SET seen=1 WHERE id=?", (id,))
  end
  count = unseen_notable_count(DB[])
  emit(Dict("type" => "unseen_count", "count" => count))
end

# ── Agent CRUD ───────────────────────────────────────────────────────

function handle_agents_list()
  data = [Dict("id" => a.id) for a in values(AGENTS)]
  sort!(data; by=d -> d["id"] == "prosca" ? "" : d["id"])
  emit(Dict("type" => "agents", "data" => data))
end

function handle_agent_create(msg)
  name = string(get(msg, :name, ""))
  description = string(get(msg, :description, ""))
  isempty(name) && (emit(Dict("type" => "error", "text" => "Agent name required")); return)
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

# ── Conversation CRUD ────────────────────────────────────────────────

function handle_conversations_list()
  rows = SQLite.DBInterface.execute(DB[], """
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
  SQLite.execute(DB[], """
    INSERT INTO conversations (id, agent_id, title, created_at, updated_at)
    VALUES (?, ?, 'New chat', datetime('now'), datetime('now'))
  """, (id, agent_id))
  handle_conversations_list()
end

function handle_conversation_delete(msg)
  id = string(get(msg, :id, ""))
  SQLite.execute(DB[], "DELETE FROM conversations WHERE id=?", (id,))
  delete!(GUI_CONVERSATIONS, id)
  handle_conversations_list()
end

function handle_conversation_update_title(msg)
  id = string(get(msg, :id, ""))
  title = string(get(msg, :title, ""))
  SQLite.execute(DB[], "UPDATE conversations SET title=?, updated_at=datetime('now') WHERE id=?", (title, id))
  handle_conversations_list()
end

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
    put!(agent.inbox, Envelope(text; outbox, approvals, session_history=conv.history, auto_allowed=conv.auto_allowed, conversation_id=conv_id))
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
handle_agents_list()
handle_conversations_list()

while !eof(stdin)
  line = readline()
  isempty(line) && continue

  msg = try
    JSON3.read(line)
  catch e
    @warn "Failed to parse input JSON" line exception=e
    emit(Dict("type" => "error", "text" => "Invalid JSON: $(sprint(showerror, e))"))
    continue
  end

  msg_type = get(msg, :type, "")
  conv_id = let v = get(msg, :conversation_id, nothing)
    v === nothing ? nothing : string(v)
  end

  try
    if msg_type == "user_message"
      text = string(get(msg, :text, ""))
      agent_id = string(get(msg, :agent_id, "prosca"))
      last_user_activity_at[] = now(Dates.UTC)
      agent = get(AGENTS, agent_id, default_agent())
      conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id, agent_id)
      outbox = Channel(32)
      approvals = Channel(32)
      put!(agent.inbox, Envelope(text; outbox, approvals, session_history=conv.history, auto_allowed=conv.auto_allowed, conversation_id=conv_id))
      @async handle_events(outbox; conversation_id=conv_id, approvals)
    elseif msg_type == "tool_approval"
      id = parse(UInt64, string(get(msg, :id, "0")))
      decision_str = string(get(msg, :decision, "deny"))
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
    elseif msg_type == "config_get"
      handle_config_get()
    elseif msg_type == "config_set"
      handle_config_set(string(msg.key), msg.value)
    elseif msg_type == "skills_list"
      handle_skills_list()
    elseif msg_type == "models_list"
      @async handle_models_list()
    elseif msg_type == "reset"
      handle_reset(conv_id)
    elseif msg_type == "restore_context"
      messages = get(msg, :messages, [])
      handle_restore_context(messages; conv_id)
    elseif msg_type == "generate_title"
      text = string(get(msg, :text, ""))
      @async handle_generate_title(text; conversation_id=conv_id)
    elseif msg_type == "command"
      cmd_name = string(get(msg, :name, ""))
      cmd_args = string(get(msg, :args, ""))
      if haskey(COMMANDS, cmd_name)
        result = try
          COMMANDS[cmd_name].fn(cmd_args)
        catch e
          "Command error: $(sprint(showerror, e))"
        end
        emit(Dict("type" => "command_result", "name" => cmd_name, "result" => string(result)))
      else
        emit(Dict("type" => "error", "text" => "Unknown command: $cmd_name"))
      end
    elseif msg_type == "projects_list"
      handle_projects_list()
    elseif msg_type == "project_create"
      handle_project_create(msg)
    elseif msg_type == "project_update"
      handle_project_update(msg)
    elseif msg_type == "project_delete"
      handle_project_delete(msg)
    elseif msg_type == "routines_list"
      handle_routines_list(msg)
    elseif msg_type == "routine_create"
      handle_routine_create(msg)
    elseif msg_type == "routine_update"
      handle_routine_update(msg)
    elseif msg_type == "routine_delete"
      handle_routine_delete(msg)
    elseif msg_type == "routine_runs_list"
      handle_routine_runs_list(msg)
    elseif msg_type == "routine_runs_mark_seen"
      handle_routine_runs_mark_seen(msg)
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
    else
      emit(Dict("type" => "error", "text" => "Unknown message type: $msg_type"))
    end
  catch e
    @error "Error handling message" msg_type exception=(e, catch_backtrace())
    emit(Dict("type" => "error", "text" => "Error: $(sprint(showerror, e))"))
  end
end
