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
    prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
    return "Saved $k to config."
  end

  # No argument: show current model
  if isempty(query)
    return "Current: $(prosca.CONFIG["llm"])\n\nUsage: /model <name or search query>"
  end

  # Search for models matching the query
  allowed = get(prosca.CONFIG, "providers", nothing)
  provider = allowed isa Vector ? string.(allowed) : nothing
  results = prosca.search_models(query; provider, max_results=10)

  # Exact match → switch to it
  exact = findfirst(r -> r["id"] == query, results)
  if exact !== nothing
    switch_model!(query)
    return "Switched to $query ($(results[exact]["provider"]))"
  end

  # Single result → switch to it
  if length(results) == 1
    id = results[1]["id"]
    switch_model!(id)
    return "Switched to $id ($(results[1]["provider"]))"
  end

  # Multiple results → show list
  if isempty(results)
    # Try switching directly (e.g. for ollama models not in models.dev)
    switch_model!(query)
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

function switch_model!(model_id::String)
  prosca.CONFIG["llm"] = model_id
  prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
  for (_, agent) in prosca.AGENTS
    agent.llm = prosca.LLM(model_id, prosca.CONFIG)
  end
end

end
