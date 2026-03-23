@use "./types" ScoredNote

# Score-weighted Reciprocal Rank Fusion
function reciprocal_rank_fusion(signal_scores::Dict{Symbol, Dict{String, Float64}},
                                weights::Dict{Symbol, Float64},
                                titles::Dict{String, String};
                                k=60)
  # Rank each signal
  ranked = Dict{Symbol, Vector{String}}()
  for (sig, scores) in signal_scores
    ranked[sig] = sort(collect(keys(scores)); by=id->scores[id], rev=true)
  end
  # Compute fused scores
  all_ids = Set{String}()
  for ids in values(ranked); union!(all_ids, ids) end
  fused = Dict{String, Dict{Symbol, Float64}}()
  for id in all_ids
    fused[id] = Dict{Symbol, Float64}()
  end
  for (sig, ids) in ranked
    w = get(weights, sig, 0.0)
    raw_scores = signal_scores[sig]
    for (rank, id) in enumerate(ids)
      raw = get(raw_scores, id, 0.0)
      fused[id][sig] = w * raw / (k + rank + 1)
    end
  end
  results = ScoredNote[]
  for (id, signals) in fused
    score = sum(values(signals))
    score > 0 && push!(results, ScoredNote(id, get(titles, id, id), score, signals))
  end
  sort!(results; by=r->r.score, rev=true)
end

# ── Dampening Pipeline ───────────────────────────────────────────────

# Gravity: halve score if high semantic but zero title keyword overlap
function dampen_gravity(results::Vector{ScoredNote}, query, titles; threshold=0.3)
  map(results) do r
    sem = get(r.signals, :semantic, 0.0)
    sem < threshold && return r
    title = get(titles, r.id, "")
    qtokens = Set(lowercase.(m.match for m in eachmatch(r"[a-zA-Z0-9]+", query)))
    ttokens = Set(lowercase.(m.match for m in eachmatch(r"[a-zA-Z0-9]+", title)))
    isempty(intersect(qtokens, ttokens)) || return r
    ScoredNote(r.id, r.title, r.score * 0.5, r.signals)
  end
end

# Hub: penalize notes above P90 degree count
function dampen_hubs(results::Vector{ScoredNote},
                     degree_fn; max_penalty=0.6)
  degrees = [degree_fn(r.id) for r in results]
  isempty(degrees) && return results
  p90 = sort(degrees)[max(1, ceil(Int, 0.9 * length(degrees)))]
  p90 == 0 && return results
  map(results) do r
    d = degree_fn(r.id)
    d <= p90 && return r
    penalty = min(max_penalty, (d - p90) / p90 * 0.3)
    ScoredNote(r.id, r.title, r.score * (1 - penalty), r.signals)
  end
end

# Resolution boost: 1.25x for decision/learning type notes
function boost_resolution(results::Vector{ScoredNote}, note_types::Dict{String, Symbol})
  map(results) do r
    t = get(note_types, r.id, :note)
    multiplier = t in (:decision, :learning) ? 1.25 : 1.0
    ScoredNote(r.id, r.title, r.score * multiplier, r.signals)
  end
end
