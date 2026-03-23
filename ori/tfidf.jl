@use "./types" Note
@use "./semantic" score_semantic embed_query
@use LinearAlgebra: normalize, norm, dot

struct TFIDFIndex
  vocab::Dict{String, Int}
  idf::Vector{Float64}
  vectors::Dict{String, Vector{Float64}} # note_id => unit vector
end

const STOPWORDS = Set(["a","an","the","is","are","was","were","be","been","being",
  "have","has","had","do","does","did","will","would","shall","should",
  "i","you","he","she","it","we","they","me","him","her","us","them",
  "my","your","his","its","our","their","this","that","these","those",
  "and","but","or","nor","not","so","yet","if","then","else",
  "of","with","by","as","at","in","on","to","for","from",
  "how","what","when","where","which","who","whom","why"])

tokenize(text) = filter(∉(STOPWORDS), [lowercase(m.match) for m in eachmatch(r"[a-zA-Z0-9]+", text)])

function note_tokens(note::Note)
  vcat(repeat(tokenize(note.title), 3),
       repeat(tokenize(note.description), 2),
       tokenize(note.body))
end

function build_tfidf(notes::Vector{Note})
  df = Dict{String, Int}()
  all_tokens = Dict{String, Vector{String}}()
  for note in notes
    toks = note_tokens(note)
    all_tokens[note.id] = toks
    for t in Set(toks)
      df[t] = get(df, t, 0) + 1
    end
  end
  vocab = Dict(t => i for (i, t) in enumerate(sort(collect(keys(df)))))
  n = length(notes)
  idf = zeros(length(vocab))
  for (t, idx) in vocab
    idf[idx] = log(1 + n / get(df, t, 1))
  end
  vectors = Dict{String, Vector{Float64}}()
  for note in notes
    vec = tfidf_vector(vocab, idf, all_tokens[note.id])
    vectors[note.id] = vec
  end
  TFIDFIndex(vocab, idf, vectors)
end

function tfidf_vector(vocab, idf, tokens)
  vec = zeros(length(vocab))
  tf = Dict{String, Int}()
  for t in tokens; tf[t] = get(tf, t, 0) + 1 end
  for (t, count) in tf
    idx = get(vocab, t, 0)
    idx == 0 && continue
    vec[idx] = (1 + log(count)) * idf[idx]
  end
  n = norm(vec)
  n > 0 ? vec / n : vec
end

embed_query(index::TFIDFIndex, query) = tfidf_vector(index.vocab, index.idf, tokenize(query))

function score_semantic(index::TFIDFIndex, query::AbstractString)
  qvec = embed_query(index, query)
  scores = Dict{String, Float64}()
  for (id, vec) in index.vectors
    sim = dot(qvec, vec)
    sim > 0 && (scores[id] = sim)
  end
  scores
end

function has_title_overlap(query, title)
  qtokens = Set(tokenize(query))
  ttokens = Set(tokenize(title))
  !isempty(intersect(qtokens, ttokens))
end

function embed_new!(index::TFIDFIndex, notes::Dict{String, Note})
  notes_vec = collect(values(notes))
  new_index = build_tfidf(notes_vec)
  empty!(index.vocab); merge!(index.vocab, new_index.vocab)
  resize!(index.idf, length(new_index.idf)); index.idf .= new_index.idf
  empty!(index.vectors); merge!(index.vectors, new_index.vectors)
end
