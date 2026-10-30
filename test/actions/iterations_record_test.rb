# frozen_string_literal: true

require_relative "action_test_helper"

# I15 lane `surface` — the record read: GET /spaces/:id/iterations/:ordinal.
# Owner-scoped (session OR bearer via authenticated_user); anonymous,
# non-owner, unknown space, unknown ordinal → 404 JSON. 200 serves the FULL
# structured record — the one surface where transcripts appear.
class IterationsRecordActionTest < Minitest::Test
  include ActionTestHelper

  GATE_EXPECT = { exit_code: 0, stdout_match: "RUBY_SUITE_OK" }.freeze

  FREEZE_PAYLOAD = {
    iteration: {
      ordinal: 7, name: "structured-iterations-ingest", slug: nil,
      freeze_sha: "da7c509a", branch: "main", status: "frozen"
    },
    gates: [
      { id: "allfax-ruby-suite", ac: "AC2", cwd: "repos/all-fax-no-printer",
        cmd: "mise exec ruby@4.0.5 -- bundle exec rake test", timeout: 600, expect: GATE_EXPECT },
      { id: "iter-db-prepare", ac: "AC1", cmd: "bundle exec hanami db prepare" }
    ]
  }.freeze

  LANE_PAYLOAD = {
    iteration: { ordinal: 7, name: "structured-iterations-ingest" },
    lane: {
      name: "surface", repo: "all-fax-no-printer", base_sha: "7398ccc",
      model: "openrouter/z-ai/glm-5.3-flash", harness: "pi", effort: "high",
      touch_set: ["config/routes.rb", "app/actions/spaces/show.rb"], status: "complete",
      bounds_override_reason: nil, escalations: [],
      gate_results: [
        { gate_id: "allfax-ruby-suite", status: "pass", reason: "",
          transcript: "465 runs, 0 failures, 0 errors, 0 skips" },
        { gate_id: "iter-db-prepare", status: "pass", reason: "rc=0" }
      ]
    }
  }.freeze

  VERDICT_PAYLOAD = {
    iteration: { ordinal: 7, name: "structured-iterations-ingest" },
    verdict: {
      decision: "continue",
      ac_rulings: [{ ac: "AC1", ruling: "pass", note: "store green" }],
      phase0_resolutions: []
    }
  }.freeze

  INTEGRATION_PAYLOAD = {
    iteration: { ordinal: 7, name: "structured-iterations-ingest", status: "integrated" },
    integration: { branch: "main", lanes: [{ name: "surface", merge_sha: "abc123", integration_branch: "main" }] }
  }.freeze

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i15-record-owner", username: "i15-record-owner"]
    @other = Factory[:user, github_uid: "i15-record-other", username: "i15-record-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def mint_token(user)
    Space::Server::App["repos.api_tokens_repo"].create(user_id: user.id, name: "cli")
  end

  # GET with a bearer header — ActionTestHelper#get carries cookies only.
  def get_with_bearer(path, bearer: nil)
    env = Rack::MockRequest.env_for(path, "REQUEST_METHOD" => "GET")
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    app.call(env)
  end

  def post_payload(path, payload, bearer:)
    body = JSON.generate(payload)
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      input: body
    )
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    env["HTTP_X_SPACE_SLUG"] = "record-iter" if bearer
    app.call(env)
  end

  # Seed through the sibling's four mouths (bearer) — the store ends up exactly
  # as ENTRY 2 will leave it: freeze + lane + verdict + integration.
  def seed_store
    secret, = mint_token(@owner)
    %w[freeze lane verdict integration].zip(
      [FREEZE_PAYLOAD, LANE_PAYLOAD, VERDICT_PAYLOAD, INTEGRATION_PAYLOAD]
    ).each do |mouth, payload|
      status, _, body = post_payload("/iterations/ingest/#{mouth}", payload, bearer: secret)
      assert_equal 200, status, "#{mouth} seeding failed: #{body}"
    end
    secret
  end

  def owner_space
    Space::Server::App["repos.spaces_repo"].by_pk(
      Space::Server::App["repos.spaces_repo"].list_visible_to(@owner).first.id
    )
  end

  # --- 404s -------------------------------------------------------------------

  def test_record_anonymous_returns_404_json
    status, _, body = get_with_bearer("/spaces/1/iterations/7")
    assert_equal 404, status
    assert parse_json(body).key?("error"), "anonymous read must be a JSON 404"
  end

  def test_record_non_owner_session_returns_404
    space = Factory[:space, user_id: @owner.id, slug: "record-iter"]
    Factory[:iteration, space_id: space.id, ordinal: 7, name: "iter-seven"]
    sign_in(@other)

    status, _, body = get_with_bearer("/spaces/#{space.id}/iterations/7")
    assert_equal 404, status
    assert parse_json(body).key?("error")
  end

  def test_record_non_owner_bearer_returns_404
    space = Factory[:space, user_id: @owner.id, slug: "record-iter"]
    Factory[:iteration, space_id: space.id, ordinal: 7, name: "iter-seven"]
    secret, = mint_token(@other)

    status, _, _ = get_with_bearer("/spaces/#{space.id}/iterations/7", bearer: secret)
    assert_equal 404, status
  end

  def test_record_unknown_space_returns_404
    secret, = mint_token(@owner)
    status, _, _ = get_with_bearer("/spaces/987654/iterations/7", bearer: secret)
    assert_equal 404, status
  end

  def test_record_unknown_ordinal_returns_404
    secret, = seed_store
    space = owner_space
    status, _, _ = get_with_bearer("/spaces/#{space.id}/iterations/99", bearer: secret)
    assert_equal 404, status
  end

  def test_record_non_numeric_ordinal_returns_404
    secret, = seed_store
    space = owner_space
    status, _, _ = get_with_bearer("/spaces/#{space.id}/iterations/nope", bearer: secret)
    assert_equal 404, status
  end

  # --- 200 happy path -----------------------------------------------------------

  def test_record_bearer_auth_full_shape_with_transcript
    secret, = seed_store
    space = owner_space

    status, headers, body = get_with_bearer("/spaces/#{space.id}/iterations/7", bearer: secret)
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)

    assert_equal space.id, data["space"]["id"]
    assert_equal "record-iter", data["space"]["slug"]

    iter = data["iteration"]
    assert_equal({ "id" => nil, "ordinal" => nil, "name" => nil, "slug" => nil,
                   "freeze_sha" => nil, "branch" => nil, "status" => nil,
                   "verdict" => nil, "phase_kind" => nil, "phase_at" => nil,
                   "created_at" => nil, "occurred_at" => nil,
                   "gates" => nil, "lanes" => nil, "verdict_detail" => nil }.keys.sort,
                 iter.keys.sort, "record iteration keys must match the spec shape")
    assert_equal 7, iter["ordinal"]
    assert_equal "structured-iterations-ingest", iter["name"]
    assert_nil iter["slug"]
    assert_equal "da7c509a", iter["freeze_sha"]
    assert_equal "main", iter["branch"]
    assert_equal "integrated", iter["status"]
    assert_equal "continue", iter["verdict"]
    assert Time.iso8601(iter["created_at"])
    assert_nil iter["occurred_at"]

    # Gates — definitions verbatim, ordered by gate_id
    assert_equal ["allfax-ruby-suite", "iter-db-prepare"], iter["gates"].map { |g| g["gate_id"] }
    gate = iter["gates"].first
    assert_equal "AC2", gate["ac"]
    assert_equal "repos/all-fax-no-printer", gate["cwd"]
    assert_equal 600, gate["timeout"]
    assert_equal JSON.parse(JSON.generate(GATE_EXPECT)), gate["expect"]

    # Lanes — full fidelity incl. transcript (the ONLY surface with transcripts)
    assert_equal ["surface"], iter["lanes"].map { |l| l["name"] }
    lane = iter["lanes"].first
    assert_equal "all-fax-no-printer", lane["repo"]
    assert_equal "7398ccc", lane["base_sha"]
    assert_equal "openrouter/z-ai/glm-5.3-flash", lane["model"]
    assert_equal "pi", lane["harness"]
    assert_equal "high", lane["effort"]
    assert_equal ["config/routes.rb", "app/actions/spaces/show.rb"], lane["touch_set"]
    assert_equal "complete", lane["status"]
    assert_nil lane["bounds_override_reason"]
    assert_equal [], lane["escalations"]
    assert_equal "abc123", lane["merge_sha"]
    assert_equal "main", lane["integration_branch"]
    assert Time.iso8601(lane["integrated_at"])
    assert_equal ["allfax-ruby-suite", "iter-db-prepare"],
                 lane["gate_results"].map { |r| r["gate_id"] }
    result = lane["gate_results"].first
    assert_equal "pass", result["status"]
    # The landed lane contract's params schema strips empty strings to nil
    # (dry-schema params + maybe(:string)) — a payload reason: "" stores as NULL.
    assert_nil result["reason"]
    assert_equal "465 runs, 0 failures, 0 errors, 0 skips", result["transcript"],
      "the record endpoint is the full-fidelity surface — transcript must appear"
    assert_equal "rc=0", lane["gate_results"].last["reason"]

    # Verdict detail
    assert_equal({ "decision" => "continue",
                   "ac_rulings" => [{ "ac" => "AC1", "ruling" => "pass", "note" => "store green" }],
                   "phase0_resolutions" => [] }, iter["verdict_detail"])
  end

  def test_record_session_auth_full_shape
    seed_store
    space = owner_space
    sign_in(@owner)

    status, _, body = get_with_bearer("/spaces/#{space.id}/iterations/7")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal 7, data["iteration"]["ordinal"]
    assert_equal "465 runs, 0 failures, 0 errors, 0 skips",
                 data["iteration"]["lanes"].first["gate_results"].first["transcript"],
      "session-authed owner reads carry the same full fidelity as bearer"
  end

  def test_record_verdict_detail_nil_without_verdict_mouth
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    space = owner_space

    status, _, body = get_with_bearer("/spaces/#{space.id}/iterations/7", bearer: secret)
    assert_equal 200, status
    iter = parse_json(body)["iteration"]
    assert_nil iter["verdict_detail"]
    assert_equal [], iter["lanes"]
    assert_equal "frozen", iter["status"]
  end

  # I11 narration-split (lane afnp) — the phase facet rides the record read:
  # additive, nil-safe both ways (no ping → null; a ping lands → server-stamped
  # values).
  PHASE_PAYLOAD = {
    iteration: { ordinal: 7, name: "structured-iterations-ingest" },
    phase: { kind: "judge-running" }
  }.freeze

  def test_record_phase_keys_nil_safe_then_stamped
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/freeze", FREEZE_PAYLOAD, bearer: secret)
    space = owner_space

    status, _, body = get_with_bearer("/spaces/#{space.id}/iterations/7", bearer: secret)
    assert_equal 200, status
    iter = parse_json(body)["iteration"]
    assert iter.key?("phase_kind"), "phase_kind key always present"
    assert iter.key?("phase_at"), "phase_at key always present"
    assert_nil iter["phase_kind"], "an iteration without a ping reads null"
    assert_nil iter["phase_at"]

    status, _, _ = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    assert_equal 200, status

    status, _, body = get_with_bearer("/spaces/#{space.id}/iterations/7", bearer: secret)
    assert_equal 200, status
    iter = parse_json(body)["iteration"]
    assert_equal "judge-running", iter["phase_kind"]
    assert Time.iso8601(iter["phase_at"])
  end
end
