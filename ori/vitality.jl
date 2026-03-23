@use SQLite
@use JSON3
@use Dates: DateTime, now, UTC, Millisecond

# ACT-R Base-Level Learning: B_i = ln(Σ t_j^(-d))
function base_level(access_times::Vector{DateTime}; d=0.5, t_now=now(UTC))
  isempty(access_times) && return 0.0
  total = 0.0
  for t in access_times
    age = max(1.0, Dates.value(Millisecond(t_now - t)) / 1000.0)
    total += age^(-d)
  end
  log(max(total, 1e-30))
end

vitality_score(bl) = 1.0 / (1.0 + exp(-bl))

function record_access!(db::SQLite.DB, note_id::AbstractString)
  row = SQLite.DBInterface.execute(db,
    "SELECT access_times FROM vitality WHERE note_id = ?", (note_id,)) |> collect
  raw = isempty(row) ? missing : row[1].access_times
  times = (raw === missing || raw === nothing) ? DateTime[] : JSON3.read(raw, Vector{DateTime})
  push!(times, now(UTC))
  length(times) > 100 && (times = times[end-99:end])
  t = JSON3.write(times)
  SQLite.execute(db, """
    INSERT INTO vitality (note_id, access_times) VALUES (?, ?)
    ON CONFLICT(note_id) DO UPDATE SET access_times = ?
  """, (note_id, t, t))
end

function get_vitality(db::SQLite.DB, note_id::AbstractString; structural_boost=0)
  row = SQLite.DBInterface.execute(db,
    "SELECT access_times, decay_rate FROM vitality WHERE note_id = ?", (note_id,)) |> collect
  isempty(row) && return 0.5
  raw = row[1].access_times
  times = (raw === missing || raw === nothing) ? DateTime[] : JSON3.read(raw, Vector{DateTime})
  d = coalesce(row[1].decay_rate, 0.5) / (1.0 + 0.1 * min(structural_boost, 10))
  vitality_score(base_level(times; d))
end

function get_all_vitality(db::SQLite.DB, incoming::Dict{String, Set{String}})
  result = Dict{String, Float64}()
  for row in SQLite.DBInterface.execute(db, "SELECT note_id, access_times, decay_rate FROM vitality")
    raw = row.access_times
    times = (raw === missing || raw === nothing) ? DateTime[] : JSON3.read(raw, Vector{DateTime})
    boost = length(get(incoming, row.note_id, Set{String}()))
    d = coalesce(row.decay_rate, 0.5) / (1.0 + 0.1 * min(boost, 10))
    result[row.note_id] = vitality_score(base_level(times; d))
  end
  result
end
