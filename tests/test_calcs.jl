# tests/test_calcs.jl — runs as a standalone script: `julia tests/test_calcs.jl`
using Test
using Dates

# Stub @use macro so we can include the production files directly without Kip
macro use(args...)
  return :(nothing)
end

const HOME = mktempdir() * "/"
const CALCS_DIR = HOME * "calcs/"
mkpath(CALCS_DIR)

include(joinpath(@__DIR__, "..", "calc_summary.jl"))

@testset "summarize" begin
  @test summarize(3).short == "3"
  @test summarize(3).long === nothing
  @test summarize("hi").short == "\"hi\""
  @test summarize("x"^100).long !== nothing
  @test occursin("100-char string", summarize("x"^100).short)
  @test summarize([1,2,3]).short == "Int64[3]"
  @test summarize(Dict("a"=>1)).short == "Dict (1 entries)"
  @test summarize(nothing).short == "nothing"
  @test summarize(true).short == "true"
  @test summarize(:foo).short == ":foo"
end

@testset "safe_summarize" begin
  struct ErrType end
  Base.show(::IO, ::ErrType) = error("boom")
  s = safe_summarize(ErrType())
  @test s.short == "summarize error"
  @test occursin("boom", something(s.long, ""))
end

# Stub interpret and interpret_value before including calcs.jl
module _StubRepl
  interpret(mod, code; kwargs...) = (Core.eval(mod, Meta.parseall(code)); "ok")
  interpret_value(mod, code) = Core.eval(mod, Meta.parseall(code))
end
# Provide to calcs.jl via @use stub
const interpret = _StubRepl.interpret
const interpret_value = _StubRepl.interpret_value

# FSPath stub — must be defined before calcs.jl is included
import Base: *
struct FSPath; path::String; end
*(p::FSPath, s::String) = FSPath(joinpath(p.path, s))
Base.string(p::FSPath) = p.path

home() = FSPath("/tmp")  # overridden by calcs_dir() in the testset anyway

# JSON stubs — parse_json / write_json used by the CRUD functions in calcs.jl
function _json_encode(x)
  io = IOBuffer()
  _json_write(io, x)
  String(take!(io))
end
function _json_write(io, x::Nothing); write(io, "null"); end
function _json_write(io, x::Bool); write(io, x ? "true" : "false"); end
function _json_write(io, x::AbstractString)
  write(io, "\"")
  for c in x
    if c == '"'; write(io, "\\\"")
    elseif c == '\\'; write(io, "\\\\")
    elseif c == '\n'; write(io, "\\n")
    else; write(io, c)
    end
  end
  write(io, "\"")
end
function _json_write(io, x::Real); write(io, string(x)); end
function _json_write(io, x::AbstractVector)
  write(io, "[")
  for (i, v) in enumerate(x)
    i > 1 && write(io, ",")
    _json_write(io, v)
  end
  write(io, "]")
end
function _json_write(io, x::AbstractDict)
  write(io, "{")
  first = true
  for (k, v) in x
    first || write(io, ",")
    first = false
    _json_write(io, string(k))
    write(io, ":")
    _json_write(io, v)
  end
  write(io, "}")
end

const write_json = _json_encode

function parse_json(s::AbstractString)
  i = Ref(1)
  _parse_value(s, i)
end
function _skip_ws(s, i)
  while i[] <= lastindex(s) && isspace(s[i[]])
    i[] = nextind(s, i[])
  end
end
function _parse_value(s, i)
  _skip_ws(s, i)
  c = s[i[]]
  c == '{' && return _parse_object(s, i)
  c == '[' && return _parse_array(s, i)
  c == '"' && return _parse_string(s, i)
  c == 'n' && (i[] += 4; return nothing)
  c == 't' && (i[] += 4; return true)
  c == 'f' && (i[] += 5; return false)
  return _parse_number(s, i)
