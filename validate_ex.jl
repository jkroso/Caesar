# validate_ex.jl — AST-based validation for Julia expressions before REPL execution

"""
    validate_ex(code::String)::Bool

Parse `code` as Julia AST and check for disallowed patterns.
Returns `false` (triggering user confirmation) for:
- ENV mutations (ENV[...] = ..., delete!(ENV, ...))
- eval / Meta.parse calls (dynamic code generation)
- File write operations (write, open(...,"w"), rm, mv, cp) to paths outside allowed_dirs

Returns `true` for everything else.
"""
function validate_ex(code::String)::Bool
  expr = try
    Meta.parseall(code)  # parseall wraps all statements in :toplevel — catches multi-expression bypasses
  catch
    return false  # unparseable code requires confirmation
  end
  _walk_expr(expr)
end

function _walk_expr(expr)::Bool
  expr isa Expr || return true
  # Check this node
  _check_node(expr) || return false
  # Recurse into children
  all(_walk_expr, expr.args)
end

function _check_node(expr::Expr)::Bool
  # ENV mutation: ENV[k] = v or ENV["X"] = "Y"
  if expr.head == :(=) && length(expr.args) >= 2
    lhs = expr.args[1]
    if lhs isa Expr && lhs.head == :ref && length(lhs.args) >= 1 && lhs.args[1] == :ENV
      return false
    end
  end

  # delete!(ENV, ...) or push!(ENV, ...)
  if expr.head == :call && length(expr.args) >= 2
    fn = expr.args[1]
    if fn in (:delete!, :push!, :pop!) && length(expr.args) >= 2 && expr.args[2] == :ENV
      return false
    end
  end

  # eval(...) or Base.eval(...) or Meta.parse(...)
  if expr.head == :call
    fn = expr.args[1]
    if fn == :eval
      return false
    end
    if fn isa Expr && fn.head == :.
      dname = _dotted_name(fn)
      if dname in ("Base.eval", "Core.eval", "Meta.parse")
        return false
      end
    end
  end

  # File write operations with path validation: write, open, rm, mv, cp
  if expr.head == :call && length(expr.args) >= 2
    fn = expr.args[1]
    if fn in (:write, :rm, :mv, :cp)
      path_arg = expr.args[2]
      if path_arg isa String
        !is_allowed_path(path_arg) && return false
      elseif !(path_arg isa Symbol && path_arg in (:stdout, :stderr, :devnull))
        # Non-literal path can't be validated — require confirmation
        return false
      end
    end
    # open("path", "w") — check for write mode
    if fn == :open && length(expr.args) >= 3
      path_arg = expr.args[2]
      mode_arg = expr.args[3]
      if mode_arg isa String && occursin("w", mode_arg)
        if path_arg isa String
          !is_allowed_path(path_arg) && return false
        else
          return false  # Non-literal path with write mode — require confirmation
        end
      end
    end
  end

  true
end

"Convert a dotted expression like :(Base.eval) to \"Base.eval\""
function _dotted_name(expr::Expr)::String
  expr.head != :. && return ""
  parts = String[]
  for a in expr.args
    if a isa Symbol
      push!(parts, string(a))
    elseif a isa QuoteNode
      push!(parts, string(a.value))
    elseif a isa Expr
      s = _dotted_name(a)
      !isempty(s) && push!(parts, s)
    end
  end
  join(parts, ".")
end
