# ═══════════════════════════════════════════════════════════════════════
# Prosca JSON I/O — stdin/stdout bridge for the GUI (Tauri sidecar)
#
# Protocol: newline-delimited JSON on stdin/stdout.
# All output lines are prefixed with "PROSCA:" so the Rust sidecar
# can filter them from Julia noise.
# ═══════════════════════════════════════════════════════════════════════

include("main.jl")

const outbox = Channel(32)
const inbox = Channel(32)

# ── Output helpers ────────────────────────────────────────────────────

function emit(obj)
  println("PROSCA:", JSON3.write(obj))
  flush(stdout)
end

# ── Drain agent events and emit as JSON ──────────────────────────────

function handle_events(outbox::Channel)
  while true
    event = take!(outbox)
    if event isa AgentMessage
      emit(Dict("type" => "agent_message", "text" => event.text))
    elseif event isa ToolCallRequest
      emit(Dict("type" => "tool_call_request", "id" => string(event.id), "name" => event.name, "args" => event.args))
    elseif event isa ToolResult
      emit(Dict("type" => "tool_result", "name" => event.name, "result" => event.result))
    elseif event isa AgentDone
      emit(Dict("type" => "agent_done"))
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

function handle_reset()
  empty!(SESSION_HISTORY)
  empty!(AUTO_ALLOWED_TOOLS)
end

function handle_generate_title(text::String)
  messages = PromptingTools.AbstractMessage[
    PromptingTools.SystemMessage("Generate a short chat title (3-6 words, no quotes, no punctuation) that summarizes the user's message. Reply with ONLY the title, nothing else."),
    PromptingTools.UserMessage(text)
  ]
  title = strip(call_llm(messages))
  emit(Dict("type" => "title", "title" => title))
end

function handle_restore_context(messages)
  empty!(SESSION_HISTORY)
  empty!(AUTO_ALLOWED_TOOLS)
  for msg in messages
    role = string(get(msg, :role, ""))
    text = string(get(msg, :text, ""))
    if role == "user"
      push!(SESSION_HISTORY, PromptingTools.UserMessage(text))
    elseif role == "agent"
      push!(SESSION_HISTORY, PromptingTools.AIMessage(text))
    end
  end
  # Keep only the last 20 entries (10 exchange pairs) like _run_agent does
  if length(SESSION_HISTORY) > 20
    splice!(SESSION_HISTORY, 1:length(SESSION_HISTORY)-20)
  end
end

# ── Main loop ────────────────────────────────────────────────────────

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

  try
    if msg_type == "user_message"
      text = string(get(msg, :text, ""))
      @async run_agent(text, outbox, inbox)
      handle_events(outbox)
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
      put!(inbox, ToolApproval(id, decision))
    elseif msg_type == "config_get"
      handle_config_get()
    elseif msg_type == "config_set"
      handle_config_set(string(msg.key), msg.value)
    elseif msg_type == "skills_list"
      handle_skills_list()
    elseif msg_type == "mcp_list"
      handle_mcp_list()
    elseif msg_type == "reset"
      handle_reset()
    elseif msg_type == "restore_context"
      messages = get(msg, :messages, [])
      handle_restore_context(messages)
    elseif msg_type == "generate_title"
      text = string(get(msg, :text, ""))
      @async handle_generate_title(text)
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
