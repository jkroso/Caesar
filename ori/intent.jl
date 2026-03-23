struct QueryIntent
  type::Symbol
  weights::Dict{Symbol, Float64}
end

const INTENT_PATTERNS = [
  (:episodic,   [r"when did"i, r"last time"i, r"remember"i, r"what happened"i, r"history"i, r"why did"i, r"go down"i, r"went down"i, r"outage"i, r"incident"i, r"broke"i]),
  (:procedural, [r"how to"i, r"how do"i, r"steps to"i, r"process for"i, r"way to"i]),
  (:decision,   [r"should we"i, r"decision"i, r"choose"i, r"trade.?off"i, r"compare"i]),
]

const INTENT_WEIGHTS = Dict(
  :episodic   => Dict(:semantic => 0.20, :bm25 => 0.30, :pagerank => 0.20, :warmth => 0.10),
  :procedural => Dict(:semantic => 0.30, :bm25 => 0.30, :pagerank => 0.25, :warmth => 0.15),
  :decision   => Dict(:semantic => 0.20, :bm25 => 0.20, :pagerank => 0.25, :warmth => 0.15),
  :semantic   => Dict(:semantic => 0.30, :bm25 => 0.25, :pagerank => 0.25, :warmth => 0.20),
)

function classify_intent(query::AbstractString)
  for (intent, patterns) in INTENT_PATTERNS
    for p in patterns
      occursin(p, query) && return QueryIntent(intent, INTENT_WEIGHTS[intent])
    end
  end
  QueryIntent(:semantic, INTENT_WEIGHTS[:semantic])
end
