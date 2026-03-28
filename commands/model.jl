module model_cmd
const prosca = parentmodule(@__MODULE__)

const name = "model"
const description = "Switch LLM model or search available models"

function fn(args::AbstractString)::String
  query = String(strip(args))

  # Handle "key:<api_key>" to set a provider key
  if startswith(query, "key:")
    kv = query[5:end]
    eq = findfirst('=', kv)
    eq === nothing && return "Usage: /model key:<config_key>=<value>"
    k, v = strip(kv[1:eq-1]), strip(kv[eq+1:end])
    prosca.CONFIG[k] = v
    save_config!()
    return "Saved $k to config."
  end

  # No argument: show current model
  if isempty(query)
    return "Current: $(prosca.CONFIG["llm"])\n\nUsage: /model <name or search query>"
  end

  # Search for models matching the query
  results = prosca.search_models(query; max_results=10)

  # Exact match → switch to it
  exact = findfirst(r -> r["id"] == query, results)
  if exact !== nothing
    prosca.CONFIG["llm"] = query
    save_config!()
    return "Switched to $query ($(results[exact]["provider"]))"
  end

  # Single result → switch to it
  if length(results) == 1
    id = results[1]["id"]
    prosca.CONFIG["llm"] = id
    save_config!()
    return "Switched to $id ($(results[1]["provider"]))"
  end

  # Multiple results → show list
  if isempty(results)
    # Try switching directly (e.g. for ollama models not in models.dev)
    prosca.CONFIG["llm"] = query
    save_config!()
    return "Switched to $query"
  end

  lines = ["Models matching \"$query\":", ""]
  for r in results
    cost = r["cost"]
    cost_str = cost !== nothing ? " [\$$(get(cost, "input", "?"))/\$$(get(cost, "output", "?")) per Mtok]" : ""
    ctx = r["context"]
    ctx_str = ctx !== nothing ? " $(div(ctx, 1000))k ctx" : ""
    flags = String[]
    r["reasoning"] && push!(flags, "reasoning")
    r["tool_call"] && push!(flags, "tools")
    flag_str = isempty(flags) ? "" : " ($(join(flags, ", ")))"
    push!(lines, "  $(r["id"])$flag_str$ctx_str$cost_str")
  end
  push!(lines, "", "Use /model <id> to switch")
  join(lines, "\n")
end

function save_config!()
  prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
end

end
