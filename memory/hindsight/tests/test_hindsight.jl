@use Test: @test @testset

# Skip all tests if Docker is not available
docker_available = try; success(`docker info`); catch; false end
if !docker_available
  @info "Docker not available, skipping Hindsight tests"
  exit(0)
end

@use "../docker" ensure_running is_running stop
@use "../hindsight" HindsightConn init retain recall reflect

const TEST_BANK = "test-prosca-$(rand(1000:9999))"

@testset "Hindsight Docker" begin
  @testset "ensure_running starts container" begin
    key = get(ENV, "OPENAI_API_KEY", "")
    if isempty(key)
      @info "No OPENAI_API_KEY, skipping Docker start test"
      return
    end
    result = ensure_running(; llm_key=key)
    @test result == true
    @test is_running() == true
  end
end

# Skip remaining tests if container isn't running
if !is_running()
  @info "Hindsight container not running, skipping API tests"
  exit(0)
end

@testset "Hindsight Client" begin
  @testset "bank creation" begin
    conn = init(TEST_BANK; mission="Test agent memory")
    @test conn !== nothing
    @test conn isa HindsightConn
    @test conn.bank_id == TEST_BANK

    # Idempotent
    conn2 = init(TEST_BANK; mission="Test agent memory")
    @test conn2 !== nothing
  end

  @testset "retain and recall" begin
    conn = HindsightConn("http://localhost:8888", TEST_BANK)

    @test retain(conn, "Alice is a senior engineer at Google") == true
    @test retain(conn, "Bob works at Meta as a product manager") == true
    @test retain(conn, "Alice and Bob are working on a joint AI project") == true

    # Give Hindsight a moment to process
    sleep(3)

    results = recall(conn, "What does Alice do?")
    @test length(results) > 0
    @test any(r -> occursin("Alice", get(r, "text", "")), results)
  end

  @testset "reflect" begin
    conn = HindsightConn("http://localhost:8888", TEST_BANK)
    answer = reflect(conn, "Summarize what you know about Alice and Bob")
    @test answer !== nothing
    @test length(answer) > 0
  end

  @testset "empty recall on fresh bank" begin
    fresh_bank = "test-empty-$(rand(1000:9999))"
    conn = init(fresh_bank; mission="Empty test")
    @test conn !== nothing
    results = recall(conn, "anything at all")
    @test results isa Vector
  end

  @testset "retain failure handling" begin
    bad_conn = HindsightConn("http://localhost:1", "bad-bank")
    @test retain(bad_conn, "should fail") == false
  end
end
