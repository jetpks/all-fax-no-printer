# frozen_string_literal: true

require_relative "action_test_helper"

# G2 (crux): The render actions emit faithful Inertia page objects.
# G3 (crux): B2 seam inverted per spec §2 matrix — every row asserted.
# G4: can_manage in show props across viewer states.
# G5: sessions flash round-trips.
#
# All render requests use X-Inertia (XHR) for hermetic, manifest-free execution.
# The version header = Space::Server::App["vite"].digest (hashes app/frontend sources,
# not the manifest) so no node/npm/build is required.
class InertiaRenderTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner    = Factory[:user, github_uid: "uid-iowner", username: "iowner"]
    @stranger = Factory[:user, github_uid: "uid-istranger", username: "istranger"]

    @conv = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1 = Factory[:message, conversation_id: @conv.id, role: "user",
                    content: [{"type" => "text", "text" => "prompt"}], position: 1, published: false]
    @msg2 = Factory[:message, conversation_id: @conv.id, role: "assistant",
                    content: [{"type" => "text", "text" => "reply"}], position: 2, published: false]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  def inertia_page(path, cookie: nil)
    _, _, body = inertia_get(path, cookie: cookie)
    parse_json(body)
  end

  # ── G2: Index render ─────────────────────────────────────────────────────

  def test_index_page_object_shape
    _, headers, body = inertia_get("/conversations")
    assert_equal "true", headers["x-inertia"]
    assert_equal "application/json", headers["content-type"]
    data = parse_json(body)
    assert_equal "Conversations/Index", data["component"]
    assert data.key?("url")
    assert data.key?("version")
    assert data["props"].key?("conversations")
    assert data["props"].key?("current_user")
    assert data["props"].key?("flash")
  end

  def test_index_anon_sees_only_published
    pub = Factory[:conversation, published: true]
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, pub.id
    refute_includes ids, @conv.id
  end

  def test_index_signed_in_sees_owned
    sign_in(@owner)
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, @conv.id
  end

  def test_index_conversation_list_json_exact_key_set
    pub = Factory[:conversation, published: true]
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == pub.id }
    refute_nil conv_data
    expected_keys = %w[id title status published turns_count owned agent_role agent_name model original_cwd space_id updated_at].sort
    assert_equal expected_keys, conv_data.keys.sort,
                 "conversation_list_json key set must match exactly"
  end

  def test_index_owned_flag_true_for_owner
    sign_in(@owner)
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    assert_equal true, conv_data["owned"]
  end

  def test_index_turns_count_correct
    # I36: turns_count is the denormalized column (0 here — @conv's messages
    # were inserted directly); just verify type/shape.
    sign_in(@owner)
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    refute_nil conv_data
    assert_kind_of Integer, conv_data["turns_count"]
  end

  # ── G2: Show render ──────────────────────────────────────────────────────

  def test_show_page_object_shape_for_owner
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal "Conversations/Show", data["component"]
    props = data["props"]
    assert props.key?("conversation"), "props must have conversation"
    assert props.key?("turns"),        "props must have turns"
    assert props.key?("current_user")
    assert props.key?("flash")
    assert props.key?("errors")
  end

  def test_show_conversation_json_exact_key_set
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    conv = data["props"]["conversation"]
    expected_keys = %w[id title status published source original_cwd git_branch
                       agent_version agent_role agent_name model space_id
                       can_manage owner parent children].sort
    assert_equal expected_keys, conv.keys.sort,
                 "conversation_json key set must match exactly"
  end

  def test_show_turns_are_turn_json
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    turns = data["props"]["turns"]
    assert_kind_of Array, turns
    turns.each do |t|
      assert t.key?("anchor_id"), "turn must have anchor_id"
      assert t.key?("rounds"),    "turn must have rounds"
    end
  end

  # ── G3: B2 matrix — missing records stay JSON 404 ───────────────────────

  def test_show_missing_record_returns_404_json
    status, headers, body = inertia_get("/conversations/99999")
    assert_equal 404, status
    assert_includes headers["content-type"], "application/json"
    assert parse_json(body).key?("error")
  end

  # ── G4: can_manage by viewer state ───────────────────────────────────────

  def test_can_manage_for_owner
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal true, data["props"]["conversation"]["can_manage"]
  end

  def test_can_manage_false_for_published_anon
    Space::Server::App["repos.conversations_repo"].update(@conv.id, published: true, updated_at: Time.now)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal false, data["props"]["conversation"]["can_manage"]
  end

  # ── G5: sessions flash ───────────────────────────────────────────────────

  def test_sessions_create_notice_flash
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "flash-test-uid",
      info: {nickname: "flashuser", name: "Flash User", email: nil, image: nil},
      credentials: nil
    )
    _, headers, _ = post("/auth/github/callback")
    flash = flash_from_redirect(headers)
    assert_equal "Signed in as flashuser.", flash["notice"]
  end

  def test_sessions_destroy_notice_flash
    sign_in(@owner)
    _, headers, _ = get("/logout")
    flash = flash_from_redirect(headers)
    assert_equal "Signed out.", flash["notice"]
  end

  def test_sessions_failure_alert_flash
    _, headers, _ = get("/auth/failure?message=access_denied")
    flash = flash_from_redirect(headers)
    assert_equal "Authentication failed: access_denied.", flash["alert"]
  end

  # ── Digest handshake — hermetic proof ────────────────────────────────────

  def test_version_header_prevents_409
    # Sending the correct digest → no stale-version 409
    status, _, _ = inertia_get("/conversations")
    assert_equal 200, status, "correct X-Inertia-Version must not trigger 409"
  end
end