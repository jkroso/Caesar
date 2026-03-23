@use HTTP

const CONTAINER_NAME = "prosca-hindsight"
const IMAGE = "ghcr.io/vectorize-io/hindsight:latest"

# Supported providers: openai, anthropic, gemini, groq, ollama, lmstudio, minimax, vertexai
function detect_llm_config()
  # Check for explicit hindsight config first
  for (key_env, provider) in [
    ("HINDSIGHT_API_LLM_API_KEY", nothing),  # already configured, use as-is
    ("ANTHROPIC_API_KEY", "anthropic"),
    ("OPENAI_API_KEY", "openai"),
    ("GEMINI_API_KEY", "gemini"),
    ("GROQ_API_KEY", "groq"),
  ]
    key = get(ENV, key_env, "")
    isempty(key) && continue
    return (provider=provider, key=key)
  end
  (provider=nothing, key="")
end

function is_running()
  try
    out = String(read(`docker inspect -f '{{.State.Running}}' $CONTAINER_NAME`))
    strip(out) == "true"
  catch
    false
  end
end

function ensure_running(; port=8888, admin_port=9999, llm_key="", llm_provider="", llm_model="")
  is_running() && return true
  try run(`docker start $CONTAINER_NAME`); catch end
  if is_running()
    wait_healthy(port)
    return true
  end
  # Auto-detect LLM config if not provided
  detected = detect_llm_config()
  key = isempty(llm_key) ? detected.key : llm_key
  provider = isempty(llm_provider) ? (detected.provider === nothing ? "" : detected.provider) : llm_provider
  isempty(key) && (@warn "No LLM API key found for Hindsight. Set OPENAI_API_KEY, ANTHROPIC_API_KEY, etc."; return false)
  # Build env flags
  env_flags = ["-e", "HINDSIGHT_API_LLM_API_KEY=$key"]
  isempty(provider) || append!(env_flags, ["-e", "HINDSIGHT_API_LLM_PROVIDER=$provider"])
  isempty(llm_model) || append!(env_flags, ["-e", "HINDSIGHT_API_LLM_MODEL=$llm_model"])
  try
    cmd = `docker run -d --name $CONTAINER_NAME
           -p $port:8888 -p $admin_port:9999
           $env_flags
           -v prosca-hindsight-data:/home/hindsight/.pg0
           $IMAGE`
    run(cmd)
  catch e
    @warn "Failed to start Hindsight container" exception=e
    return false
  end
  wait_healthy(port)
end

function wait_healthy(port; timeout=30)
  url = "http://localhost:$port/health"
  deadline = time() + timeout
  while time() < deadline
    try
      resp = HTTP.get(url; connect_timeout=2, readtimeout=2)
      resp.status == 200 && return true
    catch end
    sleep(1)
  end
  @warn "Hindsight health check timed out after $(timeout)s"
  false
end

function stop()
  try run(`docker stop $CONTAINER_NAME`) catch end
end
