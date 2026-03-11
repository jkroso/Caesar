@use "github.com/jkroso/URI.jl/FSPath" home
@use JSON3
@use LinearAlgebra...
@use PromptingTools
@use RAGTools...
@use LibGit2
@use SQLite
@use Dates
@use HTTP
@use YAML
@use Logging

include("events.jl")
include("mcp_client.jl")
include("validate_ex.jl")

const HOME = mkpath(home() * "Prosca")

if !isfile(HOME * "config.yaml")
  YAML.write_file(HOME * "config.yaml", Dict(
    "llm" => "qwen3.5:27b",
    "github_token" => "",
    "allowed_dirs" => [HOME, expanduser("~/projects")],
    "allowed_commands" => ["ls *", "cat *", "head *", "tail *", "grep *", "find *", "git *", "julia *", "pwd", "echo *", "wc *"],
    "log_level" => "info",
  ))
end

const CONFIG = YAML.load_file(string(HOME * "config.yaml"))

const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)
Logging.global_logger(Logging.ConsoleLogger(stderr, get(LOG_LEVELS, get(CONFIG, "log_level", "warn"), Logging.Warn)))

const PERSONALITY = read(HOME * "soul.md", String)
const INSTRUCTIONS = read(joinpath(HOME, "instructions.md"), String)
const MEMORY_DB_PATH = HOME * "memories/memories.db"
MEMORY_DB_PATH.exists || mkpath(MEMORY_DB_PATH.parent)
const DB = SQLite.DB(string(MEMORY_DB_PATH))

SQLite.execute(DB, """
  CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    role TEXT,
    content TEXT,
    embedding TEXT,
    metadata TEXT DEFAULT '{}'
  );
""")
SQLite.execute(DB, "CREATE INDEX IF NOT EXISTS idx_timestamp ON memories(timestamp);")

function _detect_schema()
  model = get(CONFIG, "llm", "")
  if startswith(model, "gpt-") || startswith(model, "o3") || startswith(model, "o4")
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
const LLM_SCHEMA = Ref{Any}(_detect_schema())

# ============= EMBEDDINGS =============
const EMBED_SCHEMA = PromptingTools.OllamaSchema()
const EMBED_MODEL = get(CONFIG, "embed_model", "qwen3-embedding:8b")

function get_embedding(text::String)::Union{Vector{Float64}, Nothing}
  try
    msg = PromptingTools.aiembed(EMBED_SCHEMA, text; model=EMBED_MODEL, copy=true)
    normalize(vec(msg.content))
  catch e
    @warn "Embedding failed: $e"
    nothing
  end
end

# ============= EMBEDDINGS + RAGTOOLS MEMORY =============
const MEMORY_INDEX = Ref{ChunkIndex}()

function rebuild_memory_index()
  # Load all memory contents (source of truth = SQLite)
  rows = map(SQLite.DBInterface.execute(DB, """
    SELECT id, content FROM memories
    ORDER BY timestamp DESC
  """)) do row
    (id=row.id, content=row.content)
  end

  if isempty(rows)
    @info "No memories yet — index will be empty"
    MEMORY_INDEX[] = build_index(["(empty memory)"]; chunker_kwargs=(; sources=["mem-0"]))
    return
  end

  docs = [r.content for r in rows]
  sources = ["mem-$(r.id)" for r in rows]

  # Build fresh index with short source labels (RAGTools requires < 512 chars)
  MEMORY_INDEX[] = build_index(docs; chunker_kwargs=(; sources))
  @info "RAG index rebuilt with $(length(docs)) memories"
end

function log_memory(text::String; role::String="Agent", metadata=Dict())
  emb = get_embedding(text)  # keep for future hybrid use
  stmt = SQLite.Stmt(DB, """
    INSERT INTO memories (timestamp, role, content, embedding, metadata)
    VALUES (?, ?, ?, ?, ?)
  """)
  SQLite.execute(stmt, (Dates.now(Dates.UTC), role, text, emb === nothing ? "" : JSON3.write(emb), JSON3.write(metadata)))

  rebuild_memory_index()  # real-time update
end

function search_memories(query::String; limit::Int=5)::String
  if !isassigned(MEMORY_INDEX) || isempty(MEMORY_INDEX[].chunks)
    return "(no memories yet)"
  end

  try
    result = retrieve(MEMORY_INDEX[], query; top_k=limit)
    ctx = result.context
    isempty(ctx) && return "(no relevant memories)"
    "=== Relevant past memories ===\n" * join(ctx, "\n\n")
  catch e
    @warn "Memory search failed: $e"
    "(memory search unavailable)"
  end
end

