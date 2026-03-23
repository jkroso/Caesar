@use "./types" Note
@use "./semantic" score_semantic embed_query
@use LinearAlgebra: normalize, norm, dot
@use HTTP
@use JSON3

const DEFAULT_MODEL = "nomic-embed-text"
const OLLAMA_URL = "http://localhost:11434/api/embed"

struct OllamaIndex
  vectors::Dict{String, Vector{Float64}} # note_id => unit vector
  model::String
  dim::Int
end

function batch_embed(texts::Vector{String}; model=DEFAULT_MODEL, batchsize=100)
  embeddings = Vector{Vector{Float64}}()
  for chunk in Iterators.partition(texts, batchsize)
    resp = HTTP.post(OLLAMA_URL,
      ["Content-Type" => "application/json"],
      JSON3.write(Dict("model" => model, "input" => collect(chunk)));
      connect_timeout=5, readtimeout=120)
    data = JSON3.read(resp.body)
    for e in data.embeddings
      push!(embeddings, normalize(Vector{Float64}(e)))
    end
  end
  embeddings
end

function ollama_available(; model=DEFAULT_MODEL)
  try
    resp = HTTP.post(OLLAMA_URL,
      ["Content-Type" => "application/json"],
      JSON3.write(Dict("model" => model, "input" => ["test"]));
      connect_timeout=2, readtimeout=10)
    resp.status == 200
  catch
    false
  end
end

function build_embeddings(notes::Vector{Note}; model=DEFAULT_MODEL)
  texts = [join(filter(!isempty, [note.title, note.description, note.body]), "\n") for note in notes]
  vecs = batch_embed(texts; model)
  dim = isempty(vecs) ? 0 : length(first(vecs))
  vectors = Dict(notes[i].id => vecs[i] for i in eachindex(notes))
  OllamaIndex(vectors, model, dim)
end

function embed_query(index::OllamaIndex, query)
  vecs = batch_embed([String(query)]; model=index.model)
  isempty(vecs) ? zeros(index.dim) : first(vecs)
end

function score_semantic(index::OllamaIndex, query::AbstractString)
  qvec = embed_query(index, query)
  scores = Dict{String, Float64}()
  for (id, vec) in index.vectors
    sim = dot(qvec, vec)
    sim > 0 && (scores[id] = sim)
  end
  scores
end

function embed_new!(index::OllamaIndex, notes::Dict{String, Note})
  new_ids = collect(setdiff(keys(notes), keys(index.vectors)))
  isempty(new_ids) && return
  new_notes = [notes[id] for id in new_ids]
  texts = [join(filter(!isempty, [n.title, n.description, n.body]), "\n") for n in new_notes]
  vecs = batch_embed(texts; model=index.model)
  for (i, id) in enumerate(new_ids)
    index.vectors[id] = vecs[i]
  end
end
