module model_cmd
const prosca = parentmodule(@__MODULE__)

const name = "model"
const description = "Switch LLM model and provider"

# Provider → (name, prefix, env_var, config_key, models)
const PROVIDERS = [
  ("Ollama (local)", :ollama, nothing, nothing, ["qwen3.5:35b", "qwen3.5:27b", "llama3.3:70b", "gemma3:27b", "deepseek-r1:32b"]),
  ("OpenAI", :openai, "OPENAI_API_KEY", "openai_key", ["gpt-5.4"]),
  ("Anthropic", :anthropic, "ANTHROPIC_API_KEY", "anthropic_key", ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5-20251001"]),
  ("Google Gemini", :google, "GOOGLE_API_KEY", "google_key", ["gemini-2.5-pro", "gemini-2.5-flash"]),
  ("Mistral", :mistral, "MISTRAL_API_KEY", "mistral_key", ["mistral-large-latest", "mistral-medium-latest"]),
  ("DeepSeek", :deepseek, "DEEPSEEK_API_KEY", "deepseek_key", ["deepseek-chat", "deepseek-reasoner"]),
  ("xAI", :xai, "XAI_API_KEY", "xai_key", ["grok-code-fast-1", "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning"]),
]

# Flat list of all model names for autocomplete
const ALL_MODELS = String[]
for (_, _, _, _, models) in PROVIDERS
  append!(ALL_MODELS, models)
end

"Find which provider a model belongs to"
function find_provider(model_name::AbstractString)
  for (pname, ptype, env_var, config_key, models) in PROVIDERS
    model_name in models && return (pname, ptype, env_var, config_key)
  end
  ("Ollama (local)", :ollama, nothing, nothing)
end

function fn(args::AbstractString)::String
  model_name = String(strip(args))

  if isempty(model_name)
    lines = ["Current: $(prosca.CONFIG["llm"])", "", "Usage: /model <name>", "", "Available models:"]
    for (pname, _, _, _, models) in PROVIDERS
      push!(lines, "  $pname:")
      for m in models
        push!(lines, "    $m")
      end
    end
    return join(lines, "\n")
  end

  # Handle "key:<api_key>" to set a provider key
  if startswith(model_name, "key:")
    kv = model_name[5:end]
    eq = findfirst('=', kv)
    eq === nothing && return "Usage: /model key:<config_key>=<value>"
    k, v = strip(kv[1:eq-1]), strip(kv[eq+1:end])
    prosca.CONFIG[k] = v
    save_config!()
    return "Saved $k to config."
  end

  pname, _, env_var, config_key = find_provider(model_name)

  if env_var !== nothing
    existing_key = get(prosca.CONFIG, config_key, "")
    if isempty(existing_key) && !haskey(ENV, env_var)
      return "Missing API key. Set it with: /model key:$config_key=<your-key>"
    end
  end

  prosca.CONFIG["llm"] = model_name
  save_config!()

  "Switched to $model_name ($pname)"
end

function save_config!()
  prosca.YAML.write_file(string(prosca.HOME * "config.yaml"), prosca.CONFIG)
end

end
