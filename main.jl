@use "github.com/jkroso/URI.jl/FSPath" home FSPath
@use "github.com/jkroso/Promises.jl" @thread
@use "github.com/jkroso/LLM.jl" LLM search
@use Serialization
@use "github.com/jkroso/LLM.jl/providers/abstract_provider" Message SystemMessage UserMessage AIMessage ToolResultMessage Tool ToolCall FinishReason Image ImageURL ImageData Audio Document
@use "github.com/jkroso/JSON.jl" parse_json write_json
@use "./gateway/mail_api" mail_request mail_send mail_list mail_get mail_mark_read MailAPIError
@use "./repl" interpret interpret_value TRUSTED_MODULES
@use "./calc_summary"...
@use "./calcs" load_translator!
@use "./gateway/mail_auth" MailAuth ensure_token!
@use "./safety"...
@use LibGit2
@use Logging
@use SQLite
@use Base64
@use Dates
@use UUIDs
@use YAML

# ── Constants set at precompile time ─────────────────────────────────
const HOME = mkpath(home() * "Caesar")
const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)

# ── Mutable state initialized at runtime ─────────────────────────────
const CONFIG = Dict{String,Any}()
const DB = Ref{SQLite.DB}()
const MAIL_AUTH = Ref{Union{MailAuth, Nothing}}(nothing)

const MEMORY_PROVIDERS = Dict{String, Tuple{Symbol, Any}}()
const MODEL_CACHE_PATH = HOME * "model_cache.bin"

"Save a model info NamedTuple to disk for fast boot"
function cache_model_info(info::NamedTuple)
  Serialization.serialize(string(MODEL_CACHE_PATH), info)
end

"Load a cached model info NamedTuple from disk, or nothing if missing/stale"
function load_cached_model_info(model::String)::Union{NamedTuple, Nothing}
  isfile(MODEL_CACHE_PATH) || return nothing
  info = try Serialization.deserialize(string(MODEL_CACHE_PATH)) catch; return nothing end
  info isa NamedTuple || return nothing
  cached_id = "$(info.provider)/$(info.id)"
  model == cached_id || model == info.id || return nothing
  info
end

"Create an LLM, using the disk cache when possible"
function cached_LLM(model::String, config::Dict)::LLM
  info = load_cached_model_info(model)
  if info !== nothing
    return LLM(info, config)
  end
  llm = LLM(model, config)
  cache_model_info(llm.info)
  llm
end

"Ensure a model string has a provider prefix (e.g. 'ollama/gemma4:31b') to avoid slow all-provider scan"
function ensure_provider_prefix(model::AbstractString)::String
  s = string(model)
  contains(s, '/') && return s
  isempty(s) && return s
  allowed = get(CONFIG, "providers", nothing)
  allowed_ids = allowed isa Vector ? union(string.(allowed), ["ollama"]) : String[]
  results = search("", s; max_results=1, allowed_providers=allowed_ids)
  if isempty(results)
    return s
  end
  cache_model_info(results[1])
  "$(results[1].provider)/$(results[1].id)"
end

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
  args::String
  result::String
end

struct StreamToken
  text::String
end

struct AgentDone
  input_tokens::Int
  output_tokens::Int
end
AgentDone() = AgentDone(0, 0)

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
"Send messages to the default LLM and return the full response text"

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
  if provider == :hindsight
    hs = @use("./memory/hindsight/hindsight")
    results = Base.invokelatest(hs.recall, conn, query; limit)
    isempty(results) && return "(no relevant memories)"
    lines = [get(r, "text", "") for r in results]
    "=== Relevant memories ===\n" * join(lines, "\n\n")
  elseif provider == :ori
    ori = @use("./memory/ori/ori")
    results = Base.invokelatest(ori.recall, conn, query; limit)
    isempty(results) && return "(no relevant memories)"
    lines = [get(r, "text", "") for r in results]
    "=== Relevant memories ===\n" * join(lines, "\n\n")
  else
    "(unknown memory provider)"
  end
end


# ── Tools ────────────────────────────────────────────────────────────
const TOOL_FNS = Dict{String, Function}()
const TOOL_DEFS = Tool[]
const TOOL_CONFIRM = Set{String}()

