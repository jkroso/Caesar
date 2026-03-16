# mcp_client.jl — Generic MCP client (JSON-RPC 2.0 over HTTP)

@use HTTP
@use JSON3
@use Logging

struct MCPTool
  name::String
  description::String
  schema::Any  # JSON3.Object from tools/list response
end

mutable struct MCPServer
  name::String
  url::String
  is_runtime::Bool
  session_id::String
  tools::Vector{MCPTool}
  connected::Bool
end

MCPServer(name, url; is_runtime=false) = MCPServer(name, url, is_runtime, "", MCPTool[], false)

const MCP_PROTOCOL_VERSION = "2025-11-25"
const MCP_SERVERS = Dict{String, MCPServer}()

let request_id = Ref(0)
  global next_request_id() = (request_id[] += 1; request_id[])
end

function send_jsonrpc(server::MCPServer, method::String, params::Dict=Dict())
  body = Dict(
    "jsonrpc" => "2.0",
    "id" => next_request_id(),
    "method" => method,
    "params" => params
  )
  headers = [
    "Content-Type" => "application/json",
    "Accept" => "application/json",
    "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION
  ]
  if !isempty(server.session_id)
    push!(headers, "Mcp-Session-Id" => server.session_id)
  end
  resp = HTTP.post(server.url, headers, JSON3.write(body); status_exception=false)
  # Capture session ID from response headers
  for h in resp.headers
    if lowercase(first(h)) == "mcp-session-id" && isempty(server.session_id)
      server.session_id = last(h)
    end
  end
  resp.status >= 400 && error("MCP request failed ($(resp.status)): $(String(resp.body))")
  resp_body = String(resp.body)
  # Handle SSE responses (text/event-stream) — extract JSON from "data: {...}" lines
  content_type = ""
  for h in resp.headers
    lowercase(first(h)) == "content-type" && (content_type = lowercase(last(h)))
  end
  if startswith(content_type, "text/event-stream") || startswith(resp_body, "data:")
    # Collect all data lines, take the last JSON-RPC response
    json_parts = String[]
    for line in split(resp_body, "\n")
      if startswith(line, "data:")
        push!(json_parts, strip(line[6:end]))
      end
    end
    isempty(json_parts) && error("Empty SSE response from MCP server")
    # Find the last non-empty data line (the final JSON-RPC response)
    resp_body = last(filter(!isempty, json_parts))
  end
  result = JSON3.read(resp_body)
  haskey(result, :error) && error("MCP error: $(result.error.message)")
  get(result, :result, nothing)
end

function mcp_connect!(server::MCPServer)
  @info "Connecting to MCP server: $(server.name) at $(server.url)"
  # Initialize handshake
  send_jsonrpc(server, "initialize", Dict(
    "protocolVersion" => MCP_PROTOCOL_VERSION,
    "capabilities" => Dict(),
    "clientInfo" => Dict("name" => "Prosca", "version" => "0.1.0")
  ))
  # Send initialized notification (no id, no response expected)
  notify_body = Dict("jsonrpc" => "2.0", "method" => "notifications/initialized")
  headers = [
    "Content-Type" => "application/json",
    "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION
  ]
  !isempty(server.session_id) && push!(headers, "Mcp-Session-Id" => server.session_id)
  HTTP.post(server.url, headers, JSON3.write(notify_body); status_exception=false)
  # Discover tools
  tools_result = send_jsonrpc(server, "tools/list")
  if tools_result !== nothing && haskey(tools_result, :tools)
    server.tools = [MCPTool(t.name, get(t, :description, ""), get(t, :inputSchema, Dict())) for t in tools_result.tools]
  end
  server.connected = true
  @info "Connected to $(server.name): $(length(server.tools)) tools discovered"
end

function mcp_call_tool(server::MCPServer, tool_name::String, args::Dict)::String
  !server.connected && return "Error: MCP server '$(server.name)' is not connected"
  result = send_jsonrpc(server, "tools/call", Dict(
    "name" => tool_name,
    "arguments" => args
  ))
  result === nothing && return "(no result)"
  # MCP tool results have a "content" array
  if haskey(result, :content)
    parts = [get(c, :text, string(c)) for c in result.content]
    return join(parts, "\n")
  end
  string(result)
end

function mcp_disconnect!(server::MCPServer)
  server.connected = false
  server.session_id = ""
  empty!(server.tools)
  @info "Disconnected from MCP server: $(server.name)"
end

function load_mcp_servers!(home_dir)
  empty!(MCP_SERVERS)
  config_path = string(home_dir * "mcp_servers.json")
  !isfile(config_path) && return
  servers = try
    JSON3.read(read(config_path, String), Dict{String, Any})
  catch e
    @warn "Failed to parse mcp_servers.json: $e"
    return
  end
  for (name, cfg) in servers
    name_str = string(name)
    url = cfg["url"]
    is_runtime = get(cfg, "runtime", false)
    server = MCPServer(name_str, url; is_runtime)
    MCP_SERVERS[name_str] = server
    try
      mcp_connect!(server)
    catch e
      @warn "Failed to connect to MCP server '$name_str': $e"
    end
  end
end

"Find the runtime MCP server (if any)"
function runtime_server()::Union{MCPServer, Nothing}
  for s in values(MCP_SERVERS)
    s.is_runtime && s.connected && return s
  end
  nothing
end
