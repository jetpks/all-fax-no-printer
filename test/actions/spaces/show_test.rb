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

# I12 phone observation deck: the narrator prop on the space show page — the
# newest narrator conversation (for_space is already desc(:updated_at)) reduced
# to its last qualifying assistant message's text.
class SpacesShowNarratorTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i12-narrator-owner", username: "i12_narrator_owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def narrator_prop(space_id)
    props = nil
    _, _, body = inertia_get("/spaces/#{space_id}")
    props = parse_json(body)["props"]
    props
  end

  def test_show_narrator_present_with_last_assistant_text
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "narrator-space"]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "narrator", updated_at: Time.now]
    Factory[:message, conversation_id: conv.id, role: "user", position: 1,
            content: [{ "type" => "text", "text" => "user chatter" }]]
    Factory[:message, conversation_id: conv.id, role: "assistant", position: 2,
            content: [{ "type" => "text", "text" => "part one" },
                      { "type" => "thinking", "thinking" => "hmm" },
                      { "type" => "text", "text" => "part two" }]]
    # A later user message must not displace the last qualifying assistant message.
    Factory[:message, conversation_id: conv.id, role: "user", position: 3,
            content: [{ "type" => "text", "text" => "later user text" }]]

    props = narrator_prop(space.id)
    assert props.key?("narrator"), "narrator key must always be present"
    narrator = props["narrator"]
    assert_equal conv.id, narrator["conversation_id"]
    assert_equal "part one\n\npart two", narrator["text"],
      "the message's text blocks join with blank lines"
    assert narrator.key?("updated_at")
    assert Time.iso8601(narrator["updated_at"])
  end

  def test_show_narrator_last_qualifying_assistant_message_wins
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "narrator-last-space"]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "narrator", updated_at: Time.now]
    Factory[:message, conversation_id: conv.id, role: "assistant", position: 1,
            content: [{ "type" => "text", "text" => "earlier text" }]]
    Factory[:message, conversation_id: conv.id, role: "assistant", position: 2,
            content: [{ "type" => "text", "text" => "later text" }]]

    props = narrator_prop(space.id)
    assert_equal "later text", props["narrator"]["text"]
  end

  def test_show_narrator_newest_narrator_conversation_wins
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "narrator-newest-space"]
    older = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "narrator", updated_at: Time.now - 3600]
    newer = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "narrator", updated_at: Time.now]
    Factory[:message, conversation_id: older.id, role: "assistant", position: 1,
            content: [{ "type" => "text", "text" => "older narrator text" }]]
    Factory[:message, conversation_id: newer.id, role: "assistant", position: 1,
            content: [{ "type" => "text", "text" => "newer narrator text" }]]

    props = narrator_prop(space.id)
    assert_equal newer.id, props["narrator"]["conversation_id"],
      "for_space is desc(:updated_at) — the first match is the newest"
    assert_equal "newer narrator text", props["narrator"]["text"]
  end

  def test_show_narrator_nil_without_narrator_conversation
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "narrator-absent-space"]
    Factory[:conversation, user_id: @owner.id, space_id: space.id, agent_role: "builder"]

    props = narrator_prop(space.id)
    assert props.key?("narrator"), "narrator key must always be present"
    assert_nil props["narrator"]
  end

  def test_show_narrator_nil_without_qualifying_assistant_text
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "narrator-no-text-space"]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "narrator", updated_at: Time.now]
    # Assistant messages with only empty-text blocks don't qualify.
    Factory[:message, conversation_id: conv.id, role: "assistant", position: 1,
            content: [{ "type" => "text", "text" => "" }]]
    Factory[:message, conversation_id: conv.id, role: "user", position: 2,
            content: [{ "type" => "text", "text" => "only user text" }]]

    props = narrator_prop(space.id)
    assert props.key?("narrator")
    assert_nil props["narrator"]
  end
end

