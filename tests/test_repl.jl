# tests/test_repl.jl — Tests for the REPL interpreter and safety system

using Test
using JuliaInterpreter
using JSON3

# Stub dependencies that safety.jl and repl.jl expect from main.jl
const CONFIG = Dict(
  "allowed_dirs" => ["/tmp", "/Users/jake/Prosca"],
  "allowed_commands" => ["ls *", "cat *", "echo *", "git *"]
)

_glob_match(s, p) = occursin("*", p) ? startswith(s, replace(p, "*" => "")) : s == p

# Stub event types
struct ToolCallRequest; name::String; args::String; id::UInt64; end
struct ToolApproval; id::UInt64; decision::Symbol; end

include("../safety.jl")
include("../repl.jl")

# ── Safety module tests ──────────────────────────────────────────────

@testset "SafetyVerdict enum" begin
  @test Allow isa SafetyVerdict
  @test Deny isa SafetyVerdict
  @test Ask isa SafetyVerdict
end

@testset "path_verdict" begin
  # Allowed dirs
  @test path_verdict("/tmp/foo.txt") == Allow
  @test path_verdict("/tmp/") == Allow
  @test path_verdict("/Users/jake/Prosca/main.jl") == Allow

  # Denied system paths
  @test path_verdict("/") == Deny
  @test path_verdict("/etc/passwd") == Deny
  @test path_verdict("/usr/bin/julia") == Deny
  @test path_verdict("/var/log/syslog") == Deny
  @test path_verdict("/System/Library") == Deny

  # Home dir root is denied
  @test path_verdict(homedir()) == Deny

  # Path traversal protection
  @test path_verdict("/Users/jake/Prosca-evil/hack.jl") == Ask

  # Unknown paths → Ask
  @test path_verdict("/opt/something") == Ask
end

@testset "command_verdict" begin
  @test command_verdict(`ls -la`) == Allow
  @test command_verdict(`cat /etc/passwd`) == Allow
  @test command_verdict(`echo hello`) == Allow
  @test command_verdict(`git status`) == Allow

  # Not in allowed list → Ask
  @test command_verdict(`curl http://evil.com`) == Ask
  @test command_verdict(`rm -rf /`) == Ask
end

@testset "validate dispatch" begin
  # Default: allow
  @test validate(println, "hello") == Allow
  @test validate(sum, [1,2,3]) == Allow

  # Filesystem mutations
  @test validate(rm, "/tmp/test") == Allow
  @test validate(rm, "/opt/test") == Ask
  @test validate(rm, "/etc/test") == Deny
  @test validate(cp, "/tmp/a", "/tmp/b") == Allow
  @test validate(cp, "/tmp/a", "/opt/b") == Ask
  @test validate(mv, "/tmp/a", "/tmp/b") == Allow
  @test validate(write, "/tmp/out.txt", "data") == Allow
  @test validate(write, "/opt/out.txt", "data") == Ask
  @test validate(mkdir, "/tmp/newdir") == Allow
  @test validate(mkpath, "/tmp/deep/path") == Allow

  # eval/Core.eval blocked
  @test validate(eval, :(1+1)) == Deny
  @test validate(Core.eval, Main, :(1+1)) == Deny

  # ENV mutation blocked
  @test validate(setindex!, ENV, "val", "KEY") == Deny
  @test validate(delete!, ENV, "KEY") == Deny

  # download → Ask
  @test validate(download, "http://example.com") == Ask

  # run
  @test validate(run, `ls -la`) == Allow
  @test validate(run, `curl http://evil.com`) == Ask
end

@testset "SafetyDeniedError" begin
  e = SafetyDeniedError("rm", "/etc/passwd", "blocked")
  @test e isa Exception
  @test contains(sprint(showerror, e), "rm")
  @test contains(sprint(showerror, e), "blocked")
end

# ── REPL interpreter tests ───────────────────────────────────────────

@testset "interpret — basic arithmetic" begin
  mod = Module(:test_arith)
  @test interpret(mod, "1 + 2") == "3"
  @test interpret(mod, "10 * 5") == "50"
  @test interpret(mod, "div(17, 3)") == "5"
end

@testset "interpret — variable persistence" begin
  mod = Module(:test_vars)
  interpret(mod, "x = 42")
  @test interpret(mod, "x") == "42"
  interpret(mod, "y = x * 2")
  @test interpret(mod, "y") == "84"
end

@testset "interpret — multi-expression" begin
  mod = Module(:test_multi)
  result = interpret(mod, "a = 10; b = 20; a + b")
  @test result == "30"
