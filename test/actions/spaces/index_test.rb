# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "i08-index-owner-uid", username: "i08-index-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── conversations_count / last_activity_at (AC: Spaces/Index feed) ────────────

  def test_index_space_row_includes_feed_keys
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-offset-key-space"]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    %w[conversations_count last_activity_at].each do |key|
      assert space_row.key?(key), "space row must include '#{key}' key"
    end
  end

  def test_index_space_row_feed_keys_zero_and_nil_by_default
    sign_in(@owner)
    Factory[:space, user_id: @owner.id, slug: "idx-offset-nil-space"]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert_equal 0,   space_row["conversations_count"]
    assert_nil        space_row["last_activity_at"]
  end

  def test_index_space_row_feed_keys_reflect_conversations
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "idx-offset-set-space"]
    Factory[:conversation, user_id: @owner.id, space_id: space.id,
            updated_at: Time.parse("2026-06-28T21:32:12.278000Z").utc]

    _, _, body = inertia_get("/spaces")
    space_row = parse_json(body)["props"]["spaces"].first

    assert_equal 1, space_row["conversations_count"]
    assert_match(/T21:32:12\.278000/, space_row["last_activity_at"],
      "last_activity_at must have 6 fractional digits")
  end

  # ── unspaced (I08): per-cwd buckets of the viewer's space-less conversations ──

  def test_index_unspaced_prop_present_and_array
    sign_in(@owner)
    _, _, body = inertia_get("/spaces")
    props = parse_json(body)["props"]
    assert props.key?("unspaced"), "spaces index props must include 'unspaced'"
    assert_kind_of Array, props["unspaced"]
  end

  def test_index_unspaced_buckets_carry_cwd_counts_and_last_activity
    sign_in(@owner)
    Factory[:conversation, user_id: @owner.id, space_id: nil,
            original_cwd: "/Users/eric/unspaced-proj", updated_at: Time.now]

    _, _, body = inertia_get("/spaces")
    bucket = parse_json(body)["props"]["unspaced"].first

    assert_equal "/Users/eric/unspaced-proj", bucket["cwd"]
    assert_equal 1, bucket["conversations_count"]
    assert bucket.key?("last_activity_at")
  end
end
