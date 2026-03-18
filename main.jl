@use "github.com/jkroso/URI.jl/FSPath" home FSPath
@use LinearAlgebra...
@use PromptingTools
@use RAGTools...
@use LibGit2
@use Logging
@use SQLite
@use JSON3
@use Dates
@use HTTP
@use YAML
@use UUIDs
@use "./safety"...
@use "./repl" interpret require TRUSTED_DIRS

# ── Constants set at precompile time ─────────────────────────────────
const HOME = mkpath(home() * "Prosca")
const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)

# ── Mutable state initialized at runtime ─────────────────────────────
const CONFIG = Dict{String,Any}()
const DB = Ref{SQLite.DB}()
const LLM_SCHEMA = Ref{Any}()
const EMBED_MODEL = Ref{String}("qwen3-embedding:8b")

# Agent → Interface events
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

struct AgentDone end

# Interface → Agent events
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

# ── LLM Schema Detection ────────────────────────────────────────────

function _detect_schema()
  model = get(CONFIG, "llm", "")
  _detect_schema_for(model)
end

function _detect_schema_for(model::String)
  if startswith(model, "ollama:")
    PromptingTools.OllamaSchema()
  elseif startswith(model, "gpt-") || startswith(model, "o3") || startswith(model, "o4")
    haskey(CONFIG, "openai_key") && (ENV["OPENAI_API_KEY"] = CONFIG["openai_key"])
    PromptingTools.OpenAISchema()
  elseif startswith(model, "claude-")
    haskey(CONFIG, "anthropic_key") && (ENV["ANTHROPIC_API_KEY"] = CONFIG["anthropic_key"])
    PromptingTools.AnthropicSchema()
  elseif startswith(model, "gemini-")
    haskey(CONFIG, "google_key") && (ENV["GOOGLE_API_KEY"] = CONFIG["google_key"])
    PromptingTools.GoogleSchema()
  elseif startswith(model, "mistral-")
    haskey(CONFIG, "mistral_key") && (ENV["MISTRAL_API_KEY"] = CONFIG["mistral_key"])
    PromptingTools.MistralOpenAISchema()
  elseif startswith(model, "deepseek-")
    haskey(CONFIG, "deepseek_key") && (ENV["DEEPSEEK_API_KEY"] = CONFIG["deepseek_key"])
    PromptingTools.DeepSeekOpenAISchema()
  elseif startswith(model, "grok-")
    haskey(CONFIG, "xai_key") && (ENV["XAI_API_KEY"] = CONFIG["xai_key"])
    PromptingTools.XAIOpenAISchema()
  else
    PromptingTools.OllamaSchema()
  end
end

# ── Embeddings ───────────────────────────────────────────────────────
const EMBED_SCHEMA = PromptingTools.OllamaSchema()

function get_embedding(text::String)::Union{Vector{Float64}, Nothing}
  try
    msg = PromptingTools.aiembed(EMBED_SCHEMA, text; model=EMBED_MODEL[], copy=true)
    normalize(vec(msg.content))
  catch e
    @warn "Embedding failed: $e"
    nothing
  end
end

# ── Memory (RAGTools) ────────────────────────────────────────────────
const MEMORY_INDEXES = Dict{Tuple{String, Union{String,Nothing}}, ChunkIndex}()

