@use "./types" Note
@use "./vault" write_note
@use "./engine" Engine init_engine search flat_search record_feedback! record_session!

# ── Sample Vault ─────────────────────────────────────────────────────
# A fictional engineering team's knowledge base with rich wiki-link structure

const SAMPLE_NOTES = [
  Note(title="Auth Service",
       description="Core authentication microservice",
       type=:note,
       body="""Our authentication service handles all user login and token management.
It relies on [[JWT Tokens]] for stateless auth and stores user credentials in the [[User Database]].
The service processes ~50k requests/minute at peak and is the gateway for all API access.
We're currently evaluating [[OAuth2 Migration]] to support third-party integrations."""),

  Note(title="JWT Tokens",
       description="JSON Web Token implementation details",
       type=:note,
       body="""We use RS256-signed JWTs with 15-minute expiry. Refresh tokens are stored in [[Session Management]].
The signing keys rotate weekly via an automated process.
Token validation happens in the [[Auth Service]] middleware layer.
Known issue: token size grows with claims — we need to audit what's included."""),

  Note(title="Session Management",
       description="Redis-backed session handling",
       type=:note,
       body="""Sessions are managed through [[Redis Cache]] with a 24-hour TTL.
Each session stores the refresh token, device fingerprint, and last-active timestamp.
The session service connects to [[JWT Tokens]] for token refresh flows.
We maintain ~200k concurrent sessions during business hours."""),

  Note(title="Redis Cache",
       description="Caching infrastructure layer",
       type=:note,
       body="""Redis 7.2 cluster with 3 primaries and 3 replicas. Used for session storage,
API rate limiting, and feature flags.
Connected to [[Infrastructure]] monitoring via Prometheus exporters.
We recently completed [[Performance Tuning]] to optimize memory usage.
The connection pool was the root cause of the [[March 15 Outage]]."""),

  Note(title="User Database",
       description="PostgreSQL user credential store",
       type=:note,
       body="""PostgreSQL 15 with pgcrypto for password hashing. Stores ~2M user records.
Schema changes go through [[Database Migrations]] with zero-downtime rollouts.
The [[Auth Service]] reads from a read replica for login verification.
Considering sharding once we hit 10M users."""),

  Note(title="Database Migrations",
       description="Schema change management process",
       type=:note,
       body="""We use Flyway for versioned migrations against the [[User Database]].
All migrations must be backward-compatible for at least one release cycle.
The migration runner is integrated into our [[Deployment Pipeline]].
Last major migration: added MFA columns (took 3 hours on production)."""),

  Note(title="Infrastructure",
       description="Cloud infrastructure overview",
       type=:note,
       body="""Running on AWS EKS with Terraform-managed infrastructure.
Key components: [[Deployment Pipeline]] for CI/CD, [[Monitoring]] for observability.
We spend ~\$45k/month on compute, with Redis being the largest single cost.
DR strategy: multi-AZ with automated failover."""),

  Note(title="Deployment Pipeline",
       description="CI/CD process and tooling",
       type=:note,
       body="""GitHub Actions → Docker build → ECR → ArgoCD → EKS.
The pipeline runs [[Infrastructure]] validation via Terraform plan.
Canary deployments with 5% traffic for 30 minutes before full rollout.
Average deploy time: 12 minutes from merge to production."""),

  Note(title="Monitoring",
       description="Observability stack",
       type=:note,
       body="""Grafana + Prometheus + Loki stack. Dashboards for all services.
Connected to [[Infrastructure]] health checks and [[Incident Response]] alerting.
Key SLOs: p99 latency < 200ms, error rate < 0.1%.
PagerDuty integration for on-call rotation."""),

  Note(title="Incident Response",
       description="How we handle production incidents",
       type=:note,
       body="""Structured incident response process with Incident Commander rotation.
[[Monitoring]] triggers PagerDuty alerts based on SLO burn rates.
Post-incident reviews are mandatory within 48 hours.
Recent example: [[March 15 Outage]] — our most significant incident this quarter."""),

  Note(title="March 15 Outage",
       description="Service went down for 2 hours due to Redis connection pool exhaustion",
       type=:decision,
       body="""The service went down on March 15 due to [[Redis Cache]] connection pool exhaustion.
The outage lasted 2 hours. Root cause: a traffic spike caused the Redis connection pool to run out.
Timeline: 14:23 UTC alerts fired, 14:31 IC engaged, 16:22 fully resolved.
Impact: the service was down for ~5% of requests. Users reported failed logins.
[[Session Management]] was the primary victim — users couldn't refresh tokens.
Actions taken: increased pool size, added connection recycling, added pool exhaustion alerts.
Decision: invest in [[Performance Tuning]] and circuit breakers for Redis problems.
Lessons learned: our [[Incident Response]] process worked well but detection was 8 minutes slow."""),

  Note(title="Performance Tuning",
       description="Optimization efforts across the stack",
       type=:learning,
       body="""Recent optimization work focused on [[Redis Cache]] and [[User Database]].
Redis: switched from standalone to cluster mode, reduced memory 40% with key compression.
PostgreSQL: added partial indexes for active users, query time dropped 60%.
Next: evaluate connection pooling with PgBouncer.
These changes were partly motivated by findings from the [[March 15 Outage]]."""),

  Note(title="OAuth2 Migration",
       description="Planning migration from custom JWT to OAuth2/OIDC",
       type=:decision,
       body="""Proposal to migrate from custom [[JWT Tokens]] to standard OAuth2/OIDC.
Motivation: support SSO for enterprise customers, reduce custom auth code.
Impact on [[Auth Service]]: major refactor of token issuance and validation.
Timeline: Q3 planning, Q4 implementation.
Risk: session format changes could affect [[Session Management]].
Decision pending leadership review."""),
]