end
function _parse_object(s, i)
  i[] = nextind(s, i[])  # skip {
  out = Dict{String,Any}()
  _skip_ws(s, i)
  s[i[]] == '}' && (i[] = nextind(s, i[]); return out)
  while true
    _skip_ws(s, i)
    k = _parse_string(s, i)
    _skip_ws(s, i)
    @assert s[i[]] == ':'
    i[] = nextind(s, i[])
    v = _parse_value(s, i)
    out[k] = v
    _skip_ws(s, i)
    if s[i[]] == ','; i[] = nextind(s, i[]); continue; end
    if s[i[]] == '}'; i[] = nextind(s, i[]); return out; end
  end
end
function _parse_array(s, i)
  i[] = nextind(s, i[])  # skip [
  out = Any[]
  _skip_ws(s, i)
  s[i[]] == ']' && (i[] = nextind(s, i[]); return out)
  while true
    push!(out, _parse_value(s, i))
    _skip_ws(s, i)
    if s[i[]] == ','; i[] = nextind(s, i[]); continue; end
    if s[i[]] == ']'; i[] = nextind(s, i[]); return out; end
  end
end
function _parse_string(s, i)
  @assert s[i[]] == '"'
  i[] = nextind(s, i[])
  io = IOBuffer()
  while s[i[]] != '"'
    if s[i[]] == '\\'
      i[] = nextind(s, i[])
      c = s[i[]]
      if c == 'n'; write(io, '\n')
      elseif c == '"'; write(io, '"')
      elseif c == '\\'; write(io, '\\')
      else; write(io, c)
      end
    else
      write(io, s[i[]])
    end
    i[] = nextind(s, i[])
  end
  i[] = nextind(s, i[])
  String(take!(io))
end
function _parse_number(s, i)
  j = i[]
  while j <= lastindex(s) && (isdigit(s[j]) || s[j] in "-+.eE")
    j = nextind(s, j)
  end
  num_str = s[i[]:prevind(s, j)]
  i[] = j
  return occursin('.', num_str) || occursin('e', num_str) || occursin('E', num_str) ?
    parse(Float64, num_str) : parse(Int, num_str)
end

import UUIDs: uuid4

include(joinpath(@__DIR__, "..", "calcs.jl"))

@testset "snapshot/apply round-trip" begin
  src = Module(:src_test)
  Core.eval(src, :(x = 7))
  Core.eval(src, :(y = "hello"))
  Core.eval(src, :(z = [1,2,3]))

  snap = snapshot(src)
  @test Set(keys(snap)) == Set([:x, :y, :z])

  dst = Module(:dst_test)
  apply!(dst, snap)
  @test getfield(dst, :x) == 7
  @test getfield(dst, :y) == "hello"
  @test getfield(dst, :z) === getfield(src, :z)  # shared reference
end

@testset "snapshot ignores generated/internal names" begin
  m = Module(:gen_test)
  Core.eval(m, :(real = 1))
  snap = snapshot(m)
  @test :real in keys(snap)
  @test !(:eval in keys(snap))
  @test !(nameof(m) in keys(snap))
end

println("calc_summary tests passed")
println("snapshot tests passed")

# Override calcs_dir for tests so we don't touch the user's real calcs/
const _TEST_CALCS_DIR = mktempdir()
calcs_dir() = FSPath(_TEST_CALCS_DIR)

@testset "calc CRUD round-trip" begin
  empty!(CALCS)
  c = create_calc("Holiday budget")
  @test c.name == "Holiday budget"
  @test isfile(calc_path(c.id))

  push!(c.paragraphs, Paragraph("The price of a banana is \$3"))
  c.paragraphs[1].code_template = "banana_price = {{p0}}"
  push!(c.paragraphs[1].parameters,
        Parameter("p0", (24, 25), "3"))
  c.paragraphs[1].last_value_short = "3"
  save_calc(c)

  empty!(CALCS)  # force reload from disk
  reloaded = load_calc(c.id)
  @test reloaded.name == "Holiday budget"
  @test length(reloaded.paragraphs) == 1
  @test reloaded.paragraphs[1].code_template == "banana_price = {{p0}}"
  @test reloaded.paragraphs[1].parameters[1].current_value == "3"

  list = list_calcs()
  @test length(list) == 1
  @test list[1]["id"] == c.id

  rename_calc(c.id, "Trip budget")
  @test load_calc(c.id).name == "Trip budget"

  delete_calc(c.id)
  @test !isfile(calc_path(c.id))
end