function prune_memories(;older_than_days::Int=30, batch_size::Int=50)
  cutoff = Dates.now(Dates.UTC) - Dates.Day(older_than_days)
  rows = map(SQLite.DBInterface.execute(DB, """
    SELECT id, role, content FROM memories
    WHERE timestamp < ? ORDER BY timestamp ASC LIMIT ?
  """, (string(cutoff), batch_size))) do row
    (id=row.id, role=row.role, content=row.content)
  end

  isempty(rows) && return "No old memories to prune."

  texts = join(["$(r.role): $(r.content)" for r in rows], "\n")
  summary = call_llm([
    PromptingTools.SystemMessage("Summarize these memories into a concise paragraph preserving key facts and decisions:"),
    PromptingTools.UserMessage(texts)
  ])

  ids = join([string(r.id) for r in rows], ",")
  SQLite.execute(DB, "DELETE FROM memories WHERE id IN ($ids)")

  rebuild_memory_index()          # ← crucial for RAGTools
  log_memory("Memory consolidation: $summary"; role="System")

  "✅ Pruned $(length(rows)) old memories into one summary."
end

# Build index on startup
rebuild_memory_index()

# ============= TOOLS =============

function is_allowed_path(path::String)::Bool
  p = abspath(expanduser(path))
  any(startswith(p, abspath(expanduser(string(d)))) for d in CONFIG["allowed_dirs"])
end

# Auto-discover tools from tools/ folder
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

load_tools!()

# ============= COMMANDS =============
const COMMANDS_DIR = HOME * "commands"
COMMANDS_DIR.exists || mkpath(COMMANDS_DIR)

const COMMANDS = Dict{String, Module}()

function load_commands!()
  empty!(COMMANDS)
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

load_commands!()

# ============= SKILLS =============
const SKILLS_DIR = HOME * "skills"
SKILLS_DIR.exists || mkpath(SKILLS_DIR)

struct Skill
  name::String
  description::String
  content::String
end

function parse_skill(path::String)::Union{Skill, Nothing}
  text = read(path, String)
  # Parse YAML frontmatter between --- delimiters
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
  for file in SKILLS_DIR.children
    file.extension == "md" || continue
    skill = parse_skill(string(file))
    skill === nothing && continue
    SKILLS[skill.name] = skill
    @info "Loaded skill: $(skill.name)"
  end
end

load_skills!()

# ============= MCP SERVERS =============
const MCP_CONFIG_PATH = string(HOME * "mcp_servers.json")
if !isfile(MCP_CONFIG_PATH)
  write(MCP_CONFIG_PATH, JSON3.write(Dict(
    "kaimon" => Dict("url" => "http://localhost:2828", "runtime" => true)
  )))
end
load_mcp_servers!()

# ============= AGENT =============
function build_system_prompt(;active_skill::Union{Skill, Nothing}=nothing)::String
  skill_list = if isempty(SKILLS)
    ""
  else
    catalog = join(["- /$(s.name): $(s.description)" for s in values(SKILLS)], "\n")
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

  # Build MCP tool sections
  runtime = runtime_server()
  runtime_section = if runtime !== nothing
    # Only surface key introspection tools with short descriptions — full list bloats prompt
    key_tools = Dict(
      "list_names" => "List variables/functions currently in REPL scope",
      "type_info" => "Inspect a type's fields, supertypes, methods",
      "search_methods" => "Find methods matching a signature or name",
    )
    introspection_lines = String[]
    for t in runtime.tools
      t.name == "ex" && continue
      if haskey(key_tools, t.name)
        push!(introspection_lines, "- $(runtime.name).$(t.name): $(key_tools[t.name])")
      end
    end
    introspection_str = join(introspection_lines, "\n")
    """
    ## Julia Runtime (via $(runtime.name).ex) — USE THIS BY DEFAULT
    You have a persistent Julia REPL. This is your PRIMARY tool. Write Julia code for almost everything:
    - Read files: read("path", String)
    - List dirs: readdir("path")
    - HTTP requests: using HTTP; HTTP.get(url)
    - Data processing: any Julia code
    - Package management: using Pkg; Pkg.add("Foo")

    Use $(runtime.name).ex for everything — file I/O, shell commands (via `run(\`cmd\`)`), HTTP, data processing, etc.

    To execute (fire-and-forget): {"tool": "$(runtime.name).ex", "args": {"e": "your_code_here"}}
    To execute and SEE the result: {"tool": "$(runtime.name).ex", "args": {"e": "your_code_here", "q": false}}
    IMPORTANT: By default q=true which HIDES the return value. Use "q": false whenever you need to see output.
    Example: {"tool": "$(runtime.name).ex", "args": {"e": "read(\\"README.md\\", String)", "q": false}}
    Shell example: {"tool": "$(runtime.name).ex", "args": {"e": "run(\`git status\`)", "q": false}}
    IMPORTANT: Always escape double quotes inside the "e" value with backslash.

    ## Julia Introspection
    $introspection_str
    """
  else
    ""
  end

  # Non-runtime MCP tools
  other_mcp_tools = String[]
  for (sname, server) in MCP_SERVERS
    server.is_runtime && continue
    !server.connected && continue
    for t in server.tools
      push!(other_mcp_tools, "- $sname.$(t.name): $(t.description)")
    end
  end
  other_mcp_section = isempty(other_mcp_tools) ? "" : "\n## External Tools (MCP)\n$(join(other_mcp_tools, "\n"))\n"

  """
  $PERSONALITY

  Current instructions:
  $INSTRUCTIONS

  You have persistent memory across sessions.

  $runtime_section
  ## Built-in Tools
  Available tools (respond with valid JSON only):
  $(join(TOOL_SCHEMAS, "\n"))
  $other_mcp_section$skill_list
  Or {"final_answer": "your response here"}
  $skill_injection
  """