# ── Demo Runner ──────────────────────────────────────────────────────

function create_demo_vault(dir)
  for note in SAMPLE_NOTES
    write_note(dir, note)
  end
end

function format_signals(signals::Dict{Symbol, Float64})
  parts = String[]
  for sig in [:bm25, :semantic, :pagerank, :warmth]
    v = get(signals, sig, 0.0)
    v > 0 && push!(parts, "$(sig)=$(round(v; digits=3))")
  end
  join(parts, "  ")
end

function run_query(engine, query; top_k=5, show_flat=true)
  println("\n━━━ Query: \"$(query)\" ━━━")
  intent = @use("./intent").classify_intent(query)
  println("  Intent: $(intent.type)")

  results = search(engine, query; top_k)
  println("\n  Graph-aware results:")
  for (i, r) in enumerate(results)
    marker = all(v -> v == 0, get(r.signals, :bm25, 0.0)) &&
             get(r.signals, :semantic, 0.0) == 0 ? "  ← graph-discovered" :
             get(r.signals, :pagerank, 0.0) > get(r.signals, :semantic, 0.0) + get(r.signals, :bm25, 0.0) ?
             "  ← graph-boosted" : ""
    # Check if this was found primarily through graph
    pg = get(r.signals, :pagerank, 0.0)
    direct = get(r.signals, :bm25, 0.0) + get(r.signals, :semantic, 0.0)
    if pg > 0 && direct == 0
      marker = "  ← graph-discovered"
    elseif pg > direct && pg > 0
      marker = "  ← graph-boosted"
    end
    score_str = rpad(round(r.score; digits=3), 6)
    title_str = rpad(r.title, 30)
    println("    $(i). $(title_str) $(score_str) [$(format_signals(r.signals))]$(marker)")
  end

  if show_flat
    flat = flat_search(engine, query; top_k)
    println("\n  Flat search (semantic only):")
    for (i, r) in enumerate(flat)
      score_str = rpad(round(r.score; digits=3), 6)
      title_str = rpad(r.title, 30)
      println("    $(i). $(title_str) $(score_str)")
    end
    # Count graph-exclusive finds
    flat_ids = Set(r.id for r in flat)
    graph_ids = Set(r.id for r in results)
    exclusive = setdiff(graph_ids, flat_ids)
    if !isempty(exclusive)
      names = [engine.notes[id].title for id in exclusive if haskey(engine.notes, id)]
      println("\n  Graph retrieval surfaced $(length(exclusive)) note(s) flat search missed: $(join(names, ", "))")
    end
  end
  results
end

function run_demo()
  dir = mktempdir()
  println("╭─────────────────────────────────────────────────╮")
  println("│  Ori Memory System — Julia Implementation Demo  │")
  println("╰─────────────────────────────────────────────────╯")

  # Create vault
  create_demo_vault(dir)
  engine = init_engine(dir)
  n_notes = length(engine.notes)
  n_links = sum(length(links) for links in values(engine.graph.outgoing))
  n_bridges = length(engine.bridges)
  println("\n  Vault: $(n_notes) notes, $(n_links) wiki-links, $(n_bridges) bridge nodes")
  println("  Bridge nodes: ", join([engine.graph.titles[id] for id in engine.bridges], ", "))

  # Query 1: Multi-hop — outage investigation
  r1 = run_query(engine, "Why did the service go down?")

  # Query 2: Conceptual — auth architecture
  r2 = run_query(engine, "How does authentication work?")

  # Query 3: Infrastructure risk assessment
  r3 = run_query(engine, "What are the infrastructure risks and bottlenecks?")

  # Simulate learning: user finds outage-related notes useful across multiple sessions
  println("\n\n━━━ Learning Demo ━━━")
  println("  Simulating usage: marking outage-related notes as useful across 5 sessions...")
  outage_ids = [id for (id, n) in engine.notes
                if n.title in ("March 15 Outage", "Redis Cache", "Session Management",
                               "Performance Tuning", "Incident Response")]
  for _ in 1:5
    for id in outage_ids
      record_feedback!(engine, id, 1.0)
    end
    record_session!(engine, outage_ids)
    engine.total_queries += 2  # simulate more queries for lambda growth
  end

  # Re-query to show learned Q-values now boost relevant notes
  println("  Re-querying — Q-values should now boost previously useful notes...")
  run_query(engine, "What caused the Redis problems?"; show_flat=false)

  # Cleanup
  rm(dir; recursive=true)
  println("\n  Done.")
end

run_demo()
