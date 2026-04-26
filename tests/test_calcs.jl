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
