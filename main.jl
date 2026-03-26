@use "github.com/jkroso/URI.jl/FSPath" home FSPath
@use "github.com/jkroso/Promises.jl" @thread
@use LinearAlgebra...
@use "github.com/jkroso/LLM.jl" LLM OpenAI Anthropic Google Ollama TokenStream
@use "github.com/jkroso/LLM.jl/pricing" get_pricing token
@use LibGit2
@use Logging
@use SQLite
@use JSON3
@use Dates
@use HTTP
@use YAML
@use UUIDs
@use Base64
@use "./safety"...
@use "./repl" interpret TRUSTED_MODULES
@use "./gateway/mail_auth" MailAuth ensure_token!
@use "./gateway/mail_api" mail_request mail_send mail_list mail_get mail_mark_read MailAPIError
@use "./ori/engine" Engine init_engine search rebuild! update_note!
@use "./ori/embeddings" OllamaIndex
@use "./ori/vault" extract_links
@use "./ori/types" Note ScoredNote

# ── Constants set at precompile time ─────────────────────────────────
const HOME = mkpath(home() * "Caesar")
const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)

# ── Mutable state initialized at runtime ─────────────────────────────
const CONFIG = Dict{String,Any}()
const DB = Ref{SQLite.DB}()
const MAIL_AUTH = Ref{Union{MailAuth, Nothing}}(nothing)

const MEMORY_PROVIDERS = Dict{String, Tuple{Symbol, Any}}()
const ORI_LOCKS = Dict{String, ReentrantLock}()
ori_lock(agent_id) = get!(() -> ReentrantLock(), ORI_LOCKS, agent_id)

# Agent → Interface events (per-message outbox)
struct AgentMessage
  text::String
end

struct ToolCallRequest
  name::String
  args::String
  id::UInt64
end

struct ToolResult
  name::String
  result::String
end

struct StreamToken
  text::String
end

struct AgentDone end

# Interface → Agent events (per-message approvals channel)
struct UserInput
  text::String
end

struct ToolApproval
  id::UInt64
  decision::Symbol  # :allow, :deny, :always
end

struct ToolApprovalRetracted
  id::UInt64
  reason::String
end

# ── Channel Gateway ──────────────────────────────────────────────────

struct InboundEnvelope{C}
  sender_id::String
  text::String
  topic_id::String
  reply_to_id::Union{String,Nothing}
  raw::Dict
  received_at::Dates.DateTime
end

struct OutboundEnvelope{C}
  text::String
  topic_id::String
  reply_to_id::Union{String,Nothing}
  buttons::Vector{Tuple{String,String}}  # (label, callback_data) for inline keyboards
end

OutboundEnvelope{C}(text::String, topic_id::String) where C =
  OutboundEnvelope{C}(text, topic_id, nothing, Tuple{String,String}[])

abstract type ChannelAdapter end

function start!(adapter::ChannelAdapter, gateway) end
function stop!(adapter::ChannelAdapter) end
is_connected(::ChannelAdapter) = false

function send_message(adapter::ChannelAdapter, env::OutboundEnvelope)::String
  error("send_message not implemented for $(typeof(adapter))")
end

function retract_message(adapter::ChannelAdapter, message_id::String)
  error("retract_message not implemented for $(typeof(adapter))")
end

mutable struct PendingApproval
  id::UInt64
  tool_name::String
  args::String
  conversation_id::Union{String,Nothing}
  current_target::Symbol
  telegram_message_id::Union{String,Nothing}
  lock::ReentrantLock
  response::Channel{ToolApproval}
end

mutable struct PresenceRouter
  idle_threshold_mins::Int
  active_adapters::Vector{ChannelAdapter}
  pending_approvals::Dict{UInt64, PendingApproval}
  gui_io::Union{Function, Nothing}
  check_gui_active::Union{Function, Nothing}
  _inbound_handler::Union{Function, Nothing}
end

PresenceRouter(; idle_threshold_mins=15) = PresenceRouter(
  idle_threshold_mins,
  ChannelAdapter[],
  Dict{UInt64, PendingApproval}(),
  nothing,
  nothing,
  nothing
)

channel_symbol(::ChannelAdapter) = :unknown

function register_adapter!(router::PresenceRouter, adapter::ChannelAdapter)
  push!(router.active_adapters, adapter)
end

function primary_adapter(router::PresenceRouter)::Union{ChannelAdapter, Nothing}
  isempty(router.active_adapters) ? nothing : first(router.active_adapters)
end

function gui_is_active(router::PresenceRouter)::Bool
  router.check_gui_active === nothing && return false
  try
    router.check_gui_active()
  catch
    false
  end
end

function route_approval(router::PresenceRouter, request::ToolCallRequest, inbox::Channel;
                      conversation_id::Union{String,Nothing}=nothing)
  pa = PendingApproval(
    request.id, request.name, request.args, conversation_id,
    :gui, nothing, ReentrantLock(), Channel{ToolApproval}(1)
  )
  router.pending_approvals[request.id] = pa
  adapter = primary_adapter(router)
  if gui_is_active(router)
    lock(pa.lock) do
      pa.current_target = :gui
    end
    if router.gui_io !== nothing
      router.gui_io(Dict("type" => "tool_call_request",
                        "id" => string(request.id),
                        "name" => request.name,
                        "args" => request.args);
                   conversation_id)
    end
  elseif adapter !== nothing
    _send_approval_to_adapter(router, pa, adapter)
  else
    lock(pa.lock) do
      pa.current_target = :gui
    end
    if router.gui_io !== nothing
      router.gui_io(Dict("type" => "tool_call_request",
                        "id" => string(request.id),
                        "name" => request.name,
                        "args" => request.args);
                   conversation_id)
    end
  end
  approval = take!(pa.response)
  delete!(router.pending_approvals, request.id)
  put!(inbox, approval)
end

