# REPL Runtime Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MCP/Kaimon with a built-in JuliaInterpreter-based REPL that has runtime safety verification via dispatch, per-agent Module isolation, and a first-class `{"eval": "..."}` response type.

**Architecture:** A `safety.jl` module defines the `SafetyVerdict` enum and `validate` dispatch methods. A `repl.jl` module uses JuliaInterpreter's `step_expr!` to manually step through code, calling `validate` before each function call. The ReAct loop in `main.jl` handles `{"eval": "..."}` responses. All MCP code is removed.

**Tech Stack:** Julia, JuliaInterpreter.jl

**Spec:** `docs/specs/2026-03-16-repl-runtime-design.md`

---

## File Structure

**New files:**
- `safety.jl` — `SafetyVerdict` enum, `SafetyDeniedError`, `validate` dispatch, `path_verdict`, `command_verdict`
- `repl.jl` — `interpret` function using JuliaInterpreter `step_expr!`

**Modified files:**
- `agents.jl` — Add `repl_module::Module` to Agent struct, update `load_agent`, `create_agent!`
- `main.jl` — Remove MCP imports/config/code, remove `validate_ex` import, remove `is_allowed_path`, add `safety.jl`/`repl.jl` imports, add `eval` handling + scope reminder to ReAct loop, simplify `build_system_prompt`
- `json_io.jl` — Remove `handle_mcp_list` and `mcp_list` handler

**Deleted files:**
- `mcp_client.jl`
- `validate_ex.jl`
- `gui/src/pages/McpToolsPage.tsx`

**GUI modified:**
- `gui/src/App.tsx` — Remove MCP Tools page
- `gui/src/components/layout/Sidebar.tsx` — Remove MCP Tools nav item

---

## Chunk 1: Safety Module + REPL Interpreter

### Task 1: Safety module

**Files:**
- Create: `safety.jl`

- [ ] **Step 1: Create `safety.jl`**

```julia
# safety.jl — Runtime safety verification via dispatch

@enum SafetyVerdict Allow Deny Ask

struct SafetyDeniedError <: Exception
  func::String
  args::String
  reason::String
end

Base.showerror(io::IO, e::SafetyDeniedError) =
  print(io, "Safety denied: $(e.func)($(e.args)) — $(e.reason)")

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

# Prevent eval/Core.eval bypass
validate(::typeof(eval), args...) = Deny
validate(::typeof(Core.eval), args...) = Deny

# Prevent ENV mutation
validate(::typeof(setindex!), ::typeof(ENV), args...) = Deny
validate(::typeof(delete!), ::typeof(ENV), args...) = Deny

# Download — both network and filesystem
validate(::typeof(download), args...) = Ask

# ── Verdict helpers ──────────────────────────────────────────────────

const DENIED_PATHS = Set(["/", "/usr", "/bin", "/etc", "/var", "/System"])

function path_verdict(path::AbstractString)::SafetyVerdict
  abs_path = abspath(path)
  abs_path in DENIED_PATHS && return Deny
  abs_path == homedir() && return Deny
  for dir in get(CONFIG, "allowed_dirs", [])
    dir_str = rstrip(string(dir), '/')
    (startswith(abs_path, dir_str * "/") || abs_path == dir_str) && return Allow
  end
  Ask
end

function command_verdict(cmd::Cmd)::SafetyVerdict
  cmd_str = join(cmd.exec, " ")
  for pattern in get(CONFIG, "allowed_commands", [])
    _glob_match(cmd_str, string(pattern)) && return Allow
  end
  Ask
end
```

Note: `CONFIG` and `_glob_match` are defined in `main.jl` which loads before `safety.jl`. These are available in scope when `safety.jl` is `@use`d with `...` spread from a file that already has them.

- [ ] **Step 2: Verify it parses**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'include("safety.jl"); println(Allow, " ", Deny, " ", Ask)'`

Note: This will fail if `CONFIG` and `_glob_match` aren't in scope. That's expected — they'll be available when loaded from `main.jl`. For now, just verify no syntax errors. You can stub them:
```
cd /Users/jake/Prosca && julia --project=. -e '
CONFIG = Dict("allowed_dirs" => ["/tmp"], "allowed_commands" => ["ls *"])
_glob_match(s, p) = occursin("*", p) ? startswith(s, replace(p, "*" => "")) : s == p
include("safety.jl")
println(path_verdict("/tmp/foo"))
println(path_verdict("/etc/passwd"))
println(command_verdict(`ls -la`))
'
```
Expected: `Allow`, `Deny`, `Allow`

- [ ] **Step 3: Commit**

```bash
git add safety.jl
git commit -m "feat: add safety module with validate dispatch and verdict functions"
```

### Task 2: REPL interpreter

**Files:**
- Create: `repl.jl`

- [ ] **Step 1: Add JuliaInterpreter to project dependencies**

Run: `cd /Users/jake/Prosca && julia --project=. -e 'using Pkg; Pkg.add("JuliaInterpreter")'`

- [ ] **Step 2: Create `repl.jl`**

```julia
# repl.jl — JuliaInterpreter-based REPL with runtime safety

