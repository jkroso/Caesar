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
  provider, model_query = if contains(query, '/')
    parts = split(query, '/'; limit=2)
    string(parts[1]), string(parts[2])
  else
    "", query
  end
  allowed = get(prosca.CONFIG, "providers", nothing)
  allowed_ids = allowed isa Vector ? union(string.(allowed), ["ollama"]) : String[]
  results = prosca.search(provider, model_query; max_results=50, allowed_providers=allowed_ids)

  # Exact match → switch to it
  exact = findfirst(r -> r.id == query || "$(r.provider)/$(r.id)" == query, results)
  if exact !== nothing
    r = results[exact]
    switch_model!(r)
    return "Switched to $(r.provider)/$(r.id)"
  end

  # Single result → switch to it
  if length(results) == 1
    r = results[1]
    switch_model!(r)
    return "Switched to $(r.provider)/$(r.id)"
  end

  # Multiple results → show list
  if isempty(results)
    # Try switching directly (e.g. for ollama models not in models.dev)
    switch_model!(query)
    return "Switched to $query"
  end

  lines = ["Models matching \"$query\":", ""]
  for r in results
    p = r.pricing
    cost_str = p !== nothing ? " [\$$(p[1])/\$$(p[2]) per Mtok]" : ""
    ctx = r.context
    ctx_str = ctx !== nothing ? " $(div(ctx, 1000))k ctx" : ""
    flags = String[]
    r.reasoning && push!(flags, "reasoning")
    r.tool_call && push!(flags, "tools")
    flag_str = isempty(flags) ? "" : " ($(join(flags, ", ")))"
    push!(lines, "  $(r.provider)/$(r.id)$flag_str$ctx_str$cost_str")
  end
  push!(lines, "", "Use /model <provider/id> to switch")
  join(lines, "\n")
end

function switch_model!(info::NamedTuple)
  model_id = "$(info.provider)/$(info.id)"
  prosca.cache_model_info(info)
  prosca.CONFIG["llm"] = model_id
  prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
  for (_, agent) in prosca.AGENTS
    agent.llm = prosca.LLM(info, prosca.CONFIG)
  end
end

function switch_model!(model_id::String)
  prosca.CONFIG["llm"] = prosca.ensure_provider_prefix(model_id)
  prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
  for (_, agent) in prosca.AGENTS
    agent.llm = prosca.cached_LLM(prosca.CONFIG["llm"], prosca.CONFIG)
  end
end

function complete(prefix)
  allowed = get(prosca.CONFIG, "providers", nothing)
  allowed_ids = allowed isa Vector ? union(string.(allowed), ["ollama"]) : String[]
  models = if contains(prefix, '/')
    parts = split(prefix, '/'; limit=2)
    prosca.search(string(parts[1]), string(parts[2]); max_results=20, allowed_providers=allowed_ids)
  else
    prosca.search(prefix; max_results=20, allowed_providers=allowed_ids)
  end
  map(m -> "/model $(m.provider)/$(m.id)", models)
end

end # end module