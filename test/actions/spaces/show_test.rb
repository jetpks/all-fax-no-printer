# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesShowI03Test < Minitest::Test
  include ActionTestHelper

  ITERATION_MARKDOWN = <<~MD
    # I01: Test Iteration

    ## Grounds

    The grounds content.

    ## Specification

    The specification content.

    ## Acceptance Criteria

    - AC-1: First criterion

    ## Builder Prompt

    Build this.

    ## Builder Report

    Done building.

    ## Verdict

    continue
  MD

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i03-show-owner-uid", username: "i03-show-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── decisions ────────────────────────────────────────────────────────────────

  def test_show_includes_decisions_for_iteration_artifact
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "decisions-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert iteration.key?("decisions"), "must include decisions key"
    assert_kind_of Array, iteration["decisions"]
    assert iteration["decisions"].length > 0, "must have at least one decision"
  end

  def test_show_decisions_canonical_order
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "order-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    names = decisions.map { |d| d["name"] }
    canonical = ["Grounds", "Specification", "Acceptance Criteria",
                 "Builder Prompt", "Builder Report", "Verdict"]
    assert_equal canonical & names, names,
      "decisions must appear in canonical order"
  end

  def test_show_decisions_include_body_content
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "body-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    grounds = decisions.find { |d| d["name"] == "Grounds" }
    refute_nil grounds, "Grounds decision must be present"
    assert_match "grounds content", grounds["body"],
      "body must contain section markdown"
  end

  def test_show_decisions_omits_absent_sections
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "partial-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    # Only Grounds + Verdict sections present
    partial_md = "## Grounds\n\nSome grounds.\n\n## Verdict\n\ncontinue\n"
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: partial_md]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    names = decisions.map { |d| d["name"] }
    assert_includes names, "Grounds"
    assert_includes names, "Verdict"
    refute_includes names, "Specification"
    refute_includes names, "Builder Prompt"
  end

  def test_show_decisions_empty_when_no_iteration_artifact
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "no-art-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]
    # Only a non-iteration artifact
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "lane_report", path: "build/I01/report.md", title: "Report",
            raw: "Report content."]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    assert_equal [], decisions
  end

  # ── content fidelity (nested ## subsections) ─────────────────────────────────

  NESTED_ITERATION_MARKDOWN = <<~MD
    # I01: Real Iteration

    ## Grounds

    The grounds content.

    ## Specification

    Top-level spec intro.

    ## Objective

    The nested objective subsection.

    ## Boundaries

    The nested boundaries subsection.

    ## Acceptance Criteria

    - AC-1: criterion

    ## Builder Prompt

    Build this.

    ## Verdict

    continue
  MD

  def test_show_decisions_specification_body_includes_nested_subsections
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "nested-spec-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-nested"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01-nested.md", title: "I01 Nested",
            raw: NESTED_ITERATION_MARKDOWN]

    _, _, body = inertia_get("/spaces/#{space.id}")
    decisions = parse_json(body)["props"]["iterations"].first["decisions"]

    spec = decisions.find { |d| d["name"] == "Specification" }
    refute_nil spec, "Specification decision must be present"
    assert_match "Top-level spec intro",           spec["body"]
    assert_match "## Objective",                   spec["body"],
      "nested ## Objective header must be preserved in Specification body"
    assert_match "The nested objective subsection", spec["body"],
      "nested Objective content must be in Specification body"
    assert_match "## Boundaries",                  spec["body"],
      "nested ## Boundaries header must be preserved in Specification body"

    # Nested non-canonical headers must NOT become top-level decisions
    names = decisions.map { |d| d["name"] }
    refute_includes names, "Objective",  "Objective must not be its own decision"
    refute_includes names, "Boundaries", "Boundaries must not be its own decision"

    # Canonical order preserved
    canonical = ["Grounds", "Specification", "Acceptance Criteria",
                 "Builder Prompt", "Builder Report", "Verdict"]
    assert_equal canonical & names, names, "decisions must be in canonical order"
  end

  # ── created_at ───────────────────────────────────────────────────────────────

  def test_show_iteration_includes_created_at
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "ts-iter-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-one"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert iteration.key?("created_at"), "iteration must include created_at"
    refute_nil iteration["created_at"]
    # Must be parseable as iso8601
    assert Time.iso8601(iteration["created_at"])
  end

  def test_show_iteration_includes_occurred_at_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-occurred-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-occ"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert iter.key?("occurred_at"), "iteration must include occurred_at key"
  end

  def test_show_iteration_occurred_at_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-nil-occurred-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-nil"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    # Factory creates without occurred_at; must serialize as null
    assert_nil iter["occurred_at"]
  end

  # ── microsecond precision (AC-3) ──────────────────────────────────────────────

  def test_show_iteration_created_at_microsecond_precision
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-micro-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-micro"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, iter["created_at"],
      "iteration created_at must have 6 fractional digits")
  end

  def test_show_iteration_occurred_at_microsecond_precision_when_present
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-occ-micro-space"]
    t = Time.parse("2026-06-28T15:32:12.278000Z").utc
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-occ-micro",
            occurred_at: t]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_match(/T\d\d:\d\d:\d\d\.\d{6}/, iter["occurred_at"],
      "iteration occurred_at must have 6 fractional digits when present")
  end
  def test_show_iteration_includes_occurred_at_utc_offset_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-key-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-key"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert iter.key?("occurred_at_utc_offset"), "iteration must include occurred_at_utc_offset key"
  end

  def test_show_iteration_occurred_at_utc_offset_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-nil-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-nil"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_nil iter["occurred_at_utc_offset"]
  end

  def test_show_iteration_occurred_at_utc_offset_integer_when_set
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "iter-offset-set-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-offset-set",
            occurred_at_utc_offset: -21600]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iter = parse_json(body)["props"]["iterations"].first

    assert_equal(-21600, iter["occurred_at_utc_offset"])
  end

  # ── git_utc_offset on space prop (AC-3) ───────────────────────────────────────

  def test_show_space_prop_includes_git_utc_offset_key
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-key-space"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert space_prop.key?("git_utc_offset"), "space prop must include git_utc_offset key"
  end

  def test_show_space_prop_git_utc_offset_nil_by_default
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-nil-space"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert_nil space_prop["git_utc_offset"]
  end

  def test_show_space_prop_git_utc_offset_integer_when_set
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "space-offset-set-space",
                    git_utc_offset: -21600]

    _, _, body = inertia_get("/spaces/#{space.id}")
    space_prop = parse_json(body)["props"]["space"]

    assert_equal(-21600, space_prop["git_utc_offset"])
  end

  # ── harness and model on run_props (builder rows) ────────────────────────────


  # ── conversations feed (I08: no runs arrays — the conversation list is the space feed) ──

  def test_show_conversations_prop_lists_space_conversations
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "conv-feed-space"]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    session_id: "sess-1", agent_role: "builder",
                    agent_name: "mouth-lane", model: "minimax/minimax-m3", title: "Folded"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    conversations = parse_json(body)["props"]["conversations"]

    assert_kind_of Array, conversations
    row = conversations.first
    assert_equal conv.id, row["id"]
    %w[id title agent_role agent_name status model updated_at].each do |key|
      assert row.key?(key), "conversation feed row must include '#{key}'"
    end
    assert_equal "builder",           row["agent_role"]
    assert_equal "mouth-lane",        row["agent_name"]
    assert_equal "minimax/minimax-m3", row["model"]
  end

  def test_show_conversations_ordered_by_updated_at_desc
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "conv-order-space"]
    older = Factory[:conversation, user_id: @owner.id, space_id: space.id, updated_at: Time.now - 3600]
    newer = Factory[:conversation, user_id: @owner.id, space_id: space.id, updated_at: Time.now]

    _, _, body = inertia_get("/spaces/#{space.id}")
    conversations = parse_json(body)["props"]["conversations"]
    assert_equal [newer.id, older.id], conversations.map { |c| c["id"] }
  end

  def test_show_excludes_runs_props
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "no-runs-props-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-no-runs"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    props = parse_json(body)["props"]

    refute props.key?("architect_runs"), "architect_runs must be gone (runs died)"
    refute props.key?("unassigned_runs"), "unassigned_runs must be gone (runs died)"
    assert props.key?("conversations"), "conversations feed replaces the run arrays"
  end
end
