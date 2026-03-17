@use "." HOME run_agent default_agent CONFIG ToolApproval COMMANDS ToolResult AgentDone ToolCallRequest AgentMessage

println("🧠 Prosca started")
println("Brain: $HOME")
println("Model: $(CONFIG["llm"])")
println("Type 'exit' to quit.\n")

const outbox = Channel(32)
const inbox = Channel(32)

function handle_events(outbox::Channel)
  while true
    event = take!(outbox)
    if event isa AgentMessage
      println("\nAgent: $(event.text)")
    elseif event isa ToolCallRequest
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
      put!(inbox, ToolApproval(event.id, decision))
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
  if startswith(input, ";")
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
    @async run_agent(input, outbox, inbox, default_agent())
    handle_events(outbox)
  end
end
