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

println("calc_summary tests passed")
