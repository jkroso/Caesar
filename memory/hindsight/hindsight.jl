@use "./docker" ensure_running is_running
@use "github.com/jkroso/HTTP.jl/client" GET POST PUT DELETE HTTPError
@use JSON3

struct HindsightConn
  url::String
  bank_id::String
end

const TENANT = "default"
const VERBS = Dict("GET" => GET, "POST" => POST, "PUT" => PUT, "DELETE" => DELETE)

function api(conn::HindsightConn, method, path; body=nothing)
  url = "$(conn.url)/v1/$TENANT$path"
  meta = ["Content-Type" => "application/json"]
  request = VERBS[method]
  resp = try
    if body !== nothing
      request(url; meta, data=JSON3.write(body), connect_timeout=5, readtimeout=120)
    else
      request(url; meta, data="", connect_timeout=5, readtimeout=30)
    end
  catch e
    e isa HTTPError || rethrow()
    error("Hindsight API error $(e.status): $(read(e, String))")
  end
  JSON3.read(read(resp, String))
end

function init(agent_id; url="http://localhost:8888", port=8888, admin_port=9999,
              llm_key="", llm_provider="", llm_model="", mission="")
  if !is_running()
    ensure_running(; port, admin_port, llm_key, llm_provider, llm_model) || return nothing
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
    api(conn, "POST", "/banks/$(conn.bank_id)/memories";
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
    resp = api(conn, "POST", "/banks/$(conn.bank_id)/reflect"; body)
    string(get(resp, :text, ""))
  catch e
    @warn "Hindsight reflect failed" exception=e
    nothing
  end
end
