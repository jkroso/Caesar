# calcs.jl — Calcs feature: per-document module state, snapshots, cascade replay
@use "github.com/jkroso/URI.jl/FSPath" home FSPath
@use "github.com/jkroso/JSON.jl" parse_json write_json
@use "./repl" interpret interpret_value
@use "./calc_summary" Summary summarize safe_summarize
@use Dates...
@use UUIDs...

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

# ── Module allocation ────────────────────────────────────────────────

function fresh_module(c::Calc)::Module
  c.mod_seq += 1
  Module(Symbol("Calc_$(c.id)_$(c.mod_seq)"))
end

# ── Snapshot bootstrap (lazy) ────────────────────────────────────────

"""Build snapshots[1..end] from scratch by replaying every paragraph's
cached code. Called on first cascade after a fresh load from disk."""
function build_snapshots!(c::Calc)
  c.mod = fresh_module(c)
  empty!(c.snapshots)
  for p in c.paragraphs
    code = isempty(p.code_template) ? "" : render_code(p.code_template, p.parameters)
    if !isempty(code)
      try
        interpret_value(c.mod, code)
      catch
        # Leave the paragraph result as-is; cascade callers handle errors.
      end
    end
    push!(c.snapshots, snapshot(c.mod))
  end
end

# ── Cascade replay ───────────────────────────────────────────────────

"""
    cascade!(c::Calc, from::Int; on_result, on_error, translator)

Rebuild `c.mod` from snapshot `from-1` (or empty if `from == 1`), then
re-execute paragraphs `from..end` in order. After each paragraph, call
`on_result(idx, paragraph, summary)` or `on_error(idx, paragraph, msg)`.
On a paragraph eval error, invoke `translator(c, idx)` (which should
update the paragraph's code_template/parameters in place) and retry once.
"""
function cascade!(c::Calc, from::Int;
                  on_result=(_,_,_)->nothing,
                  on_error=(_,_,_)->nothing,
                  translator=nothing)
  isempty(c.snapshots) && build_snapshots!(c)

  new_mod = fresh_module(c)
  if from > 1
    apply!(new_mod, c.snapshots[from-1])
  end

  for i in from:length(c.paragraphs)
    p = c.paragraphs[i]
    code = isempty(p.code_template) ? "" : render_code(p.code_template, p.parameters)
    succeeded = false
    if isempty(code)
      p.last_value_short = nothing
      p.last_value_long = nothing
      p.last_error = nothing
      succeeded = true
    else
      try
        v = interpret_value(new_mod, code)
        s = safe_summarize(v)
        p.last_value_short = s.short
        p.last_value_long = s.long
        p.last_error = nothing
        on_result(i, p, s)
        succeeded = true
      catch e
        msg = sprint(showerror, e)
        if translator !== nothing && i > from
          try
            translator(c, i)
            new_code = render_code(p.code_template, p.parameters)
            v = interpret_value(new_mod, new_code)
            s = safe_summarize(v)
            p.last_value_short = s.short
            p.last_value_long = s.long
            p.last_error = nothing
            on_result(i, p, s)
            succeeded = true
          catch e2
            p.last_error = sprint(showerror, e2)
            p.last_value_short = "error"
            p.last_value_long = nothing
            on_error(i, p, p.last_error)
          end
        else
          p.last_error = msg
          p.last_value_short = "error"
          p.last_value_long = nothing
          on_error(i, p, msg)
        end
      end
    end
    if length(c.snapshots) >= i
      c.snapshots[i] = snapshot(new_mod)
    else
      push!(c.snapshots, snapshot(new_mod))
    end
  end

  c.mod = new_mod
  save_calc(c)
end

# ── Translator (custom mini-agent loop) ──────────────────────────────

@use "github.com/jkroso/LLM.jl" LLM search
@use "github.com/jkroso/LLM.jl/providers/abstract_provider" Message SystemMessage UserMessage AIMessage ToolResultMessage Tool ToolCall
@use YAML

const _TRANSLATOR = Ref{Union{LLM,Nothing}}(nothing)
const _TRANSLATOR_PROMPT = Ref{String}("")
const _TRANSLATOR_CONFIG = Ref{Dict{String,Any}}(Dict{String,Any}())

function load_translator!()
  agent_dir = home() * "Caesar" * "agents" * "calc"
  soul_path = string(agent_dir * "soul.md")
  cfg_path = string(agent_dir * "config.yaml")

  # Read soul if present, else use minimal default
  _TRANSLATOR_PROMPT[] = isfile(soul_path) ? read(soul_path, String) :
    "You convert natural language paragraphs into Julia code. Use the eval tool to test, then call record_result."

  # Read config if present, else use defaults
  cfg = if isfile(cfg_path)
    raw = try YAML.load_file(cfg_path) catch; Dict() end
    raw isa Dict ? Dict{String,Any}(raw) : Dict{String,Any}()
  else
    Dict{String,Any}()
  end
  # Apply baked-in defaults for missing keys
  get!(cfg, "llm", "anthropic/claude-haiku-4-5-20251001")
  get!(cfg, "temperature", 0.0)
  get!(cfg, "max_steps", 5)

  _TRANSLATOR_CONFIG[] = cfg
  _TRANSLATOR[] = _build_llm(string(cfg["llm"]))
end

"""
Build an LLM instance. Always passes `allowed_providers` to avoid
LLM.jl's `all_models()` bug (it sorts a Vector-of-Vectors by `.release_date`).
A model string of "anthropic/claude-..." filters to that provider; an
unprefixed string falls back to a common-provider list.
"""
function _build_llm(model_str::AbstractString)::LLM
  results = if contains(model_str, '/')
    provider, model = split(model_str, '/'; limit=2)
    search(string(provider), string(model);
           max_results=1, allowed_providers=[string(provider)])
  else
    search("", string(model_str); max_results=1,
           allowed_providers=["anthropic", "openai", "google", "ollama"])
  end
  isempty(results) && error("No model found matching '$model_str'")
  LLM(results[1], Dict{String,Any}())
