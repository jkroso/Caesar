# calcs.jl — Calcs feature: per-document module state, snapshots, cascade replay
@use "github.com/jkroso/URI.jl/FSPath" home FSPath
@use "github.com/jkroso/JSON.jl" parse_json write_json
@use "./repl" interpret interpret_value
@use "./calc_summary"...
@use Dates
@use UUIDs

# ── Module snapshot (cheap binding map; values shared by reference) ──

"""Capture every user-visible binding in `mod` as a Dict{Symbol, Any}."""
function snapshot(mod::Module)::Dict{Symbol,Any}
  d = Dict{Symbol,Any}()
  for n in names(mod; all=true)
    n === nameof(mod) && continue
    isdefined(mod, n) || continue
    s = string(n)
    startswith(s, "#") && continue        # generated names
    startswith(s, "include") && continue  # module's own include
    n === :eval && continue               # module's own eval
    d[n] = getfield(mod, n)
  end
  d
end

"""Copy every (name, value) in `snap` into the (assumed-fresh) `mod`."""
function apply!(mod::Module, snap::Dict{Symbol,Any})
  for (n, v) in snap
    Core.eval(mod, :($n = $v))
  end
  mod
end
