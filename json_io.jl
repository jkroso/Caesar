# ═══════════════════════════════════════════════════════════════════════
# Prosca JSON I/O — stdin/stdout bridge for the GUI (Tauri sidecar)
#
# Protocol: newline-delimited JSON on stdin/stdout.
# All output lines are prefixed with "PROSCA:" so the Rust sidecar
# can filter them from Julia noise.
# ═══════════════════════════════════════════════════════════════════════

include("main.jl")
include("scheduler.jl")
using .Scheduler

const AGENT_LOCK = ReentrantLock()
const last_user_activity_at = Ref{DateTime}(now(Dates.UTC))

mutable struct GUIConversation
  history::Vector{PromptingTools.AbstractMessage}
  auto_allowed::Set{String}
  outbox::Channel
  inbox::Channel
end

const GUI_CONVERSATIONS = Dict{String, GUIConversation}()

function get_gui_conversation(id::String)
  get!(GUI_CONVERSATIONS, id) do
    GUIConversation(PromptingTools.AbstractMessage[], Set{String}(), Channel(32), Channel(32))
  end
end

# ── Output helpers ────────────────────────────────────────────────────

function emit(obj; conversation_id::Union{String,Nothing}=nothing)
  if conversation_id !== nothing
    obj["conversation_id"] = conversation_id
  end
  println("PROSCA:", JSON3.write(obj))
  flush(stdout)
end

# ── Drain agent events and emit as JSON ──────────────────────────────

function handle_events(outbox::Channel; conversation_id::Union{String,Nothing}=nothing)
  while true
    event = take!(outbox)
    if event isa AgentMessage
      emit(Dict("type" => "agent_message", "text" => event.text); conversation_id)
    elseif event isa ToolCallRequest
      emit(Dict("type" => "tool_call_request", "id" => string(event.id), "name" => event.name, "args" => event.args); conversation_id)
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
  # Re-detect LLM schema if model changed
  if key == "llm"
    LLM_SCHEMA[] = _detect_schema()
  end
  emit(Dict("type" => "config", "data" => CONFIG))
end

function handle_skills_list()
  skills = [Dict("name" => s.name, "description" => s.description, "file" => "") for s in values(SKILLS)]
  emit(Dict("type" => "skills", "data" => skills))
end

function handle_mcp_list()
  servers = Dict{String, Any}()
  for (name, server) in MCP_SERVERS
    tools = [Dict("name" => t.name, "description" => t.description, "schema" => Dict()) for t in server.tools]
    servers[name] = Dict(
      "url" => server.url,
      "runtime" => server.is_runtime,
      "connected" => server.connected,
      "tools" => tools
    )
  end
  emit(Dict("type" => "mcp_servers", "data" => servers))
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
  messages = PromptingTools.AbstractMessage[
    PromptingTools.SystemMessage("Generate a short chat title (3-6 words, no quotes, no punctuation) that summarizes the user's message. Reply with ONLY the title, nothing else."),
    PromptingTools.UserMessage(text)
  ]
  title = strip(call_llm(messages).content)
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
      push!(history, PromptingTools.UserMessage(text))
    elseif role == "agent"
      push!(history, PromptingTools.AIMessage(text))
    end
  end
  # Keep only the last 20 entries (10 exchange pairs) like _run_agent does
  if length(history) > 20
    splice!(history, 1:length(history)-20)
  end
end

# ── Scheduler ─────────────────────────────────────────────────────────

function scheduler_tick!()
  # Only run if agent is idle
  trylock(AGENT_LOCK) || return
  try
    _scheduler_tick!()
  catch e
    @error "Scheduler tick error" exception=(e, catch_backtrace())
  finally
    unlock(AGENT_LOCK)
  end
end

