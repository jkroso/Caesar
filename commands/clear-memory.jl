module clear_memory
const prosca = parentmodule(@__MODULE__)
using .prosca.Kip

const name = "clear-memory"
const description = "Wipe the current agent's memory clean"

function fn(args::AbstractString)::String
  agent_id = isempty(strip(args)) ? "prosca" : String(strip(args))
  entry = get(prosca.MEMORY_PROVIDERS, agent_id, nothing)
  entry === nothing && return "No memory provider for agent '$agent_id'"
  provider, conn = entry

  if provider == :hindsight
    try
      hs = @use("../memory/hindsight/hindsight")
      hs.api(conn, "DELETE", "/banks/$(conn.bank_id)/memories")
      "Hindsight memories cleared for agent=$agent_id"
    catch e
      "Failed to clear Hindsight memories: $(sprint(showerror, e))"
    end
  elseif provider == :ori
    vault_dir = conn.vault_dir
    notes_dir = joinpath(vault_dir, "notes")
    inbox_dir = joinpath(vault_dir, "inbox")
    count = 0
    for dir in (notes_dir, inbox_dir)
      isdir(dir) || continue
      for f in readdir(dir; join=true)
        endswith(f, ".md") && f != joinpath(notes_dir, "index.md") || continue
        rm(f)
        count += 1
      end
    end
    # Clear embedding index
    db_path = joinpath(vault_dir, ".ori", "embeddings.db")
    isfile(db_path) && rm(db_path)
    "Cleared $count notes from Ori vault for agent=$agent_id"
  else
    "Unknown provider: $provider"
  end
end

end
