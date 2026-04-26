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

# ── Constants ────────────────────────────────────────────────────────

const CALCS_DIR_NAME = "calcs"

calcs_dir()::FSPath = home() * "Caesar" * CALCS_DIR_NAME

# ── Data types ───────────────────────────────────────────────────────

mutable struct Parameter
  id::String
  text_span::Tuple{Int,Int}      # half-open [start, end) over UTF-8 byte offsets
  current_value::String          # textual literal as it appears in the source
end

mutable struct Paragraph
  id::String
  text::String
  code_template::String          # may contain {{p0}}, {{p1}}, ...
  parameters::Vector{Parameter}
  last_value_short::Union{String,Nothing}
  last_value_long::Union{String,Nothing}
  last_error::Union{String,Nothing}
end

mutable struct Calc
  id::String
  name::String
  created_at::DateTime
  updated_at::DateTime
  paragraphs::Vector{Paragraph}
  # In-memory only:
  mod::Union{Module,Nothing}                 # current live module, or nothing if not yet built
  snapshots::Vector{Dict{Symbol,Any}}        # one per paragraph; populated lazily
  mod_seq::Int                               # bumps each cascade so module names don't collide
end

Calc(id::String, name::String) = Calc(
  id, name, now(UTC), now(UTC), Paragraph[], nothing, Dict{Symbol,Any}[], 0)

Paragraph(text::String="") = Paragraph(
  "para_" * string(uuid4())[1:8], text, "", Parameter[], nothing, nothing, nothing)

# ── JSON conversion ──────────────────────────────────────────────────

param_to_dict(p::Parameter) = Dict{String,Any}(
  "id" => p.id,
  "text_span" => [p.text_span[1], p.text_span[2]],
  "current_value" => p.current_value)

param_from_dict(d) = Parameter(
  string(d["id"]),
  (Int(d["text_span"][1]), Int(d["text_span"][2])),
  string(d["current_value"]))

para_to_dict(p::Paragraph) = Dict{String,Any}(
  "id" => p.id,
  "text" => p.text,
  "code_template" => p.code_template,
  "parameters" => [param_to_dict(x) for x in p.parameters],
  "last_value_short" => p.last_value_short,
  "last_value_long" => p.last_value_long,
  "last_error" => p.last_error)

para_from_dict(d) = Paragraph(
  string(d["id"]),
  string(d["text"]),
  string(get(d, "code_template", "")),
  [param_from_dict(x) for x in get(d, "parameters", [])],
  d["last_value_short"] === nothing ? nothing : string(d["last_value_short"]),
  d["last_value_long"] === nothing ? nothing : string(d["last_value_long"]),
  d["last_error"] === nothing ? nothing : string(d["last_error"]))

calc_to_dict(c::Calc) = Dict{String,Any}(
  "id" => c.id,
  "name" => c.name,
  "created_at" => string(c.created_at) * "Z",
  "updated_at" => string(c.updated_at) * "Z",
  "paragraphs" => [para_to_dict(p) for p in c.paragraphs])

function calc_from_dict(d)::Calc
  Calc(
    string(d["id"]),
    string(d["name"]),
    DateTime(replace(string(d["created_at"]), "Z" => "")),
    DateTime(replace(string(d["updated_at"]), "Z" => "")),
    [para_from_dict(p) for p in get(d, "paragraphs", [])],
    nothing,
    Dict{Symbol,Any}[],
    0)
end

# ── CRUD ─────────────────────────────────────────────────────────────

const CALCS = Dict{String,Calc}()

function calc_path(id::String)::String
  string(calcs_dir() * (id * ".json"))
end

function list_calcs()::Vector{Dict{String,Any}}
  d = string(calcs_dir())
  isdir(d) || mkpath(d)
  out = Dict{String,Any}[]
  for entry in readdir(d)
    endswith(entry, ".json") || continue
    full = joinpath(d, entry)
    try
      c = calc_from_dict(parse_json(read(full, String)))
      push!(out, Dict("id" => c.id, "name" => c.name, "updated_at" => string(c.updated_at) * "Z"))
    catch e
      @warn "Failed to load calc index entry" file=full exception=e
    end
  end
  sort!(out; by = e -> e["updated_at"], rev = true)
  out
end

function load_calc(id::String)::Calc
  haskey(CALCS, id) && return CALCS[id]
  path = calc_path(id)
  isfile(path) || throw(ArgumentError("calc not found: $id"))
  c = calc_from_dict(parse_json(read(path, String)))
  CALCS[id] = c
end

function save_calc(c::Calc)
  c.updated_at = now(UTC)
  d = string(calcs_dir())
  isdir(d) || mkpath(d)
  write(calc_path(c.id), write_json(calc_to_dict(c)))
  c
end

