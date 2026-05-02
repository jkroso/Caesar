# calc_summary.jl — short/long abbreviations of evaluated values for the Calcs UI
@use Dates...

struct Summary
  short::String
  long::Union{Nothing,String}
end

summarize(x::Number) = Summary(string(x), nothing)

# Rationals are correct Julia but never what the human wants to read.
# Collapse to a bare integer when the denominator is 1; otherwise show
# the floating-point value (so `5//2` → `"2.5"`, not `"5//2"`).
summarize(x::Rational) = isone(denominator(x)) ?
  Summary(string(numerator(x)), nothing) :
  Summary(string(float(x)), nothing)

summarize(x::AbstractString) = length(x) <= 60 ?
  Summary(repr(x), nothing) :
  Summary("$(length(x))-char string", repr(x))

summarize(x::AbstractArray) = Summary(
  "$(eltype(x))[$(join(size(x), '×'))]",
  sprint(show, MIME"text/plain"(), x))

summarize(x::AbstractDict) = Summary(
  "Dict ($(length(x)) entries)",
  sprint(show, MIME"text/plain"(), x))

summarize(::Nothing) = Summary("nothing", nothing)
summarize(x::Bool) = Summary(string(x), nothing)
summarize(x::Symbol) = Summary(":$(x)", nothing)
summarize(x::Date) = Summary(string(x), nothing)
summarize(x::DateTime) = Summary(string(x), nothing)

# Fallback: short via 2-arg show, long via MIME text/plain
function summarize(x)
  short = sprint(show, x)
  long_str = sprint(show, MIME"text/plain"(), x)
  Summary(length(short) > 80 ? first(short, 80) * "…" : short,
          long_str == short ? nothing : long_str)
end

"""Wrap summarize in try/catch and return a Summary even on error."""
function safe_summarize(x)::Summary
  try
    summarize(x)
  catch e
    Summary("summarize error", sprint(showerror, e))
  end
end
