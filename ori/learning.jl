@use SQLite
@use JSON3
@use LinearAlgebra: norm
@use Dates: now, UTC

# ── Q-Value Learning ─────────────────────────────────────────────────
# Notes earn Q-values from session outcomes via exponential moving average

function get_qvalue(db::SQLite.DB, note_id::AbstractString)
  row = SQLite.DBInterface.execute(db,
    "SELECT value, count, exposure_count FROM qvalues WHERE note_id = ?", (note_id,)) |> collect
  isempty(row) && return (value=0.0, count=0, exposure=0)
  r = row[1]
  (value=Float64(coalesce(r.value, 0.0)),
   count=Int(coalesce(r.count, 0)),
   exposure=Int(coalesce(r.exposure_count, 0)))
end

function update_qvalue!(db::SQLite.DB, note_id::AbstractString, reward::Float64; alpha=0.1)
  q = get_qvalue(db, note_id)
  new_val = (1 - alpha) * q.value + alpha * (reward / sqrt(max(1, q.exposure)))
  SQLite.execute(db, """
    INSERT INTO qvalues (note_id, value, count, exposure_count) VALUES (?, ?, 1, 1)
    ON CONFLICT(note_id) DO UPDATE SET
      value = ?, count = count + 1, exposure_count = exposure_count + 1
  """, (note_id, new_val, new_val))
end

function record_exposure!(db::SQLite.DB, note_id::AbstractString)
  SQLite.execute(db, """
    INSERT INTO qvalues (note_id, value, count, exposure_count) VALUES (?, 0, 0, 1)
    ON CONFLICT(note_id) DO UPDATE SET exposure_count = exposure_count + 1
  """, (note_id,))
end

# UCB-Tuned exploration bonus
function ucb_bonus(db::SQLite.DB, note_id::AbstractString; total_queries=1, c=1.0)
  q = get_qvalue(db, note_id)
  q.count == 0 && return c  # max exploration for unvisited
  c * sqrt(log(max(1, total_queries)) / q.count)
end

function rerank_with_qvalues(db::SQLite.DB, results, total_queries; lambda=0.3)
  map(results) do r
    q = get_qvalue(db, r.id)
    bonus = ucb_bonus(db, r.id; total_queries)
    boosted = r.score + lambda * (q.value + bonus)
    typeof(r)(r.id, r.title, boosted, r.signals)
  end
end

# ── Co-occurrence (Hebbian Learning) ─────────────────────────────────
# Notes retrieved together grow co-occurrence edges

function record_cooccurrence!(db::SQLite.DB, ids::Vector{String})
  t = string(now(UTC))
  for i in 1:length(ids), j in i+1:length(ids)
    a, b = minmax(ids[i], ids[j])
    SQLite.execute(db, """
      INSERT INTO cooccurrence (source_id, target_id, weight, count, last_seen)
      VALUES (?, ?, 1.0, 1, ?)
      ON CONFLICT(source_id, target_id) DO UPDATE SET
        weight = weight + 1.0 / (1.0 + count),
        count = count + 1,
        last_seen = ?
    """, (a, b, t, t))
  end
end

function get_cooccurrence_neighbors(db::SQLite.DB, note_id::AbstractString; min_weight=0.5)
  results = Dict{String, Float64}()
  for row in SQLite.DBInterface.execute(db, """
    SELECT source_id, target_id, weight FROM cooccurrence
    WHERE (source_id = ? OR target_id = ?) AND weight >= ?
  """, (note_id, note_id, min_weight))
    other = row.source_id == note_id ? row.target_id : row.source_id
    results[other] = row.weight
  end
  results
end

# ── LinUCB Contextual Bandit (Stage Meta-Learning) ───────────────────
# Each pipeline stage wrapped in a bandit that learns when to activate

struct LinUCBBandit
  dim::Int
  A_inv::Matrix{Float64}
  b::Vector{Float64}
  count::Int
end

LinUCBBandit(dim::Int) = LinUCBBandit(dim, Matrix{Float64}(I, dim, dim), zeros(dim), 0)

# I matrix needs LinearAlgebra
using LinearAlgebra: I

function bandit_score(bandit::LinUCBBandit, context::Vector{Float64}; alpha=1.0)
  theta = bandit.A_inv * bandit.b
  exploit = dot(theta, context)
  explore = alpha * sqrt(context' * bandit.A_inv * context)
  exploit + explore
end

function bandit_update(bandit::LinUCBBandit, context::Vector{Float64}, reward::Float64)
  x = reshape(context, :, 1)
  A_inv_new = bandit.A_inv - (bandit.A_inv * x * x' * bandit.A_inv) / (1 + (x' * bandit.A_inv * x)[1])
  b_new = bandit.b + reward * context
  LinUCBBandit(bandit.dim, A_inv_new, b_new, bandit.count + 1)
end

# Query feature vector for bandit context (8 dimensions)
function query_features(query::AbstractString)
  words = split(lowercase(query))
  n = length(words)
  Float64[
    n,                                          # query length
    count(w -> length(w) > 6, words) / max(n,1), # long word ratio
    occursin(r"\?", query) ? 1.0 : 0.0,         # is question
    occursin(r"how|what|why|when"i, query) ? 1.0 : 0.0, # has question word
    occursin(r"bug|error|fail|broke"i, query) ? 1.0 : 0.0, # is debug
    occursin(r"should|decide|choose"i, query) ? 1.0 : 0.0, # is decision
    min(n / 10.0, 1.0),                          # normalized length
    occursin(r"[A-Z]{2,}", query) ? 1.0 : 0.0,  # has acronym
  ]
end
