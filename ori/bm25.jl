@use "./types" Note

struct BM25Index
  docs::Vector{Dict{String, Int}}   # term frequencies per doc
  df::Dict{String, Int}             # document frequency
  avgdl::Float64
  n::Int
  ids::Vector{String}
end

const STOPWORDS = Set(["a","an","the","is","are","was","were","be","been","being",
  "have","has","had","do","does","did","will","would","shall","should",
  "i","you","he","she","it","we","they","me","him","her","us","them",
  "my","your","his","its","our","their","this","that","these","those",
  "and","but","or","nor","not","so","yet","if","then","else",
  "of","with","by","as","at","in","on","to","for","from",
  "how","what","when","where","which","who","whom","why"])

tokenize(text) = filter(∉(STOPWORDS), [lowercase(m.match) for m in eachmatch(r"[a-zA-Z0-9]+", text)])

function build_bm25(notes::Vector{Note})
  docs = Dict{String, Int}[]
  df = Dict{String, Int}()
  total_len = 0
  ids = String[]
  for note in notes
    # Field-weighted: title 3x, description 2x, body 1x
    tokens = vcat(repeat(tokenize(note.title), 3),
                  repeat(tokenize(note.description), 2),
                  tokenize(note.body))
    tf = Dict{String, Int}()
    for t in tokens; tf[t] = get(tf, t, 0) + 1 end
    push!(docs, tf)
    push!(ids, note.id)
    total_len += length(tokens)
    for t in keys(tf); df[t] = get(df, t, 0) + 1 end
  end
  BM25Index(docs, df, length(notes) > 0 ? total_len / length(notes) : 0.0, length(notes), ids)
end

function score_bm25(index::BM25Index, query::AbstractString; k1=1.2, b=0.75)
  qtokens = tokenize(query)
  scores = Dict{String, Float64}()
  for (i, doc) in enumerate(index.docs)
    dl = sum(values(doc); init=0)
    s = 0.0
    for t in qtokens
      tf = get(doc, t, 0)
      tf == 0 && continue
      n_t = get(index.df, t, 0)
      idf = log((index.n - n_t + 0.5) / (n_t + 0.5) + 1)
      s += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / max(index.avgdl, 1e-10)))
    end
    s > 0 && (scores[index.ids[i]] = s)
  end
  scores
end
