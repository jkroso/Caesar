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
  for denied in DENIED_PATHS
    denied == "/" && continue  # handled by exact match above
    startswith(abs_path, denied * "/") && return Deny
  end
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

export SafetyDeniedError, validate, SafetyVerdict, Allow, Deny, Ask
