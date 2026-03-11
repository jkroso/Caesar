include("main.jl")

rt = runtime_server()
println("Connected: ", rt !== nothing && rt.connected)

if rt !== nothing && rt.connected
  # Test 1: Check commands loaded
  result = mcp_call_tool(rt, "ex", Dict{String,Any}("e" => "include(\"main.jl\"); join(keys(COMMANDS), \", \")", "q" => false))
  println("Commands: ", result)

  # Test 2: Check LLM_SCHEMA exists
  result2 = mcp_call_tool(rt, "ex", Dict{String,Any}("e" => "LLM_SCHEMA[]", "q" => false))
  println("LLM_SCHEMA: ", result2)

  # Test 3: Check model
  result3 = mcp_call_tool(rt, "ex", Dict{String,Any}("e" => "CONFIG[\"llm\"]", "q" => false))
  println("Model: ", result3)
end
