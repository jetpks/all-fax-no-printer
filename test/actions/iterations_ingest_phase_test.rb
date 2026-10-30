# frozen_string_literal: true

require_relative "action_test_helper"

# I11 narration-split (lane afnp) — Mouth 5: POST /iterations/ingest/phase.
# Bearer-authed, X-Space-Slug scoped, contract-strict (unknown keys rejected),
# order-tolerant (a ping may arrive BEFORE the freeze emission and must create
# the stub), scalar upsert (every ping restamps phase_kind/phase_at on the
# server clock; an absent note never nulls the stored one; identical re-POST →
# 200, same row content modulo the phase_at restamp).
class IterationsIngestPhaseActionTest < Minitest::Test
  include ActionTestHelper

  PHASE_PAYLOAD = {
    iteration: { ordinal: 11, name: "narration-split", branch: "main" },
    phase: { kind: "spec-launched", note: "kicked off" }
  }.freeze

  def setup
    setup_db
    @owner = Factory[:user, github_uid: "phase-owner", username: "phase_owner"]
    @other = Factory[:user, github_uid: "phase-other", username: "phase_other"]
    @iterations = Space::Server::Repos::IterationsRepo.new
  end

  def mint_token(user)
    Space::Server::App["repos.api_tokens_repo"].create(user_id: user.id, name: "cli")
  end

  def post_json(path, body, slug: "phase-iter", bearer: nil)
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

  def owner_space
    Space::Server::Repos::SpacesRepo.new.upsert_by_slug(@owner.id, "phase-iter", title: "phase-iter")
  end

  def iteration_row
    @iterations.for_space(owner_space.id).first
  end

  # --- auth / slug -----------------------------------------------------------

  def test_no_bearer_returns_401_json_error
    status, _, body = post_json("/iterations/ingest/phase", JSON.generate(PHASE_PAYLOAD))
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_wrong_bearer_returns_401
    status, _, body = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: "nope")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_missing_slug_returns_422
    secret, = mint_token(@owner)
    status, _, body = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, slug: nil, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("X-Space-Slug")
  end

  # --- contract ----------------------------------------------------------------

  def test_missing_kind_422
    secret, = mint_token(@owner)
    bad = { iteration: PHASE_PAYLOAD[:iteration], phase: { note: "no kind" } }
    status, _, body = post_payload("/iterations/ingest/phase", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("kind")
  end

  def test_empty_kind_422
    secret, = mint_token(@owner)
    # "" coerces to nil at the params boundary (same as lane reason) → filled fails.
    bad = { iteration: PHASE_PAYLOAD[:iteration], phase: { kind: "" } }
    status, _, body = post_payload("/iterations/ingest/phase", bad, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("kind")
  end

  def test_unknown_key_rejected_at_every_level
    secret, = mint_token(@owner)
    top = PHASE_PAYLOAD.merge(bogus: 1)
    status, _, body = post_payload("/iterations/ingest/phase", top, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("bogus")

    deep = PHASE_PAYLOAD.merge(iteration: PHASE_PAYLOAD[:iteration].merge(nope: "x"))
    status, _, body = post_payload("/iterations/ingest/phase", deep, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("nope")

    in_phase = { iteration: PHASE_PAYLOAD[:iteration],
                 phase: { kind: "judge-running", stamped_at: "2026-01-01" } }
    status, _, body = post_payload("/iterations/ingest/phase", in_phase, bearer: secret)
    assert_equal 422, status
    assert parse_json(body)["errors"].join.include?("stamped_at"),
      "the payload carries NO timestamp — the server clock is the time base"
  end

  def test_free_text_kind_accepted_no_vocabulary_constraint
    secret, = mint_token(@owner)
    payload = { iteration: PHASE_PAYLOAD[:iteration], phase: { kind: "whatever-the-loop-says" } }
    status, _, body = post_payload("/iterations/ingest/phase", payload, bearer: secret)
    assert_equal 200, status
    assert_equal "whatever-the-loop-says", parse_json(body)["iteration"]["phase_kind"]
  end

  # --- happy path / frozen response shape --------------------------------------

  def test_happy_path_200_response_shape
    secret, = mint_token(@owner)
    status, headers, body = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert_equal %w[id slug], data["space"].keys.sort
    assert_equal %w[id name ordinal phase_at phase_kind], data["iteration"].keys.sort
    assert_equal "phase-iter", data["space"]["slug"]
    assert_equal 11, data["iteration"]["ordinal"]
    assert_equal "narration-split", data["iteration"]["name"]
    assert_equal "spec-launched", data["iteration"]["phase_kind"]
    assert Time.iso8601(data["iteration"]["phase_at"]), "phase_at is the server-stamped time base"
    assert_equal true, data["phase_applied"]
  end

  # --- order tolerance ------------------------------------------------------------

  def test_ping_before_freeze_creates_iteration_stub
    secret, = mint_token(@owner)
    status, _, _ = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    assert_equal 200, status
    iterations = @iterations.for_space(owner_space.id)
    assert_equal 1, iterations.size, "iteration stub created order-tolerantly"
    assert_equal "narration-split", iterations.first.name
    assert_equal "spec-launched", iterations.first.phase_kind
    assert_equal "main", iterations.first.branch, "shared iteration-block scalars upsert too"
  end

  # --- scalar upsert / restamp / idempotency ---------------------------------------

  def test_upsert_second_kind_overwrites_and_restamps
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    first_at = iteration_row.phase_at

    sleep 0.05 # the restamp must be observable on the server clock
    second = { iteration: PHASE_PAYLOAD[:iteration], phase: { kind: "builders-settled" } }
    status, _, _ = post_payload("/iterations/ingest/phase", second, bearer: secret)
    assert_equal 200, status

    row = iteration_row
    assert_equal "builders-settled", row.phase_kind
    assert_operator row.phase_at, :>, first_at, "phase_at restamped from the server clock"
    assert_equal "kicked off", row.phase_note, "an absent note never nulls the stored one"
    assert_equal 1, @iterations.for_space(owner_space.id).size, "upsert in place — no new row"
  end

  def test_identical_repost_200_same_row_content_modulo_restamp
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    before = iteration_row

    status, _, _ = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    assert_equal 200, status

    after = iteration_row
    assert_equal before.id, after.id
    assert_equal before.ordinal, after.ordinal
    assert_equal before.name, after.name
    assert_equal before.phase_kind, after.phase_kind
    assert_equal before.phase_note, after.phase_note
    assert_operator after.phase_at, :>=, before.phase_at, "every ping restamps phase_at"
  end

  def test_note_upserts_only_when_present_absent_never_nulls
    secret, = mint_token(@owner)
    bare = { iteration: PHASE_PAYLOAD[:iteration], phase: { kind: "spec-launched" } }

    post_payload("/iterations/ingest/phase", bare, bearer: secret)
    assert_nil iteration_row.phase_note, "no note yet"

    post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    assert_equal "kicked off", iteration_row.phase_note, "present note upserts"

    post_payload("/iterations/ingest/phase", bare, bearer: secret)
    assert_equal "kicked off", iteration_row.phase_note, "absent note leaves the stored one"
  end

  def test_same_slug_other_user_gets_own_space
    secret, = mint_token(@owner)
    post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: secret)
    owner_row_count = Space::Server::App["db.gateway"].connection[:iterations].count

    other_secret, = mint_token(@other)
    status, _, body = post_payload("/iterations/ingest/phase", PHASE_PAYLOAD, bearer: other_secret)
    assert_equal 200, status
    assert_equal "phase-iter", parse_json(body)["space"]["slug"]
    spaces = Space::Server::App["db.gateway"].connection[:spaces].where(slug: "phase-iter").to_a
    assert_equal 2, spaces.size, "user B's same slug gets their OWN space"
    assert_equal owner_row_count + 1, Space::Server::App["db.gateway"].connection[:iterations].count,
      "user B's ping lands in their own space"
  end
end
