@use "./docker" ensure_running is_running stop
@use "./hindsight" HindsightConn init retain recall reflect

function run_demo()
  println("╭───────────────────────────────────────────────────╮")
  println("│  Hindsight Memory Provider — Demo                 │")
  println("╰───────────────────────────────────────────────────╯")

  # Check Docker
  println("\n  Checking Docker...")
  docker_ok = try; success(`docker info`); catch; false end
  if !docker_ok
    println("  Docker not available. Install Docker to run this demo.")
    return
  end

  # Start container (auto-detects LLM provider from env: ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
  println("  Starting Hindsight container (auto-detecting LLM provider)...")
  if !ensure_running()
    println("  Failed to start Hindsight. Check Docker logs.")
    return
  end
  println("  Container running. Admin UI at http://localhost:9999")

  # Create a demo bank
  bank_id = "demo-$(rand(1000:9999))"
  println("\n  Creating bank: $bank_id")
  conn = init(bank_id; mission="Demo agent that remembers conversations about a software project")
  conn === nothing && (println("  Bank creation failed."); return)
  println("  Bank created.")

  # Simulate a conversation
  println("\n━━━ Simulating Conversation ━━━")
  turns = [
    "User: We decided to use PostgreSQL for the user database instead of MongoDB.\n\nAssistant: Good choice. PostgreSQL gives us better ACID compliance and the jsonb type handles our semi-structured data well.",
    "User: The auth service is hitting 50k requests per minute at peak. We need to add caching.\n\nAssistant: I'd recommend Redis for session caching with a 24-hour TTL. We can put it between the auth service and the database.",
    "User: We had an outage yesterday. Redis connection pool ran out under a traffic spike.\n\nAssistant: That's a common issue. We should increase the pool size, add connection recycling, and set up pool exhaustion alerts.",
    "User: Alice from the platform team is leading the migration to OAuth2 for enterprise SSO support.\n\nAssistant: That makes sense. OAuth2/OIDC will reduce our custom auth code significantly. Alice has good experience with identity providers.",
  ]

  for (i, turn) in enumerate(turns)
    println("\n  Retaining turn $i...")
    retain(conn, turn; context="engineering discussion")
    println("    Done.")
  end

  # Wait for processing
  println("\n  Waiting for Hindsight to process (5s)...")
  sleep(5)

  # Test recall
  println("\n━━━ Recall (Search) ━━━")
  queries = [
    "What database are we using?",
    "What happened with Redis?",
    "Who is working on OAuth2?",
  ]

  for query in queries
    println("\n  Query: \"$query\"")
    results = recall(conn, query; limit=3)
    if isempty(results)
      println("    (no results)")
    else
      for (i, r) in enumerate(results)
        text = get(r, "text", "")
        println("    $i. $(first(text, 120))")
      end
    end
  end

  # Test reflect
  println("\n\n━━━ Reflect (Synthesized Answer) ━━━")
  reflect_queries = [
    "Summarize our infrastructure decisions",
    "What are the current risks in our system?",
  ]

  for query in reflect_queries
    println("\n  Query: \"$query\"")
    answer = reflect(conn, query)
    if answer === nothing || isempty(answer)
      println("    (no answer)")
    else
      # Word-wrap at 80 chars with indent
      words = split(answer)
      line = "    "
      for w in words
        if length(line) + length(w) + 1 > 80
          println(line)
          line = "    $w"
        else
          line *= (length(line) > 4 ? " " : "") * w
        end
      end
      println(line)
    end
  end

  println("\n\n  Done. Bank '$bank_id' persists in Hindsight.")
  println("  View in admin UI: http://localhost:9999")
end

run_demo()
