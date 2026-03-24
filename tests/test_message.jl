# tests/test_message.jl — Tests for the message(agent, text) -> Promise API

@use "github.com/jkroso/Promises.jl" need @thread
@use Test...

# ── Stub types matching main.jl ─────────────────────────────────────
struct AgentMessage; text::String end
struct AgentDone end
struct ToolCallRequest; name::String; args::String; id::UInt64 end
struct ToolResult; name::String; result::String end
struct ToolApproval; id::UInt64; decision::Symbol end

# ── Minimal Agent stub ──────────────────────────────────────────────
struct Agent
  id::String
end

# ── message implementation (mirrors main.jl) ────────────────────────
function message(run::Function, agent::Agent, text::String)
  outbox = Channel(32)
  inbox = Channel(32)
  reply = Ref("")
  drainer = @async begin
    while true
      event = take!(outbox)
      event isa AgentMessage && (reply[] = event.text)
      event isa AgentDone && break
    end
  end
  @thread begin
    run(text, agent, outbox)
    wait(drainer)
    reply[]
  end
end

# ── Tests ───────────────────────────────────────────────────────────

@testset "message — returns last AgentMessage" begin
  a = Agent("t1")
  p = message(a, "hi") do text, agent, outbox
    put!(outbox, AgentMessage("hello"))
    put!(outbox, AgentMessage("final reply"))
    put!(outbox, AgentDone())
  end
  @test need(p) == "final reply"
end

@testset "message — single message" begin
  a = Agent("t2")
  p = message(a, "hi") do text, agent, outbox
    put!(outbox, AgentMessage("only one"))
    put!(outbox, AgentDone())
  end
  @test need(p) == "only one"
end

@testset "message — empty reply when no AgentMessage" begin
  a = Agent("t3")
  p = message(a, "hi") do text, agent, outbox
    put!(outbox, AgentDone())
  end
  @test need(p) == ""
end

@testset "message — ignores ToolResult events" begin
  a = Agent("t4")
  p = message(a, "hi") do text, agent, outbox
    put!(outbox, ToolResult("eval", "42"))
    put!(outbox, AgentMessage("the answer"))
    put!(outbox, ToolResult("eval", "43"))
    put!(outbox, AgentDone())
  end
  @test need(p) == "the answer"
end

@testset "message — passes text through to run function" begin
  a = Agent("t5")
  received = Ref("")
  p = message(a, "specific input") do text, agent, outbox
    received[] = text
    put!(outbox, AgentMessage("ok"))
    put!(outbox, AgentDone())
  end
  need(p)
  @test received[] == "specific input"
end

@testset "message — drainer doesn't miss events from fast producer" begin
  a = Agent("t6")
  p = message(a, "hi") do text, agent, outbox
    for i in 1:30
      put!(outbox, AgentMessage("msg $i"))
    end
    put!(outbox, AgentDone())
  end
  @test need(p) == "msg 30"
end

@testset "message — channel buffer overflow doesn't deadlock" begin
  # Channel has 32 slots. Producing >32 events would deadlock
  # if drainer wasn't running concurrently with run_agent
  a = Agent("t7")
  p = message(a, "hi") do text, agent, outbox
    for i in 1:50
      put!(outbox, AgentMessage("msg $i"))
    end
    put!(outbox, AgentDone())
  end
  @test need(p) == "msg 50"
end

@testset "message — concurrent messages to different agents" begin
  a1 = Agent("c1")
  a2 = Agent("c2")
  p1 = message(a1, "hi") do text, agent, outbox
    sleep(0.05)
    put!(outbox, AgentMessage("from a1"))
    put!(outbox, AgentDone())
  end
  p2 = message(a2, "hi") do text, agent, outbox
    put!(outbox, AgentMessage("from a2"))
    put!(outbox, AgentDone())
  end
  @test need(p2) == "from a2"
  @test need(p1) == "from a1"
end

@testset "message — two sequential messages to same agent" begin
  a = Agent("s1")
  p1 = message(a, "first") do text, agent, outbox
    put!(outbox, AgentMessage("reply 1"))
    put!(outbox, AgentDone())
  end
  @test need(p1) == "reply 1"

  p2 = message(a, "second") do text, agent, outbox
    put!(outbox, AgentMessage("reply 2"))
    put!(outbox, AgentDone())
  end
  @test need(p2) == "reply 2"
end

@testset "message — concurrent messages to same agent are isolated" begin
  a = Agent("race")
  gate = Channel(1)
  p1 = message(a, "first") do text, agent, outbox
    take!(gate)
    put!(outbox, AgentMessage("reply 1"))
    put!(outbox, AgentDone())
  end
  p2 = message(a, "second") do text, agent, outbox
    put!(outbox, AgentMessage("reply 2"))
    put!(outbox, AgentDone())
    put!(gate, nothing)
  end
  @test need(p1) == "reply 1"
  @test need(p2) == "reply 2"
end

@testset "message — interleaved events on shared channel stay ordered" begin
  # Simulates tool calls mixed with messages
  a = Agent("i1")
  p = message(a, "hi") do text, agent, outbox
    put!(outbox, AgentMessage("thinking..."))
    put!(outbox, ToolResult("eval", "42"))
    put!(outbox, ToolCallRequest("search", "{}", UInt64(1)))
    put!(outbox, AgentMessage("done thinking"))
    put!(outbox, AgentDone())
  end
  @test need(p) == "done thinking"
end
