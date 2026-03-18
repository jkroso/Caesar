# repl.jl — JuliaInterpreter-based REPL with safety validation
#
# Executes code expression-by-expression, intercepting function calls
# and validating them via the safety dispatch system before allowing execution.

@use JuliaInterpreter
@use JuliaInterpreter: step_expr!, pc_expr, Frame, SSAValue, lookup
@use "./safety"...
@use JSON3

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

"""Collect all variable names assigned at the top level of a list of statements."""
function _collect_assigned_vars(stmts)::Set{Symbol}
  vars = Set{Symbol}()
  for stmt in stmts
    _collect_assignments!(vars, stmt)
  end
  vars
end

const _ASSIGN_HEADS = Set([:(=), :(+=), :(-=), :(*=), :(/=), :(÷=), :(%=), :(^=),
                           :(&=), :(|=), :(⊻=), :(>>>=), :(>>=), :(<<=)])

function _collect_assignments!(vars::Set{Symbol}, ex)
  ex isa Expr || return
  if ex.head in _ASSIGN_HEADS && ex.args[1] isa Symbol
    push!(vars, ex.args[1])
  elseif ex.head in (:block, :toplevel)
    for arg in ex.args
      _collect_assignments!(vars, arg)
    end
  end
end

"""Inject `global var1, var2, ...` into for/while loop bodies so that
outer variables are accessible (REPL-style soft scope)."""
function _inject_globals(ex, vars::Set{Symbol})
  ex isa Expr || return ex
  if ex.head in (:for, :while)
    body = ex.args[end]
    if body isa Expr && body.head == :block
      # Find which vars are assigned in this loop body
      loop_vars = Set{Symbol}()
      _collect_assignments!(loop_vars, body)
      needed = intersect(loop_vars, vars)
      if !isempty(needed)
        global_decl = Expr(:global, needed...)
        new_body = Expr(:block, global_decl, body.args...)
        new_args = copy(ex.args)
        new_args[end] = new_body
        return Expr(ex.head, [_inject_globals(a, vars) for a in new_args]...)
      end
    end
    return Expr(ex.head, [_inject_globals(a, vars) for a in ex.args]...)
  end
  Expr(ex.head, [_inject_globals(a, vars) for a in ex.args]...)
end

# ── Trusted modules ──────────────────────────────────────────────────

"""Modules whose functions skip safety validation entirely.
Functions from these modules execute natively without interception."""
const TRUSTED_MODULES = Set{Module}()

"""No functions are unconditionally blocked by name anymore.
eval is controlled via validate() dispatches in safety.jl."""
_name_blocked(f) = false

"""Check whether a call should be validated (skip Core and trusted modules)."""
function _should_validate(f)::Bool
  f isa Function || return false
  # Always validate eval regardless of module
  fname = try nameof(f) catch; nothing end
  fname === :eval && return true
  mod = try parentmodule(f) catch; return false end
  mod === Core && return false
  mod in TRUSTED_MODULES && return false
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
    interpret(mod::Module, code::String; outbox=nothing, inbox=nothing, log=nothing) -> String

Execute `code` in `mod` expression-by-expression via JuliaInterpreter,
validating every function call through the safety system.

If `log` is provided, writes each input/output pair in REPL-style format.

Returns the string representation of the last expression's value.
"""
function interpret(mod::Module, code::String;
                   outbox::Union{Channel,Nothing}=nothing,
                   inbox::Union{Channel,Nothing}=nothing,
                   log::Union{IO,Nothing}=nothing)
  parsed = Meta.parseall(code)
  stmts = _flatten_toplevel(parsed)
  # Inject global declarations into loops for REPL-style soft scope
  # Include both variables assigned in this code AND existing module bindings
  assigned = _collect_assigned_vars(stmts)
  for n in names(mod; all=true)
    n == nameof(mod) && continue
    push!(assigned, n)
  end
  if !isempty(assigned)
    stmts = [_inject_globals(s, assigned) for s in stmts]
  end
  isempty(stmts) && return "nothing"

  # Log the input
  if log !== nothing
    for (i, line) in enumerate(split(code, '\n'))
      println(log, i == 1 ? "julia> $line" : "       $line")
    end
  end

  last_result = nothing
  error_thrown = nothing

  try
    for stmt in stmts
      # Wrap non-Expr atoms (e.g. bare symbols, literals) so Frame can handle them
      expr = stmt isa Expr ? stmt : Expr(:block, stmt)

      frame = try
        Frame(mod, expr)
      catch e
        error_thrown = e
        err_msg = "Failed to lower expression: $(sprint(showerror, e))"
        if log !== nothing
          println(log, "ERROR: $err_msg")
          println(log)
          flush(log)
        end
        throw(ErrorException(err_msg))
      end

      last_result = _step_frame!(frame; outbox, inbox)
    end
  catch e
    if log !== nothing && error_thrown !== e
      println(log, "ERROR: $(sprint(showerror, e))")
      println(log)
      flush(log)
    end
    rethrow()
  end

  result_str = string(last_result)

  # Log the output
  if log !== nothing
    println(log, result_str)
    println(log)
    flush(log)
  end

  return result_str
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

export interpret, TRUSTED_MODULES
