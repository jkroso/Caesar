@use "./docker" ensure_running is_running
@use HTTP
@use JSON3

struct HindsightConn
  url::String
  bank_id::String
end

const TENANT = "default"

function api(conn::HindsightConn, method, path; body=nothing)
  url = "$(conn.url)/v1/$TENANT$path"
  headers = ["Content-Type" => "application/json"]
  resp = if body !== nothing
    HTTP.request(method, url, headers, JSON3.write(body);
                 connect_timeout=5, readtimeout=120)
  else
    HTTP.request(method, url, headers; connect_timeout=5, readtimeout=30)
  end
  resp.status >= 400 && error("Hindsight API error $(resp.status): $(String(resp.body))")
  JSON3.read(resp.body)
end

function init(agent_id; url="http://localhost:8888", port=8888, admin_port=9999,
              llm_key="", mission="")
  if !is_running()
    ensure_running(; port, admin_port, llm_key) || return nothing
  end
  try
    api(HindsightConn(url, agent_id), "PUT", "/banks/$(agent_id)";
        body=Dict("name" => agent_id, "mission" => mission))
  catch e
    @warn "Hindsight bank creation failed" exception=e
    return nothing
  end
  HindsightConn(url, agent_id)
end

function retain(conn::HindsightConn, content; context=nothing, metadata=nothing)
  item = Dict{String, Any}("content" => content)
  context !== nothing && (item["context"] = context)
  metadata !== nothing && (item["metadata"] = metadata)
  try
    api(conn, "POST", "/banks/$(conn.bank_id)/memories/retain";
        body=Dict("items" => [item]))
    true
  catch e
    @warn "Hindsight retain failed" exception=e
    false
  end
end

function recall(conn::HindsightConn, query; limit=5)
  try
    resp = api(conn, "POST", "/banks/$(conn.bank_id)/memories/recall";
               body=Dict("query" => query, "max_tokens" => 4096))
    results = get(resp, :results, [])
    [Dict("id" => string(get(r, :id, "")), "text" => string(get(r, :text, "")),
          "type" => string(get(r, :type, "")))
     for r in results[1:min(limit, length(results))]]
  catch e
    @warn "Hindsight recall failed" exception=e
    Dict{String, Any}[]
  end
end

function reflect(conn::HindsightConn, query; context=nothing)
  body = Dict{String, Any}("query" => query)
  context !== nothing && (body["context"] = context)
  try
    resp = api(conn, "POST", "/banks/$(conn.bank_id)/memories/reflect"; body)
    string(get(resp, :text, ""))
  catch e
    @warn "Hindsight reflect failed" exception=e
    nothing
  end
end