# I15 lane `surface` — the structured-record READ SURFACE on the spaces show
# page: additive prop keys (branch/status/gates/lanes/verdict_detail) surfaced
# ALONGSIDE the artifact-derived decisions path. Transcripts never enter page
# props (phone-page weight) — full fidelity lives on the record endpoint.
class SpacesShowStructuredPropsTest < Minitest::Test
  include ActionTestHelper

  TRANSCRIPT_MARKER = "RECORD-ONLY-TRANSCRIPT-do-not-leak-into-props"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i15-show-struct-owner", username: "i15-show-struct-owner"]
    @repos = {
      gates:            Space::Server::Repos::GatesRepo.new,
      lanes:            Space::Server::Repos::LanesRepo.new,
      gate_results:     Space::Server::Repos::GateResultsRepo.new,
      verdicts:         Space::Server::Repos::VerdictsRepo.new,
      verdict_rulings:  Space::Server::Repos::VerdictRulingsRepo.new
    }
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def seed_structured_store(space, iteration)
    @repos[:gates].replace_for_iteration(iteration.id, [
      { gate_id: "z-gate", ac: "AC2", cwd: "repos/x", cmd: "rake test", timeout: 600,
        expect: { "exit_code" => 0, "stdout_match" => "OK" } },
      { gate_id: "a-gate", ac: "AC1", cmd: "hanami db prepare", timeout: 60 }
    ])
    gates = @repos[:gates].for_iteration(iteration.id).to_h { |g| [g.gate_id, g] }

    lane = @repos[:lanes].upsert_by_name(iteration.id, "surface", {
      repo: "all-fax-no-printer", base_sha: "7398ccc", model: "glm-5.3", harness: "pi",
      effort: "high", touch_set: ["config/routes.rb"], status: "complete",
      bounds_override_reason: nil, escalations: [], merge_sha: "abc123",
      integration_branch: "main", integrated_at: Time.now
    })
    @repos[:lanes].upsert_by_name(iteration.id, "mouths", {
      repo: "all-fax-no-printer", status: "complete", touch_set: [], escalations: []
    })
    @repos[:gate_results].upsert(gates.fetch("a-gate").id, lane.id,
                                 { status: "pass", reason: "", transcript: TRANSCRIPT_MARKER })
    @repos[:gate_results].upsert(gates.fetch("z-gate").id, lane.id,
                                 { status: "fail", reason: "boom" })

    verdict = @repos[:verdicts].upsert_for_iteration(iteration.id,
                                                     { decision: "continue", phase0_resolutions: [] })
    @repos[:verdict_rulings].replace_for_verdict(verdict.id, [
      { ac: "AC1", ruling: "pass", note: nil },
      { ac: "AC2", ruling: "fail", note: "boom" }
    ])
    gates
  end

  def test_show_structured_props_full_shape
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "struct-props-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 3, name: "iter-struct",
                    freeze_sha: "da7c509a", branch: "main", status: "integrated", verdict: "continue"]
    seed_structured_store(space, iter)

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    # Identity columns
    assert_equal "main",       iteration["branch"]
    assert_equal "integrated", iteration["status"]

    # Gates: ordered by gate_id, definitions only
    assert_equal ["a-gate", "z-gate"], iteration["gates"].map { |g| g["gate_id"] }
    a_gate = iteration["gates"].first
    assert_equal({ "gate_id" => "a-gate", "ac" => "AC1", "cwd" => nil,
                   "cmd" => "hanami db prepare", "timeout" => 60.0,
                   "expect" => nil }.keys.sort, a_gate.keys.sort)
    assert_equal "hanami db prepare", a_gate["cmd"]
    z_gate = iteration["gates"].last
    assert_equal 0, z_gate["expect"]["exit_code"]
    assert_equal "OK", z_gate["expect"]["stdout_match"]

    # Lanes: ordered by name, gate results statuses only (no transcripts)
    assert_equal ["mouths", "surface"], iteration["lanes"].map { |l| l["name"] }
    surface = iteration["lanes"].last
    assert_equal({ "name" => "surface", "repo" => "all-fax-no-printer", "base_sha" => "7398ccc",
                   "model" => "glm-5.3", "harness" => "pi", "effort" => "high",
                   "touch_set" => ["config/routes.rb"], "status" => "complete",
                   "bounds_override_reason" => nil, "escalations" => [],
                   "merge_sha" => "abc123", "integration_branch" => "main",
                   "integrated_at" => nil, "gate_results" => nil }.keys.sort, surface.keys.sort)
    assert Time.iso8601(surface["integrated_at"])
    assert_equal ["a-gate", "z-gate"], surface["gate_results"].map { |r| r["gate_id"] }
    assert_equal({ "gate_id" => "a-gate", "status" => "pass", "reason" => "" },
                 surface["gate_results"].first)

    # Verdict detail
    assert_equal({ "decision" => "continue",
                   "ac_rulings" => [{ "ac" => "AC1", "ruling" => "pass", "note" => nil },
                                    { "ac" => "AC2", "ruling" => "fail", "note" => "boom" }],
                   "phase0_resolutions" => [] }, iteration["verdict_detail"])
  end

  def test_show_transcripts_never_appear_in_props
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "struct-transcript-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-transcript"]
    seed_structured_store(space, iter)

    _, _, body = inertia_get("/spaces/#{space.id}")
    refute_includes body.join, TRANSCRIPT_MARKER,
      "a seeded transcript must never surface in the show props"
  end

  def test_show_no_modeled_data_renders_unchanged_page_plus_empty_defaults
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "struct-empty-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-bare"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    # Pre-existing keys all still present
    ["id", "ordinal", "name", "freeze_sha", "verdict", "created_at",
     "occurred_at", "occurred_at_utc_offset", "decisions", "artifacts"].each do |key|
      assert iteration.key?(key), "pre-existing key #{key} must stay present"
    end
    # Additive keys default
    assert_nil iteration["branch"]
    assert_nil iteration["status"]
    assert_equal [], iteration["gates"]
    assert_equal [], iteration["lanes"]
    assert_nil iteration["verdict_detail"]
  end

  def test_show_structured_props_do_not_disturb_decisions_path
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "struct-decisions-space"]
    iter  = Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-both"]
    Factory[:artifact, space_id: space.id, iteration_id: iter.id,
            kind: "iteration", path: "architecture/I01.md", title: "I01",
            raw: <<~MD]
      ## Grounds

      Structured-era grounds.

      ## Verdict

      continue
    MD
    seed_structured_store(space, iter)

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert_equal ["Grounds", "Verdict"], iteration["decisions"].map { |d| d["name"] },
      "the artifact-derived decisions path must render exactly as before"
    assert_match "Structured-era grounds", iteration["decisions"].first["body"]
    assert_equal 2, iteration["gates"].length,
      "modeled gates surface alongside decisions, not instead of them"
  end