end

# Session conversation history for continuity across run_agent calls
const SESSION_HISTORY = PromptingTools.AbstractMessage[]
# Tools the user has approved with "always" for this session
const AUTO_ALLOWED_TOOLS = Set{String}()

# TODO: streaming (streamcallback=stdout) doesn't pair well with JSON tool dispatch
# in a ReAct loop — the raw JSON gets streamed before we can parse it. Revisit if
# switching to a structured output / function-calling API.
function call_llm(messages)::String
  temperature = get(CONFIG, "temperature", 0.7)
  timeout = get(CONFIG, "llm_timeout", 60)
  resp = PromptingTools.aigenerate(LLM_SCHEMA[], messages;
    model=CONFIG["llm"], temperature,
    http_kwargs=(; retry_non_idempotent=false, retries=0, readtimeout=timeout))
  resp.content
end

function run_agent(user_input::String, outbox::Channel, inbox::Channel)
  try
    _run_agent(user_input, outbox, inbox)
  catch e
    @error "Agent error" exception=(e, catch_backtrace())
    put!(outbox, AgentMessage("Agent error: $(sprint(showerror, e))"))
    put!(outbox, AgentDone())
  end
end

function _run_agent(user_input::String, outbox::Channel, inbox::Channel)
  log_memory("User: $user_input"; role="User")

  # Check for /skill-name prefix
  active_skill = nothing
  if startswith(user_input, "/")
    parts = split(user_input, limit=2)
    skill_name = parts[1][2:end]  # strip leading /
    if haskey(SKILLS, skill_name)
      active_skill = SKILLS[skill_name]
      user_input = length(parts) > 1 ? strip(parts[2]) : skill_name
      @info "Activated skill: $(skill_name)"
    end
  end

  memories = search_memories(user_input)  # now powered by RAGTools
  messages = PromptingTools.AbstractMessage[PromptingTools.SystemMessage(build_system_prompt(;active_skill))]

  window = SESSION_HISTORY[max(1, end-19):end]  # last 10 exchange pairs
  append!(messages, window)
  push!(messages, PromptingTools.UserMessage("$memories\n\nTask: $user_input"))

  max_steps = get(CONFIG, "max_steps", 15)
  for step in 1:max_steps
    # Periodic runtime awareness: every 5 tool calls, refresh REPL scope
    if runtime_server() !== nothing && step > 1 && step % 5 == 0
      try
        scope = mcp_call_tool(runtime_server(), "list_names", Dict{String,Any}())
        push!(messages, PromptingTools.UserMessage("[Runtime scope reminder] Variables in Julia REPL:\n$scope"))
      catch; end
    end

    response_text = try
      call_llm(messages)
    catch e
      put!(outbox, AgentMessage("LLM error: $(sprint(showerror, e))"))
      break
    end
    @debug "LLM response ($(length(response_text)) chars): $(response_text[1:min(200, end)])"

    # Try to parse as JSON tool call — strip markdown fences and extract JSON
    json_str = strip(response_text)
    # Strip ```json ... ``` wrapping that LLMs love to add
    m = match(r"```(?:json)?\s*\n?(.*?)\n?\s*```"s, json_str)
    if m !== nothing
      json_str = strip(m.captures[1])
    end
    # Extract first {...} block if there's surrounding text
    if !startswith(json_str, "{")
      m2 = match(r"\{.*\}"s, json_str)
      if m2 !== nothing
        json_str = m2.match
      end
    end

    parsed = try
      result = JSON3.read(json_str)
      result isa AbstractDict ? result : nothing  # only accept JSON objects
    catch
      nothing
    end

    if parsed === nothing
      # Check if it looks like it was TRYING to be JSON (malformed tool call)
      if contains(response_text, "\"tool\"") && contains(response_text, "\"args\"")
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Your JSON was malformed and couldn't be parsed. Remember to escape quotes inside strings with \\\\\" — for example: {\"tool\": \"kaimon.ex\", \"args\": {\"e\": \"read(\\\\\"README.md\\\\\", String)\"}}. Try again."))
        @warn "Malformed JSON from LLM, asking to retry" response_text
        continue
      end
      # LLM responded with plain text — treat as final answer
      put!(outbox, AgentMessage(response_text))
      log_memory("Agent: $response_text")
      break
    end

    if haskey(parsed, :final_answer)
      put!(outbox, AgentMessage(parsed.final_answer))
      log_memory("Agent: $(parsed.final_answer)")
      break
    end

    if haskey(parsed, :skill)
      sn = string(parsed.skill)
      if haskey(SKILLS, sn)
        active_skill = SKILLS[sn]
        @info "LLM activated skill: $sn"
        # Rebuild system prompt with the skill and retry
        messages[1] = PromptingTools.SystemMessage(build_system_prompt(;active_skill))
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Skill '$sn' activated. Proceed with the task using this skill's guidance."))
        continue
      else
        push!(messages, PromptingTools.AIMessage(response_text))
        push!(messages, PromptingTools.UserMessage("Unknown skill '$sn'. Available: $(join(keys(SKILLS), ", "))"))
        continue
      end
    end

    tool_name = get(parsed, :tool, nothing)
    tn = tool_name === nothing ? "" : string(tool_name)
    args_str = haskey(parsed, :args) ? JSON3.write(parsed.args) : "{}"

    # Resolve tool: built-in first, then MCP servers
    is_builtin = haskey(TOOLS, tn)
    mcp_server = nothing
    mcp_tool_name = ""
    if !is_builtin && contains(tn, ".")
      parts = split(tn, "."; limit=2)
      server_name, mcp_tool_name = String(parts[1]), String(parts[2])
      if haskey(MCP_SERVERS, server_name) && MCP_SERVERS[server_name].connected
        mcp_server = MCP_SERVERS[server_name]
      end
    end

    if !is_builtin && mcp_server === nothing
      push!(messages, PromptingTools.AIMessage(response_text))
      push!(messages, PromptingTools.UserMessage("Error: Unknown tool '$tn'. Use a valid tool name or return {\"final_answer\": \"...\"}"))
      continue
    end

    # Determine if confirmation is needed
    needs_confirm = false
    if is_builtin
      needs_confirm = tn in TOOL_CONFIRM && tn ∉ AUTO_ALLOWED_TOOLS
    elseif mcp_server !== nothing
      if mcp_server.is_runtime
        # Runtime server: no confirmation unless ex fails validation
        if mcp_tool_name == "ex"
          if haskey(parsed, :args) && hasproperty(parsed.args, :e)
            needs_confirm = !validate_ex(string(parsed.args.e))
          else
            needs_confirm = true  # missing expression requires confirmation
          end
        end
      else
        # Non-runtime MCP: always confirm unless auto-allowed
        needs_confirm = tn ∉ AUTO_ALLOWED_TOOLS
      end
    end

    if needs_confirm
      req_id = rand(UInt64)
      put!(outbox, ToolCallRequest(tn, args_str, req_id))
      approval = take!(inbox)
      if approval isa ToolApproval && approval.id == req_id
        if approval.decision == :always
          push!(AUTO_ALLOWED_TOOLS, tn)
        elseif approval.decision == :deny
          push!(messages, PromptingTools.AIMessage(response_text))
          push!(messages, PromptingTools.UserMessage("Tool call to '$tn' was denied by user. Try a different approach or ask the user."))
          continue
        end
      end
    end

    # Execute the tool
    result = try
      if is_builtin
        TOOLS[tn](parsed.args)
      else
        args_dict = if haskey(parsed, :args)
          Dict{String,Any}(string(k) => v for (k, v) in pairs(parsed.args))
        else
          Dict{String,Any}()
        end
        mcp_call_tool(mcp_server, mcp_tool_name, args_dict)
      end
    catch e
      "Tool error ($(typeof(e))): $(sprint(showerror, e))"
    end
    @info "Tool result: $(result[1:min(200, end)])"
    put!(outbox, ToolResult(tn, result))
    log_memory("Tool: $tn($args_str) → $(result[1:min(500, end)])")

    push!(messages, PromptingTools.AIMessage(response_text))
    push!(messages, PromptingTools.UserMessage("Tool result: $result"))
  end

  put!(outbox, AgentDone())

  # Save exchange to session history for continuity
  push!(SESSION_HISTORY, PromptingTools.UserMessage(user_input))
  # Find the last AIMessage (not a UserMessage like "Tool result: ...")
  for i in length(messages):-1:1
    if messages[i] isa PromptingTools.AIMessage
      push!(SESSION_HISTORY, messages[i])
      break
    end
  end
end