@use JuliaInterpreter

"""
    interpret(mod::Module, code::String; outbox=nothing, inbox=nothing) -> String

Evaluate `code` in the given module using JuliaInterpreter with manual stepping.
Before each function call, checks `validate(f, args...)` for safety.
Returns a string representation of the result.
"""
function interpret(mod::Module, code::String; outbox=nothing, inbox=nothing)::String
  expr = Meta.parseall(code)
  # Wrap in a block if parseall returns :toplevel
  if expr.head == :toplevel
    expr = Expr(:block, expr.args...)
  end

  result = nothing
  try
    frame = JuliaInterpreter.Frame(mod, expr)
    result = _step_through!(frame; outbox, inbox)
  catch e
    e isa SafetyDeniedError && rethrow()
    return "Error: $(sprint(showerror, e))"
  end
  result === nothing ? "nothing" : sprint(show, result)
end

"""
Step through a frame expression by expression, validating function calls.
"""
function _step_through!(frame::JuliaInterpreter.Frame; outbox=nothing, inbox=nothing)
  while true
    stmt = JuliaInterpreter.pc_expr(frame)
    # Check if this statement is a call we should validate
    if _is_call_expr(stmt)
      _validate_call!(frame, stmt; outbox, inbox)
    end
    # Step one expression
    ret = JuliaInterpreter.step_expr!(frame)
    # If step_expr! returns a value and there's nothing left, we're done
    if ret !== nothing && !isa(ret, JuliaInterpreter.BreakpointRef)
      return ret
    end
    # Check if frame is finished
    JuliaInterpreter.is_leaf(frame) && JuliaInterpreter.pc_expr(frame) === nothing && return ret
  end
end

"""Check if an expression is a function call."""
function _is_call_expr(stmt)
  stmt isa Expr && (stmt.head == :call || stmt.head == :invoke)
end

"""
Validate a function call before it executes.
Extract the function and resolved arguments from the frame, then dispatch to validate().
"""
function _validate_call!(frame::JuliaInterpreter.Frame, stmt::Expr; outbox=nothing, inbox=nothing)
  try
    # Resolve the function being called
    args_start = stmt.head == :invoke ? 2 : 1
    f = try
      JuliaInterpreter.@lookup(frame, stmt.args[args_start])
    catch
      return  # can't resolve — skip validation
    end

    # Resolve arguments
    resolved_args = []
    for i in (args_start+1):length(stmt.args)
      arg = try
        JuliaInterpreter.@lookup(frame, stmt.args[i])
      catch
        nothing  # can't resolve — leave as-is
      end
      push!(resolved_args, arg)
    end

    verdict = validate(f, resolved_args...)

    if verdict == Deny
      throw(SafetyDeniedError(string(f), string(resolved_args), "blocked by safety rules"))
    elseif verdict == Ask
      if outbox !== nothing && inbox !== nothing
        req_id = rand(UInt64)
        put!(outbox, ToolCallRequest(string(f), JSON3.write(resolved_args), req_id))
        approval = take!(inbox)
        if approval isa ToolApproval && approval.id == req_id
          if approval.decision == :deny
            throw(SafetyDeniedError(string(f), string(resolved_args), "denied by user"))
          end
          # :allow or :always → proceed
        end
      else
        # No approval channel — deny by default
        throw(SafetyDeniedError(string(f), string(resolved_args), "requires approval but no approval channel"))
      end
    end
    # Allow → proceed
  catch e
    e isa SafetyDeniedError && rethrow()
    # If we can't inspect the call, let it proceed
    @debug "Could not validate call" exception=e
  end
