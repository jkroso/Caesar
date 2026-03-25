# tests/test_message.jl — Tests for the inbox/outbox message architecture

@use "github.com/jkroso/Promises.jl" need @thread
@use Test...

# ── Stub types matching main.jl ─────────────────────────────────────
struct AgentMessage; text::String end
struct AgentDone end
struct ToolCallRequest; name::String; args::String; id::UInt64 end
struct ToolResult; name::String; result::String end
struct ToolApproval; id::UInt64; decision::Symbol end

struct Envelope
  text::String
  outbox::Channel
  approvals::Channel
end

# ── Minimal Agent stub with inbox ────────────────────────────────────
struct Agent
  id::String
  inbox::Channel
end
Agent(id::String) = Agent(id, Channel(Inf))

"Start the agent's sequential message-processing loop with a custom handler"
function start!(handler::Function, agent::Agent)
  @async for env in agent.inbox
    handler(env.text, agent, env.outbox)
  end
end

# ── message() mirrors main.jl ───────────────────────────────────────
function message(agent::Agent, text::String)
  outbox = Channel(32)
  approvals = Channel(32)
  reply = Ref("")
  drainer = @async begin
    while true
      event = take!(outbox)
      event isa AgentMessage && (reply[] = event.text)
      event isa AgentDone && break
    end
  end
  put!(agent.inbox, Envelope(text, outbox, approvals))
  @thread begin
    wait(drainer)
    reply[]
  end
end

# ── Tests ───────────────────────────────────────────────────────────

@testset "message — returns last AgentMessage" begin
  a = Agent("t1")
  start!(a) do text, agent, outbox
    put!(outbox, AgentMessage("hello"))
    put!(outbox, AgentMessage("final reply"))
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "final reply"
end

@testset "message — single message" begin
  a = Agent("t2")
  start!(a) do text, agent, outbox
    put!(outbox, AgentMessage("only one"))
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "only one"
end

@testset "message — empty reply when no AgentMessage" begin
  a = Agent("t3")
  start!(a) do text, agent, outbox
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == ""
end

@testset "message — ignores ToolResult events" begin
  a = Agent("t4")
  start!(a) do text, agent, outbox
    put!(outbox, ToolResult("eval", "42"))
    put!(outbox, AgentMessage("the answer"))
    put!(outbox, ToolResult("eval", "43"))
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "the answer"
end

@testset "message — passes text through to handler" begin
  a = Agent("t5")
  received = Ref("")
  start!(a) do text, agent, outbox
    received[] = text
    put!(outbox, AgentMessage("ok"))
    put!(outbox, AgentDone())
  end
  need(message(a, "specific input"))
  @test received[] == "specific input"
end

@testset "message — drainer doesn't miss events from fast producer" begin
  a = Agent("t6")
  start!(a) do text, agent, outbox
    for i in 1:30
      put!(outbox, AgentMessage("msg $i"))
    end
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "msg 30"
end

@testset "message — channel buffer overflow doesn't deadlock" begin
  a = Agent("t7")
  start!(a) do text, agent, outbox
    for i in 1:50
      put!(outbox, AgentMessage("msg $i"))
    end
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "msg 50"
end

@testset "message — concurrent messages to different agents" begin
  a1 = Agent("c1")
  a2 = Agent("c2")
  start!(a1) do text, agent, outbox
    sleep(0.05)
    put!(outbox, AgentMessage("from a1"))
    put!(outbox, AgentDone())
  end
  start!(a2) do text, agent, outbox
    put!(outbox, AgentMessage("from a2"))
    put!(outbox, AgentDone())
  end
  p1 = message(a1, "hi")
  p2 = message(a2, "hi")
  @test need(p2) == "from a2"
  @test need(p1) == "from a1"
end

@testset "message — sequential processing on same agent" begin
  a = Agent("s1")
  start!(a) do text, agent, outbox
    put!(outbox, AgentMessage("reply to $text"))
    put!(outbox, AgentDone())
  end
  @test need(message(a, "first")) == "reply to first"
  @test need(message(a, "second")) == "reply to second"
end

@testset "message — concurrent sends to same agent process in order" begin
  a = Agent("seq")
  order = String[]
  start!(a) do text, agent, outbox
    push!(order, text)
    put!(outbox, AgentMessage("reply to $text"))
    put!(outbox, AgentDone())
  end
  p1 = message(a, "first")
  p2 = message(a, "second")
  @test need(p1) == "reply to first"
  @test need(p2) == "reply to second"
  @test order == ["first", "second"]
end

@testset "message — interleaved events on per-message outbox stay ordered" begin
  a = Agent("i1")
  start!(a) do text, agent, outbox
    put!(outbox, AgentMessage("thinking..."))
    put!(outbox, ToolResult("eval", "42"))
    put!(outbox, ToolCallRequest("search", "{}", UInt64(1)))
    put!(outbox, AgentMessage("done thinking"))
    put!(outbox, AgentDone())
  end
  @test need(message(a, "hi")) == "done thinking"
end

@testset "message — each message gets its own outbox" begin
  a = Agent("iso")
  outboxes = Channel[]
  start!(a) do text, agent, outbox
    push!(outboxes, outbox)
    put!(outbox, AgentMessage(text))
    put!(outbox, AgentDone())
  end
  need(message(a, "one"))
  need(message(a, "two"))
  @test length(outboxes) == 2
  @test outboxes[1] !== outboxes[2]
end
