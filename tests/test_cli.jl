# tests/test_cli.jl — Tests for CLI event loop, envelope wiring, and JSON parsing

using Test
using JSON3

# ── Stub types matching main.jl ─────────────────────────────────────
struct AgentMessage; text::String; end
struct ToolCallRequest; name::String; args::String; id::UInt64; end
struct ToolResult; name::String; result::String; end
struct AgentDone end
struct ToolApproval; id::UInt64; decision::Symbol; end

# ── handle_events (copied from cli.jl for unit testing) ─────────────
function handle_events(outbox::Channel)
  while true
    event = take!(outbox)
    if event isa AgentMessage
      # would println in real CLI
    elseif event isa ToolCallRequest
      # would prompt user
    elseif event isa ToolResult
      # noop
    elseif event isa AgentDone
      break
    end
  end
end

# ── Tests ────────────────────────────────────────────────────────────

@testset "handle_events — normal flow" begin
  outbox = Channel(8)
  put!(outbox, AgentMessage("hello"))
  put!(outbox, ToolResult("eval", "42"))
  put!(outbox, AgentMessage("done"))
  put!(outbox, AgentDone())
  # Should drain all events and return when it hits AgentDone
  handle_events(outbox)
  @test !isready(outbox)  # all events consumed
end

@testset "handle_events — hangs without AgentDone" begin
  outbox = Channel(8)
  put!(outbox, AgentMessage("hello"))
  # No AgentDone — handle_events will block on take!
  task = @async handle_events(outbox)
  sleep(0.1)
  @test !istaskdone(task)  # still blocked
  # Unblock it
  put!(outbox, AgentDone())
  sleep(0.1)
  @test istaskdone(task)
end

@testset "@async MethodError leaves handle_events hanging" begin
  # This reproduces the cli.jl bug: calling a function with wrong args
  # inside @async silently fails, never putting AgentDone on the channel
  outbox = Channel(8)

  # Simulate what cli.jl does: @async a function that will throw MethodError
  fake_handler(a::String, b::Channel, c::Channel, d::Int) = put!(b, AgentDone())
  @async fake_handler("hi", outbox, Channel(1))  # missing 4th arg → MethodError

  task = @async handle_events(outbox)
  sleep(0.2)
  @test !istaskdone(task)  # hung — the bug

  # Clean up: unblock the hung task
  put!(outbox, AgentDone())
  sleep(0.1)
  @test istaskdone(task)
end

@testset "cli sends envelopes to agent inbox" begin
  cli_src = read(joinpath(@__DIR__, "..", "cli.jl"), String)
  # CLI should push Envelopes into agent.inbox instead of calling process_message directly
  @test occursin("agent.inbox", cli_src) || occursin("default_agent().inbox", cli_src)
  @test occursin("Envelope", cli_src)
  # process_message should NOT be called directly from the CLI
  @test !occursin(r"process_message\(", cli_src)
end

@testset "channel flow — agent task puts AgentDone on error" begin
  # A properly wrapped agent task should always put AgentDone even on error
  outbox = Channel(8)

  function resilient_agent(outbox::Channel)
    try
      error("simulated failure")
    catch e
      put!(outbox, AgentMessage("Error: $(sprint(showerror, e))"))
    finally
      put!(outbox, AgentDone())
    end
  end

  @async resilient_agent(outbox)
  task = @async handle_events(outbox)
  sleep(0.2)
  @test istaskdone(task)  # should complete, not hang
end

# ── JSON parsing tests (extracted logic from main.jl) ────────────────

"""Extract and parse JSON from an LLM response, matching main.jl logic."""
function parse_llm_json(response_text::String)
  json_str = strip(response_text)
  m = match(r"```(?:json)?\s*\n?(.*?)\n?\s*```"s, json_str)
  if m !== nothing
    json_str = strip(m.captures[1])
  end
  if !startswith(json_str, "{")
    for line in reverse(split(json_str, '\n'))
      stripped = strip(line)
      if startswith(stripped, "{") && endswith(stripped, "}")
        json_str = stripped
        break
      end
    end
  end

  parsed = try
    result = JSON3.read(json_str)
    result isa AbstractDict ? result : nothing
  catch
    # Try extracting just the first JSON object
    first_obj = match(r"\{(?:[^{}]|\{[^{}]*\})*\}", json_str)
    if first_obj !== nothing
      try
        result = JSON3.read(first_obj.match)
        result isa AbstractDict ? result : nothing
      catch
        nothing
      end
    else
      nothing
    end
  end
  parsed
end

"""Check if a failed parse looks like it was an attempted JSON action."""
function looks_like_json(response_text::String)
  contains(response_text, "\"tool\"") && contains(response_text, "\"args\"") ||
  contains(response_text, "\"eval\"") ||
  contains(response_text, "\"final_answer\"") ||
  contains(response_text, "\"skill\"") ||
  contains(response_text, "\"handoff\"")
end

@testset "JSON parsing — single valid object" begin
  p = parse_llm_json("""{"eval": "1 + 2"}""")
  @test p !== nothing
  @test p[:eval] == "1 + 2"
end

@testset "JSON parsing — code fence wrapped" begin
  p = parse_llm_json("```json\n{\"eval\": \"sum([1,2,3])\"}\n```")
  @test p !== nothing
  @test p[:eval] == "sum([1,2,3])"
end

@testset "JSON parsing — final_answer" begin
  p = parse_llm_json("""{"final_answer": "The answer is 42."}""")
  @test p !== nothing
  @test p[:final_answer] == "The answer is 42."
end

@testset "JSON parsing — text before JSON" begin
  p = parse_llm_json("Let me think about this...\n{\"eval\": \"42\"}")
  @test p !== nothing
  @test p[:eval] == "42"
end

@testset "JSON parsing — multiple concatenated objects" begin
  # This is the bug: LLM returns multiple JSON objects in one response
  input = """{"eval": "is_prime(n) = n > 1"} {"eval": "filter(is_prime, 70:200)"}"""
  p = parse_llm_json(input)
  @test p !== nothing  # should parse the first object
  @test p[:eval] == "is_prime(n) = n > 1"
end

@testset "JSON parsing — plain text (not JSON)" begin
  p = parse_llm_json("The answer is 42. No tools needed.")
  @test p === nothing
end

@testset "looks_like_json — detects eval attempts" begin
  @test looks_like_json("""{"eval": "1+1"} {"eval": "2+2"}""")
  @test looks_like_json("""{"tool": "search", "args": {}}""")
  @test looks_like_json("""{"final_answer": "done"}""")
  @test looks_like_json("""{"skill": "code"}""")
  @test looks_like_json("""{"handoff": {"to": "other"}}""")
  @test !looks_like_json("The answer is 42.")
end

@testset "JSON parsing — tool with nested args" begin
  p = parse_llm_json("""{"tool": "search", "args": {"query": "hello world"}}""")
  @test p !== nothing
  @test p[:tool] == "search"
  @test p[:args][:query] == "hello world"
end