function create_calc(name::String)::Calc
  id = "c_" * string(uuid4())[1:12]
  c = Calc(id, name)
  CALCS[id] = c
  save_calc(c)
end

function delete_calc(id::String)
  delete!(CALCS, id)
  path = calc_path(id)
  isfile(path) && rm(path)
  nothing
end

function rename_calc(id::String, name::String)
  c = load_calc(id)
  c.name = name
  save_calc(c)
end

# ── Paragraph splitting ──────────────────────────────────────────────

"""
    split_paragraphs(text::AbstractString) -> Vector{Tuple{String,UnitRange{Int}}}

Split `text` into paragraphs by runs of 2+ newlines. Returns a vector of
(paragraph_text, char_range) tuples. Char ranges are 1-indexed Char offsets
into `text`. Empty leading/trailing whitespace is excluded from the ranges.
"""
function split_paragraphs(text::AbstractString)
  out = Tuple{String, UnitRange{Int}}[]
  isempty(text) && return out
  i = 1
  n = lastindex(text)
  while i <= n
    while i <= n && text[i] == '\n'
      i = nextind(text, i)
    end
    i > n && break
    start = i
    while i <= n
      if text[i] == '\n' && i < n && text[nextind(text, i)] == '\n'
        break
      end
      i = nextind(text, i)
    end
    stop = i > n ? n : prevind(text, i)
    while stop >= start && text[stop] in (' ', '\t', '\n')
      stop = prevind(text, stop)
    end
    if stop >= start
      push!(out, (text[start:stop], start:stop))
    end
    while i <= n && text[i] == '\n'
      i = nextind(text, i)
    end
  end
  out
end

# ── Edit classification ──────────────────────────────────────────────

"""
    diff_range(old, new) -> Union{Nothing, Tuple{UnitRange{Int}, String}}

Returns nothing if equal. Otherwise (old_range, replacement_text).
"""
function diff_range(old::AbstractString, new::AbstractString)
  old == new && return nothing
  oi, ni = firstindex(old), firstindex(new)
  oend, nend = lastindex(old), lastindex(new)
  while oi <= oend && ni <= nend && old[oi] == new[ni]
    oi = nextind(old, oi); ni = nextind(new, ni)
  end
  oj, nj = oend, nend
  while oj >= oi && nj >= ni && old[oj] == new[nj]
    oj = prevind(old, oj); nj = prevind(new, nj)
  end
  old_range = oi:oj
  replacement = nj >= ni ? new[ni:nj] : ""
  (old_range, replacement)
end

@enum EditClass UNCHANGED PARAMETER STRUCTURAL

"""
    classify_edit(old_text, new_text, parameters) -> (EditClass, Union{Nothing, Tuple{Int, String}})

PARAMETER if and only if the diff is a single contiguous edit lying entirely
within ONE existing parameter span. Returns the parameter index (1-based)
and the new substring of the entire span.
"""
function classify_edit(old_text::AbstractString, new_text::AbstractString,
                       parameters::Vector{Parameter})
  d = diff_range(old_text, new_text)
  d === nothing && return (UNCHANGED, nothing)
  old_range, replacement = d

  for (i, p) in enumerate(parameters)
    char_lo = _byte_to_char(old_text, p.text_span[1] + 1)
    char_hi = _byte_to_char(old_text, p.text_span[2])
    char_hi < char_lo && continue
    if first(old_range) >= char_lo && last(old_range) <= char_hi
      prefix = old_text[char_lo:prevind(old_text, first(old_range))]
      suffix = old_text[nextind(old_text, last(old_range)):char_hi]
      new_value = string(prefix, replacement, suffix)
      return (PARAMETER, (i, new_value))
    end
  end
  (STRUCTURAL, nothing)
end

"Convert a 1-indexed byte offset into a 1-indexed Char index."
function _byte_to_char(s::AbstractString, byte_idx::Int)
  byte_idx <= 0 && return firstindex(s)
  cur = 1
  for (ci, _) in enumerate(eachindex(s))
    cur > byte_idx && return ci - 1
    cur += ncodeunits(s[ci])
  end
  lastindex(s)
end

# ── Template rendering ───────────────────────────────────────────────

"""
    render_code(template::AbstractString, parameters::Vector{Parameter}) -> String

Substitute every `{{pN}}` placeholder in `template` with the corresponding
parameter's `current_value`. Unknown placeholders raise.
"""
function render_code(template::AbstractString, parameters::Vector{Parameter})::String
  by_id = Dict(p.id => p.current_value for p in parameters)
  replace(template, r"\{\{([a-zA-Z0-9_]+)\}\}" => s -> begin
    id = match(r"\{\{([a-zA-Z0-9_]+)\}\}", s).captures[1]
    haskey(by_id, id) || error("Unknown parameter $id in template")
    by_id[id]
  end)
end
