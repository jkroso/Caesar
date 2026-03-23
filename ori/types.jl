@use "github.com/jkroso/Prospects.jl" @struct
@use Dates: DateTime, now, UTC
@use UUIDs: uuid4

@struct struct Note
  id::String = string(uuid4())
  title::String = ""
  description::String = ""
  body::String = ""
  type::Symbol = :note # :note, :decision, :learning, :map, :log
  tags::Vector{String} = String[]
  links::Vector{String} = String[]
  space::Symbol = :notes # :self, :notes, :ops
  path::String = ""
  created::DateTime = now(UTC)
  modified::DateTime = now(UTC)
end

struct ScoredNote
  id::String
  title::String
  score::Float64
  signals::Dict{Symbol, Float64}
end
