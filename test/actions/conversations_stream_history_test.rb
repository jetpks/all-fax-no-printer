# frozen_string_literal: true

require_relative "action_test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/conversations/stream_key"

# Upward history pagination for the conversation live log: GET
# /conversations/:id/stream/history?before=<entry_id>&limit=N returns the
# at-most-N messages strictly before the entry, chronological, whole
# message boundaries, plus a `more` flag for the next page.
class ConversationsStreamHistoryActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "stream-hist-owner", username: "stream_hist_owner"]
    @other = Factory[:user, github_uid: "stream-hist-other", username: "stream_hist_other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis::LocalEndpoint
  end

  # `count` messages (message_start + delta each) with the message index in
  # the data JSON, returning the entry ids in insertion order.
  def seed_messages(redis_client, key, count)
    ids = []
    count.times do |i|
      ids << redis_client.xadd(key, "*", "type", "message_start", "data", %({"type":"message_start","seq":#{i}}))
      ids << redis_client.xadd(key, "*", "type", "text_delta", "data", %({"type":"text_delta","seq":#{i}}))
    end
    ids
  end

  # --- authz posture ------------------------------------------------------------------

  def test_history_missing_conversation_returns_404
    status, _, _ = get("/conversations/99999/stream/history")
    assert_equal 404, status
  end

  def test_history_anon_returns_401
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/conversations/#{conv.id}/stream/history?before=1-1")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_history_authenticated_non_owner_returns_403
    sign_in(@other)
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/conversations/#{conv.id}/stream/history?before=1-1")
    assert_equal 403, status
    assert parse_json(body).key?("error")
  end

  # --- windowing -----------------------------------------------------------------------

  def test_history_returns_window_before_id_with_more_flag
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      ids = seed_messages(redis_client, key, 3)

      # Before = message 2's message_start (the client holds messages 2+); one
      # page of one message → message 1 only; message 0 still below → more: true.
      status, _, body = get("/conversations/#{conv.id}/stream/history?before=#{ids[4]}&limit=1")
      assert_equal 200, status

      json = parse_json(body)
      assert_equal true, json["more"]
      seqs = json["events"].map { |e| e.dig("data", "seq") }.compact
      assert_equal [1, 1], seqs, "one whole message (boundaries), strictly before `before`"
      assert_equal [ids[2], ids[3]], json["events"].map { |e| e["id"] }, "chronological, real stream ids"

      # A page below the oldest message_start: nothing left → more: false.
      status, _, body = get("/conversations/#{conv.id}/stream/history?before=#{ids[0]}&limit=5")
      json = parse_json(body)
      assert_equal false, json["more"]
      assert_predicate json["events"], :empty?
    ensure
      redis_client&.close
    end
  end

  def test_history_without_before_defaults_to_the_full_backlog_tail
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      seed_messages(redis_client, key, 4)

      status, _, body = get("/conversations/#{conv.id}/stream/history?limit=2")
      json = parse_json(body)
      seqs = json["events"].map { |e| e.dig("data", "seq") }.compact
      assert_equal [2, 2, 3, 3], seqs, "no before → the last `limit` messages of everything"
      assert_equal true, json["more"]
    ensure
      redis_client&.close
    end
  end

  def test_history_returns_empty_when_redis_expired
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 2, published: false]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      redis_client.del(Space::Server::Conversations::StreamKey.for(conv.id))

      status, _, body = get("/conversations/#{conv.id}/stream/history?before=1-1")
      assert_equal 200, status
      json = parse_json(body)
      assert_equal [], json["events"]
      assert_equal false, json["more"], "expired display stream → nothing to page"
    ensure
      redis_client&.close
    end
  end
end
