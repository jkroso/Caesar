@use HTTP

const CONTAINER_NAME = "prosca-hindsight"
const IMAGE = "ghcr.io/vectorize-io/hindsight:latest"

function is_running()
  try
    out = String(read(`docker inspect -f '{{.State.Running}}' $CONTAINER_NAME`))
    strip(out) == "true"
  catch
    false
  end
end

function ensure_running(; port=8888, admin_port=9999, llm_key="")
  is_running() && return true
  try run(`docker start $CONTAINER_NAME`); catch end
  if is_running()
    wait_healthy(port)
    return true
  end
  key = isempty(llm_key) ? get(ENV, "OPENAI_API_KEY", "") : llm_key
  isempty(key) && (@warn "No LLM API key for Hindsight"; return false)
  try
    run(`docker run -d --name $CONTAINER_NAME
         -p $port:8888 -p $admin_port:9999
         -e HINDSIGHT_API_LLM_API_KEY=$key
         -v prosca-hindsight-data:/home/hindsight/.pg0
         $IMAGE`)
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