end

# I11 narration-split (lane afnp) — the phase facet on the show page props:
# additive, MODELED FIRST, nil when an iteration carries no ping (the same
# "nil when absent" discipline as the other structured keys).
class SpacesShowPhasePropsTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i11-show-phase-owner", username: "i11-show-phase-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_show_props_carry_phase_keys_nil_without_ping
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "phase-nil-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-no-ping"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iteration = parse_json(body)["props"]["iterations"].first

    assert iteration.key?("phase_kind"), "phase_kind key must always be present"
    assert iteration.key?("phase_at"), "phase_at key must always be present"
    assert_nil iteration["phase_kind"]
    assert_nil iteration["phase_at"]
  end

  def test_show_props_carry_phase_values_only_for_pinged_iterations
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "phase-set-space"]
    Factory[:iteration, space_id: space.id, ordinal: 1, name: "iter-pinged",
            phase_kind: "builders-settled", phase_at: Time.now]
    Factory[:iteration, space_id: space.id, ordinal: 2, name: "iter-bare"]

    _, _, body = inertia_get("/spaces/#{space.id}")
    iterations = parse_json(body)["props"]["iterations"]
    pinged = iterations.find { |i| i["name"] == "iter-pinged" }
    bare   = iterations.find { |i| i["name"] == "iter-bare" }

    assert_equal "builders-settled", pinged["phase_kind"]
    assert Time.iso8601(pinged["phase_at"])
    assert_nil bare["phase_kind"], "nil when this iteration carries no ping"
    assert_nil bare["phase_at"]
  end
end