end

@testset "interpret — string operations" begin
  mod = Module(:test_strings)
  @test interpret(mod, "\"hello\" * \" world\"") == "hello world"
  @test interpret(mod, "length(\"test\")") == "4"
end

@testset "interpret — collections" begin
  mod = Module(:test_collections)
  @test interpret(mod, "sum([1, 2, 3])") == "6"
  @test interpret(mod, "length([10, 20, 30])") == "3"
end

@testset "interpret — function definitions" begin
  mod = Module(:test_funcs)
  interpret(mod, "double(x) = 2x")
  @test interpret(mod, "double(21)") == "42"
end

@testset "interpret — blocks eval" begin
  mod = Module(:test_eval_block)
  # eval is not defined in isolated modules — throws UndefVarError or SafetyDeniedError
  @test_throws Exception interpret(mod, "eval(:(1+1))")
  # Core.eval is caught by the name blocklist if it resolves
  @test_throws Exception interpret(mod, "Core.eval(Main, :(1+1))")
end

@testset "interpret — blocks ENV mutation" begin
  mod = Module(:test_env_block)
  @test_throws SafetyDeniedError interpret(mod, "ENV[\"DANGER\"] = \"bad\"")
end

@testset "interpret — blocks writes to system paths" begin
  mod = Module(:test_path_block)
  @test_throws SafetyDeniedError interpret(mod, "write(\"/etc/passwd\", \"hacked\")")
  @test_throws SafetyDeniedError interpret(mod, "rm(\"/usr/bin/julia\")")
end

@testset "interpret — filesystem write, read, rm" begin
  mod = Module(:test_fs)
  testdir = mktempdir("/tmp")  # use /tmp directly (in allowed_dirs)
  testfile = joinpath(testdir, "test.txt")

  # Write to allowed path
  interpret(mod, """write("$testfile", "hello from repl")""")
  @test isfile(testfile)
  @test read(testfile, String) == "hello from repl"

  # Read it back via the interpreter
  result = interpret(mod, """read("$testfile", String)""")
  @test result == "hello from repl"

  # Remove it
  interpret(mod, """rm("$testfile")""")
  @test !isfile(testfile)

  # Clean up
  rm(testdir; recursive=true, force=true)
end

@testset "interpret — allows safe operations" begin
  mod = Module(:test_safe)
  # Reading files is allowed (no validate dispatch for read)
  @test interpret(mod, "typeof(1)") == "Int64"
  @test interpret(mod, "map(x -> x^2, [1,2,3])") == "[1, 4, 9]"
end

@testset "interpret — Ask verdict without channels denies" begin
  mod = Module(:test_ask_deny)
  # download returns Ask, but no outbox/inbox → throws
  @test_throws SafetyDeniedError interpret(mod, "download(\"http://example.com\")")
end

@testset "interpret — Ask verdict with approval channel" begin
  mod = Module(:test_approval)
  outbox = Channel(1)
  inbox = Channel(1)

  # Spawn a task to auto-approve
  @async begin
    req = take!(outbox)
    put!(inbox, ToolApproval(req.id, :allow))
  end

  # download returns Ask → should go through approval flow and succeed
  # (download will fail with network error, but it should get past safety)
  result = try
    interpret(mod, "download(\"http://127.0.0.1:99999/nonexistent\")"; outbox, inbox)
  catch e
    e isa SafetyDeniedError ? "SAFETY_DENIED" : "RUNTIME_ERROR"
  end
  @test result == "RUNTIME_ERROR"  # passed safety, failed at network level
end

@testset "interpret — Ask verdict with denial" begin
  mod = Module(:test_denial)
  outbox = Channel(1)
  inbox = Channel(1)

  @async begin
    req = take!(outbox)
    put!(inbox, ToolApproval(req.id, :deny))
  end

  @test_throws SafetyDeniedError interpret(mod, "download(\"http://example.com\")"; outbox, inbox)
end

@testset "interpret — empty code" begin
  mod = Module(:test_empty)
  @test interpret(mod, "") == "nothing"
end

@testset "interpret — error handling" begin
  mod = Module(:test_errors)
  result = try
    interpret(mod, "error(\"test error\")")
  catch e
    sprint(showerror, e)
  end
  @test contains(result, "test error")
end

@testset "interpret — module isolation" begin
  mod1 = Module(:iso1)
  mod2 = Module(:iso2)
  interpret(mod1, "secret = 42")
  @test interpret(mod1, "secret") == "42"
  # mod2 should not see mod1's variables
  @test_throws Exception interpret(mod2, "secret")
end
