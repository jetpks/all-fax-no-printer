# frozen_string_literal: true

require_relative "action_test_helper"

# G2/G3 (crux): B2 inversion — authz/visibility guards now redirect+flash.
# G3: Index scope (published ∪ owned; anon → published).
# G4: visible_messages data-scoping (snippet viewers get only published messages).
# G4: can_manage seam in show props.
#
# All render paths use inertia_get (X-Inertia). PATCH/DELETE guard rows use
# inertia_patch/inertia_delete to trigger the middleware 302→303 coercion.
class AuthzActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @conv_repo = Space::Server::App["repos.conversations_repo"]
    @msg_repo  = Space::Server::App["repos.messages_repo"]

    @owner    = Factory[:user, github_uid: "uid-owner", username: "owner"]
    @stranger = Factory[:user, github_uid: "uid-stranger", username: "stranger"]

    @conv = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1 = Factory[:message, conversation_id: @conv.id, role: "user",
                    content: [{ "type" => "text", "text" => "q" }], position: 1, published: false]
    @msg2 = Factory[:message, conversation_id: @conv.id, role: "assistant",
                    content: [{ "type" => "text", "text" => "a" }], position: 2, published: false]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── conversations/show — visibility guards ──────────────────────────────

  def test_show_anon_on_invisible_conv_redirects_302
    status, headers, _ = get("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_anon_on_invisible_conv_flash_sign_in_nudge
    _, headers, _ = get("/conversations/#{@conv.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to view this conversation.", flash["alert"]
  end

  def test_show_signed_in_non_owner_redirects_302
    sign_in(@stranger)
    status, headers, _ = get("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_signed_in_non_owner_flash_not_found
    sign_in(@stranger)
    _, headers, _ = get("/conversations/#{@conv.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Not found.", flash["alert"]
  end

  def test_show_owner_returns_200
    sign_in(@owner)
    status, _, body = inertia_get("/conversations/#{@conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal @conv.id, data["props"]["conversation"]["id"]
  end

  # G4: snippet viewer receives only published messages (via turns)
  def test_show_snippet_viewer_receives_only_published_turns
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    status, _, body = inertia_get("/conversations/#{@conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    all_message_ids = data["props"]["turns"].flat_map do |t|
      [t.dig("prompt", "id")].compact +
        t["rounds"].flat_map { |r| r["messages"].map { |m| m["id"] } }
    end
    assert_includes all_message_ids, @msg2.id,  "published message must be in turns"
    refute_includes all_message_ids, @msg1.id,  "unpublished message must not be in turns"
  end

  # G4: owner receives all messages
  def test_show_owner_receives_all_messages
    @msg_repo.update(@msg1.id, published: true, updated_at: Time.now)
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@owner)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    all_message_ids = data["props"]["turns"].flat_map do |t|
      [t.dig("prompt", "id")].compact +
        t["rounds"].flat_map { |r| r["messages"].map { |m| m["id"] } }
    end
    assert_includes all_message_ids, @msg1.id
    assert_includes all_message_ids, @msg2.id
  end

  # G4: can_manage seam
  def test_show_can_manage_for_owner
    sign_in(@owner)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal true,  data["props"]["conversation"]["can_manage"], "owner: can_manage must be true"
  end

  def test_show_no_can_manage_for_public_viewer_of_published_conv
    @conv_repo.update(@conv.id, published: true, updated_at: Time.now)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal false, data["props"]["conversation"]["can_manage"]
  end

  # ── conversations/publish + destroy — PATCH/DELETE → 303 with X-Inertia ──

  def test_publish_anon_redirects_302
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_publish_anon_flash_sign_in
    _, headers, _ = patch("/conversations/#{@conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_publish_non_owner_redirects_302
    sign_in(@stranger)
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_publish_non_owner_flash_not_authorized
    sign_in(@stranger)
    _, headers, _ = patch("/conversations/#{@conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_publish_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_patch("/conversations/#{@conv.id}/publish")
    assert_equal 303, status
  end

  def test_publish_owner_redirects_to_conversation
    sign_in(@owner)
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/conversations/#{@conv.id}", headers["location"]
  end

  def test_destroy_anon_redirects_302
    status, headers, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_destroy_non_owner_redirects_302
    sign_in(@stranger)
    status, _, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
  end

  def test_destroy_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_delete("/conversations/#{@conv.id}")
    assert_equal 303, status
  end

  def test_destroy_owner_redirects_to_root
    sign_in(@owner)
    status, headers, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # ── messages/publish ─────────────────────────────────────────────────────

  def test_message_publish_anon_redirects_302
    status, headers, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_message_publish_anon_flash_sign_in
    _, headers, _ = patch("/messages/#{@msg1.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_message_publish_non_owner_redirects_302
    sign_in(@stranger)
    status, _, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
  end

  def test_message_publish_non_owner_flash_not_authorized
    sign_in(@stranger)
    _, headers, _ = patch("/messages/#{@msg1.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_message_publish_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_patch("/messages/#{@msg1.id}/publish")
    assert_equal 303, status
  end

  def test_message_publish_owner_redirects_to_conversation
    sign_in(@owner)
    status, headers, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
    assert_match %r{/conversations/#{@conv.id}#message-#{@msg1.id}}, headers["location"]
  end

  # ── index scope ──────────────────────────────────────────────────────────

  def test_index_anon_returns_only_published_conversations
    pub_conv   = Factory[:conversation, published: true]
    _priv_conv = @conv

    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }

    assert_includes ids, pub_conv.id,  "published conv must appear for anon"
    refute_includes ids, @conv.id,     "private conv must not appear for anon"
  end

  def test_index_signed_in_user_sees_published_only_beyond_own
    pub_conv  = Factory[:conversation, published: true]
    own_conv  = @conv

    other_conv = Factory[:conversation, user_id: @owner.id, published: false]

    sign_in(@stranger)
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }

    assert_includes ids, pub_conv.id,    "published conv visible to everyone"
    refute_includes ids, other_conv.id,  "another user's private conv must not appear"
    refute_includes ids, own_conv.id,    "private conv of a different user must not appear"
  end

  def test_index_signed_in_owner_sees_own_conversations
    sign_in(@owner)
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, @conv.id, "owner must see own private conv"
  end

  def test_index_user_with_empty_org_ids_returns_safely
    sign_in(@stranger)
    status, _, body = inertia_get("/conversations")
    assert_equal 200, status
    data = parse_json(body)
    assert_kind_of Array, data["props"]["conversations"]
  end

  def test_index_conversation_list_json_key_set
    Factory[:conversation, published: true]
    _, _, body = inertia_get("/conversations")
    data = parse_json(body)
    conv = data["props"]["conversations"].first
    expected_keys = %w[id title status published turns_count owned agent_role agent_name model original_cwd space_id updated_at]
    expected_keys.each do |k|
      assert conv.key?(k), "conversation_list_json must include key #{k.inspect}"
    end
    assert_equal expected_keys.sort, conv.keys.sort, "key set must match exactly"
  end
end