end

translator()::LLM = _TRANSLATOR[] === nothing ? (load_translator!(); _TRANSLATOR[]) : _TRANSLATOR[]

const _EVAL_TOOL = Tool(
  "eval",
  "Evaluate Julia code in the sandbox. Returns the value's string repr or an error message.",
  Dict("type"=>"object",
       "properties"=>Dict("code"=>Dict("type"=>"string", "description"=>"Julia code")),
       "required"=>["code"]))

const _RECORD_TOOL = Tool(
  "record_result",
  "Finalize the translation. Emit the code_template (with {{p0}} placeholders) and the list of parameters. Calling this ends your turn.",
  Dict("type"=>"object",
       "properties"=>Dict(
         "code_template"=>Dict("type"=>"string"),
         "parameters"=>Dict("type"=>"array", "items"=>Dict(
           "type"=>"object",
           "properties"=>Dict(
             "id"=>Dict("type"=>"string"),
             "text_span"=>Dict("type"=>"array", "items"=>Dict("type"=>"integer"), "minItems"=>2, "maxItems"=>2),
             "current_value"=>Dict("type"=>"string")),
           "required"=>["id","text_span","current_value"]))),
       "required"=>["code_template","parameters"]))

"""
    translate_paragraph(c::Calc, idx::Int) -> Bool

Run the translator agent for paragraph `idx`. On success, mutates the
paragraph's `code_template` and `parameters` and returns `true`. The
sandbox module is allocated and seeded from snapshot `idx-1`.
"""
function translate_paragraph(c::Calc, idx::Int)::Bool
  isempty(c.snapshots) && build_snapshots!(c)
  sandbox = Module(Symbol("CalcSandbox_$(c.id)_$(rand(UInt32))"))
  if idx > 1 && length(c.snapshots) >= idx-1
    apply!(sandbox, c.snapshots[idx-1])
  end

  para = c.paragraphs[idx]
  user_msg = _build_translator_input(c, idx)

  messages = Message[
    SystemMessage(_TRANSLATOR_PROMPT[]),
    UserMessage(user_msg)]

  cfg = _TRANSLATOR_CONFIG[]
  max_steps = Int(get(cfg, "max_steps", 5))
  temperature = Float64(get(cfg, "temperature", 0.0))
  tools = Tool[_EVAL_TOOL, _RECORD_TOOL]

  for step in 1:max_steps
    stream = try
      translator()(messages; temperature, tools)
    catch e
      @warn "Translator LLM call failed" calc_id=c.id paragraph_idx=idx step exception=(e, catch_backtrace())
      return false
    end
    buf = IOBuffer()
    while !eof(stream)
      chunk = readavailable(stream)
      isempty(chunk) || write(buf, chunk)
    end
    response_text = String(take!(buf))
    tool_calls = stream.tool_calls

    if isempty(tool_calls)
      @warn "Translator returned text without tool calls" calc_id=c.id paragraph_idx=idx step text=first(response_text, 500)
      return false
    end

    push!(messages, AIMessage(response_text, tool_calls))

    for tc in tool_calls
      @warn "Translator tool call" calc_id=c.id paragraph_idx=idx step tool=tc.name args=tc.arguments
      if tc.name == "record_result"
        ok = _apply_record_result!(para, tc.arguments)
        ok || @warn "record_result args failed validation" calc_id=c.id paragraph_idx=idx args=tc.arguments
        return ok
      elseif tc.name == "eval"
        code = string(get(tc.arguments, "code", ""))
        result = try
          v = interpret_value(sandbox, code)
          first(string(v), 4000)
        catch e
          "ERROR: " * sprint(showerror, e)
        end
        @warn "Translator eval result" result=first(result, 200)
        push!(messages, ToolResultMessage(tc.id, result))
      else
        @warn "Translator called unknown tool" calc_id=c.id paragraph_idx=idx tool=tc.name
        push!(messages, ToolResultMessage(tc.id, "Unknown tool $(tc.name)"))
      end
    end
  end
  @warn "Translator exhausted max_steps without record_result" calc_id=c.id paragraph_idx=idx max_steps
  false
end

function _build_translator_input(c::Calc, idx::Int)::String
  io = IOBuffer()
  println(io, "Document context:")
  for (j, p) in enumerate(c.paragraphs)
    j == idx && continue
    code = isempty(p.code_template) ? "" : render_code(p.code_template, p.parameters)
    result = something(p.last_value_short, "(no result)")
    println(io, "¶$j  ", repr(p.text))
    println(io, "      code: ", code)
    println(io, "      result: ", result)
  end
  println(io)
  println(io, "Translate paragraph $idx:")
  print(io, repr(c.paragraphs[idx].text))
  String(take!(io))
end

function _apply_record_result!(para::Paragraph, args::Dict)::Bool
  code_template = string(get(args, "code_template", ""))
  raw_params = get(args, "parameters", [])
  raw_params isa Vector || return false
  params = Parameter[]
  for rp in raw_params
    rp isa Dict || return false
    span = get(rp, "text_span", nothing)
    span isa Vector && length(span) == 2 || return false
    push!(params, Parameter(
      string(get(rp, "id", "")),
      (Int(span[1]), Int(span[2])),
      string(get(rp, "current_value", ""))))
  end
  para.code_template = code_template
  para.parameters = params
  true
end