end
```

- [ ] **Step 3: Verify basic interpretation works**

```
cd /Users/jake/Prosca && julia --project=. -e '
CONFIG = Dict("allowed_dirs" => ["/tmp"], "allowed_commands" => ["ls *"])
_glob_match(s, p) = occursin("*", p) ? startswith(s, replace(p, "*" => "")) : s == p
include("safety.jl")
include("repl.jl")
mod = Module(:test)
println(interpret(mod, "1 + 2"))
println(interpret(mod, "x = 42; x * 2"))
'
```
Expected: `3` and `84`

- [ ] **Step 4: Commit**

```bash
git add repl.jl Project.toml Manifest.toml
git commit -m "feat: add JuliaInterpreter-based REPL with safety validation"
```

### Task 3: Add repl_module to Agent struct

**Files:**
- Modify: `agents.jl`

- [ ] **Step 1: Update Agent struct to include `repl_module`**

In `agents.jl`, add `repl_module::Module` as the last field of the `Agent` struct:
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

- [ ] **Step 2: Update `load_agent` to create the module**

Change the `Agent(...)` constructor call in `load_agent` to include a new module:
```julia
function load_agent(agent_dir::FSPath)::Union{Agent, Nothing}
  id = agent_dir.name
  soul_path = agent_dir*"soul.md"
  instr_path = agent_dir*"instructions.md"
  isfile(soul_path) && isfile(instr_path) || return nothing
  Agent(
    id,
    read(soul_path, String),
    read(instr_path, String),
    load_agent_skills(agent_dir),
    agent_dir,
    Module(Symbol("agent_$id"))
  )
end
```

- [ ] **Step 3: Update `create_agent!`**

`create_agent!` calls `load_agent` internally, which now creates the module. No additional changes needed — verify the call chain is correct.

- [ ] **Step 4: Verify agents load with module**

```
cd /Users/jake/Prosca && julia --project=. -e '
include("main.jl")
a = default_agent()
println("Agent: $(a.id), Module: $(a.repl_module)")
'
```
Expected: `Agent: prosca, Module: agent_prosca`

- [ ] **Step 5: Commit**

```bash
git add agents.jl
git commit -m "feat: add repl_module to Agent struct for per-agent REPL isolation"
```

---

## Chunk 2: Remove MCP + Integrate REPL into ReAct Loop

### Task 4: Remove all MCP code from main.jl

**Files:**
- Modify: `main.jl`
- Delete: `mcp_client.jl`, `validate_ex.jl`

- [ ] **Step 1: Remove MCP and validate_ex imports from top of main.jl**

Remove these lines:
```julia
@use "./validate_ex" validate_ex
@use "./mcp_client" MCPTool MCPServer MCP_SERVERS send_jsonrpc mcp_connect! mcp_call_tool mcp_disconnect! load_mcp_servers! runtime_server
```

Add the new imports instead:
```julia
@use "./safety"...
@use "./repl" interpret
```

- [ ] **Step 2: Remove MCP config creation section**

Remove the entire `# ============= MCP SERVERS =============` section (around lines 546-553) which creates `MCP_CONFIG_PATH` and writes the default `mcp_servers.json`, and the `load_mcp_servers!(HOME)` call.

- [ ] **Step 3: Remove `is_allowed_path` function**

Remove the `is_allowed_path` function (around line 315). It's replaced by `path_verdict` in `safety.jl`.

- [ ] **Step 4: Simplify `build_system_prompt` — remove MCP sections**

In `build_system_prompt`, remove:
- The `runtime = runtime_server()` block and all the runtime tool descriptions
- The `other_mcp_tools` loop that lists non-runtime MCP tools
- The `other_mcp_section` variable

Replace with a simple REPL section:
```julia
  repl_section = """
  ## Julia REPL
  You have a persistent Julia REPL. Use {"eval": "code"} to evaluate Julia expressions.
  Variables and functions persist across evaluations.
  Use standard Julia for introspection: names(@__MODULE__), methods(f), typeof(x), etc.
  """
```

Include `$repl_section` in the final string template where the MCP sections used to be.

- [ ] **Step 5: Remove MCP tool dispatch from the ReAct loop**

In `_run_agent`, remove:
- The periodic runtime scope refresh block (around line 759-763): `if runtime_server() !== nothing ...`
- The `mcp_server`/`mcp_tool_name` resolution block (around lines 878-884)
- The `if !is_builtin && mcp_server === nothing` error (around line 888)
- The MCP confirmation logic in `needs_confirm` (around lines 898-910)
- The MCP tool execution branch (around lines 936-939)
- The `validate_ex` reference in confirmation logic (line 903)
- Update the malformed JSON error message to remove the `kaimon.ex` example

Simplify tool resolution to only handle built-in tools:
```julia
    if !haskey(TOOLS, tn)
      push!(messages, PromptingTools.AIMessage(response_text))
      push!(messages, PromptingTools.UserMessage("Error: Unknown tool '$tn'. Use {\"eval\": \"...\"} for Julia code, or use a valid tool name, or return {\"final_answer\": \"...\"}"))
      continue
    end
```

