# repl.jl — JuliaInterpreter-based REPL with safety validation
#
# Executes code expression-by-expression, intercepting function calls
# and validating them via the safety dispatch system before allowing execution.

using JuliaInterpreter
using JSON3
import JuliaInterpreter: step_expr!, pc_expr, Frame, SSAValue, lookup

const _INTERP = JuliaInterpreter.RecursiveInterpreter()

# ── Helpers ──────────────────────────────────────────────────────────

"""Extract individual expressions from `Meta.parseall` output, stripping LineNumberNodes."""
function _flatten_toplevel(ex)
  stmts = Any[]
  if ex isa Expr && ex.head == :toplevel
    for arg in ex.args
      append!(stmts, _flatten_toplevel(arg))
    end
  elseif !(ex isa LineNumberNode)
    push!(stmts, ex)
  end
  stmts
end

# Functions blocked by name — catches per-module definitions (e.g. Module.eval)
const _BLOCKED_NAMES = Set([:eval, :include])

"""Check if a function is blocked by name regardless of which module defines it."""
function _name_blocked(f)::Bool
  fname = try nameof(f) catch; return false end
  fname in _BLOCKED_NAMES
end

"""Check whether a call should be validated (skip Core internals like tuple construction)."""
function _should_validate(f)::Bool
  f isa Function || return false
  # Always validate name-blocked functions regardless of module
  _name_blocked(f) && return true
  mod = try parentmodule(f) catch; return false end
  # Skip Core builtins that are just data construction (tuple, etc.)
  mod === Core && return false
  true
end

"""Resolve all args of a :call node from the frame's SSA/slot state."""
function _resolve_call_args(frame::Frame, node::Expr)
  resolved = Any[]
  for arg in node.args
    try
      push!(resolved, lookup(_INTERP, frame, arg))
    catch
      push!(resolved, arg)  # fallback to raw expression
    end
  end
  resolved
end

# ── Main interpret function ──────────────────────────────────────────

"""
    interpret(mod::Module, code::String; outbox=nothing, inbox=nothing) -> String

Execute `code` in `mod` expression-by-expression via JuliaInterpreter,
validating every function call through the safety system.

Returns the string representation of the last expression's value.
"""
function interpret(mod::Module, code::String;
                   outbox::Union{Channel,Nothing}=nothing,
                   inbox::Union{Channel,Nothing}=nothing)
  parsed = Meta.parseall(code)
  stmts = _flatten_toplevel(parsed)
  isempty(stmts) && return "nothing"

  last_result = nothing

  for stmt in stmts
    # Wrap non-Expr atoms (e.g. bare symbols, literals) so Frame can handle them
    expr = stmt isa Expr ? stmt : Expr(:block, stmt)

    frame = try
      Frame(mod, expr)
    catch e
      throw(ErrorException("Failed to lower expression: $(sprint(showerror, e))"))
    end

    last_result = _step_frame!(frame; outbox, inbox)
  end

  return string(last_result)
end

"""Step through a single frame, validating calls, and return the final value."""
function _step_frame!(frame::Frame;
                      outbox::Union{Channel,Nothing}=nothing,
                      inbox::Union{Channel,Nothing}=nothing)
  max_steps = 10_000  # safety limit

  for _ in 1:max_steps
    node = pc_expr(frame)

    # Check for ReturnNode — extract value and stop
    if node isa Core.ReturnNode
      return try lookup(_INTERP, frame, node.val) catch; nothing end
    end

    # Intercept function calls for safety validation
    if node isa Expr && node.head == :call
      resolved = _resolve_call_args(frame, node)
      if length(resolved) >= 1
        f = resolved[1]
        args = resolved[2:end]
        if _should_validate(f)
          _check_safety(f, args; outbox, inbox)
        end
      end
    end

    # Execute the step
    step_expr!(frame, true)
  end

  nothing
end

"""Validate a function call and handle the verdict."""
function _check_safety(f, args;
                       outbox::Union{Channel,Nothing}=nothing,
                       inbox::Union{Channel,Nothing}=nothing)
  # Name-based blocklist catches per-module variants (e.g. AgentModule.eval)
  if _name_blocked(f)
    throw(SafetyDeniedError(string(f), string(args), "blocked by safety policy"))
  end

  verdict = try
    validate(f, args...)
  catch
    Allow  # if validate itself errors, default to allow
  end

  if verdict == Deny
    throw(SafetyDeniedError(string(f), string(args), "blocked by safety policy"))
  elseif verdict == Ask
    if outbox !== nothing && inbox !== nothing
      req_id = rand(UInt64)
      put!(outbox, ToolCallRequest(string(f), JSON3.write(args), req_id))
      approval = take!(inbox)
      if approval isa ToolApproval && approval.id == req_id
        if approval.decision == :deny
          throw(SafetyDeniedError(string(f), string(args), "denied by user"))
        end
        # :allow or :always — proceed
      end
    else
      # No approval channel available — deny by default for Ask verdicts
      throw(SafetyDeniedError(string(f), string(args), "requires approval but no approval channel"))
    end
  end
  # Allow — proceed
  nothing
end