# Built-in tools
const EVAL_TOOL = Tool("eval", "Evaluate Julia code in the agent's sandboxed REPL. Variables persist across calls.",
  Dict("type"=>"object", "properties"=>Dict("code"=>Dict("type"=>"string", "description"=>"Julia code to evaluate")), "required"=>["code"]))

const JS_TOOL = Tool("js", "Execute JavaScript in the browser via the GUI sidecar",
  Dict("type"=>"object", "properties"=>Dict("code"=>Dict("type"=>"string", "description"=>"JavaScript code to execute")), "required"=>["code"]))

function load_tools!()
  empty!(TOOL_FNS)
  empty!(TOOL_DEFS)
  empty!(TOOL_CONFIRM)
  push!(TOOL_DEFS, EVAL_TOOL)
  push!(TOOL_DEFS, JS_TOOL)
  for file in (HOME*"tools").children
    file.extension == "jl" || continue
    mod = include(string(file))
    n = Base.invokelatest(getfield, mod, :name)
    TOOL_FNS[n] = Base.invokelatest(getfield, mod, :fn)
    desc = Base.invokelatest(getfield, mod, :description)
    params = Base.invokelatest(getfield, mod, :parameters)
    push!(TOOL_DEFS, Tool(n, desc, params))
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
  auto_allowed::Set{String}
  conversation_id::Union{String,Nothing}
  images::Vector{Image}
  audio::Vector{Audio}
  documents::Vector{Document}
end

function Envelope(text::String;
                  outbox::Channel=Channel(32),
                  approvals::Channel=Channel(32),
                  auto_allowed::Set{String}=AUTO_ALLOWED_TOOLS,
                  conversation_id::Union{String,Nothing}=nothing,
                  images::Vector{Image}=Image[],
                  audio::Vector{Audio}=Audio[],
                  documents::Vector{Document}=Document[])
  Envelope(text, outbox, approvals, auto_allowed, conversation_id, images, audio, documents)
end

mutable struct Agent
  id::String
  personality::String
  instructions::String
  skills::Dict{String, Skill}
  path::FSPath
  repl_module::Module
  repl_log::IOStream
  config::Dict{String, Any}
  llm::LLM
  history::Vector{Message}
  inbox::Channel
end

function Agent(id::String, personality::String, instructions::String;
               skills::Dict{String, Skill}=Dict{String, Skill}(),
               path::FSPath=HOME*"agents"*id,
               repl_module::Module=Module(Symbol("agent_$id")),
               repl_log::IOStream=open(string(HOME*"agents"*id*"repl.log"), "w"),
               config::Dict{String, Any}=Dict{String, Any}(),
               llm::LLM=cached_LLM(get(CONFIG, "llm", "ollama:llama3"), CONFIG),
               history::Vector{Message}=Message[],
               inbox::Channel=Channel(Inf))
  agent = Agent(id, personality, instructions, skills, path, repl_module, repl_log, config, llm, history, inbox)
  start!(agent)
  agent
end