function rebuild_memory_index(; agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  query, params = if conversation_id !== nothing
    "SELECT id, content FROM memories WHERE agent_id = ? AND conversation_id = ? ORDER BY timestamp DESC", (agent_id, conversation_id)
  else
    "SELECT id, content FROM memories WHERE agent_id = ? AND conversation_id IS NULL ORDER BY timestamp DESC", (agent_id,)
  end
  rows = map(SQLite.DBInterface.execute(DB[], query, params)) do row
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

function log_memory(text::String; role::String="Agent", metadata=Dict(),
                    agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  emb = get_embedding(text)
  stmt = SQLite.Stmt(DB[], """
    INSERT INTO memories (timestamp, role, content, embedding, metadata, agent_id, conversation_id)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  """)
  SQLite.execute(stmt, (Dates.now(Dates.UTC), role, text, emb === nothing ? "" : JSON3.write(emb), JSON3.write(metadata), agent_id, conversation_id))
  rebuild_memory_index(; agent_id, conversation_id)
end

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

function prune_memories(;older_than_days::Int=30, batch_size::Int=50,
                        agent_id::String="prosca", conversation_id::Union{String,Nothing}=nothing)
  cutoff = Dates.now(Dates.UTC) - Dates.Day(older_than_days)
  query, params = if conversation_id !== nothing
    "SELECT id, role, content FROM memories WHERE agent_id = ? AND conversation_id = ? AND timestamp < ? ORDER BY timestamp ASC LIMIT ?", (agent_id, conversation_id, string(cutoff), batch_size)
  else
    "SELECT id, role, content FROM memories WHERE agent_id = ? AND conversation_id IS NULL AND timestamp < ? ORDER BY timestamp ASC LIMIT ?", (agent_id, string(cutoff), batch_size)
  end
  rows = map(SQLite.DBInterface.execute(DB[], query, params)) do row
    (id=row.id, role=row.role, content=row.content)
  end

  isempty(rows) && return "No old memories to prune."

  texts = join(["$(r.role): $(r.content)" for r in rows], "\n")
  summary = call_llm([
    PromptingTools.SystemMessage("Summarize these memories into a concise paragraph preserving key facts and decisions:"),
    PromptingTools.UserMessage(texts)
  ]).content

  ids = join([string(r.id) for r in rows], ",")
  SQLite.execute(DB[], "DELETE FROM memories WHERE id IN ($ids)")

  rebuild_memory_index(; agent_id, conversation_id)
  log_memory("Memory consolidation: $summary"; role="System", agent_id, conversation_id)

  "Pruned $(length(rows)) old memories into one summary."
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
struct Agent
  id::String
  personality::String
  instructions::String
  skills::Dict{String, Skill}
  path::FSPath
  repl_module::Module
  repl_log::IOStream
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
  # Seed the REPL module with require() for loading trusted libraries
  Core.eval(mod, :(require(path) = $require(@__MODULE__, path)))
  Agent(id, read(soul_path, String), read(instr_path, String),
        load_agent_skills(agent_dir), agent_dir, mod, logfile)
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

default_agent()::Agent = get(AGENTS, "prosca", first(values(AGENTS)))

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

  """
  $(agent.personality)

  Current instructions:
  $(agent.instructions)

  You have persistent memory across sessions.

  ## Julia REPL
  You have a persistent Julia REPL. Use {"eval": "code"} to evaluate Julia expressions.
  Variables and functions persist across evaluations.
  Use standard Julia for introspection: names(@__MODULE__), methods(f), typeof(x), etc.

  ## Built-in Tools
  Available tools (respond with valid JSON only):
  $(join(TOOL_SCHEMAS, "\n"))
  $skill_list
  Or {"final_answer": "your response here"}
  $skill_injection$handoff_section
  """
end

# ── Session State ────────────────────────────────────────────────────
const SESSION_HISTORY = PromptingTools.AbstractMessage[]
const AUTO_ALLOWED_TOOLS = Set{String}()

struct LlmResult
  content::String
  input_tokens::Int
  output_tokens::Int
end

function call_llm(messages; model::Union{String,Nothing}=nothing, schema=nothing)::LlmResult
  temperature = get(CONFIG, "temperature", 0.7)
  use_model = model !== nothing ? model : CONFIG["llm"]
  is_local = startswith(use_model, "ollama:")
  if is_local
    use_model = use_model[length("ollama:")+1:end]
  end
  default_timeout = is_local ? 300 : 60
  timeout = get(CONFIG, "llm_timeout", default_timeout)
  use_schema = schema !== nothing ? schema : LLM_SCHEMA[]
  if model !== nothing && schema === nothing
    use_schema = _detect_schema_for(model)
  end
  resp = PromptingTools.aigenerate(use_schema, messages;
    model=use_model, temperature,
    http_kwargs=(; retry_non_idempotent=false, retries=0, readtimeout=timeout))
  input_tokens = try get(resp.run_info, :prompt_tokens, 0) catch; 0 end
  output_tokens = try get(resp.run_info, :completion_tokens, 0) catch; 0 end
  LlmResult(resp.content, input_tokens, output_tokens)
end

# ── ReAct Agent Loop ─────────────────────────────────────────────────

function run_agent(user_input::String, outbox::Channel, inbox::Channel, agent::Agent;
                   session_history=SESSION_HISTORY, auto_allowed=AUTO_ALLOWED_TOOLS,
                   conversation_id::Union{String,Nothing}=nothing)
  try
    _run_agent(user_input, outbox, inbox, agent; session_history, auto_allowed, conversation_id)
  catch e
    @error "Agent error" exception=(e, catch_backtrace())
    put!(outbox, AgentMessage("Agent error: $(sprint(showerror, e))"))
    put!(outbox, AgentDone())
  end
end

function _run_agent(user_input::String, outbox::Channel, inbox::Channel, agent::Agent;
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
  messages = PromptingTools.AbstractMessage[PromptingTools.SystemMessage(build_system_prompt(agent; active_skill))]

  window = session_history[max(1, end-19):end]
  append!(messages, window)
  push!(messages, PromptingTools.UserMessage("$memories\n\nTask: $user_input"))

  max_steps = get(CONFIG, "max_steps", 15)
  for step in 1:max_steps
    if step > 1 && step % 5 == 0
      user_names = filter(n -> n != Symbol(agent.repl_module), names(agent.repl_module; all=false))
      if !isempty(user_names)
        scope = join(user_names, ", ")
        push!(messages, PromptingTools.UserMessage("[REPL scope] Variables: $scope"))
      end
    end

    response_text = try
      call_llm(messages).content
    catch e
      put!(outbox, AgentMessage("LLM error: $(sprint(showerror, e))"))
      break
    end
    @debug "LLM response ($(length(response_text)) chars): $(response_text[1:min(200, end)])"

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
                        contains(response_text, "\"final_answer\"") ||
                        contains(response_text, "\"skill\"") ||
                        contains(response_text, "\"handoff\"")
      if looks_like_json
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Your JSON was malformed and couldn't be parsed. Return exactly ONE JSON object per response. Try again."))
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
        interpret(agent.repl_module, code; outbox, inbox, log=agent.repl_log)
      catch e
        e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
      end
      put!(outbox, ToolResult("eval", result))
      log_memory("Eval: $code → $(result[1:min(500,end)])"; agent_id=agent.id, conversation_id)
      push!(messages, PromptingTools.AIMessage(response_text))
      push!(messages, PromptingTools.UserMessage("Result: $result"))
      continue
    end

    tool_name = get(parsed, :tool, nothing)
    tn = tool_name === nothing ? "" : string(tool_name)
    args_str = haskey(parsed, :args) ? JSON3.write(parsed.args) : "{}"

    if !haskey(TOOLS, tn)
      push!(messages, PromptingTools.AIMessage(response_text))
      push!(messages, PromptingTools.UserMessage("Error: Unknown tool '$tn'. Use {\"eval\": \"...\"} for Julia code, or use a valid tool name, or return {\"final_answer\": \"...\"}"))
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
          push!(messages, PromptingTools.AIMessage(response_text))
          push!(messages, PromptingTools.UserMessage("Tool call to '$tn' was denied by user. Try a different approach or ask the user."))
          continue
        end
      end
    end

    result = try
      TOOLS[tn](parsed.args)
    catch e
      "Tool error ($(typeof(e))): $(sprint(showerror, e))"
    end
    @info "Tool result: $(result[1:min(200, end)])"
    put!(outbox, ToolResult(tn, result))
    log_memory("Tool: $tn($args_str) → $(result[1:min(500, end)])"; agent_id=agent.id, conversation_id)

    push!(messages, PromptingTools.AIMessage(response_text))
    push!(messages, PromptingTools.UserMessage("Tool result: $result"))
  end

  put!(outbox, AgentDone())

  push!(session_history, PromptingTools.UserMessage(user_input))
  for i in length(messages):-1:1
    if messages[i] isa PromptingTools.AIMessage
      push!(session_history, messages[i])
      break
    end
  end
end

# ── Initialization (runs at runtime, not precompile) ─────────────────

function __init__()
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

  # Initialize LLM schema
  LLM_SCHEMA[] = _detect_schema()
  EMBED_MODEL[] = get(CONFIG, "embed_model", "qwen3-embedding:8b")

  # Load everything
  load_tools!()
  load_commands!()
  load_skills!()
  load_agents!()

  # Set up trusted library paths for the REPL
  empty!(TRUSTED_DIRS)
  push!(TRUSTED_DIRS, string(SKILLS_DIR))
  for agent in values(AGENTS)
    push!(TRUSTED_DIRS, string(agent.path * "skills"))
  end

  # Build memory indexes
  for agent_id in keys(AGENTS)
    rebuild_memory_index(; agent_id)
  end
end

export AgentMessage, ToolCallRequest, ToolResult, AgentDone, UserInput, ToolApproval, ToolApprovalRetracted,
       run_agent, HOME, CONFIG, default_agent, Agent
