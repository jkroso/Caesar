# Spreading activation via BFS from seed nodes
function spread_activation(outgoing::Dict{String, Set{String}},
                           incoming::Dict{String, Set{String}},
                           seeds::Dict{String, Float64};
                           damping=0.6, max_hops=2)
  activation = Dict{String, Float64}()
  # BFS queue: (id, value, hop)
  frontier = [(id, val, 0) for (id, val) in seeds]
  while !isempty(frontier)
    id, value, hop = popfirst!(frontier)
    hop > max_hops && continue
    activation[id] = get(activation, id, 0.0) + value
    hop == max_hops && continue
    boost = value * damping
    boost < 1e-6 && continue
    for nb in union(get(outgoing, id, Set()), get(incoming, id, Set()))
      push!(frontier, (nb, boost, hop + 1))
    end
  end
  activation
end