- [ ] **Step 6: Add `eval` handling to the ReAct loop**

After the `handoff` block and before the `tool` block, add:
```julia
    if haskey(parsed, :eval)
      code = string(parsed.eval)
      result = try
        interpret(agent.repl_module, code; outbox, inbox)
      catch e
        e isa SafetyDeniedError ? "Safety error: $(sprint(showerror, e))" : "Error: $(sprint(showerror, e))"
      end
      put!(outbox, ToolResult("eval", result))
      log_memory("Eval: $code → $(result[1:min(500,end)])"; agent_id=agent.id, conversation_id)
      push!(messages, PromptingTools.AIMessage(response_text))
      push!(messages, PromptingTools.UserMessage("Result: $result"))
      continue
    end
```

- [ ] **Step 7: Replace periodic MCP scope reminder with REPL scope**

Replace the `runtime_server()` scope refresh block with:
```julia
    if step > 1 && step % 5 == 0
      user_names = filter(n -> n != Symbol(agent.repl_module), names(agent.repl_module; all=false))
      if !isempty(user_names)
        scope = join(user_names, ", ")
        push!(messages, PromptingTools.UserMessage("[REPL scope] Variables: $scope"))
      end
    end
```

- [ ] **Step 8: Delete removed files**

```bash
rm mcp_client.jl validate_ex.jl
```

- [ ] **Step 9: Verify main.jl loads**

```
cd /Users/jake/Prosca && julia --project=. -e '
include("main.jl")
a = default_agent()
println("Agent: $(a.id)")
println("Prompt length: $(length(build_system_prompt(a)))")
println("Eval: $(interpret(a.repl_module, "1+1"))")
'
```
Expected: Agent loaded, prompt built, eval returns "2"

- [ ] **Step 10: Commit**

```bash
git add main.jl
git rm mcp_client.jl validate_ex.jl
git commit -m "feat: replace MCP with interpreted REPL, remove all MCP code"
```

### Task 5: Remove MCP from json_io.jl

**Files:**
- Modify: `json_io.jl`

- [ ] **Step 1: Remove `handle_mcp_list` function**

Delete the `handle_mcp_list` function (around line 94).

- [ ] **Step 2: Remove `mcp_list` message handler from main loop**

Remove the `elseif msg_type == "mcp_list"` branch.

- [ ] **Step 3: Remove `handle_skills_list` MCP reference if present**

Check if `handle_skills_list` references MCP and remove if so.

- [ ] **Step 4: Verify json_io.jl loads**

```
cd /Users/jake/Prosca && julia --project=. -e 'try; include("json_io.jl"); catch e; println(sprint(showerror, e)); end' 2>&1 | head -5
```
Expected: `PROSCA:{"type":"ready"}` — no MCP errors

- [ ] **Step 5: Commit**

```bash
git add json_io.jl
git commit -m "feat: remove MCP handlers from json_io.jl"
```

### Task 6: Remove MCP from GUI

**Files:**
- Delete: `gui/src/pages/McpToolsPage.tsx`
- Modify: `gui/src/App.tsx`
- Modify: `gui/src/components/layout/Sidebar.tsx`

- [ ] **Step 1: Remove McpToolsPage import and routing from App.tsx**

Remove the import line: `import McpToolsPage from "@/pages/McpToolsPage";`
Remove `"mcp-tools"` from the `Page` type union.
Remove `"mcp-tools": "MCP Tools"` from the page titles object.
Remove `{page === "mcp-tools" && <McpToolsPage />}` from the render.

- [ ] **Step 2: Remove MCP Tools nav item from Sidebar.tsx**

Remove `"mcp-tools"` from the `Page` type union.
Remove `{ page: "mcp-tools", icon: Hammer, label: "MCP Tools" }` from `NAV_ITEMS`.
Remove the `Hammer` import from lucide-react if it's no longer used.

- [ ] **Step 3: Delete McpToolsPage and related components**

```bash
rm gui/src/pages/McpToolsPage.tsx
# Also check for McpServerCard component
ls gui/src/components/mcp-tools/ && rm -r gui/src/components/mcp-tools/
```

- [ ] **Step 4: Type check**

Run: `cd /Users/jake/Prosca/gui && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
cd /Users/jake/Prosca/gui
git rm src/pages/McpToolsPage.tsx
git rm -r src/components/mcp-tools/ 2>/dev/null
git add src/App.tsx src/components/layout/Sidebar.tsx
git commit -m "feat(gui): remove MCP Tools page and nav item"
```
