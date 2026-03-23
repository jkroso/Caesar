@use "./pagerank" personalized_pagerank
@use LinearAlgebra: dot

# Associative warmth: embed conversation context, find similar notes,
# then run PPR from those seeds to discover graph-connected notes
function compute_warmth(context_embedding::Vector{Float64},
                        note_embeddings::Dict{String, Vector{Float64}},
                        outgoing::Dict{String, Set{String}};
                        top_k=5, alpha=0.85)
  # Find notes most similar to conversation context
  sims = [(id, dot(context_embedding, vec)) for (id, vec) in note_embeddings]
  filter!(p -> p[2] > 0, sims)
  sort!(sims; by=last, rev=true)
  seeds = Dict(id => sim for (id, sim) in sims[1:min(top_k, length(sims))])
  isempty(seeds) && return Dict{String, Float64}()
  personalized_pagerank(outgoing, seeds; alpha)
end
