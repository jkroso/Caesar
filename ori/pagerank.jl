function personalized_pagerank(outgoing::Dict{String, Set{String}},
                               seeds::Dict{String, Float64};
                               alpha=0.85, iterations=20)
  ids = collect(keys(outgoing))
  n = length(ids)
  n == 0 && return Dict{String, Float64}()
  id_to_idx = Dict(id => i for (i, id) in enumerate(ids))
  # Normalize seed vector
  s = zeros(n)
  total = sum(values(seeds))
  total < 1e-10 && return Dict{String, Float64}()
  for (id, val) in seeds
    idx = get(id_to_idx, id, 0)
    idx > 0 && (s[idx] = val / total)
  end
  # Power iteration
  r = copy(s)
  for _ in 1:iterations
    r_new = (1 - alpha) .* s
    for (i, id) in enumerate(ids)
      out = get(outgoing, id, Set{String}())
      isempty(out) && continue
      share = alpha * r[i] / length(out)
      for target in out
        j = get(id_to_idx, target, 0)
        j > 0 && (r_new[j] += share)
      end
    end
    r = r_new
  end
  Dict(ids[i] => r[i] for i in 1:n if r[i] > 1e-10)
end
