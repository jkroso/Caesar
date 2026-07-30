# tests/test_calcs_llm.jl — real-LLM integration tests for the calc translator.
#
# Drives `translate_paragraph` against the live Anthropic translator
# (default: Haiku 4.5) and asserts SEMANTIC properties of the cascade,
# not exact code text. Skipped silently if ANTHROPIC_API_KEY is missing.
#
# Run: `julia --project=. tests/test_calcs_llm.jl`
using Test

if !haskey(ENV, "ANTHROPIC_API_KEY") || isempty(ENV["ANTHROPIC_API_KEY"])
  @info "Skipping LLM integration tests — set ANTHROPIC_API_KEY to enable"
  exit(0)
end

# Kip provides the real `@use` macro. The user's startup.jl loads it
# globally; load defensively in case this script runs in a stripped REPL.
isdefined(Main, Symbol("@use")) || Core.eval(Main, :(using Kip))

# Load the real calcs.jl with all dependencies (LLM.jl, Units, Money, ...).
# `@use` resolves paths from `@__FILE__`, so include() works fine.
include(joinpath(@__DIR__, "..", "calcs.jl"))

# Send writes to a tempdir instead of ~/Caesar/calcs/.
const _LLM_TEST_CALCS_DIR = mktempdir()
calcs_dir() = FSPath(_LLM_TEST_CALCS_DIR)

# Allow CALC_TEST_MODEL=<provider/model> to override the translator model
# for cross-provider comparisons. Otherwise use the agent's configured model.
load_translator!()
if haskey(ENV, "CALC_TEST_MODEL") && !isempty(ENV["CALC_TEST_MODEL"])
  m = ENV["CALC_TEST_MODEL"]
  _TRANSLATOR_CONFIG[]["llm"] = m
  _TRANSLATOR[] = _build_llm(m)
end
println("\n══ Translator model: ", _TRANSLATOR_CONFIG[]["llm"], " ══\n")

"""Run the real translator + cascade for a single paragraph index."""
function translate_and_cascade!(c::Calc, idx::Int)
  ok = translate_paragraph(c, idx)
  ok || error("translate_paragraph returned false at idx=$idx (paragraph: $(repr(c.paragraphs[idx].text)))")
  cascade!(c, idx; translator=(calc, i) -> translate_paragraph(calc, i))
end

"""Pretty-print what the translator produced — printed before assertions
so a failing test surfaces the LLM's actual output, not just a NaN."""
function _dump(p::Paragraph, label::AbstractString)
  println("─── $label ───")
  println("  text:     ", repr(p.text))
  println("  template: ", repr(p.code_template))
  println("  params:")
  for param in p.parameters
    println("    ", param.id, " span=", param.text_span,
            " current_value=", repr(param.current_value))
  end
  println("  short:    ", repr(p.last_value_short))
  println("  error:    ", repr(p.last_error))
end

"""Parse the leading numeric value out of a Money-formatted short string
like \"6,494.19 AUD\". Returns NaN if no number is found."""
function _leading_number(s::AbstractString)::Float64
  m = match(r"([\-+]?[\d,]*\.?\d+)", s)
  m === nothing && return NaN
  parse(Float64, replace(m.captures[1], "," => ""))
end

# ── Scenarios ─────────────────────────────────────────────────────────
# Wrapped in an outer testset so a failing scenario doesn't halt the
# script before later scenarios get a chance to run (Test.jl throws at
# the end of an unfailed top-level @testset).

@testset "calcs LLM integration" begin

# ── Scenario 1: AUD currency parameter parsed and propagated ──

@testset "LLM preserves AUD currency through GST division" begin
  empty!(CALCS)
  c = create_calc("llm-aud")
  text = "I purchased an item for 6494.19AUD including GST"
  push!(c.paragraphs, Paragraph("p1", text, "", Parameter[], nothing, nothing, nothing))
  translate_and_cascade!(c, 1)
  _dump(c.paragraphs[1], "AUD scenario · ¶1")

  @test c.paragraphs[1].last_error === nothing
  short1 = something(c.paragraphs[1].last_value_short, "")
  @test occursin("AUD", short1)
  @test isapprox(_leading_number(short1), 6494.19, rtol=1e-6)

  # The translator must have emitted at least one parameter whose
  # current_value carries the literal price (with or without unit suffix).
  params = c.paragraphs[1].parameters
  @test any(p -> occursin("6494.19", p.current_value), params)

  # _snap_span must have placed at least one parameter span over the
  # exact "6494.19AUD" substring in the source text. Skip spans that
  # are out-of-bounds — those are LLM garbage we couldn't snap.
  text1 = c.paragraphs[1].text
  spans_text = String[]
  for p in params
    s = p.text_span
    0 <= s[1] <= s[2] <= sizeof(text1) || continue
    push!(spans_text, text1[s[1]+1:s[2]])
  end
  @test any(s -> occursin("6494.19AUD", s), spans_text)

  push!(c.paragraphs, Paragraph(
    "p2", "It's cost before GST?", "", Parameter[], nothing, nothing, nothing))
  translate_and_cascade!(c, 2)
  _dump(c.paragraphs[2], "AUD scenario · ¶2")

  @test c.paragraphs[2].last_error === nothing
  short2 = something(c.paragraphs[2].last_value_short, "")
  @test occursin("AUD", short2)
  @test isapprox(_leading_number(short2), 6494.19 / 1.1, rtol=1e-3)

  delete_calc(c.id)
