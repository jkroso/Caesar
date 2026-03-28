@use "github.com/jkroso/JSON.jl" parse_json json
@use Logging

mutable struct OriConn
  process::Base.Process
  input::IO
  output::IO
  vault_dir::String
  next_id::Int
end

"Send a JSON-RPC request and wait for the matching response"
function mcp_request(conn::OriConn, method::String, params::Dict=Dict())
  conn.next_id += 1
  id = conn.next_id
  msg = json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
  println(conn.input, msg)
  flush(conn.input)
  # Read lines until we find the response matching our id
  while true
    line = readline(conn.output; keep=false)
    if isempty(line)
      process_running(conn.process) || error("Ori process exited")
      continue
    end
    resp = try parse_json(line) catch; continue end
    haskey(resp, "id") || continue  # skip server notifications
    Int(resp["id"]) == id || continue  # skip mismatched ids (JSON parses numbers as Float32)
    haskey(resp, "error") && error("MCP error: $(resp["error"])")
    return get(resp, "result", Dict())
  end
end

"Send a JSON-RPC notification (no response expected)"
function mcp_notify(conn::OriConn, method::String, params::Dict=Dict())
  msg = json(Dict("jsonrpc" => "2.0", "method" => method, "params" => params))
  println(conn.input, msg)
  flush(conn.input)
end

"Call an MCP tool and return the text from the first content block"
function mcp_call_tool(conn::OriConn, tool_name::String, arguments::Dict=Dict())
  result = mcp_request(conn, "tools/call", Dict("name" => tool_name, "arguments" => arguments))
  get(result, "isError", false) && (@warn "Ori tool $tool_name failed: $(result)"; return nothing)
  content = get(result, "content", [])
  for block in content
    get(block, "type", "") == "text" && return get(block, "text", "")
  end
  nothing
end

function init(agent_id; vault_dir, command="npx", personality="")
  mkpath(vault_dir)
  # Initialize vault if not already initialized (creates .ori marker, inbox/, notes/, etc.)
  if !isdir(joinpath(vault_dir, ".ori"))
    init_cmd = command == "npx" ? `npx -y ori-memory init --json $vault_dir` :
                                  `$command init --json $vault_dir`
    try run(pipeline(init_cmd; stdout=devnull)) catch e
      @warn "Ori vault init failed" exception=e
      return nothing
    end
    # Pre-populate identity so Ori skips its onboarding flow
    if !isempty(personality)
      identity_path = joinpath(vault_dir, "self", "identity.md")
      open(identity_path, "w") do io
        println(io, "---")
        println(io, "description: Agent identity — who you are, how you work, what you value")
        println(io, "type: self")
        println(io, "---\n")
        println(io, "# Identity\n")
        print(io, personality)
      end
    end
  end
  cmd = command == "npx" ? `npx -y ori-memory serve --mcp --vault $vault_dir` :
                           `$command serve --mcp --vault $vault_dir`
  local proc, input, output
  try
    input = Pipe()
    output = Pipe()
    proc = run(pipeline(cmd; stdin=input, stdout=output, stderr=devnull); wait=false)
  catch e
    @warn "Failed to start Ori MCP server" exception=e
    return nothing
  end
  conn = OriConn(proc, input, output, vault_dir, 0)
  try
    mcp_request(conn, "initialize", Dict(
      "protocolVersion" => "2024-11-05",
      "capabilities" => Dict(),
      "clientInfo" => Dict("name" => "caesar", "version" => "1.0")
    ))
    mcp_notify(conn, "notifications/initialized")
    conn
  catch e
    @warn "Ori MCP handshake failed" exception=e
    kill(proc)
    nothing
  end
end

function retain(conn::OriConn, content::String; context=nothing)
  process_running(conn.process) || return false
  try
    # ori_add requires title; use first line as title, rest as body
    lines = split(content, '\n'; limit=2)
    title = strip(first(lines))
    isempty(title) && return false
    body = length(lines) > 1 ? strip(lines[2]) : ""
    args = Dict{String,Any}("title" => title)
    isempty(body) || (args["content"] = body)
    # ori_add auto-promotes when vault config has promote.auto: true (default)
    mcp_call_tool(conn, "ori_add", args)
    true
  catch e
    @warn "Ori retain failed" exception=e
    false
  end
end

function recall(conn::OriConn, query::String; limit::Int=5)
  process_running(conn.process) || return Dict{String,Any}[]
  try
    # Use ori_explore which includes note content snippets
    text = mcp_call_tool(conn, "ori_explore", Dict("query" => query, "limit" => limit, "include_content" => true))
    text === nothing && return Dict{String,Any}[]
    parsed = try parse_json(text) catch; nothing end
    parsed === nothing && return [Dict{String,Any}("text" => text)]
    data = get(parsed, "data", Dict())
    results = get(data, "results", get(data, "notes", []))
    isempty(results) && return Dict{String,Any}[]
    map(results) do r
      title = get(r, "title", "")
      snippet = get(r, "snippet", get(r, "content", ""))
      Dict{String,Any}("text" => isempty(snippet) ? title : "$title: $snippet")
    end
  catch e
    @warn "Ori recall failed" exception=e
    Dict{String,Any}[]
  end
end

function orient(conn::OriConn)
  process_running(conn.process) || return ""
  try
    text = mcp_call_tool(conn, "ori_orient")
    text === nothing ? "" : text
  catch e
    @warn "Ori orient failed" exception=e
    ""
  end
end

function shutdown(conn::OriConn)
  try
    process_running(conn.process) && kill(conn.process)
    close(conn.input)
    close(conn.output)
  catch; end
  nothing
end