"Spawn the agent's sequential message-processing loop"
function start!(agent::Agent)
  @async for envelope in agent.inbox
    process_message(envelope.text, agent;
              outbox=envelope.outbox, inbox=envelope.approvals,
              auto_allowed=envelope.auto_allowed,
              conversation_id=envelope.conversation_id,
              images=envelope.images, audio=envelope.audio, documents=envelope.documents)
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
    cfg_path = entry * "config.yaml"
    if isfile(cfg_path)
      cfg = try YAML.load_file(string(cfg_path)) catch; Dict() end
      cfg isa Dict && get(cfg, "hidden", false) === true && continue
    end
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
    result = read(default_agent().llm(gen_msgs), String)
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

  ## Tools
  Use the `eval` tool to run Julia code in your persistent REPL. Variables and functions survive across calls.
  Use the `js` tool to execute JavaScript in the browser when the browser skill is active.

  When you have the final answer for the user, respond with plain text (no tool call).
  $skill_list
  $skill_injection$handoff_section
  """
end

# ── Session State ────────────────────────────────────────────────────
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
                         auto_allowed=AUTO_ALLOWED_TOOLS,
                         conversation_id::Union{String,Nothing}=nothing,
                         images::Vector{Image}=Image[], audio::Vector{Audio}=Audio[], documents::Vector{Document}=Document[])
  try
    _process_message(user_input, agent; outbox, inbox, auto_allowed, conversation_id, images, audio, documents)
  catch e
    @error "Agent error" exception=(e, catch_backtrace())
    put!(outbox, AgentMessage("Agent error: $(sprint(showerror, e))"))
    put!(outbox, AgentDone())
  end
end

function _process_message(user_input::String, agent::Agent;
                    outbox::Channel, inbox::Channel,
                    auto_allowed=AUTO_ALLOWED_TOOLS,
                    conversation_id::Union{String,Nothing}=nothing,
                    images::Vector{Image}=Image[], audio::Vector{Audio}=Audio[], documents::Vector{Document}=Document[])
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
  messages = Message[SystemMessage(build_system_prompt(agent; active_skill))]

  window = agent.history[max(1, end-19):end]
  append!(messages, window)
  push!(messages, UserMessage("$memories\n\nTask: $user_input", images, audio, documents))

  max_steps = get(CONFIG, "max_steps", 1000)
  hit_limit = false
  total_input_tokens = 0
  total_output_tokens = 0
  for step in 1:max_steps
    if step > 1 && step % 5 == 0
      user_names = filter(n -> n != Symbol(agent.repl_module), names(agent.repl_module; all=false))
      if !isempty(user_names)
        scope = join(user_names, ", ")
        push!(messages, UserMessage("[REPL scope] Variables: $scope"))
      end
    end

    # Call LLM with tools
    stream = try
      temperature = get(CONFIG, "temperature", 0.7)
      open(string(agent.path * "last_prompt.md"), "w") do io
        for m in messages
          println(io, "## ", typeof(m).name.name)
          if m isa AIMessage
            !isempty(m.text) && println(io, m.text)
            for tc in m.tool_calls
              println(io, "  tool_call: $(tc.name)($(write_json(tc.arguments)))")
            end
          elseif m isa ToolResultMessage
            println(io, m.content)
          else
            println(io, m.text)
          end
          println(io)
        end
      end
      agent.llm(Message[m for m in messages]; temperature, tools=TOOL_DEFS)
    catch e
      put!(outbox, AgentMessage("LLM error: $(sprint(showerror, e))"))
      break
    end

    # Stream text tokens to outbox
    buf = IOBuffer()
    while !eof(stream)
      chunk = String(readavailable(stream))
      !isempty(chunk) && (write(buf, chunk); put!(outbox, StreamToken(chunk)))
    end
    response_text = String(take!(buf))
    tool_calls = stream.tool_calls
    finish_reason = stream.finish_reason
    # Accumulate token usage
    try
      input_tok, output_tok = stream.tokens
      total_input_tokens += Int(input_tok.value)
      total_output_tokens += Int(output_tok.value)
    catch; end
    close(stream)

    # No tool calls — treat as final text response
    if isempty(tool_calls)
      text = String(strip(response_text))
      isempty(text) && (step == max_steps && (hit_limit = true); continue)
      put!(outbox, AgentMessage(text))
      log_memory("Agent: $text"; agent_id=agent.id, conversation_id)
      push!(messages, AIMessage(text))
      break
    end

    # Process tool calls
    push!(messages, AIMessage(response_text, tool_calls))
    for tc in tool_calls
      result = if tc.name == "eval"
        code = get(tc.arguments, "code", "")
        try
          cd(string(agent.path)) do
            interpret(agent.repl_module, code; outbox, inbox, log=agent.repl_log)
          end
        catch e
          e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
        end
      elseif tc.name == "js"
        js_code = get(tc.arguments, "code", "")
        try
          cd(string(agent.path)) do
            interpret(agent.repl_module, "js(b, $(repr(js_code)))"; outbox, inbox, log=agent.repl_log)
          end
        catch e
          e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
        end
      elseif haskey(TOOL_FNS, tc.name)
        # Check confirmation
        if tc.name in TOOL_CONFIRM && tc.name ∉ auto_allowed
          req_id = rand(UInt64)
          put!(outbox, ToolCallRequest(tc.name, write_json(tc.arguments), req_id))
          approval = take!(inbox)
          if approval isa ToolApproval && approval.id == req_id
            if approval.decision == :always
              push!(auto_allowed, tc.name)
            elseif approval.decision == :deny
              push!(messages, ToolResultMessage(tc.id, "Tool call denied by user."))
              continue
            end
          end
        end
        try
          TOOL_FNS[tc.name](tc.arguments)
        catch e
          "Tool error: $(sprint(showerror, e))"
        end
      else
        "Unknown tool '$(tc.name)'"
      end

      put!(outbox, ToolResult(tc.name, write_json(tc.arguments), result))
      log_memory("$(tc.name): $(first(result, 500))"; agent_id=agent.id, conversation_id)
      truncated = length(result) > 4000 ? first(result, 4000) * "\n... (truncated)" : result
      push!(messages, ToolResultMessage(tc.id, truncated))
    end
    step == max_steps && (hit_limit = true)
  end

  if hit_limit
    put!(outbox, AgentMessage("Stopped: reached the maximum of $max_steps steps."))
  end

  put!(outbox, AgentDone(total_input_tokens, total_output_tokens))

  push!(agent.history, UserMessage(user_input))
  for i in length(messages):-1:1
    if messages[i] isa AIMessage
      push!(agent.history, messages[i])
      break
    end
  end

  # Async memory retention
  entry = get(MEMORY_PROVIDERS, agent.id, nothing)
  if entry !== nothing
    provider, conn = entry
    if provider == :hindsight
      @async begin
        try
          hs = @use("./memory/hindsight/hindsight")
          last_response = ""
          for i in length(messages):-1:1
            if messages[i] isa AIMessage
              last_response = messages[i].text
              break
            end
          end
          Base.invokelatest(hs.retain, conn, "User: $user_input\n\nAssistant: $last_response";
                           context="conversation turn")
        catch e
          @warn "Hindsight retain failed" exception=e
        end
      end
    elseif provider == :ori
      @async begin
        try
          ori = @use("./memory/ori/ori")
          last_response = ""
          for i in length(messages):-1:1
            if messages[i] isa AIMessage
              last_response = messages[i].text
              break
            end
          end
          Base.invokelatest(ori.retain, conn,
            "User: $user_input\n\nAssistant: $last_response";
            context="conversation turn")
        catch e
          @warn "Ori retain failed" exception=e
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
  db_path = HOME * "memory/main.db"
  db_path.exists || mkpath(db_path.parent)
  DB[] = SQLite.DB(string(db_path))

  # Create tables
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
      handed_off_from TEXT, created_at TEXT, updated_at TEXT,
      messages TEXT DEFAULT '[]'
    )""")
  # Add messages column if missing (existing DBs)
  try SQLite.execute(DB[], "ALTER TABLE conversations ADD COLUMN messages TEXT DEFAULT '[]'") catch end

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

  try
    load_translator!()
    @info "Loaded calc translator agent"
  catch e
    @warn "Failed to load calc translator agent" exception=e
  end

  # Initialize memory providers per agent
  for (agent_id, agent) in AGENTS
    provider_name = get(agent.config, "memory", "hindsight")
    try
      if provider_name == "hindsight"
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
      elseif provider_name == "ori"
        ori = @use("./memory/ori/ori")
        ori_config = get(agent.config, "ori", Dict())
        vault_dir = string(agent.path * get(ori_config, "vault_dir", "vault"))
        cmd = get(ori_config, "command", "npx")
        conn = Base.invokelatest(ori.init, agent_id; vault_dir, command=cmd, personality=agent.personality)
        if conn !== nothing
          MEMORY_PROVIDERS[agent_id] = (:ori, conn)
          @info "Memory: ori for agent=$agent_id vault=$vault_dir"
        else
          @warn "Ori init failed for agent=$agent_id, running without memory"
        end
      else
        @warn "Unknown memory provider '$provider_name' for agent=$agent_id"
      end
    catch e
      @warn "Memory init failed for agent=$agent_id" exception=e
    end
  end

  # Trust modules that the agent's skills depend on
  for mod in [Base64]
    push!(TRUSTED_MODULES, mod)
  end

end

export CONFIG, DB, AGENTS, COMMANDS, SKILLS, HOME, AUTO_ALLOWED_TOOLS,
       MEMORY_PROVIDERS,
       Agent, AgentDone, AgentMessage, StreamToken, ToolCallRequest, ToolResult,
       ToolApproval, Envelope, InboundEnvelope, OutboundEnvelope,
       PresenceRouter,
       default_agent, create_agent!, delete_agent!, update_agent!,
       cached_LLM, cache_model_info, ensure_provider_prefix,
       log_memory,
       route_approval, resolve_approval, check_pending_approvals!,
       primary_adapter, register_adapter!, channel_symbol, send_message,
       start!