end

# ── Scenario 2: count × per-unit price → "before GST" multiplies through ──

@testset "LLM factors item count into total before GST" begin
  empty!(CALCS)
  c = create_calc("llm-count")
  # "at X each" forces the per-item reading. "for X" alone is ambiguous
  # in English ("4 items for $5" usually = $5 total), so every model
  # we tested defaulted to interpreting 6494.19 as the total. Phrasing
  # the input unambiguously is the test author's responsibility.
  push!(c.paragraphs, Paragraph(
    "p1", "I purchased 4 items at 6494.19AUD each, including GST",
    "", Parameter[], nothing, nothing, nothing))
  translate_and_cascade!(c, 1)
  _dump(c.paragraphs[1], "count scenario · ¶1")
  @test c.paragraphs[1].last_error === nothing
  short1 = something(c.paragraphs[1].last_value_short, "")
  @test occursin("AUD", short1)

  # Paragraph 1's terminal value MUST be the multiplied total
  # (4 × 6494.19 = 25976.76 AUD), not just one operand. If it equals
  # 6494.19 the translator dropped the count — that's the bug.
  expected_total = 4 * 6494.19
  @test isapprox(_leading_number(short1), expected_total, rtol=1e-3)

  push!(c.paragraphs, Paragraph(
    "p2", "Total cost before GST?", "", Parameter[], nothing, nothing, nothing))
  translate_and_cascade!(c, 2)
  _dump(c.paragraphs[2], "count scenario · ¶2")
  @test c.paragraphs[2].last_error === nothing
  short2 = something(c.paragraphs[2].last_value_short, "")
  @test occursin("AUD", short2)

  # Total before GST = (4 × 6494.19) / 1.1 ≈ 23615.24 AUD.
  # If we see ~5903.81 instead, the count was ignored.
  expected_before_gst = expected_total / 1.1
  @test isapprox(_leading_number(short2), expected_before_gst, rtol=1e-3)

  delete_calc(c.id)
end

# ── Scenario 3: prose-heavy paragraph must not parameterize prepositions ──

@testset "LLM rejects prepositional phrases as parameters" begin
  # Regression for the "of water" hallucination: the translator picked
  # "of water" as a parameter with current_value also "of water", which
  # rendered as `... = of water` and crashed with `UndefVarError: of`.
  # The only legitimate parameters in this sentence are the three
  # numeric+unit values: 20kg, 5litres, 25kg.
  empty!(CALCS)
  c = create_calc("llm-prose")
  text = "A 20kg bag of concrete requires 5litres of water making for a total of 25kg of concrete per bag"
  push!(c.paragraphs, Paragraph(
    "p1", text, "", Parameter[], nothing, nothing, nothing))
  translate_and_cascade!(c, 1)
  _dump(c.paragraphs[1], "prose scenario · ¶1")

  @test c.paragraphs[1].last_error === nothing

  # Every parameter's current_value MUST evaluate cleanly in a
  # units-seeded sandbox. Catches both syntactically-invalid hallucinations
  # ("of water" — `of` not defined) AND syntactically-valid-but-
  # semantically-wrong ones ("2litres" — parses as `2 * litres`, but
  # `litres` isn't a Units.jl name, so the cascade crashes with
  # UndefVarError when this current_value gets substituted into code).
  _ensure_units_loaded!()
  for p in c.paragraphs[1].parameters
    @test _is_parseable_param_value(p.current_value)
  end

  # And every parameter span MUST cover a substring of the original text
  # that contains at least one digit — i.e. the parameter is anchored
  # to a numeric literal, not a bare noun phrase.
  text1 = c.paragraphs[1].text
  for p in c.paragraphs[1].parameters
    s = p.text_span
    @test 0 <= s[1] <= s[2] <= sizeof(text1)
    @test occursin(r"\d", text1[s[1]+1:s[2]])
  end

  delete_calc(c.id)
end

end  # outer @testset "calcs LLM integration"

println("LLM integration tests done")