function _send_approval_to_adapter(router::PresenceRouter, pa::PendingApproval, adapter::ChannelAdapter)
  C = channel_symbol(adapter)
  env = OutboundEnvelope{C}(
    "Approval needed\nTool: $(pa.tool_name)\nArgs: $(pa.args)",
    "_approvals",
    nothing,
    [("Approve", "approve:$(pa.id)"),
     ("Deny", "deny:$(pa.id)"),
     ("Always", "always:$(pa.id)")]
  )
  lock(pa.lock) do
    msg_id = send_message(adapter, env)
    pa.telegram_message_id = msg_id
    pa.current_target = C
  end
end

function resolve_approval(router::PresenceRouter, id::UInt64, decision::Symbol, from_target::Symbol)::Bool
  pa = get(router.pending_approvals, id, nothing)
  pa === nothing && return false
  return lock(pa.lock) do
    if pa.current_target != from_target
      false
    else
      put!(pa.response, ToolApproval(id, decision))
      true
    end
  end
end

function check_pending_approvals!(router::PresenceRouter)
  adapter = primary_adapter(router)
  gui_active = gui_is_active(router)
  for (id, pa) in router.pending_approvals
    lock(pa.lock) do
      C = adapter !== nothing ? channel_symbol(adapter) : :unknown
      if pa.current_target == :gui && !gui_active && adapter !== nothing
        if router.gui_io !== nothing
          router.gui_io(Dict("type" => "tool_approval_retracted",
                            "id" => pa.id,
                            "reason" => "routed_to_telegram");
                       pa.conversation_id)
        end
        _send_approval_to_adapter(router, pa, adapter)
      elseif pa.current_target == C && gui_active && adapter !== nothing
        if pa.telegram_message_id !== nothing
          try retract_message(adapter, pa.telegram_message_id) catch end
          pa.telegram_message_id = nothing
        end
        pa.current_target = :gui
        if router.gui_io !== nothing
          router.gui_io(Dict("type" => "tool_call_request",
                            "id" => string(pa.id),
                            "name" => pa.tool_name,
                            "args" => pa.args);
                       pa.conversation_id)
        end
      end
    end
  end
end

function route_notification(router::PresenceRouter, text::String;
                         project_id::Union{String,Nothing}=nothing,
                         routine_id::Union{String,Nothing}=nothing,
                         extra_gui_emit::Union{Function,Nothing}=nothing)
  adapter = primary_adapter(router)
  if gui_is_active(router) || adapter === nothing
    if router.gui_io !== nothing
      d = Dict{String,Any}("type" => "notification", "text" => text)
      project_id !== nothing && (d["project_id"] = project_id)
      routine_id !== nothing && (d["routine_id"] = routine_id)
      router.gui_io(d)
    end
    extra_gui_emit !== nothing && extra_gui_emit()
  else
    C = channel_symbol(adapter)
    topic = project_id !== nothing ? project_id : "_general"
    env = OutboundEnvelope{C}(text, topic)
    try send_message(adapter, env) catch e
      @warn "Failed to send notification to adapter" exception=e
      if router.gui_io !== nothing
        d = Dict{String,Any}("type" => "notification", "text" => text)
        project_id !== nothing && (d["project_id"] = project_id)
        routine_id !== nothing && (d["routine_id"] = routine_id)
        router.gui_io(d)
      end
      extra_gui_emit !== nothing && extra_gui_emit()
    end
  end
end
# ── Message Types (for conversation history) ────────────────────────
struct SystemMessage; content::String end
struct UserMessage; content::String end
struct AIMessage; content::String end
const AbstractMessage = Union{SystemMessage, UserMessage, AIMessage}

"Flatten a message vector into (system, user) for the LLM callable"
function flatten_messages(messages::Vector{<:AbstractMessage})
  system = ""
  parts = String[]
  for m in messages
    if m isa SystemMessage
      system = m.content
    elseif m isa UserMessage
      push!(parts, m.content)
    elseif m isa AIMessage
      push!(parts, "Assistant: $(m.content)")
    end
  end
  (system, join(parts, "\n\n"))
end

"Send messages to the default LLM and return the full response text"
function llm_generate(messages::Vector{<:AbstractMessage}; model::Union{String,Nothing}=nothing)::String
  llm = LLM(model !== nothing ? model : get(CONFIG, "llm", "ollama:llama3"), CONFIG)
  system, user = flatten_messages(messages)
  read(llm(system, user), String)
end

