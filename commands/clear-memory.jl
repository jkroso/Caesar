module clear_memory
const prosca = parentmodule(@__MODULE__)

const name = "clear-memory"
const description = "Wipe the current agent's memory clean"

function fn(args::AbstractString)::String
  agent_id = isempty(strip(args)) ? "prosca" : String(strip(args))
  entry = get(prosca.MEMORY_PROVIDERS, agent_id, nothing)
  entry === nothing && return "No memory provider for agent '$agent_id'"
  provider, conn = entry

  if provider == :hindsight
    hs = prosca.eval(:(@use("./memory/hindsight/hindsight")))
    try
      hs.api(conn, "DELETE", "/banks/$(conn.bank_id)/memories")
      "Hindsight memories cleared for agent=$agent_id"
    catch e
      "Failed to clear Hindsight memories: $(sprint(showerror, e))"
    end
  else
    "Unknown provider: $provider"
  end
end

end
