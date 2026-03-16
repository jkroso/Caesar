# REPL Runtime Design (Sub-project 2)

**Date:** 2026-03-16
**Status:** Approved
**Scope:** Replace MCP/Kaimon with JuliaInterpreter-based REPL. Per-agent isolated environments. Runtime safety verification via dispatch. Remove all MCP code.

## Overview

Replace the external Kaimon MCP server with a built-in JuliaInterpreter-based REPL. Each agent gets its own `Module` as an isolated execution environment. Code is stepped through by the interpreter, which intercepts dangerous function calls and verifies their resolved arguments against safety rules before allowing execution. The REPL becomes a first-class response type in the ReAct loop (`{"eval": "..."}`) rather than an MCP tool.

## Key Decisions

- **JuliaInterpreter for execution** — code is interpreted (stepped through), not `eval`d directly. This enables runtime interception of dangerous calls with full argument visibility.
- **Per-agent Module isolation** — each agent gets a dynamically created `Module`. Variables and functions persist across evals but don't leak between agents.
- **Runtime verification via dispatch** — dangerous functions are intercepted using Julia's multiple dispatch: `validate(::typeof(rm), path)`. Returns an enum (`Allow`, `Deny`, `Ask`).
- **First-class eval** — `{"eval": "code"}` is a new JSON response type in the ReAct loop, alongside `tool`, `final_answer`, `skill`, `handoff`.
- **Complete MCP removal** — `mcp_client.jl`, `mcp_servers.json`, all MCP references in `main.jl`, and the MCP Tools GUI page are deleted.
- **No static analysis** — `validate_ex.jl` is removed. Runtime verification replaces it.
- **Indirect calls are caught** — if agent code calls `my_delete(path)` which internally calls `rm(path)`, the `rm` breakpoint still fires because JuliaInterpreter steps through all code, including user-defined functions.

## Per-Agent REPL Environment

Each `Agent` gains a `repl_module::Module` field:

```julia
struct Agent
  id::String
  personality::String
  instructions::String
  skills::Dict{String, Skill}
  path::FSPath
  repl_module::Module
end
```

On agent load, `load_agent` creates the module and passes it to the constructor:
```julia
function load_agent(agent_dir::FSPath)::Union{Agent, Nothing}
  id = agent_dir.name
  # ... load soul, instructions, skills ...
  agent_mod = Module(Symbol("agent_$id"))
  Agent(id, personality, instructions, skills, agent_dir, agent_mod)
end
```

`create_agent!` and `update_agent!` also create/preserve the module. `update_agent!` calls `load_agent` internally which creates a fresh module — this is acceptable since editing soul/instructions doesn't need to preserve REPL state.

## Runtime Safety Verification

### Validation Enum

```julia
@enum SafetyVerdict Allow Deny Ask
```

### Custom Exception

```julia
struct SafetyDeniedError <: Exception
  func::String
  args::String
  reason::String
end
```

### Validation Dispatch

```julia
# Default: allow everything not explicitly checked
validate(f, args...; kwargs...) = Allow

# Filesystem mutations: check path is in allowed dirs
validate(::typeof(rm), path::AbstractString; kwargs...) = path_verdict(path)
validate(::typeof(cp), src::AbstractString, dst::AbstractString) = path_verdict(dst)
validate(::typeof(mv), src::AbstractString, dst::AbstractString) = path_verdict(dst)
validate(::typeof(write), path::AbstractString, data; kwargs...) = path_verdict(path)
validate(::typeof(mkdir), path::AbstractString) = path_verdict(path)
validate(::typeof(mkpath), path::AbstractString) = path_verdict(path)

# File open with write mode
validate(::typeof(open), path::AbstractString, mode::AbstractString; kwargs...) =
  contains(mode, "w") || contains(mode, "a") ? path_verdict(path) : Allow
validate(::typeof(open), f::Function, path::AbstractString, args...; kwargs...) = path_verdict(path)

# Process execution
validate(::typeof(run), cmd::Cmd) = command_verdict(cmd)

# Prevent eval/Core.eval bypass (would skip interpreter entirely)
validate(::typeof(eval), args...) = Deny
validate(::typeof(Core.eval), args...) = Deny

# Prevent ENV mutation (API keys, global state)
validate(::typeof(setindex!), ::typeof(ENV), args...) = Deny
validate(::typeof(delete!), ::typeof(ENV), args...) = Deny

# Download — both network and filesystem
validate(::typeof(download), args...) = Ask
```

### Verdict Functions

```julia
function path_verdict(path::AbstractString)::SafetyVerdict
  abs_path = abspath(path)
  # Auto-deny clearly dangerous paths
  abs_path in ("/", "/usr", "/bin", "/etc", "/var", "/System") && return Deny
  abs_path == homedir() && return Deny
  # Allow if within any allowed_dirs (check directory boundary)
  for dir in CONFIG["allowed_dirs"]
    dir_str = rstrip(string(dir), '/')
    (startswith(abs_path, dir_str * "/") || abs_path == dir_str) && return Allow
  end
  Ask  # not in allowed dirs — ask user
end

function command_verdict(cmd::Cmd)::SafetyVerdict
  cmd_str = join(cmd.exec, " ")
  for pattern in get(CONFIG, "allowed_commands", [])
    _glob_match(cmd_str, string(pattern)) && return Allow
  end
  Ask
end
```

Note: `path_verdict` uses `dir_str * "/"` to prevent path traversal (e.g. `/Users/jake/Prosca-evil` matching `/Users/jake/Prosca`).