println("calc CRUD tests passed")

@testset "split_paragraphs" begin
  @test split_paragraphs("") == []
  @test [t for (t, _) in split_paragraphs("hello")] == ["hello"]
  @test [t for (t, _) in split_paragraphs("a\n\nb")] == ["a", "b"]
  @test [t for (t, _) in split_paragraphs("a\n\n\n\nb\n\nc")] == ["a", "b", "c"]
  ps = split_paragraphs("first line\nstill first\n\nsecond")
  @test ps[1][1] == "first line\nstill first"
  @test ps[2][1] == "second"
end

@testset "diff_range" begin
  @test diff_range("abc", "abc") === nothing
  rng, rep = diff_range("abc", "axc")
  @test rng == 2:2 && rep == "x"
  rng, rep = diff_range("hello", "help")
  @test rng == 4:5 && rep == "p"
  rng, rep = diff_range("price is \$3", "price is \$30")
  @test rep == "0"  # diff is the inserted "0"; classify_edit reconstructs "30"
end

@testset "classify_edit" begin
  params = [Parameter("p0", (26, 27), "3")]
  text = "The price of a banana is \$3"
  cls, info = classify_edit(text, text, params)
  @test cls == UNCHANGED

  cls, info = classify_edit(text, "The price of a banana is \$30", params)
  @test cls == PARAMETER
  @test info == (1, "30")

  cls, info = classify_edit(text, "The price of a apple is \$3", params)
  @test cls == STRUCTURAL
end

println("paragraph splitting + classification tests passed")

@testset "render_code" begin
  ps = [Parameter("p0", (0,0), "3"), Parameter("p1", (0,0), "12")]
  @test render_code("x = {{p0}}", ps) == "x = 3"
  @test render_code("x = {{p0}} + {{p1}}", ps) == "x = 3 + 12"
  @test render_code("no params here", Parameter[]) == "no params here"
  @test_throws ErrorException render_code("x = {{nope}}", ps)
end

println("render_code tests passed")

@testset "cascade replay" begin
  empty!(CALCS)
  c = create_calc("test")

  p1 = Paragraph("first")
  p1.code_template = "x = {{p0}}"
  push!(p1.parameters, Parameter("p0", (0,0), "10"))
  push!(c.paragraphs, p1)

  p2 = Paragraph("second")
  p2.code_template = "y = x + {{p0}}"
  push!(p2.parameters, Parameter("p0", (0,0), "5"))
  push!(c.paragraphs, p2)

  cascade!(c, 1)
  @test c.paragraphs[1].last_value_short == "10"
  @test c.paragraphs[2].last_value_short == "15"

  c.paragraphs[1].parameters[1].current_value = "20"
  cascade!(c, 1)
  @test c.paragraphs[1].last_value_short == "20"
  @test c.paragraphs[2].last_value_short == "25"
end

@testset "cascade respects stale-binding invariant" begin
  empty!(CALCS)
  c = create_calc("stale")
  p1 = Paragraph("first")
  p1.code_template = "removable = 99"
  push!(c.paragraphs, p1)
  cascade!(c, 1)
  @test c.paragraphs[1].last_value_short == "99"
  @test isdefined(c.mod, :removable)

  c.paragraphs[1].code_template = "kept = 42"
  c.paragraphs[1].parameters = Parameter[]
  cascade!(c, 1)
  @test c.paragraphs[1].last_value_short == "42"
  @test !isdefined(c.mod, :removable)
  @test isdefined(c.mod, :kept)
end

@testset "cascade does not re-run upstream paragraphs" begin
  empty!(CALCS)
  c = create_calc("count")
  Core.eval(Main, :(cascade_counter_n = Ref(0)))
  p1 = Paragraph("p1")
  p1.code_template = "(Main.cascade_counter_n[] += 1; Main.cascade_counter_n[])"
  push!(c.paragraphs, p1)
  cascade!(c, 1)
  first_count = c.paragraphs[1].last_value_short

  p2 = Paragraph("p2")
  p2.code_template = "1 + 1"
  push!(c.paragraphs, p2)
  cascade!(c, 2)
  @test c.paragraphs[1].last_value_short == first_count
end

println("cascade tests passed")
