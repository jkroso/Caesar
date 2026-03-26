# scheduler.jl — Cron parser and scheduler tick logic

@use Dates...
@use SQLite
@use UUIDs
@use JSON3

# ── Cron Parser ──────────────────────────────────────────────────────

struct CronExpr
  minutes::Set{Int}    # 0-59
  hours::Set{Int}      # 0-23
  days::Set{Int}       # 1-31
  months::Set{Int}     # 1-12
  weekdays::Set{Int}   # 0-6 (0=Sunday)
end

function parse_cron_field(field::AbstractString, min_val::Int, max_val::Int)::Set{Int}
  result = Set{Int}()
  for part in split(field, ',')
    part = strip(part)
    if part == "*"
      union!(result, min_val:max_val)
    elseif contains(part, "/")
      base, step_str = split(part, "/"; limit=2)
      step = parse(Int, step_str)
      start = base == "*" ? min_val : parse(Int, base)
      for v in start:step:max_val
        push!(result, v)
      end
    elseif contains(part, "-")
      lo, hi = split(part, "-"; limit=2)
      union!(result, parse(Int, lo):parse(Int, hi))
    else
      push!(result, parse(Int, part))
    end
  end
  result
end

function parse_cron(expr::String)::CronExpr
  fields = split(strip(expr))
  length(fields) == 5 || error("Cron expression must have 5 fields: $expr")
  CronExpr(
    parse_cron_field(fields[1], 0, 59),
    parse_cron_field(fields[2], 0, 23),
    parse_cron_field(fields[3], 1, 31),
    parse_cron_field(fields[4], 1, 12),
    parse_cron_field(fields[5], 0, 6),
  )
end

function matches_cron(cron::CronExpr, dt::DateTime)::Bool
  minute(dt) in cron.minutes &&
  hour(dt) in cron.hours &&
  day(dt) in cron.days &&
  month(dt) in cron.months &&
  dayofweek(dt) % 7 in cron.weekdays  # Julia dayofweek: Mon=1..Sun=7 → %7 gives 0=Sun
end

function next_cron_time(cron::CronExpr, after::DateTime)::DateTime
  # Start from next minute
  dt = ceil(after + Minute(1), Minute)
  # Search up to 366 days ahead
  limit = dt + Day(366)
  while dt < limit
    if matches_cron(cron, dt)
      return dt
    end
    dt += Minute(1)
  end
  error("No matching cron time found within 366 days")
end

# Convert local cron match to UTC for storage
function next_cron_time_utc(cron_expr::String, after_utc::DateTime)::DateTime
  cron = parse_cron(cron_expr)
  # Convert UTC reference to local time, find next match in local, convert back
  local_offset = Dates.value(now() - now(UTC)) ÷ 1000  # offset in seconds
  after_local = after_utc + Second(local_offset)
  next_local = next_cron_time(cron, after_local)
  next_local - Second(local_offset)  # back to UTC
end

# ── Model Resolution ─────────────────────────────────────────────────

function resolve_model(db::SQLite.DB, routine_model, project_id::String, global_model::String)::String
  if routine_model !== nothing && routine_model !== "" && routine_model !== missing
    return string(routine_model)
  end
  # Look up project model
  rows = SQLite.DBInterface.execute(db, "SELECT model FROM projects WHERE id=?", (project_id,)) |> SQLite.rowtable
  if length(rows) > 0 && rows[1].model !== missing && rows[1].model !== nothing && rows[1].model !== ""
    return string(rows[1].model)
  end
  global_model
end

# ── Unseen Count ─────────────────────────────────────────────────────

function unseen_notable_count(db::SQLite.DB)::Int
  rows = SQLite.DBInterface.execute(db,
    "SELECT COUNT(*) as c FROM routine_runs WHERE notable=1 AND seen=0") |> SQLite.rowtable
  rows[1].c
end

for n in names(@__MODULE__; all=true)
  n in (nameof(@__MODULE__), :eval, :include) && continue
  startswith(string(n), '#') && continue
  startswith(string(n), '⭒') && continue
  @eval export $n
end