function log_memory(text::String; role::String="Agent", metadata=Dict(),
                    agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  dir = AGENTS_DIR * agent_id * "logs"
  mkpath(dir)
  path = dir * "$(Dates.format(Dates.today(), "yyyy-mm-dd")).log"
  open(string(path), "a") do io
    ts = Dates.format(Dates.now(Dates.UTC), "HH:MM:SS")
    println(io, "[$ts] [$role] $text")
  end
end

function search_memories(query::String; limit::Int=5,
                         agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)::String
  entry = get(MEMORY_PROVIDERS, agent_id, nothing)
  entry === nothing && return "(no memories yet)"
  provider, conn = entry
  if provider == :ori
    results = lock(ori_lock(agent_id)) do
      if conversation_id != conn.last_conversation_id
        empty!(conn.context)
        conn.last_conversation_id = conversation_id
      end
      search(conn, query; top_k=limit)
    end
    isempty(results) && return "(no relevant memories)"
    lines = map(results) do r
      note = get(conn.notes, r.id, nothing)
      snippet = note === nothing ? "" : first(note.body, 200)
      "$(r.title) ($(round(r.score; digits=2))): $snippet"
    end
    "=== Relevant memories ===\n" * join(lines, "\n\n")
  elseif provider == :hindsight
    hs = @use("./memory/hindsight/hindsight")
    results = Base.invokelatest(hs.recall, conn, query; limit)
    isempty(results) && return "(no relevant memories)"
    lines = [get(r, "text", "") for r in results]
    "=== Relevant memories ===\n" * join(lines, "\n\n")
  else
    "(unknown memory provider)"
  end
end

const EXTRACTION_MSG_COUNTS = Dict{String, Int}()

function extract_knowledge(messages::Vector, agent_id::String)
  entry = get(MEMORY_PROVIDERS, agent_id, nothing)
  entry === nothing && return
  provider, engine = entry
  provider == :ori || return

  msg_count = length(messages)
  last_count = get(EXTRACTION_MSG_COUNTS, agent_id, 0)
  msg_count <= last_count && return
  EXTRACTION_MSG_COUNTS[agent_id] = msg_count

  window = get(CONFIG, "extraction_window", 10)
  recent = messages[max(1, end-window+1):end]
  conversation = join([string(typeof(m).name.name, ": ", m.content) for m in recent], "\n\n")

  prompt = """You are a knowledge extraction system. Given the following conversation, extract any facts, decisions, or learnings worth remembering long-term.

Return a JSON array. Each element:
{"title": "Short descriptive title", "body": "Content with [[Wiki Links]] to related concepts", "type": "note|decision|learning|log", "space": "notes|self|ops", "tags": ["optional"]}

Rules:
- Only extract genuinely noteworthy information, not routine chatter
- Use [[Wiki Links]] to connect related concepts
- Classify: "decision" for choices made, "learning" for insights, "note" for facts, "log" for session ops
- Use "self" space for agent identity/goals, "ops" for session logs, "notes" for everything else
- Dangling [[Wiki Links]] are fine
- If nothing noteworthy, return []

Return ONLY a JSON array, no other text."""

  extraction_model = get(CONFIG, "extraction_model", nothing)
  response = try
    msgs = [SystemMessage(prompt), UserMessage(conversation)]
    llm_generate(msgs; model=extraction_model)
  catch e
    @warn "Knowledge extraction LLM call failed" exception=e
    return
  end

  notes_data = try
    JSON3.read(response, Vector{Dict{String, Any}})
  catch
    m = match(r"```(?:json)?\s*\n?(.*?)\n?\s*```"s, response)
    m === nothing && (@warn "Extraction returned invalid JSON"; return)
    try JSON3.read(m.captures[1], Vector{Dict{String, Any}}) catch; @warn "Extraction JSON parse failed"; return end
  end

  isempty(notes_data) && return

  updated_ids = String[]
  for nd in notes_data
    title = get(nd, "title", nothing)
    body = get(nd, "body", nothing)
    (title === nothing || body === nothing) && continue
    note = update_note!(engine, String(title), String(body);
                        type=Symbol(get(nd, "type", "note")),
                        space=Symbol(get(nd, "space", "notes")),
                        tags=String.(get(nd, "tags", String[])))
    push!(updated_ids, note.id)
  end

  isempty(updated_ids) && return

  # Incremental index rebuild
  notes_vec = collect(values(engine.notes))
  engine.graph = @use("./ori/graph").build_graph(notes_vec)
  engine.bm25 = @use("./ori/bm25").build_bm25(notes_vec)
  engine.bridges = @use("./ori/graph").articulation_points(engine.graph)
  if engine.semantic isa OllamaIndex
    @use("./ori/embeddings").embed_new!(engine.semantic, engine.notes)
  else
    @use("./ori/tfidf").embed_new!(engine.semantic, engine.notes)
  end

  # Feed learning
  for id in updated_ids
    @use("./ori/vitality").record_access!(engine.db, id)
  end
  length(updated_ids) > 1 && @use("./ori/learning").record_cooccurrence!(engine.db, updated_ids)

  @info "Extracted $(length(updated_ids)) knowledge notes for agent=$agent_id"
end

function consolidate!(engine::Engine, agent_id::String)
  vitality = @use("./ori/vitality").get_all_vitality(engine.db, engine.graph.incoming)
  low_ids = [id for (id, v) in vitality if v < 0.3]
  isempty(low_ids) && return "No low-vitality notes to consolidate."

  low_set = Set(low_ids)
  visited = Set{String}()
  clusters = Vector{String}[]
  for seed in low_ids
    seed in visited && continue
    cluster = String[]
    queue = [(seed, 0)]
    while !isempty(queue)
      id, depth = popfirst!(queue)
      id in visited && continue
      id in low_set || continue
      push!(visited, id)
      push!(cluster, id)
      depth >= 2 && continue
      for nb in @use("./ori/graph").neighbors(engine.graph, id)
        nb in visited || push!(queue, (nb, depth + 1))
      end
    end
    length(cluster) >= 3 && push!(clusters, cluster)
  end

  consolidated = 0
  for cluster in clusters
    bodies = [engine.notes[id].title * ": " * engine.notes[id].body
              for id in cluster if haskey(engine.notes, id)]
    isempty(bodies) && continue

    summary = try
      llm_generate([
        SystemMessage("Summarize these related knowledge notes into one consolidated note. Preserve key facts and use [[Wiki Links]] to connect to other concepts. Return only the note body text."),
        UserMessage(join(bodies, "\n\n---\n\n"))
      ])
    catch e
      @warn "Consolidation LLM call failed" exception=e
      continue
    end

    titles = [engine.notes[id].title for id in cluster if haskey(engine.notes, id)]
    consolidated_title = "Consolidated: " * join(titles[1:min(3, end)], ", ")
    note = update_note!(engine, consolidated_title, summary; type=:note)
    @use("./ori/vitality").record_access!(engine.db, note.id)

    for id in cluster
      n = get(engine.notes, id, nothing)
      n === nothing && continue
      isfile(n.path) && rm(n.path)
      delete!(engine.notes, id)
      SQLite.execute(engine.db, "DELETE FROM vitality WHERE note_id = ?", (id,))
      SQLite.execute(engine.db, "DELETE FROM qvalues WHERE note_id = ?", (id,))
      SQLite.execute(engine.db, "DELETE FROM cooccurrence WHERE source_id = ? OR target_id = ?", (id, id))
    end
    consolidated += 1
  end

  for id in low_ids
    id in visited && continue
    haskey(engine.notes, id) || continue
    v = get(vitality, id, 0.5)
    v >= 0.1 && continue
    incoming = get(engine.graph.incoming, id, Set{String}())
    !isempty(incoming) && continue
    id in engine.bridges && continue
    n = engine.notes[id]
    isfile(n.path) && rm(n.path)
    delete!(engine.notes, id)
    SQLite.execute(engine.db, "DELETE FROM vitality WHERE note_id = ?", (id,))
    SQLite.execute(engine.db, "DELETE FROM qvalues WHERE note_id = ?", (id,))
  end

  consolidated > 0 && rebuild!(engine)

  SQLite.execute(engine.db, """
    INSERT INTO metadata (key, value) VALUES ('last_consolidated_at', ?)
    ON CONFLICT(key) DO UPDATE SET value = ?
  """, (string(Dates.now(Dates.UTC)), string(Dates.now(Dates.UTC))))

  "Consolidated $consolidated clusters, checked $(length(low_ids)) low-vitality notes."
end

# ── Tools ────────────────────────────────────────────────────────────
const TOOLS = Dict{String, Function}()
const TOOL_SCHEMAS = String[]
const TOOL_CONFIRM = Set{String}()

function load_tools!()
  empty!(TOOLS)
  empty!(TOOL_SCHEMAS)
  empty!(TOOL_CONFIRM)
  for file in (HOME*"tools").children
    file.extension == "jl" || continue
    mod = include(string(file))
    n = Base.invokelatest(getfield, mod, :name)
    TOOLS[n] = Base.invokelatest(getfield, mod, :fn)
    push!(TOOL_SCHEMAS, "- $(Base.invokelatest(getfield, mod, :schema))")
    Base.invokelatest(getfield, mod, :needs_confirm) && push!(TOOL_CONFIRM, n)
  end
end

# ── Commands ─────────────────────────────────────────────────────────
const COMMANDS_DIR = HOME * "commands"
const COMMANDS = Dict{String, Module}()

function load_commands!()
  empty!(COMMANDS)
  COMMANDS_DIR.exists || mkpath(COMMANDS_DIR)
  for file in COMMANDS_DIR.children
    file.extension == "jl" || continue
    mod = try
      include(string(file))
    catch e
      @warn "Failed to load command from $file: $e"
      continue
    end
    n = Base.invokelatest(getfield, mod, :name)
    COMMANDS[n] = mod
    @info "Loaded command: $n"
  end
end

# ── Skills ───────────────────────────────────────────────────────────
const SKILLS_DIR = HOME * "skills"

struct Skill
  name::String
  description::String
  content::String
end

function parse_skill(path::String)::Union{Skill, Nothing}
  text = read(path, String)
  m = match(r"^---\s*\n(.*?)\n---\s*\n(.*)"s, text)
  m === nothing && return nothing
  frontmatter = try
    YAML.load(m.captures[1])
  catch e
    @warn "Failed to parse skill frontmatter in $path: $e"
    return nothing
  end
  frontmatter isa Dict || return nothing
  name = get(frontmatter, "name", nothing)
  description = get(frontmatter, "description", "")
  name === nothing && return nothing
  Skill(name, description, strip(String(m.captures[2])))
end

const SKILLS = Dict{String, Skill}()

function load_skills!()
  empty!(SKILLS)
  SKILLS_DIR.exists || mkpath(SKILLS_DIR)
  for file in SKILLS_DIR.children
    file.extension == "md" || continue
    skill = parse_skill(string(file))
    skill === nothing && continue
    SKILLS[skill.name] = skill
    @info "Loaded skill: $(skill.name)"
  end
end

# ── Agents ───────────────────────────────────────────────────────────

struct Envelope
  text::String
  outbox::Channel
  approvals::Channel
  session_history::Vector
  auto_allowed::Set{String}
  conversation_id::Union{String,Nothing}
end

function Envelope(text::String;
                  outbox::Channel=Channel(32),
                  approvals::Channel=Channel(32),
                  session_history::Vector=SESSION_HISTORY,
                  auto_allowed::Set{String}=AUTO_ALLOWED_TOOLS,
                  conversation_id::Union{String,Nothing}=nothing)
  Envelope(text, outbox, approvals, session_history, auto_allowed, conversation_id)
end

struct Agent
  id::String
  personality::String
  instructions::String
  skills::Dict{String, Skill}
  path::FSPath
  repl_module::Module
  repl_log::IOStream
  config::Dict{String, Any}
  llm::LLM
  inbox::Channel
end

function Agent(id::String, personality::String, instructions::String;
               skills::Dict{String, Skill}=Dict{String, Skill}(),
               path::FSPath=HOME*"agents"*id,
               repl_module::Module=Module(Symbol("agent_$id")),
               repl_log::IOStream=open(string(HOME*"agents"*id*"repl.log"), "w"),
               config::Dict{String, Any}=Dict{String, Any}(),
               llm::LLM=LLM(get(CONFIG, "llm", "ollama:llama3"), CONFIG),
               inbox::Channel=Channel(Inf))
  agent = Agent(id, personality, instructions, skills, path, repl_module, repl_log, config, llm, inbox)
  start!(agent)
  agent
end

"Spawn the agent's sequential message-processing loop"
function start!(agent::Agent)
  @async for envelope in agent.inbox
    process_message(envelope.text, agent;
              outbox=envelope.outbox, inbox=envelope.approvals,
              session_history=envelope.session_history,
              auto_allowed=envelope.auto_allowed,
              conversation_id=envelope.conversation_id)
  end
  agent
end

const AGENTS = Dict{String, Agent}()
const AGENTS_DIR = HOME*"agents"

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

function load_agent(agent_dir::FSPath)::Union{Agent, Nothing}
  id = agent_dir.name
  soul_path = agent_dir*"soul.md"
  instr_path = agent_dir*"instructions.md"
  isfile(soul_path) && isfile(instr_path) || return nothing
  logfile = open(string(agent_dir * "repl.log"), "w")
  mod = Module(Symbol("agent_$id"))
  Core.eval(mod, :(using Kip))
  cfg_path = agent_dir * "config.yaml"
  config = try
    isfile(cfg_path) ? YAML.load_file(string(cfg_path)) : Dict{String, Any}()
  catch
    Dict{String, Any}()
  end
  config = config isa Dict ? Dict{String, Any}(config) : Dict{String, Any}()
  Agent(id, read(soul_path, String), read(instr_path, String);
        skills=load_agent_skills(agent_dir), path=agent_dir, repl_module=mod, repl_log=logfile, config)
end

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

function create_agent!(name::String, description::String)::Union{Agent, Nothing}
  agent_dir = AGENTS_DIR * name
  isdir(agent_dir) && return nothing
  mkpath(agent_dir)
  mkpath(agent_dir * "skills")
  soul_content, instr_content = try
    gen_msgs = [
      SystemMessage("""You are creating a new AI agent persona. Generate two markdown files based on the description.

      Reply in this exact format:
      ===SOUL===
      <soul.md content: personality, tone, values — 3-5 short paragraphs>
      ===INSTRUCTIONS===
      <instructions.md content: capabilities, constraints, how to approach tasks — bullet points>"""),
      UserMessage("Agent name: $name\nDescription: $description")
    ]
    result = llm_generate(gen_msgs)
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

function delete_agent!(id::String)::Bool
  id == "prosca" && return false
  haskey(AGENTS, id) || return false
  agent = AGENTS[id]
  delete!(AGENTS, id)
  rm(agent.path; recursive=true, force=true)
  true
end

function update_agent!(id::String; soul::Union{String,Nothing}=nothing, instructions::Union{String,Nothing}=nothing)::Bool
  haskey(AGENTS, id) || return false
  agent = AGENTS[id]
  soul !== nothing && write(agent.path * "soul.md", soul)
  instructions !== nothing && write(agent.path * "instructions.md", instructions)
  updated = load_agent(agent.path)
  updated !== nothing && (AGENTS[id] = updated)
  true
end

function default_agent()::Agent
  isempty(AGENTS) && error("No agents loaded. Check that __init__() ran successfully.")
  get(AGENTS, "prosca", first(values(AGENTS)))
end

function merged_skills(agent::Agent)::Dict{String, Skill}
  merged = copy(SKILLS)
  merge!(merged, agent.skills)
  merged
end

# ── Glob matching for allowed_commands ───────────────────────────────
function _glob_match(str::String, pattern::String)::Bool
  if !contains(pattern, '*')
    return str == pattern
  end
  parts = split(pattern, '*')
  length(parts) == 2 || return false
  startswith(str, parts[1]) && endswith(str, parts[2])
end

# ── System Prompt ────────────────────────────────────────────────────
function build_system_prompt(agent::Agent; active_skill::Union{Skill, Nothing}=nothing)::String
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

  skill_injection = if active_skill !== nothing
    "\n\n# Active Skill: $(active_skill.name)\n$(active_skill.content)\n"
  else
    ""
  end

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

  # Memory provider system prompt
  entry = get(MEMORY_PROVIDERS, agent.id, nothing)
  memory_section = ""
  if entry !== nothing
    provider, _ = entry
    prompt_path = joinpath(@__DIR__, "memory", string(provider), "system.md")
    if isfile(prompt_path)
      memory_section = "\n" * read(prompt_path, String)
    end
  end

  """
  $(agent.personality)

  Current instructions:
  $(agent.instructions)
  $memory_section

  ## Julia REPL
  You have a persistent Julia REPL. Use {"eval": "code"} to evaluate Julia expressions.
  Variables and functions persist across evaluations.
  Use standard Julia for introspection: names(@__MODULE__), methods(f), typeof(x), etc.

  ## Browser JavaScript shorthand
  When the browser skill is active, use {"js": "code"} to execute JavaScript directly in the browser.
  This is equivalent to {"eval": "js(b, \"...\")"} but avoids nested escaping issues.
  The browser variable must be named `b`. Single and double quotes in your JS code are fine.

  ## Built-in Tools
  Available tools (respond with valid JSON only):
  $(join(TOOL_SCHEMAS, "\n"))
  $skill_list
  Or {"final_answer": "your response here"}
  $skill_injection$handoff_section
  """
end

# ── Session State ────────────────────────────────────────────────────
const SESSION_HISTORY = AbstractMessage[]
const AUTO_ALLOWED_TOOLS = Set{String}()

# ── ReAct Agent Loop ─────────────────────────────────────────────────

function message(agent::Agent, text::String)
  outbox = Channel(32)
  approvals = Channel(32)
  reply = Ref("")
  drainer = @async begin
    while true
      event = take!(outbox)
      event isa AgentMessage && (reply[] = event.text)
      event isa AgentDone && break
    end
  end
  put!(agent.inbox, Envelope(text; outbox, approvals))
  @thread begin
    wait(drainer)
    reply[]
  end
end

function process_message(user_input::String, agent::Agent;
                         outbox::Channel, inbox::Channel,
                         session_history=SESSION_HISTORY, auto_allowed=AUTO_ALLOWED_TOOLS,
                         conversation_id::Union{String,Nothing}=nothing)
  try
    _process_message(user_input, agent; outbox, inbox, session_history, auto_allowed, conversation_id)
  catch e
    @error "Agent error" exception=(e, catch_backtrace())
    put!(outbox, AgentMessage("Agent error: $(sprint(showerror, e))"))
    put!(outbox, AgentDone())
  end
end

function _process_message(user_input::String, agent::Agent;
                    outbox::Channel, inbox::Channel,
                    session_history=SESSION_HISTORY, auto_allowed=AUTO_ALLOWED_TOOLS,
                    conversation_id::Union{String,Nothing}=nothing)
  log_memory("User: $user_input"; role="User", agent_id=agent.id, conversation_id)

  active_skill = nothing
  if startswith(user_input, "/")
    parts = split(user_input, limit=2)
    skill_name = parts[1][2:end]
    all_skills_init = merged_skills(agent)
    if haskey(all_skills_init, skill_name)
      active_skill = all_skills_init[skill_name]
      user_input = length(parts) > 1 ? strip(parts[2]) : skill_name
      @info "Activated skill: $(skill_name)"
    end
  end

  memories = search_memories(user_input; agent_id=agent.id, conversation_id)
  messages = AbstractMessage[SystemMessage(build_system_prompt(agent; active_skill))]

  window = session_history[max(1, end-19):end]
  append!(messages, window)
  push!(messages, UserMessage("$memories\n\nTask: $user_input"))

  max_steps = get(CONFIG, "max_steps", 1000)
  hit_limit = false
  for step in 1:max_steps
    if step > 1 && step % 5 == 0
      user_names = filter(n -> n != Symbol(agent.repl_module), names(agent.repl_module; all=false))
      if !isempty(user_names)
        scope = join(user_names, ", ")
        push!(messages, UserMessage("[REPL scope] Variables: $scope"))
      end
    end

    response_text = try
      temperature = get(CONFIG, "temperature", 0.7)
      system, user = flatten_messages(messages)
      stream = agent.llm(system, user; temperature)
      buf = IOBuffer()
      while !eof(stream)
        chunk = String(readavailable(stream))
        !isempty(chunk) && (write(buf, chunk); put!(outbox, StreamToken(chunk)))
      end
      String(take!(buf))
    catch e
      put!(outbox, AgentMessage("LLM error: $(sprint(showerror, e))"))
      break
    end
    @debug "LLM response ($(length(response_text)) chars): $(first(response_text, 200))"

    json_str = strip(response_text)
    m = match(r"```(?:json)?\s*\n?(.*?)\n?\s*```"s, json_str)
    if m !== nothing
      json_str = strip(m.captures[1])
    end
    if !startswith(json_str, "{")
      for line in reverse(split(json_str, '\n'))
        stripped = strip(line)
        if startswith(stripped, "{") && endswith(stripped, "}")
          json_str = stripped
          break
        end
      end
    end

    parsed = try
      result = JSON3.read(json_str)
      result isa AbstractDict ? result : nothing
    catch
      # Try extracting just the first JSON object (LLM may concatenate multiple)
      first_obj = match(r"\{(?:[^{}]|\{[^{}]*\})*\}", json_str)
      if first_obj !== nothing
        try
          result = JSON3.read(first_obj.match)
          result isa AbstractDict ? result : nothing
        catch
          nothing
        end
      else
        nothing
      end
    end

    if parsed === nothing
      looks_like_json = contains(response_text, "\"tool\"") && contains(response_text, "\"args\"") ||
                        contains(response_text, "\"eval\"") ||
                        contains(response_text, "\"js\"") ||
                        contains(response_text, "\"final_answer\"") ||
                        contains(response_text, "\"skill\"") ||
                        contains(response_text, "\"handoff\"")
      if looks_like_json
        push!(messages, AIMessage(response_text))
        push!(messages, UserMessage("Your JSON was malformed and couldn't be parsed. Return exactly ONE JSON object per response. Try again."))
        @warn "Malformed JSON from LLM, asking to retry" response_text
        continue
      end
      put!(outbox, AgentMessage(response_text))
      log_memory("Agent: $response_text"; agent_id=agent.id, conversation_id)
      break
    end

    if haskey(parsed, :final_answer)
      put!(outbox, AgentMessage(parsed.final_answer))
      log_memory("Agent: $(parsed.final_answer)"; agent_id=agent.id, conversation_id)
      break
    end

    if haskey(parsed, :skill)
      sn = string(parsed.skill)
      all_skills = merged_skills(agent)
      if haskey(all_skills, sn)
        active_skill = all_skills[sn]
        @info "LLM activated skill: $sn"
        messages[1] = SystemMessage(build_system_prompt(agent; active_skill))
        push!(messages, AIMessage(response_text))
        push!(messages, UserMessage("Skill '$sn' activated. Proceed with the task using this skill's guidance."))
        continue
      else
        push!(messages, AIMessage(response_text))
        push!(messages, UserMessage("Unknown skill '$sn'. Available: $(join(keys(all_skills), ", "))"))
        continue
      end
    end

    if haskey(parsed, :handoff)
      to_agent_id = string(get(parsed.handoff, :to_agent, ""))
      reason = string(get(parsed.handoff, :reason, ""))
      context_summary = string(get(parsed.handoff, :context, ""))

      if !haskey(AGENTS, to_agent_id)
        push!(messages, AIMessage(response_text))
        available = join([a.id for a in values(AGENTS) if a.id != agent.id], ", ")
        push!(messages, UserMessage("Unknown agent '$to_agent_id'. Available agents: $available"))
        continue
      end

      new_conv_id = string(UUIDs.uuid4())
      try
        SQLite.execute(DB[], """
          INSERT INTO conversations (id, agent_id, title, handed_off_from, created_at, updated_at)
          VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
        """, (new_conv_id, to_agent_id, "Handoff: $reason", conversation_id))
        if conversation_id !== nothing
          SQLite.execute(DB[], "UPDATE conversations SET handed_off_to=?, updated_at=datetime('now') WHERE id=?",
                         (new_conv_id, conversation_id))
        end
      catch e
        @warn "Failed to record handoff in DB: $e"
      end

      put!(outbox, AgentMessage("Handing off to **$to_agent_id**: $reason"))
      log_memory("Handoff to $to_agent_id: $reason\nContext: $context_summary"; agent_id=agent.id, conversation_id)
      break
    end

    if haskey(parsed, :eval)
      code = string(parsed.eval)
      result = try
        cd(string(agent.path)) do
          interpret(agent.repl_module, code; outbox, inbox, log=agent.repl_log)
        end
      catch e
        e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
      end
      put!(outbox, ToolResult("eval", result))
      log_memory("Eval: $code → $(first(result, 500))"; agent_id=agent.id, conversation_id)
      push!(messages, AIMessage(response_text))
      push!(messages, UserMessage("Result: $result"))
      continue
    end

    if haskey(parsed, :js)
      js_code = string(parsed.js)
      code = "js(b, $(repr(js_code)))"
      result = try
        cd(string(agent.path)) do
          interpret(agent.repl_module, code; outbox, inbox, log=agent.repl_log)
        end
      catch e
        e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
      end
      put!(outbox, ToolResult("js", result))
      log_memory("JS: $(first(js_code, 200)) → $(first(result, 500))"; agent_id=agent.id, conversation_id)
      push!(messages, AIMessage(response_text))
      push!(messages, UserMessage("Result: $result"))
      continue
    end

    if get(parsed, :index_page, nothing) == true
      code = "index_page(b)"
      result = try
        cd(string(agent.path)) do
          interpret(agent.repl_module, code; outbox, inbox, log=agent.repl_log)
        end
      catch e
        e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
      end
      put!(outbox, ToolResult("index_page", result))
      log_memory("State: $(first(result, 500))"; agent_id=agent.id, conversation_id)
      push!(messages, AIMessage(response_text))
      push!(messages, UserMessage("Result: $result"))
      continue
    end

    tool_name = get(parsed, :tool, nothing)
    tn = tool_name === nothing ? "" : string(tool_name)
    args_str = haskey(parsed, :args) ? JSON3.write(parsed.args) : "{}"

    if !haskey(TOOLS, tn)
      push!(messages, AIMessage(response_text))
      push!(messages, UserMessage("Error: Unknown tool '$tn'. Use {\"eval\": \"...\"} for Julia code, or use a valid tool name, or return {\"final_answer\": \"...\"}"))
      continue
    end

    needs_confirm = tn in TOOL_CONFIRM && tn ∉ auto_allowed

    if needs_confirm
      req_id = rand(UInt64)
      put!(outbox, ToolCallRequest(tn, args_str, req_id))
      approval = take!(inbox)
      if approval isa ToolApproval && approval.id == req_id
        if approval.decision == :always
          push!(auto_allowed, tn)
        elseif approval.decision == :deny
          push!(messages, AIMessage(response_text))
          push!(messages, UserMessage("Tool call to '$tn' was denied by user. Try a different approach or ask the user."))
          continue
        end
      end
    end

    result = try
      TOOLS[tn](parsed.args)
    catch e
      "Tool error ($(typeof(e))): $(sprint(showerror, e))"
    end
    @info "Tool result: $(first(result, 200))"
    put!(outbox, ToolResult(tn, result))
    log_memory("Tool: $tn($args_str) → $(first(result, 500))"; agent_id=agent.id, conversation_id)

    push!(messages, AIMessage(response_text))
    push!(messages, UserMessage("Tool result: $result"))
    step == max_steps && (hit_limit = true)
  end

  if hit_limit
    put!(outbox, AgentMessage("Stopped: reached the maximum of $max_steps steps."))
  end

  put!(outbox, AgentDone())

  push!(session_history, UserMessage(user_input))
  for i in length(messages):-1:1
    if messages[i] isa AIMessage
      push!(session_history, messages[i])
      break
    end
  end

  # Async memory retention
  entry = get(MEMORY_PROVIDERS, agent.id, nothing)
  if entry !== nothing
    provider, conn = entry
    if provider == :ori
      @async begin
        try
          lock(ori_lock(agent.id)) do
            extract_knowledge(messages, agent.id)
          end
        catch e
          @warn "Knowledge extraction failed" exception=e
        end
      end
    elseif provider == :hindsight
      @async begin
        try
          hs = @use("./memory/hindsight/hindsight")
          last_response = ""
          for i in length(messages):-1:1
            if messages[i] isa AIMessage
              last_response = messages[i].content
              break
            end
          end
          Base.invokelatest(hs.retain, conn, "User: $user_input\n\nAssistant: $last_response";
                           context="conversation turn")
        catch e
          @warn "Hindsight retain failed" exception=e
        end
      end
    end
  end
end

# ── Initialization (runs at runtime, not precompile) ─────────────────

function __init__()
  # Skip runtime initialization during precompilation
  Base.generating_output() && return

  # Load config
  if !isfile(HOME * "config.yaml")
    YAML.write_file(HOME * "config.yaml", Dict(
      "llm" => "qwen3.5:27b",
      "github_token" => "",
      "allowed_dirs" => [HOME, expanduser("~/projects")],
      "allowed_commands" => ["ls *", "cat *", "head *", "tail *", "grep *", "find *", "git *", "julia *", "pwd", "echo *", "wc *", "open *", "/Applications/Google Chrome.app/*"],
      "log_level" => "info",
    ))
  end
  merge!(CONFIG, YAML.load_file(string(HOME * "config.yaml")))
  Logging.global_logger(Logging.ConsoleLogger(stderr, get(LOG_LEVELS, get(CONFIG, "log_level", "warn"), Logging.Warn)))

  # Initialize DB
  db_path = HOME * "memories/memories.db"
  db_path.exists || mkpath(db_path.parent)
  DB[] = SQLite.DB(string(db_path))

  # Create tables
  SQLite.execute(DB[], """
    CREATE TABLE IF NOT EXISTS memories (
      id INTEGER PRIMARY KEY, timestamp TEXT, role TEXT, content TEXT,
      embedding TEXT, metadata TEXT DEFAULT '{}', conversation_id TEXT DEFAULT NULL
    )""")
  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_timestamp ON memories(timestamp)")
  try SQLite.execute(DB[], "ALTER TABLE memories ADD COLUMN conversation_id TEXT DEFAULT NULL") catch end
  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_conversation_id ON memories(conversation_id)")
  try SQLite.execute(DB[], "ALTER TABLE memories ADD COLUMN agent_id TEXT DEFAULT 'prosca'") catch end
  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_agent_id ON memories(agent_id)")

  SQLite.execute(DB[], """
    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
      is_default INTEGER DEFAULT 0, paused INTEGER DEFAULT 0, model TEXT,
      idle_check_mins INTEGER DEFAULT 30, tokens_used INTEGER DEFAULT 0,
      cost_usd REAL DEFAULT 0.0, last_checked_at TEXT, created_at TEXT, metadata TEXT DEFAULT '{}'
    )""")
  try SQLite.execute(DB[], "ALTER TABLE projects ADD COLUMN paused INTEGER DEFAULT 0") catch end

  SQLite.execute(DB[], """
    CREATE TABLE IF NOT EXISTS routines (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
      name TEXT NOT NULL, prompt TEXT NOT NULL, model TEXT, schedule_natural TEXT,
      schedule_cron TEXT, enabled INTEGER DEFAULT 1, tokens_used INTEGER DEFAULT 0,
      cost_usd REAL DEFAULT 0.0, last_run_at TEXT, next_run_at TEXT, created_at TEXT, metadata TEXT DEFAULT '{}'
    )""")

  SQLite.execute(DB[], """
    CREATE TABLE IF NOT EXISTS routine_runs (
      id INTEGER PRIMARY KEY, routine_id TEXT REFERENCES routines(id),
      project_id TEXT REFERENCES projects(id), started_at TEXT, finished_at TEXT,
      result TEXT, tokens_used INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0,
      notable INTEGER DEFAULT 0, seen INTEGER DEFAULT 0
    )""")

  SQLite.execute(DB[], """
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY, agent_id TEXT NOT NULL DEFAULT 'prosca',
      title TEXT NOT NULL DEFAULT 'New chat', handed_off_to TEXT,
      handed_off_from TEXT, created_at TEXT, updated_at TEXT
    )""")

  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_routines_project ON routines(project_id)")
  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_routine_runs_project ON routine_runs(project_id)")
  SQLite.execute(DB[], "CREATE INDEX IF NOT EXISTS idx_routine_runs_notable ON routine_runs(notable, seen)")

  # Default project
  let rows = SQLite.DBInterface.execute(DB[], "SELECT COUNT(*) as c FROM projects WHERE is_default=1") |> SQLite.rowtable
    if rows[1].c == 0
      personal_path = joinpath(string(HOME), "personal") * "/"
      mkpath(personal_path)
      if !isfile(joinpath(personal_path, "Project.md"))
        write(joinpath(personal_path, "Project.md"), "# Personal Project\n\nThis is your default project.\n\n## Goals\n\n- Add your goals here\n")
      end
      SQLite.execute(DB[], """
        INSERT INTO projects (id, name, path, is_default, created_at)
        VALUES (?, 'Personal', ?, 1, datetime('now'))
      """, (string(UUIDs.uuid4()), personal_path))
    end
  end

  # Initialize mail auth if configured
  gw = get(CONFIG, "gateway", Dict())
  zoho_cfg = get(gw, "zoho_mail", nothing)
  if zoho_cfg !== nothing
    MAIL_AUTH[] = MailAuth(zoho_cfg)
    @info "Mail configured for $(zoho_cfg["from_address"])"
  end

  # Load everything
  load_tools!()
  load_commands!()
  load_skills!()
  load_agents!()

  # Initialize memory providers per agent
  for (agent_id, agent) in AGENTS
    provider_name = get(agent.config, "memory", "ori")
    try
      if provider_name == "ori"
        vault_dir = string(agent.path * "vault")
        mkpath(vault_dir)
        MEMORY_PROVIDERS[agent_id] = (:ori, init_engine(vault_dir))
        @info "Memory: ori for agent=$agent_id"
      elseif provider_name == "hindsight"
        hs = @use("./memory/hindsight/hindsight")
        llm_key = get(CONFIG, "openai_key", "")
        port = get(CONFIG, "hindsight_port", 8888)
        admin_port = get(CONFIG, "hindsight_admin_port", 9999)
        conn = Base.invokelatest(hs.init, agent_id; port, admin_port, llm_key, mission=agent.personality)
        if conn !== nothing
          MEMORY_PROVIDERS[agent_id] = (:hindsight, conn)
          @info "Memory: hindsight for agent=$agent_id"
        else
          @warn "Hindsight init failed for agent=$agent_id, running without memory"
        end
      else
        @warn "Unknown memory provider '$provider_name' for agent=$agent_id"
      end
    catch e
      @warn "Memory init failed for agent=$agent_id" exception=e
    end
  end

  # Daily consolidation check (Ori agents only)
  for (agent_id, (provider, conn)) in MEMORY_PROVIDERS
    provider == :ori || continue
    try
      row = SQLite.DBInterface.execute(conn.db,
        "SELECT value FROM metadata WHERE key = 'last_consolidated_at'") |> collect
      needs_consolidation = if isempty(row) || row[1].value === missing
        true
      else
        last_run = Dates.DateTime(row[1].value)
        Dates.now(Dates.UTC) - last_run > Dates.Day(1)
      end
      if needs_consolidation
        lock(ori_lock(agent_id)) do
          result = consolidate!(conn, agent_id)
          @info "Consolidation for $agent_id: $result"
        end
      end
    catch e
      @warn "Consolidation check failed for $agent_id" exception=e
    end
  end

  # Trust modules that the agent's skills depend on
  for mod in [HTTP, JSON3, Base64]
    push!(TRUSTED_MODULES, mod)
  end

end

# Export everything that json_io.jl and other consumers need
for n in names(@__MODULE__; all=true)
  n in (nameof(@__MODULE__), :eval, :include) && continue
  startswith(string(n), '#') && continue
  startswith(string(n), '⭒') && continue
  @eval export $n
end