function _scheduler_tick!()
  now_utc = now(Dates.UTC)

  # 1. Run due routines
  due = SQLite.DBInterface.execute(DB, """
    SELECT r.*, p.path as project_path, p.model as project_model
    FROM routines r JOIN projects p ON r.project_id = p.id
    WHERE r.enabled=1 AND r.next_run_at IS NOT NULL AND r.next_run_at <= ?
  """, (string(now_utc),)) |> SQLite.rowtable

  for routine in due
    _run_routine(routine, now_utc)
  end

  # 2. Idle project check-ins
  idle_secs = Dates.value(now_utc - last_user_activity_at[]) / 1000
  projects = SQLite.DBInterface.execute(DB, "SELECT * FROM projects") |> SQLite.rowtable

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
  model = Scheduler.resolve_model(DB, routine.model, string(routine.project_id), CONFIG["llm"])
  project_md_path = joinpath(string(routine.project_path), "Project.md")
  context = isfile(project_md_path) ? read(project_md_path, String) : ""

  prompt = """You are running a scheduled routine for a project.

Project context (from Project.md):
$context

Routine task: $(routine.prompt)

Execute this task. At the end, on a new line, write either NOTABLE:true or NOTABLE:false to indicate whether the result is actionable or noteworthy for the user."""

  messages = [PromptingTools.SystemMessage(PERSONALITY * "\n" * INSTRUCTIONS),
              PromptingTools.UserMessage(prompt)]

  started_at = string(now(Dates.UTC))
  result_obj = try
    call_llm(messages; model)
  catch e
    @error "Routine execution failed" routine_id=routine.id exception=e
    LlmResult("Error: $(sprint(showerror, e))", 0, 0)
  end

  content = result_obj.content
  notable = occursin("NOTABLE:true", content) ? 1 : 0
  clean_result = replace(content, r"\nNOTABLE:(true|false)\s*$" => "")

  cost = Scheduler.compute_cost(model, result_obj.input_tokens, result_obj.output_tokens)
  total_tokens = result_obj.input_tokens + result_obj.output_tokens
  finished_at = string(now(Dates.UTC))

  # Store run
  SQLite.execute(DB, """
    INSERT INTO routine_runs (routine_id, project_id, started_at, finished_at, result, tokens_used, cost_usd, notable)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  """, (routine.id, routine.project_id, started_at, finished_at, clean_result, total_tokens, cost, notable))

  # Update routine counters
  SQLite.execute(DB, """
    UPDATE routines SET last_run_at=?, tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (finished_at, total_tokens, cost, routine.id))

  # Compute next run
  if routine.schedule_cron !== missing && routine.schedule_cron !== nothing
    next_at = Scheduler.next_cron_time_utc(string(routine.schedule_cron), now_utc)
    SQLite.execute(DB, "UPDATE routines SET next_run_at=? WHERE id=?",
                   (string(next_at), routine.id))
  end

  # Update project counters
  SQLite.execute(DB, """
    UPDATE projects SET tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (total_tokens, cost, routine.project_id))

  # Emit notification if notable
  if notable == 1
    emit(Dict("type" => "notification", "text" => clean_result,
              "project_id" => routine.project_id, "routine_id" => routine.id))
    count = Scheduler.unseen_notable_count(DB)
    emit(Dict("type" => "unseen_count", "count" => count))
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

  messages = [PromptingTools.SystemMessage(PERSONALITY * "\n" * INSTRUCTIONS),
              PromptingTools.UserMessage(prompt)]

  started_at = string(now(Dates.UTC))
  result_obj = try
    call_llm(messages; model)
  catch e
    @error "Project check-in failed" project_id=project.id exception=e
    return
  end

  content = result_obj.content
  notable = occursin("NOTABLE:true", content) ? 1 : 0
  clean_result = replace(content, r"\nNOTABLE:(true|false)\s*$" => "")
  cost = Scheduler.compute_cost(model, result_obj.input_tokens, result_obj.output_tokens)
  total_tokens = result_obj.input_tokens + result_obj.output_tokens
  finished_at = string(now(Dates.UTC))

  # Store as routine_run with NULL routine_id
  SQLite.execute(DB, """
    INSERT INTO routine_runs (routine_id, project_id, started_at, finished_at, result, tokens_used, cost_usd, notable)
    VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)
  """, (project.id, started_at, finished_at, clean_result, total_tokens, cost, notable))

  # Update project
  SQLite.execute(DB, """
    UPDATE projects SET last_checked_at=?, tokens_used=tokens_used+?, cost_usd=cost_usd+?
    WHERE id=?
  """, (finished_at, total_tokens, cost, project.id))

  if notable == 1
    emit(Dict("type" => "notification", "text" => clean_result, "project_id" => project.id))
    count = Scheduler.unseen_notable_count(DB)
    emit(Dict("type" => "unseen_count", "count" => count))
  end
end

# ── Main loop ────────────────────────────────────────────────────────

# Start scheduler timer (ticks every 60 seconds)
const SCHEDULER_TIMER = Timer(t -> scheduler_tick!(), 60; interval=60)

# Emit initial unseen count
emit(Dict("type" => "unseen_count", "count" => Scheduler.unseen_notable_count(DB)))

# Signal ready
emit(Dict("type" => "ready"))

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
      last_user_activity_at[] = now(Dates.UTC)
      conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id)
      @async begin
        lock(AGENT_LOCK)
        try
          run_agent(text, conv.outbox, conv.inbox;
                    session_history=conv.history, auto_allowed=conv.auto_allowed,
                    conversation_id=conv_id)
        finally
          unlock(AGENT_LOCK)
        end
      end
      @async handle_events(conv.outbox; conversation_id=conv_id)
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
      conv = get_gui_conversation(conv_id === nothing ? "default" : conv_id)
      put!(conv.inbox, ToolApproval(id, decision))
    elseif msg_type == "config_get"
      handle_config_get()
    elseif msg_type == "config_set"
      handle_config_set(string(msg.key), msg.value)
    elseif msg_type == "skills_list"
      handle_skills_list()
    elseif msg_type == "mcp_list"
      handle_mcp_list()
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
    else
      emit(Dict("type" => "error", "text" => "Unknown message type: $msg_type"))
    end
  catch e
    @error "Error handling message" msg_type exception=(e, catch_backtrace())
    emit(Dict("type" => "error", "text" => "Error: $(sprint(showerror, e))"))
  end
end
