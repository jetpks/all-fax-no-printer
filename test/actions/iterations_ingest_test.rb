# frozen_string_literal: true

require_relative "action_test_helper"

# I15 structured-record mouths: POST /iterations/ingest/{freeze,lane,verdict,
# integration}. Bearer-authed, X-Space-Slug scoped, contract-strict
# (unknown keys rejected at every level, a 422 applies nothing), idempotent
# (an emission is the complete truth for its facet).
class IterationsIngestActionTest < Minitest::Test
  include ActionTestHelper

  GATE_EXPECT = {
    exit_code: 0,
    stdout_match: "RUBY_SUITE_OK",
    threshold: { match: "0 failures", op: ">=", value: 1 }
  }.freeze

  FREEZE_PAYLOAD = {
    iteration: {
      ordinal: 15, name: "structured-iterations-ingest", slug: nil,
      freeze_sha: "da7c509a", branch: "main", status: "frozen"
    },
    gates: [
      { id: "allfax-ruby-suite", ac: "AC2, AC10", cwd: "repos/all-fax-no-printer",
        cmd: "mise exec ruby@4.0.5 -- bundle exec rake test", timeout: 600, expect: GATE_EXPECT },
      { id: "iter-db-prepare", ac: "AC1", cmd: "bundle exec hanami db prepare" }
    ]
  }.freeze

  LANE_PAYLOAD = {
    iteration: { ordinal: 15, name: "structured-iterations-ingest" },
    lane: {
      name: "mouths", repo: "all-fax-no-printer", base_sha: "2d507c2",
      model: "openrouter/z-ai/glm-5.3-flash", harness: "pi", effort: "high",
      touch_set: ["config/routes.rb"], status: "complete", bounds_override_reason: nil,
      escalations: [{ topic: "branch semantics", ruling: "accept", note: "defaulted" }],
      gate_results: [
        { gate_id: "allfax-ruby-suite", status: "pass", reason: "", transcript: "465 runs" },
        { gate_id: "iter-db-prepare", status: "pass", reason: "rc=0" }
      ]
    }
  }.freeze

  VERDICT_PAYLOAD = {
    iteration: { ordinal: 15, name: "structured-iterations-ingest" },
    verdict: {
      decision: "continue",
      ac_rulings: [{ ac: "AC1", ruling: "PASS", note: "store green" }],
      phase0_resolutions: [{ lane: "mouths", topic: "branch semantics", resolution: "ACCEPT" }]
    }
  }.freeze

  INTEGRATION_PAYLOAD = {
    iteration: { ordinal: 15, name: "structured-iterations-ingest", status: "integrated" },
    integration: { branch: "main", lanes: [{ name: "mouths", merge_sha: "abc123", integration_branch: "main" }] }
  }.freeze

  RECORD_TABLES = %i[gates lanes gate_results verdicts verdict_rulings].freeze

  def setup
    setup_db
    %i[verdict_rulings verdicts gate_results gates lanes].each do |t|
      Space::Server::App["db.gateway"].connection[t].delete
    end
    @owner = Factory[:user, github_uid: "iter-owner", username: "iter_owner"]
    @other = Factory[:user, github_uid: "iter-other", username: "iter_other"]
    @repos = {
      spaces:     Space::Server::Repos::SpacesRepo.new,
      iterations: Space::Server::Repos::IterationsRepo.new,
      gates:      Space::Server::Repos::GatesRepo.new,
      lanes:      Space::Server::Repos::LanesRepo.new,
      gate_results: Space::Server::Repos::GateResultsRepo.new,
      verdicts:   Space::Server::Repos::VerdictsRepo.new,
      verdict_rulings: Space::Server::Repos::VerdictRulingsRepo.new
    }
  end

  # Symbols survive Marshal; hashes here carry symbol keys throughout.
  def deep_clone(payload)
    Marshal.load(Marshal.dump(payload))
  end

  def mint_token(user)
    Space::Server::App["repos.api_tokens_repo"].create(user_id: user.id, name: "cli")
  end

  def post_json(path, body, slug: "struct-iter", bearer: nil)
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      input: body
    )
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    env["HTTP_X_SPACE_SLUG"] = slug unless slug.nil?
    app.call(env)
  end

  def post_payload(path, payload, **opts) = post_json(path, JSON.generate(payload), **opts)

  def table_counts
    conn = Space::Server::App["db.gateway"].connection
    RECORD_TABLES.to_h { |t| [t, conn[t].count] }
  end

  def owner_space
    @repos[:spaces].upsert_by_slug(@owner.id, "struct-iter", title: "struct-iter")
  end

  # --- auth ------------------------------------------------------------------

  def test_no_bearer_returns_401_json_error
    status, _, body = post_json("/iterations/ingest/freeze", JSON.generate(FREEZE_PAYLOAD))
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_wrong_bearer_returns_401
    status, _, body = post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: "nope")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_missing_slug_returns_422
    secret, = mint_token(@owner)
    status, _, body = post_payload("/iterations/ingest/lane", LANE_PAYLOAD, slug: nil, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("X-Space-Slug")
  end

  def test_blank_slug_returns_422
    secret, = mint_token(@owner)
    status, _, _ = post_payload("/iterations/ingest/verdict", VERDICT_PAYLOAD, slug: "   ", bearer: secret)
    assert_equal 422, status
  end

  # --- freeze mouth ------------------------------------------------------------

  def test_freeze_happy_path_200_response_shape
    secret, = mint_token(@owner)
    status, headers, body = post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert_equal "struct-iter", data["space"]["slug"]
    assert_equal 15, data["iteration"]["ordinal"]
    assert_equal "structured-iterations-ingest", data["iteration"]["name"]
    assert_equal "da7c509a", data["iteration"]["freeze_sha"]
    assert_equal "frozen", data["iteration"]["status"]
    assert_equal 2, data["gates_applied"]
  end

  def test_freeze_byte_identical_repost_identical_row_counts
    secret, = mint_token(@owner)
    first_status, _, _ = post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    before = table_counts
    second_status, _, body = post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    assert_equal 200, first_status
    assert_equal 200, second_status
    assert_equal before, table_counts, "identical re-POST must change no row counts"
    assert_equal 2, parse_json(body)["gates_applied"]
  end

  def test_freeze_replace_set_leaves_no_stale_gates
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    pruned = FREEZE_PAYLOAD.merge(gates: [FREEZE_PAYLOAD[:gates].first])
    status, _, body = post_payload("/iterations/ingest/freeze", pruned, bearer: secret)
    assert_equal 200, status
    assert_equal 1, parse_json(body)["gates_applied"]
    space = owner_space
    assert_equal ["allfax-ruby-suite"], @repos[:gates].gate_ids_for_iteration(
      @repos[:iterations].for_space(space.id).first.id
    ), "stale gate must die"
  end

  def test_freeze_round_trip_stores_gates_verbatim
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    space = owner_space
    iteration = @repos[:iterations].for_space(space.id).first
    gates = @repos[:gates].for_iteration(iteration.id)
    gate = gates.find { |g| g.gate_id == "allfax-ruby-suite" }

    assert_equal "AC2, AC10", gate.ac
    assert_equal 600, gate.timeout.to_i
    # JSONB normalizes keys to strings; compare through a JSON round-trip.
    assert_equal JSON.parse(JSON.generate(GATE_EXPECT)), JSON.parse(JSON.generate(gate.expect))
  end

  def test_freeze_unknown_key_rejected_at_every_level
    secret, = mint_token(@owner)
    top = FREEZE_PAYLOAD.merge(bogus: 1)
    status, _, body = post_payload("/iterations/ingest/freeze", top, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("bogus")

    deep = FREEZE_PAYLOAD.merge(iteration: FREEZE_PAYLOAD[:iteration].merge(nope: "x"))
    status, _, body = post_payload("/iterations/ingest/freeze", deep, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("nope")

    in_gate = FREEZE_PAYLOAD.merge(gates: [FREEZE_PAYLOAD[:gates].first.merge(extra: true)])
    status, _, body = post_payload("/iterations/ingest/freeze", in_gate, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("extra")
  end

  def test_freeze_422_applies_nothing
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    before = table_counts
    bad = FREEZE_PAYLOAD.merge(gates: [{ id: "g3", ac: "AC1", cmd: "x", nope: 1 }])
    status, _, _ = post_payload("/iterations/ingest/freeze", bad, bearer: secret)
    assert_equal 422, status
    assert_equal before, table_counts, "a 422 must apply nothing"
  end

  # --- lane mouth ----------------------------------------------------------------

  def test_lane_happy_path_after_freeze_200
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    status, _, body = post_payload("/iterations/ingest/lane", LANE_PAYLOAD, bearer: secret)
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "mouths", data["lane"]["name"]
    assert_equal 2, data["gate_results_applied"]
    lane = @repos[:lanes].for_iteration(iteration_id_for(space: owner_space)).first
    assert_equal "complete", lane.status
    assert_equal ["config/routes.rb"], lane.touch_set
  end

  def test_lane_unknown_gate_id_422_lists_it_and_applies_nothing
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    before = table_counts
    bad = deep_clone(LANE_PAYLOAD)
    bad[:lane][:gate_results] = [{ gate_id: "not-a-gate", status: "pass" }]
    status, _, body = post_payload("/iterations/ingest/lane", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("not-a-gate")
    assert_equal before, table_counts, "a 422 must apply nothing — no lane row, no gate_results"
  end

  def test_lane_gate_result_status_outside_pass_fail_422
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    bad = deep_clone(LANE_PAYLOAD)
    bad[:lane][:gate_results] = [{ gate_id: "allfax-ruby-suite", status: "green" }]
    status, _, _ = post_payload("/iterations/ingest/lane", bad, bearer: secret)
    assert_equal 422, status
  end

  def test_lane_changed_repost_updates_in_place
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    _, _, body1 = post_payload("/iterations/ingest/lane", LANE_PAYLOAD, bearer: secret)
    lane_id = parse_json(body1)["lane"]["id"]
    changed = deep_clone(LANE_PAYLOAD)
    changed[:lane][:status] = "integrated"
    changed[:lane][:gate_results] = [{ gate_id: "allfax-ruby-suite", status: "fail", reason: "red" }]
    status, _, body2 = post_payload("/iterations/ingest/lane", changed, bearer: secret)
    assert_equal 200, status
    assert_equal lane_id, parse_json(body2)["lane"]["id"], "same lane row updated"
    lane = @repos[:lanes].by_pk(lane_id)
    assert_equal "integrated", lane.status
    results = @repos[:gate_results].for_lane(lane_id)
    assert_equal 1, results.size, "replace set: stale result dies"
    assert_equal "fail", results.first.status
  end

  def test_lane_before_freeze_creates_iteration_and_lane_stubs
    secret, = mint_token(@owner)
    status, _, body = post_payload("/iterations/ingest/lane", LANE_PAYLOAD_WITHOUT_RESULTS, bearer: secret)
    assert_equal 200, status
    space = owner_space
    iterations = @repos[:iterations].for_space(space.id)
    assert_equal 1, iterations.size, "iteration stub created order-tolerantly"
    assert_equal "structured-iterations-ingest", iterations.first.name
    lanes = @repos[:lanes].for_iteration(iterations.first.id)
    assert_equal ["mouths"], lanes.map(&:name), "lane stub created order-tolerantly"
  end

  LANE_PAYLOAD_WITHOUT_RESULTS = JSON.parse(JSON.generate(LANE_PAYLOAD), symbolize_names: true).tap do |payload|
    payload[:lane].delete(:gate_results)
    payload[:lane].delete(:escalations)
  end.freeze

  def test_lane_unknown_key_rejected
    secret, = mint_token(@owner)
    bad = deep_clone(LANE_PAYLOAD)
    bad[:lane][:wat] = 1
    status, _, body = post_payload("/iterations/ingest/lane", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("wat")
  end

  # --- verdict mouth ---------------------------------------------------------------

  def test_verdict_happy_path_200
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    status, _, body = post_payload("/iterations/ingest/verdict", VERDICT_PAYLOAD, bearer: secret)
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "continue", data["verdict"]["decision"]
    assert_equal 1, data["ac_rulings_applied"]
    space = owner_space
    iteration = @repos[:iterations].for_space(space.id).first
    verdict = @repos[:verdicts].for_iteration(iteration.id)
    assert_equal "continue", verdict.decision
    assert_equal 1, @repos[:verdict_rulings].for_verdict(verdict.id).size
  end

  def test_verdict_mirrors_onto_iterations_verdict_column
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    post_payload("/iterations/ingest/verdict", VERDICT_PAYLOAD, bearer: secret)
    iteration = @repos[:iterations].for_space(owner_space.id).first
    assert_equal "continue", iteration.verdict, "decision must mirror onto iterations.verdict"
  end

  def test_verdict_decision_outside_continue_kill_422
    secret, = mint_token(@owner)
    bad = deep_clone(VERDICT_PAYLOAD)
    bad[:verdict][:decision] = "proceed"
    status, _, _ = post_payload("/iterations/ingest/verdict", bad, bearer: secret)
    assert_equal 422, status
  end

  def test_verdict_rulings_replace_set_on_repost
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    post_payload("/iterations/ingest/verdict", VERDICT_PAYLOAD, bearer: secret)
    reposted = deep_clone(VERDICT_PAYLOAD)
    reposted[:verdict][:decision] = "kill"
    reposted[:verdict][:ac_rulings] = [{ ac: "AC9", ruling: "NOT-APPLICABLE" }]
    reposted[:verdict].delete(:phase0_resolutions)
    status, _, body = post_payload("/iterations/ingest/verdict", reposted, bearer: secret)
    assert_equal 200, status
    assert_equal 1, parse_json(body)["ac_rulings_applied"]
    space = owner_space
    iteration = @repos[:iterations].for_space(space.id).first
    assert_equal "kill", iteration.verdict, "mirror follows the latest emission"
    verdict = @repos[:verdicts].for_iteration(iteration.id)
    assert_equal 1, conn_count(:verdicts), "still one verdict row per iteration"
    assert_equal ["AC9"], @repos[:verdict_rulings].for_verdict(verdict.id).map(&:ac), "stale ruling dies"
    assert_equal 1, verdict.phase0_resolutions.size, "absent child set leaves stored rows untouched"
  end

  def test_verdict_before_freeze_creates_iteration_stub
    secret, = mint_token(@owner)
    status, _, _ = post_payload("/iterations/ingest/verdict", VERDICT_PAYLOAD, bearer: secret)
    assert_equal 200, status
    iterations = @repos[:iterations].for_space(owner_space.id)
    assert_equal 1, iterations.size
    assert_equal "structured-iterations-ingest", iterations.first.name
  end

  def test_verdict_unknown_key_rejected
    secret, = mint_token(@owner)
    bad = deep_clone(VERDICT_PAYLOAD)
    bad[:verdict][:ruling_override] = "x"
    status, _, body = post_payload("/iterations/ingest/verdict", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("ruling_override")
  end

  # --- integration mouth ---------------------------------------------------------------

  def test_integration_happy_path_200
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/lane", LANE_PAYLOAD_WITHOUT_RESULTS, bearer: secret)
    status, _, body = post_payload("/iterations/ingest/integration", INTEGRATION_PAYLOAD, bearer: secret)
    assert_equal 200, status
    assert_equal 1, parse_json(body)["lanes_integrated"]
    space = owner_space
    lane = @repos[:lanes].for_iteration(@repos[:iterations].for_space(space.id).first.id).first
    assert_equal "abc123", lane.merge_sha
    assert_equal "main", lane.integration_branch
    refute_nil lane.integrated_at
    iteration = @repos[:iterations].for_space(space.id).first
    assert_equal "integrated", iteration.status
  end

  def test_integration_before_any_lane_creates_lane_stub
    secret, = mint_token(@owner)
    status, _, _ = post_payload("/iterations/ingest/integration", INTEGRATION_PAYLOAD, bearer: secret)
    assert_equal 200, status
    lanes = @repos[:lanes].for_iteration(@repos[:iterations].for_space(owner_space.id).first.id)
    assert_equal ["mouths"], lanes.map(&:name), "stub lane row created order-tolerantly"
    assert_equal "abc123", lanes.first.merge_sha
  end

  def test_integration_empty_lanes_422
    secret, = mint_token(@owner)
    bad = deep_clone(INTEGRATION_PAYLOAD)
    bad[:integration][:lanes] = []
    status, _, _ = post_payload("/iterations/ingest/integration", bad, bearer: secret)
    assert_equal 422, status
  end

  def test_integration_unknown_key_rejected
    secret, = mint_token(@owner)
    bad = deep_clone(INTEGRATION_PAYLOAD)
    bad[:integration][:lanes] = [{ name: "mouths", frob: 1 }]
    status, _, body = post_payload("/iterations/ingest/integration", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("frob")
  end

  # --- whole-record idempotency ---------------------------------------------------------

  def test_full_sequence_byte_identical_repost_identical_row_counts
    secret, = mint_token(@owner)
    sequence = [
      ["/iterations/ingest/freeze", FREEZE_PAYLOAD],
      ["/iterations/ingest/lane", LANE_PAYLOAD],
      ["/iterations/ingest/verdict", VERDICT_PAYLOAD],
      ["/iterations/ingest/integration", INTEGRATION_PAYLOAD]
    ]
    sequence.each do |path, payload|
      status, _, _ = post_payload(path, payload, bearer: secret)
      assert_equal 200, status, path
    end
    before = table_counts
    sequence.each do |path, payload|
      status, _, _ = post_payload(path, payload, bearer: secret)
      assert_equal 200, status, path
    end
    assert_equal before, table_counts, "identical re-POST of the full record must change no row counts"
  end

  # --- owner scoping ----------------------------------------------------------------------

  def test_same_slug_other_user_gets_own_space_and_owner_rows_untouched
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    owner_counts = table_counts

    other_secret, = mint_token(@other)
    status, _, body = post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: other_secret)
    assert_equal 200, status
    assert_equal "struct-iter", parse_json(body)["space"]["slug"]

    spaces = Space::Server::App["db.gateway"].connection[:spaces].where(slug: "struct-iter").to_a
    assert_equal 2, spaces.size, "user B's same slug gets their OWN space"
    owner_counts.each do |table, count|
      assert_equal count, Space::Server::App["db.gateway"].connection[table].count / 2,
        "user A's #{table} rows untouched (user B mirrors them in their own space)"
    end
  end

  private

  def conn_count(table)
    Space::Server::App["db.gateway"].connection[table].count
  end

  def iteration_id_for(space:)
    @repos[:iterations].for_space(space.id).first.id
  end
end