### Interpreter Integration

The `interpret` function uses JuliaInterpreter's `step_expr!` to manually step through every expression. Before each call expression executes, the function and resolved arguments are inspected and passed to `validate`.

**Multi-expression support:** Use `Meta.parseall(code)` (not `Meta.parse`) to handle multi-line input.

**Manual stepping:** Call `step_expr!` in a loop. On each step, inspect the current frame — if it's about to enter a function call, extract the function and resolved arguments, then check `validate(f, args...)`. This catches every call including indirect ones (user-defined wrappers around dangerous functions).

```julia
function interpret(agent::Agent, code::String; outbox=nothing, inbox=nothing)::String
  expr = Meta.parseall(code)
  frame = JuliaInterpreter.prepare_thunk(agent.repl_module, expr)
  while true
    # Step one expression
    ret = JuliaInterpreter.step_expr!(frame)
    # If we're about to call a function, inspect it
    if is_call(frame)
      f, args... = extract_call_args(frame)
      verdict = validate(f, args...)
      if verdict == Deny
        throw(SafetyDeniedError(string(f), string(args), "blocked by safety rules"))
      elseif verdict == Ask
        # Use existing approval flow
        req_id = rand(UInt64)
        put!(outbox, ToolCallRequest(string(f), string(args), req_id))
        approval = take!(inbox)
        if approval.decision == :deny
          throw(SafetyDeniedError(string(f), string(args), "denied by user"))
        end
        # :allow or :always → continue
      end
      # Allow → proceed
    end
    # Check if execution is complete
    ret !== nothing && return sprint(show, ret)
  end
end
```

Note: `is_call` and `extract_call_args` are helpers that inspect the current frame state. The exact API for extracting call targets and arguments from `JuliaInterpreter.Frame` is an implementation detail — the frame's `stmt` field contains the current expression, and locals can be read with `JuliaInterpreter.locals(frame)`.

## ReAct Loop Integration

### New `eval` Response Type

After `handoff` handling and before `tool` handling in `_run_agent`:

```julia
if haskey(parsed, :eval)
  code = string(parsed.eval)
  result = interpret(agent, code; outbox, inbox)
  push!(messages, PromptingTools.AIMessage(response_text))
  push!(messages, PromptingTools.UserMessage("Result: $result"))
  log_memory("Eval: $code → $(result[1:min(500,end)])"; agent_id=agent.id, conversation_id)
  continue
end
```

### System Prompt Changes

Replace the MCP runtime section in `build_system_prompt` with:

```
## Julia REPL
You have a persistent Julia REPL. Use {"eval": "code"} to evaluate Julia expressions.
Variables and functions persist across evaluations.
Use standard Julia for introspection: names(@__MODULE__), methods(f), typeof(x), etc.
```

Remove the existing `is_allowed_path` function and all MCP tool listing code from `build_system_prompt`. The `is_allowed_path` function is replaced by `path_verdict` in `safety.jl`.

### Periodic Scope Reminder

Every 5 steps, inject the agent's module bindings (only if the module has user-defined bindings beyond the default):
```julia
if step > 1 && step % 5 == 0
  user_names = filter(n -> n != Symbol(agent.repl_module), names(agent.repl_module; all=false))
  if !isempty(user_names)
    scope = join(user_names, ", ")
    push!(messages, PromptingTools.UserMessage("[REPL scope] Variables: $scope"))
  end
end
```

## What Gets Removed

### Files Deleted
- `mcp_client.jl`
- `validate_ex.jl`
- `mcp_servers.json` (from home dir at runtime)
- `gui/src/pages/McpToolsPage.tsx`

### Files Modified
- `main.jl` — remove MCP import (`@use "./mcp_client" ...`), MCP config creation, `load_mcp_servers!` call, `validate_ex` import, `is_allowed_path`, MCP tool sections in `build_system_prompt`, MCP tool dispatch in ReAct loop, `runtime_server()` references. Update `Agent` struct (add `repl_module`), update `load_agent`, `create_agent!`, `update_agent!`.
- `json_io.jl` — remove `handle_mcp_list`, `mcp_list` message handler
- `gui/src/App.tsx` — remove MCP Tools page from routing
- `gui/src/components/layout/Sidebar.tsx` — remove MCP Tools nav item

### New Files
- `repl.jl` — `interpret` function, JuliaInterpreter integration, breakpoint setup
- `safety.jl` — `SafetyVerdict` enum, `SafetyDeniedError`, `validate` dispatch methods, `path_verdict`, `command_verdict`

## Approval Flow for `Ask` Verdicts

When the interpreter hits a dangerous call and `validate` returns `Ask`:

1. Interpreter pauses execution (breakpoint hit)
2. Sends a `ToolCallRequest` via the `outbox` with the function name and resolved args (e.g. name=`"rm"`, args=`"/Users/jake/untrusted/file.txt"`)
3. Waits for `ToolApproval` on `inbox`
4. If `:allow` or `:always` → interpreter resumes (`:always` adds to auto-allowed set)
5. If `:deny` → interpreter throws `SafetyDeniedError`

This reuses the existing approval infrastructure — GUI approval cards, Telegram inline keyboard, presence-based routing, and the `:always` auto-approve mechanism all work unchanged.

## What This Does NOT Cover

- Multi-agent project pipelines (sub-project 4)
- Network IO interception beyond `download` (can be added later by adding `validate` methods for HTTP functions)
- Package installation safety (agents can't add packages — they work with what's available)
