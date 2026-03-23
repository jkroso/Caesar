@use "./types" Note

struct KnowledgeGraph
  outgoing::Dict{String, Set{String}}
  incoming::Dict{String, Set{String}}
  titles::Dict{String, String} # id => title
end

function build_graph(notes::Vector{Note})
  outgoing = Dict{String, Set{String}}()
  incoming = Dict{String, Set{String}}()
  titles = Dict{String, String}()
  title_to_id = Dict{String, String}()
  for note in notes
    titles[note.id] = note.title
    title_to_id[lowercase(note.title)] = note.id
    outgoing[note.id] = Set{String}()
    incoming[note.id] = Set{String}()
  end
  for note in notes
    for link in note.links
      target = get(title_to_id, lowercase(link), nothing)
      target === nothing && continue
      push!(outgoing[note.id], target)
      push!(incoming[target], note.id)
    end
  end
  KnowledgeGraph(outgoing, incoming, titles)
end

degree(g::KnowledgeGraph, id) = length(get(g.outgoing, id, Set())) + length(get(g.incoming, id, Set()))
outdegree(g::KnowledgeGraph, id) = length(get(g.outgoing, id, Set()))
indegree(g::KnowledgeGraph, id) = length(get(g.incoming, id, Set()))
neighbors(g::KnowledgeGraph, id) = union(get(g.outgoing, id, Set()), get(g.incoming, id, Set()))

function hub_threshold(g::KnowledgeGraph; percentile=0.9)
  degrees = [degree(g, id) for id in keys(g.outgoing)]
  isempty(degrees) && return 0
  sort!(degrees)
  degrees[max(1, ceil(Int, percentile * length(degrees)))]
end

# Tarjan's algorithm for articulation points (bridge nodes)
function articulation_points(g::KnowledgeGraph)
  ids = collect(keys(g.outgoing))
  n = length(ids)
  n == 0 && return Set{String}()
  id_to_idx = Dict(id => i for (i, id) in enumerate(ids))
  disc = zeros(Int, n)
  low = zeros(Int, n)
  parent = zeros(Int, n)
  visited = falses(n)
  ap = falses(n)
  timer = Ref(0)
  function dfs(u)
    children = 0
    visited[u] = true
    timer[] += 1
    disc[u] = low[u] = timer[]
    for nb_id in neighbors(g, ids[u])
      v = get(id_to_idx, nb_id, 0)
      v == 0 && continue
      if !visited[v]
        children += 1
        parent[v] = u
        dfs(v)
        low[u] = min(low[u], low[v])
        parent[u] == 0 && children > 1 && (ap[u] = true)
        parent[u] != 0 && low[v] >= disc[u] && (ap[u] = true)
      elseif v != parent[u]
        low[u] = min(low[u], disc[v])
      end
    end
  end
  for i in 1:n
    visited[i] || dfs(i)
  end
  Set(ids[i] for i in 1:n if ap[i])
end
