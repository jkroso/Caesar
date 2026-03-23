@use "./types" Note ScoredNote
@use "./vault" load_vault write_note extract_links
@use "./graph" KnowledgeGraph build_graph degree neighbors articulation_points hub_threshold
@use "./db" init_db
@use "./bm25" build_bm25 score_bm25 BM25Index
@use "./semantic" score_semantic embed_query
@use "./tfidf" TFIDFIndex build_tfidf
@use "./embeddings" OllamaIndex build_embeddings ollama_available
@use "./pagerank" personalized_pagerank
@use "./vitality" record_access! get_vitality
@use "./activation" spread_activation
@use "./warmth" compute_warmth
@use "./fusion" reciprocal_rank_fusion dampen_gravity dampen_hubs boost_resolution
@use "./learning" get_qvalue update_qvalue! record_exposure! record_cooccurrence! rerank_with_qvalues ucb_bonus
@use "./intent" classify_intent QueryIntent
@use SQLite
@use JSON3
@use Dates: now, UTC

# Semantic index: either OllamaIndex or TFIDFIndex
const SemanticIndex = Union{OllamaIndex, TFIDFIndex}

function build_semantic_index(notes; model="nomic-embed-text")
  if ollama_available(; model)
    @info "Using Ollama ($model) for embeddings"
    build_embeddings(notes; model)
  else
    @warn "Ollama unavailable, falling back to TF-IDF"
    build_tfidf(notes)
  end
end




mutable struct Engine
  vault_dir::String
  notes::Dict{String, Note}  # id => Note
  graph::KnowledgeGraph
  db::SQLite.DB
  bm25::BM25Index
  semantic::SemanticIndex
  bridges::Set{String}       # articulation points
  context::Vector{String}    # conversation history for warmth
  total_queries::Int
  last_conversation_id::Union{String, Nothing}
end

function init_engine(vault_dir::AbstractString; db_path=joinpath(vault_dir, ".ori.db"),
                     embed_model="nomic-embed-text")
  notes_vec = load_vault(vault_dir)
  notes = Dict(n.id => n for n in notes_vec)
  graph = build_graph(notes_vec)
  db = init_db(db_path)
  bm25 = build_bm25(notes_vec)
  semantic = build_semantic_index(notes_vec; model=embed_model)
  bridges = articulation_points(graph)
  Engine(vault_dir, notes, graph, db, bm25, semantic, bridges, String[], 0, nothing)
end

function search(engine::Engine, query::AbstractString; top_k=5, use_warmth=true)
  engine.total_queries += 1
  intent = classify_intent(query)

  # Signal 1: BM25 keyword
  bm25_scores = score_bm25(engine.bm25, query)

  # Signal 2: Semantic (TF-IDF cosine similarity)
  semantic_scores = score_semantic(engine.semantic, query)

  # Signal 3: Graph (PPR from BM25+semantic seed nodes)
  seeds = Dict{String, Float64}()
  for (id, s) in bm25_scores; seeds[id] = get(seeds, id, 0.0) + s end
  for (id, s) in semantic_scores; seeds[id] = get(seeds, id, 0.0) + s end
  graph_scores = if !isempty(seeds)
    # Combine wiki-link graph with co-occurrence for richer traversal
    personalized_pagerank(engine.graph.outgoing, seeds; alpha=0.85)
  else
    Dict{String, Float64}()
  end

  # Signal 4: Warmth (conversation context → PPR)
  warmth_scores = Dict{String, Float64}()
  if use_warmth && !isempty(engine.context)
    ctx = join(engine.context[max(1,end-4):end], " ")
    ctx_embed = embed_query(engine.semantic, ctx)
    warmth_scores = compute_warmth(ctx_embed, engine.semantic.vectors, engine.graph.outgoing)
  end

  # Fuse signals via RRF
  signal_scores = Dict{Symbol, Dict{String, Float64}}(
    :bm25 => bm25_scores,
    :semantic => semantic_scores,
    :pagerank => graph_scores,
    :warmth => warmth_scores,
  )
  results = reciprocal_rank_fusion(signal_scores, intent.weights, engine.graph.titles; k=10)

  # Dampening pipeline
  note_types = Dict(id => n.type for (id, n) in engine.notes)
  results = dampen_gravity(results, query, engine.graph.titles)
  results = dampen_hubs(results, id -> degree(engine.graph, id))
  results = boost_resolution(results, note_types)

  # Q-value reranking — lambda grows with usage (cold start = no reranking noise)
  lambda = min(0.3, 0.03 * engine.total_queries)
  results = rerank_with_qvalues(engine.db, results, engine.total_queries; lambda)

  # Record exposure for all results
  for r in results[1:min(top_k, length(results))]
    record_exposure!(engine.db, r.id)
  end

  # Update conversation context
  push!(engine.context, query)

  # Log query
  result_ids = [r.id for r in results[1:min(top_k, length(results))]]
  SQLite.execute(engine.db, """
    INSERT INTO query_log (query, intent, result_ids, timestamp)
    VALUES (?, ?, ?, ?)
  """, (query, string(intent.type), JSON3.write(result_ids), string(now(UTC))))

  results[1:min(top_k, length(results))]
end

# Flat search (semantic only) for comparison
function flat_search(engine::Engine, query::AbstractString; top_k=5)
  scores = score_semantic(engine.semantic, query)
  sorted = sort(collect(scores); by=last, rev=true)
  [ScoredNote(id, get(engine.graph.titles, id, id), s,
              Dict(:semantic => s)) for (id, s) in sorted[1:min(top_k, length(sorted))]]
end

# Record that a result was useful (feeds Q-value learning)
function record_feedback!(engine::Engine, note_id::AbstractString, reward::Float64)
  update_qvalue!(engine.db, note_id, reward)
  record_access!(engine.db, note_id)
end

# Record co-occurrence for notes retrieved together
function record_session!(engine::Engine, used_ids::Vector{String})
  record_cooccurrence!(engine.db, used_ids)
  for id in used_ids
    update_qvalue!(engine.db, id, 1.0)
  end
end

function rebuild!(engine::Engine)
  notes_vec = load_vault(engine.vault_dir)
  empty!(engine.notes)
  for n in notes_vec; engine.notes[n.id] = n end
  engine.graph = build_graph(notes_vec)
  engine.bm25 = build_bm25(notes_vec)
  engine.semantic = build_semantic_index(notes_vec)
  engine.bridges = articulation_points(engine.graph)
  nothing
end

function update_note!(engine::Engine, title::AbstractString, body::AbstractString;
                      type::Symbol=:note, space::Symbol=:notes, tags=String[])
  existing = nothing
  for (id, note) in engine.notes
    lowercase(note.title) == lowercase(title) && (existing = note; break)
  end
  if existing !== nothing
    open(existing.path, "w") do io
      println(io, "---")
      println(io, "id: ", existing.id)
      println(io, "title: ", title)
      println(io, "type: ", type)
      isempty(tags) || println(io, "tags: ", join(tags, ", "))
      println(io, "space: ", space)
      println(io, "---")
      println(io)
      print(io, body)
    end
    updated = Note(id=existing.id, title=title, description="", body=body,
                   type=type, tags=tags, links=extract_links(body),
                   space=space, path=existing.path,
                   created=existing.created, modified=now(UTC))
    engine.notes[existing.id] = updated
    return updated
  else
    note = write_note(engine.vault_dir, Note(title=title, body=body, type=type,
                                              space=space, tags=tags,
                                              links=extract_links(body)))
    engine.notes[note.id] = note
    return note
  end
end
