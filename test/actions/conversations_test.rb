# frozen_string_literal: true

require_relative "action_test_helper"

# Basic contract tests for conversations index/show/publish/destroy and sessions.
# All render paths use inertia_get (X-Inertia) for hermetic, manifest-free tests.
class ConversationsActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "test-owner-uid", username: "owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_index_returns_200_inertia_page
    status, headers, body = inertia_get("/")
    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Conversations/Index", data["component"]
    assert_kind_of Array, data["props"]["conversations"]
  end

  def test_index_returns_only_published_conversations_for_anon
    Factory[:conversation, published: true]
    Factory[:conversation, published: false]
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conversations = data["props"]["conversations"]
    assert_equal 1, conversations.length
    assert conversations.first["published"]
  end

  # Recording logger stand-in — Sequel::Database#loggers accepts anything
  # responding to the Logger interface; #info is what Sequel calls per query.
  class SqlSpy
    attr_reader :statements
    def initialize = @statements = []
    def info(msg) = @statements << msg
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  # I36: the index must never load message rows — that's what pinned a web
  # fiber past falcon's 30s health-check timeout and produced the studio 502.
  def test_index_issues_no_message_queries
    conv = Factory[:conversation, user_id: @owner.id, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    connection = Space::Server::App["db.gateway"].connection
    spy = SqlSpy.new
    connection.loggers << spy
    inertia_get("/")
    connection.loggers.delete(spy)

    message_queries = spy.statements.select { |sql| sql.include?(%(FROM "messages")) }
    assert_equal 0, message_queries.length,
      "expected zero queries against messages, got #{message_queries.length}"
  end

  # --- pagination (I45) ---------------------------------------------------

  def test_index_pagination_default_page_1_capped_with_prop
    55.times { Factory[:conversation, published: true] }
    _, _, body = inertia_get("/")
    data = parse_json(body)
    assert_equal 50, data.dig("props", "conversations").length
    assert_equal({ "page" => 1, "has_more" => true }, data.dig("props", "pagination"))
  end

  def test_index_pagination_page_2_returns_remaining_rows
    55.times { |i| Factory[:conversation, published: true, updated_at: Time.now - i] }
    _, _, body = inertia_get("/", params: { page: 2 })
    data = parse_json(body)
    assert_equal 5, data.dig("props", "conversations").length
    assert_equal({ "page" => 2, "has_more" => false }, data.dig("props", "pagination"))
  end

  def test_index_pagination_invalid_page_defaults_to_1
    Factory[:conversation, published: true]
    _, _, body = inertia_get("/", params: { page: "abc" })
    assert_equal({ "page" => 1, "has_more" => false }, parse_json(body).dig("props", "pagination"))
  end

  def test_index_orders_by_updated_at_desc
    older = Factory[:conversation, published: true, updated_at: Time.now - 3600, created_at: Time.now - 7200]
    newer = Factory[:conversation, published: true, updated_at: Time.now, created_at: Time.now - 100]
    _, _, body = inertia_get("/")
    ids = parse_json(body)["props"]["conversations"].map { |c| c["id"] }
    assert_equal [newer.id, older.id], ids
  end

  def test_index_issues_no_message_queries_while_paging_page_2
    55.times { |i| Factory[:conversation, user_id: @owner.id, published: true, updated_at: Time.now - i] }
    conv = Factory[:conversation, user_id: @owner.id, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    connection = Space::Server::App["db.gateway"].connection
    spy = SqlSpy.new
    connection.loggers << spy
    inertia_get("/", params: { page: 2 })
    connection.loggers.delete(spy)

    message_queries = spy.statements.select { |sql| sql.include?(%(FROM "messages")) }
    assert_equal 0, message_queries.length,
      "expected zero queries against messages, got #{message_queries.length}"
  end

  def test_conversations_path_returns_index_component
    status1, _, body1 = inertia_get("/")
    status2, _, body2 = inertia_get("/conversations")
    assert_equal 200, status1
    assert_equal 200, status2
    assert_equal "Conversations/Index", parse_json(body1)["component"]
    assert_equal "Conversations/Index", parse_json(body2)["component"]
  end

  # --- conversations.show (GET /conversations/:id) ---

  def test_show_returns_200_for_published_conv_anon
    conv = Factory[:conversation, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hello" }], position: 1]

    status, headers, body = inertia_get("/conversations/#{conv.id}")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Conversations/Show", data["component"]
    assert_equal conv.id, data["props"]["conversation"]["id"]
    assert data["props"].key?("turns"), "props must include turns"
  end

  def test_show_redirects_302_for_anon_on_private_conv
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    status, headers, _ = get("/conversations/#{conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_returns_200_for_owner_on_private_conv
    sign_in(@owner)
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hello" }], position: 1]

    status, _, body = inertia_get("/conversations/#{conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal conv.id, data["props"]["conversation"]["id"]
    assert data["props"].key?("turns")
  end

  def test_show_includes_can_manage_in_props
    sign_in(@owner)
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    assert data["props"]["conversation"].key?("can_manage"), "props.conversation must include can_manage"
    assert_equal true, data["props"]["conversation"]["can_manage"]
  end

  def test_show_includes_parent_and_children_props_for_owner
    sign_in(@owner)
    parent = Factory[:conversation, published: false, user_id: @owner.id, session_id: "sess-parent"]
    conv = Factory[:conversation, published: false, user_id: @owner.id, session_id: "sess-child", parent_session_id: "sess-parent"]
    child = Factory[:conversation, published: false, user_id: @owner.id, session_id: "sess-grandchild", parent_session_id: "sess-child"]

    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    assert_equal parent.id, data["props"]["conversation"]["parent"]["id"]
    assert_equal [child.id], data["props"]["conversation"]["children"].map { |c| c["id"] }
    assert_equal "sess-grandchild", data["props"]["conversation"]["children"].first["session_id"]
  end

  def test_show_omits_parent_and_children_keys_for_non_owner
    other = Factory[:user, github_uid: "other-uid", username: "other"]
    sign_in(other)
    conv = Factory[:conversation, published: true, user_id: @owner.id, session_id: "sess-child", parent_session_id: "sess-parent"]

    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    refute data["props"]["conversation"].key?("parent"), "non-owner must not receive parent key"
    refute data["props"]["conversation"].key?("children"), "non-owner must not receive children key"
  end

  def test_show_omits_parent_and_children_keys_for_anonymous
    conv = Factory[:conversation, published: true, user_id: @owner.id, session_id: "sess-child", parent_session_id: "sess-parent"]

    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    refute data["props"]["conversation"].key?("parent"), "anon must not receive parent key"
    refute data["props"]["conversation"].key?("children"), "anon must not receive children key"
  end

  def test_show_returns_404_for_missing_conversation
    status, _, _ = inertia_get("/conversations/99999")
    assert_equal 404, status
  end

  def test_show_data_includes_turns
    conv = Factory[:conversation, published: true]
    Factory[:message, conversation_id: conv.id, role: "assistant",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    assert data["props"]["turns"].is_a?(Array)
  end

  # --- Error mapping: 404 ---

  def test_conversations_show_404_for_nonexistent_id
    status, headers, body = inertia_get("/conversations/0")
    assert_equal 404, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert data.key?("error")
  end

  def test_publish_unpublished_notice_says_published
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    _, headers, _ = patch("/conversations/#{conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Conversation published.", flash["notice"]
  end

  def test_publish_published_notice_says_unpublished
    conv = Factory[:conversation, user_id: @owner.id, published: true]
    sign_in(@owner)
    _, headers, _ = patch("/conversations/#{conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Conversation unpublished.", flash["notice"]
  end

  def test_publish_redirects_to_conversation
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    status, headers, _ = patch("/conversations/#{conv.id}/publish")
    assert_equal 302, status
    assert_equal "/conversations/#{conv.id}", headers["location"]
  end

  def test_destroy_redirects_to_root_with_notice
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    status, headers, _ = delete("/conversations/#{conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Conversation deleted.", flash["notice"]
  end

  # --- sessions seams ---

  def test_auth_callback_redirects
    status, _, _ = get("/auth/github/callback")
    assert_equal 302, status
  end

  def test_logout_get_redirects
    status, _, _ = get("/logout")
    assert_equal 302, status
  end
end
