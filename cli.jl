@use "." HOME default_agent CONFIG ToolApproval COMMANDS ToolResult AgentDone ToolCallRequest AgentMessage StreamToken Envelope SESSION_HISTORY AUTO_ALLOWED_TOOLS

println("🧠 Caesar started")
println("Brain: $HOME")
println("Model: $(CONFIG["llm"])")
println("Type 'exit' to quit.\n")

function handle_events(outbox, approvals)
  streaming = false
  while true
    event = take!(outbox)
    if event isa StreamToken
      if !streaming
        print("\nAgent: ")
        streaming = true
      end
      print(event.text)
    elseif event isa AgentMessage
      streaming && println()
      streaming = false
      println("\nAgent: $(event.text)")
    elseif event isa ToolCallRequest
      streaming && println()
      streaming = false
      printstyled("  ● $(event.name) ", color=:yellow, bold=true)
      println(event.args)
      print("  Allow? [y/n/a(lways)]: ")
      answer = lowercase(strip(readline()))
      decision = if answer == "a"
        :always
      elseif answer == "y"
        :allow
      else
        :deny
      end
      put!(approvals, ToolApproval(event.id, decision))
    elseif event isa ToolResult
      # Tool result already logged in main.jl
    elseif event isa AgentDone
      break
    end
  end
end

while true
  print("You: ")
  input = readline()
  input == "exit" && break
  isempty(input) && continue
  if startswith(input, "/") && !startswith(input, "//")
    parts = split(input, limit=2)
    cmd_name = parts[1][2:end]
    cmd_args = length(parts) > 1 ? String(strip(parts[2])) : ""
    if haskey(COMMANDS, cmd_name)
      result = try
        COMMANDS[cmd_name].fn(cmd_args)
      catch e
        "Command error: $(sprint(showerror, e))"
      end
      println(result)
    else
      println("Unknown command: $cmd_name")
      println("Available: $(join(keys(COMMANDS), ", "))")
    end
  else
    outbox = Channel(32)
    approvals = Channel(32)
    put!(default_agent().inbox, Envelope(input; outbox, approvals))
    handle_events(outbox, approvals)
  end
end
